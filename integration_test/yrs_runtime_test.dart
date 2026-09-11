import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late YrsRuntime first;
  late YrsRuntime second;
  const a = ClientId(1);
  const b = ClientId(2);
  const title = ObjectId('yrs-title');

  setUp(() async {
    first = await YrsRuntime.create();
    second = await YrsRuntime.create();
    await first.open(a);
    await second.open(b);
  });

  tearDown(() async {
    await first.close(a);
    await second.close(b);
  });

  test('creates a title and applies its V1 update to another Yrs document', () async {
    await first.createObject(a, title, ObjectKind.title, x: 10, y: 20, w: 100, h: 40);
    await first.insertText(a, title, 0, 'Hello');
    for (final update in await first.drainOutbox(a)) {
      await second.applyUpdate(b, update);
    }

    final projection = await second.projection(b);
    expect(projection.clientId, b);
    expect(projection.objects[title]!.text, 'Hello');
    expect(projection.objects[title]!.x, 10);
  });

  test('reads Yrs formatting chunks as the shared delta projection', () async {
    await first.createObject(a, title, ObjectKind.title, x: 0, y: 0, w: 10, h: 10);
    await first.insertText(a, title, 0, 'abcdef');
    await first.formatText(a, title, 2, 2, {'bold': true});

    final delta = (await first.projection(a)).objects[title]!.delta!;
    expect(delta.any((chunk) => (chunk['attributes'] as Map?)?['bold'] == true), isTrue);
  });

  test('local edits produce non-empty V1 outbox diffs', () async {
    await first.createObject(a, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    final creation = await first.drainOutbox(a);
    expect(creation, isNotEmpty);
    await first.insertText(a, title, 0, 'X');
    final insertion = await first.drainOutbox(a);
    expect(insertion, hasLength(1));
    expect(insertion.single, isNotEmpty);
  });

  test('Yrs undo and redo round-trip the latest local text edit', () async {
    // Task 20: `setUp` opens without undo (the new default); re-open `first`
    // with `undo: true` before any content exists, matching the eager
    // construction the Yjs bridge now also requires.
    await first.open(a, undo: true);
    await first.createObject(a, title, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
    await first.insertText(a, title, 0, 'before');
    await first.stopCapturing(a);
    await first.insertText(a, title, 6, ' after');

    expect(await first.undo(a), isTrue);
    expect((await first.projection(a)).objects[title]!.text, 'before');
    expect(await first.redo(a), isTrue);
    expect((await first.projection(a)).objects[title]!.text, 'before after');
  });
}
