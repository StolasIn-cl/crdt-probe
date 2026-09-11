import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';
import 'package:yjs_probe/runtime/undo_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late YjsRuntime rt;
  const alice = ClientId(1);
  const bob = ClientId(2);
  const title = ObjectId('t1');

  setUp(() async {
    rt = await YjsRuntime.create();
    await rt.open(alice);
    await rt.open(bob);
  });

  test('declares the capabilities Yjs actually has', () {
    expect(rt.capabilities.has(Capability.decodeUpdate), isTrue);
    expect(rt.capabilities.has(Capability.countPendingStructs), isTrue);
    expect(rt.capabilities.has(Capability.enumeratePerCharacterIdentity), isFalse);
  });

  // Regression for the trackedOrigins self-registration bug: Yjs's
  // UndoManager registers ITSELF in trackedOrigins in its constructor
  // (dist/yjs.cjs:3632) so it can recognise the transaction its own undo()
  // produces (transaction.origin is set to the manager instance) and push
  // the reverse StackItem onto the redo stack. bridge.js's setTrackedOrigins
  // used to call trackedOrigins.clear() without re-adding that
  // self-registration, which silently killed redo() forever on any client
  // that had ever called setTrackedOrigins — exactly what seedAxis2Title
  // does for every axis-2 scenario. Verified this test fails against the
  // clear()-only version by reverting the fix, rebuilding the bridge bundle,
  // and re-running: didUndo=true but redoStackLength stayed 0 and
  // didRedo=false; restored the fix and rebuilt before continuing.
  test("setTrackedOrigins preserves the UndoManager's own redo capability", () async {
    // Task 20: `setUp` opens both clients without undo (the new default), so
    // this test — which needs one — re-opens alice with `undo: true` before
    // any content exists. `createDoc` unconditionally builds a fresh Y.Doc
    // for a clientId (see axis0_arrival_order.dart's `pairOn` doc comment),
    // so this is safe and is exactly the opt-in timing the fix requires.
    await rt.open(alice, undo: true);
    final undo = rt as UndoRuntime;
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    await rt.insertText(alice, title, 0, 'abcde');
    await undo.setTrackedOrigins(alice, {'local'});
    await undo.stopCapturing(alice);
    await Future<void>.delayed(const Duration(milliseconds: 650));

    expect(await undo.undo(alice), isTrue);
    expect((await rt.projection(alice)).objects[title]?.text ?? '', isNot('abcde'));
    expect(
      await undo.redoStackLength(alice),
      greaterThan(0),
      reason: 'undo must push the reverse StackItem onto the redo stack',
    );
    expect(await undo.redo(alice), isTrue);
    expect((await rt.projection(alice)).objects[title]!.text, 'abcde');
  });

  test('a created title reaches the other client with its box and text', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 10, y: 20, w: 100, h: 40);
    await rt.insertText(alice, title, 0, 'Hello');

    for (final u in await rt.drainOutbox(alice)) {
      await rt.applyUpdate(bob, u);
    }

    final p = await rt.projection(bob);
    expect(p.objects[title]!.kind, 'title');
    expect(p.objects[title]!.x, 10);
    expect(p.objects[title]!.text, 'Hello');
  });

  test('formatting is visible in the delta projection', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 10, h: 10);
    await rt.insertText(alice, title, 0, 'abcdef');
    await rt.formatText(alice, title, 2, 2, {'bold': true});

    final delta = (await rt.projection(alice)).objects[title]!.delta!;
    expect(delta.any((op) => (op['attributes'] as Map?)?['bold'] == true), isTrue);
  });

  test('an update can be decoded into structs', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 10, h: 10);
    final updates = await rt.drainOutbox(alice);
    final decoded = await rt.decodeUpdate(updates.first);
    expect(decoded.structCount, greaterThan(0));
    expect(decoded.summaries, isNotEmpty);
  });

  // --- Task 3 resolution #6: Task 2's fromJson parsers ship untested. This is
  // the first thing that exercises them against a real bridge projection, so
  // round-trip a title (text/delta non-null, src null) and an image (the
  // reverse) through the actual JS bridge rather than through hand-built JSON.

  test('a title object round-trips through DocProjection with a null src', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 1, y: 2, w: 3, h: 4, rotation: 5, z: 6);
    await rt.insertText(alice, title, 0, 'hi');

    final p = await rt.projection(alice);
    final o = p.objects[title]!;
    expect(p.clientId, alice);
    expect(o.kind, 'title');
    expect(o.x, 1);
    expect(o.y, 2);
    expect(o.w, 3);
    expect(o.h, 4);
    expect(o.rotation, 5);
    expect(o.z, 6);
    expect(o.text, 'hi');
    expect(o.delta, isNotNull);
    expect(o.src, isNull);
  });

  test('an image object round-trips through DocProjection with null text/delta', () async {
    const image = ObjectId('i1');
    await rt.createObject(
      alice,
      image,
      ObjectKind.image,
      x: 7,
      y: 8,
      w: 9,
      h: 10,
      src: 'https://example.test/a.png',
    );

    final p = await rt.projection(alice);
    final o = p.objects[image]!;
    expect(o.kind, 'image');
    expect(o.x, 7);
    expect(o.y, 8);
    expect(o.w, 9);
    expect(o.h, 10);
    expect(o.src, 'https://example.test/a.png');
    expect(o.text, isNull);
    expect(o.delta, isNull);
  });

  test('pendingStructCount reads zero on a doc with nothing withheld', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    expect(await rt.pendingStructCount(alice), 0);
  });

  test('pendingStructCount rises while a causal dependency is withheld, and clears once supplied', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    final creation = await rt.drainOutbox(alice);
    await rt.insertText(alice, title, 0, 'X');
    final insertion = await rt.drainOutbox(alice);

    // Apply the insertion before the creation it structurally depends on —
    // bob has no structs from alice yet, so the insertion's item (parented to
    // a Y.Text minted during the withheld creation update) cannot be
    // integrated and is held in doc.store.pendingStructs.
    for (final u in insertion) {
      await rt.applyUpdate(bob, u);
    }
    expect(await rt.pendingStructCount(bob), greaterThan(0));

    for (final u in creation) {
      await rt.applyUpdate(bob, u);
    }
    expect(await rt.pendingStructCount(bob), 0);
    expect((await rt.projection(bob)).objects[title]!.text, 'X');
  });

  // Regression: `doc.on('update', ...)` fires for a remote-applied update too
  // (Yjs gates only on hasContent, not on transaction.local/origin), so
  // without filtering the outbox listener on origin === 'local', a client
  // that only ever *received* content would re-broadcast it on its own next
  // flush — inflating server sequence numbers and corrupting the
  // arrival-order measurements this project exists to make.
  test('receiving content never populates the outbox of the receiving client', () async {
    await rt.createObject(alice, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    await rt.insertText(alice, title, 0, 'seed');
    for (final u in await rt.drainOutbox(alice)) {
      await rt.applyUpdate(bob, u);
    }

    // Bob has only ever applied remote content so far — its outbox must be empty.
    expect(await rt.drainOutbox(bob), isEmpty);

    // Bob now makes its own edit; its outbox must contain exactly that edit's
    // update, not a re-broadcast of the seeded content it received earlier.
    await rt.insertText(bob, title, 4, '!');
    final bobOutbox = await rt.drainOutbox(bob);
    expect(bobOutbox, hasLength(1));

    for (final u in bobOutbox) {
      await rt.applyUpdate(alice, u);
    }
    expect((await rt.projection(alice)).objects[title]!.text, 'seed!');
  });
}
