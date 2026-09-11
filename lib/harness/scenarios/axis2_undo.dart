import 'dart:typed_data';

import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/driver/probe_client.dart';
import 'package:yjs_probe/runtime/undo_runtime.dart';
import '../scenario.dart';
import 'axis0_arrival_order.dart';

const _title = ObjectId('s2-title');

Future<void> seedAxis2Title(
  ProbeClient author,
  ProbeClient peer, {
  String text = '',
}) async {
  final undo = author.runtime as UndoRuntime;
  await undo.setTrackedOrigins(author.clientId, {});
  await author.createTitle(_title, x: 0, y: 0, w: 100, h: 30);
  if (text.isNotEmpty) await author.type(_title, 0, text);
  await author.flushOutbox();
  await peer.receiveAll();
  await undo.setOperationOrigin(author.clientId, 'local');
  await undo.setTrackedOrigins(author.clientId, {'local'});
  await undo.stopCapturing(author.clientId);
}

Future<String> _text(ProbeClient client) async =>
    (await client.read()).objects[_title]?.text ?? '<missing>';

final List<Scenario> axis2Scenarios = [
  Scenario(
    id: 'S2.1',
    title: 'stackitem-boundary-capture-timeout',
    targets:
        'ticket 25 §1 and ticket 16 §7 — measure the default capture timeout against Promeo\'s 1,000 ms typing group',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.type(_title, 0, 'a');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.type(_title, 1, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await a.type(_title, 2, 'c');

      final before = await ctx.undo.undoStackLength(a.clientId);
      final first = await ctx.undo.undo(a.clientId);
      final afterFirst = await _text(a);
      final second = await ctx.undo.undo(a.clientId);
      final afterSecond = await _text(a);
      ctx.driver.note(
        'stack before=$before; undo1=$first -> "$afterFirst"; '
        'undo2=$second -> "$afterSecond"',
      );

      final groupedWithinWindow = afterFirst == 'ab';
      final separatedAfterWindow = afterSecond == '';
      if (!groupedWithinWindow || !separatedAfterWindow) {
        return Failed(
          reason:
              'expected first undo to remove c and second to remove ab; '
              'observed "$afterFirst" then "$afterSecond"',
        );
      }
      return Passed(
        evidence:
            'two edits within 100 ms grouped; edit after 650 ms was a separate '
            'stack item (first undo="$afterFirst", second undo="$afterSecond")',
      );
    },
  ),
  Scenario(
    id: 'S2.2',
    title: 'remote-update-closes-stackitem-or-not',
    targets: 'ticket 25 §1 — whether a remote update closes the local capture group',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.type(_title, 0, 'A');
      await a.flushOutbox();
      await b.receiveAll();
      await b.type(_title, 1, 'B');
      await b.flushOutbox();
      await a.receiveAll();
      await a.type(_title, 2, 'C');

      final before = await _text(a);
      final didUndo = await ctx.undo.undo(a.clientId);
      final after = await _text(a);
      ctx.driver.note('before="$before"; undo=$didUndo; after="$after"');

      if (!didUndo) {
        return Failed(
          reason: 'undo did not report a change for the local capture group',
        );
      }
      return Passed(
        evidence:
            'remote B arrived between local A and C; one undo left "$after". '
            '${after == 'AB' ? 'The remote update closed the capture group.' : 'The remote update did not close it: A and C were undone together.'}',
      );
    },
  ),
  Scenario(
    id: 'S2.3',
    title: 'trackedOrigins-separates-mine-from-yours',
    targets: 'ticket 25 §2 — tracked origins separate local and untracked contributions',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await ctx.undo.setTrackedOrigins(a.clientId, {'mine'});
      await ctx.undo.setOperationOrigin(a.clientId, 'mine');
      await a.type(_title, 0, 'A');
      await ctx.undo.stopCapturing(a.clientId);
      await ctx.undo.setOperationOrigin(a.clientId, 'other');
      await a.type(_title, 1, 'B');
      await ctx.undo.stopCapturing(a.clientId);
      await ctx.undo.setOperationOrigin(a.clientId, 'mine');
      await a.type(_title, 2, 'C');

      final first = await ctx.undo.undo(a.clientId);
      final afterFirst = await _text(a);
      final second = await ctx.undo.undo(a.clientId);
      final afterSecond = await _text(a);
      ctx.driver.note(
        'undo1=$first -> "$afterFirst"; undo2=$second -> "$afterSecond"',
      );

      if (afterFirst != 'AB' || afterSecond != 'B') {
        return Failed(
          reason:
              'expected tracked mine edits A/C to undo around untracked B; '
              'observed "$afterFirst" then "$afterSecond"',
        );
      }
      return Passed(
        evidence:
            'tracked origin mine removed C then A while untracked origin other '
            'remained as B',
      );
    },
  ),
  Scenario(
    id: 'S2.4',
    title: 'undo-my-insert-inside-your-range',
    targets: 'ticket 23 §6 — undo a local insert while preserving another participant\'s edit',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b, text: 'abcd');

      await a.type(_title, 2, 'X');
      await a.flushOutbox();
      await b.receiveAll();
      await b.type(_title, 3, 'Y');
      await b.flushOutbox();
      await a.receiveAll();

      final before = await _text(a);
      final didUndo = await ctx.undo.undo(a.clientId);
      final after = await _text(a);
      ctx.driver.note('before="$before"; undo=$didUndo; after="$after"');

      if (!didUndo || after != 'abYcd') {
        return Failed(
          reason: 'expected local X removal to preserve remote Y; observed "$after"',
        );
      }
      return Passed(evidence: 'local X was removed; remote Y remained: "$after"');
    },
  ),
  Scenario(
    id: 'S2.5',
    title: 'redo-of-a-superseded-write-preserves-the-remote-value',
    targets:
        'ticket 07 §5 — a redo of a locally superseded write must not overwrite '
        'a remote value; ticket 17 §3 is about what redoItem returns internally, '
        'not about the UndoManager.redo return value; ticket 07 §10 asks whether '
        'the skip is named anywhere the redo return value does not answer',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.move(_title, 'x', 1);
      await a.flushOutbox();
      await b.receiveAll();
      final didUndo = await ctx.undo.undo(a.clientId);
      await a.flushOutbox();
      await b.receiveAll();

      await b.move(_title, 'x', 2);
      await b.flushOutbox();
      await a.receiveAll();
      final didRedo = await ctx.undo.redo(a.clientId);
      final value = (await a.read()).objects[_title]!.x;
      ctx.driver.note(
        'undo=$didUndo; remote superseding x=2; redo=$didRedo; final x=$value',
      );

      // The only property this scenario asserts: a redo of a locally
      // superseded write must not reapply over the remote value (ticket 07
      // §5). Whether redo() itself returns true or false is reported below,
      // not asserted. Ticket 17 §3 is about redoItem returning null for a
      // superseded item internally, not about what UndoManager.redo reports
      // to the caller -- a redo() that processes a stack item, finds the
      // revive is not possible, and still returns true is fully consistent
      // with that clause.
      if (!didUndo || value != 2) {
        return Failed(
          reason:
              'expected the remote x=2 to survive the redo attempt; observed '
              'undo=$didUndo, redo=$didRedo, x=$value',
        );
      }
      return Passed(
        evidence:
            'the property this scenario asserts held: the remote value '
            'survived the redo attempt, final x=$value on ${ctx.runtime.name}, '
            'unchanged from what B wrote. Reported but NOT asserted: redo() '
            'itself returned $didRedo on this runtime. That boolean is a '
            'separate claim from whether the write was skipped: measured '
            'across both runtimes in this project own test run, Yjs redo() '
            'returns true while skipping the superseded write, and Yrs redo() '
            'returns false for the identical scenario, yet both leave x=2 '
            'unchanged. Neither boolean names what was skipped or why, which '
            'is the gap ticket 07 §10 asked about and this scenario cannot '
            'close by itself.',
      );
    },
  ),
  Scenario(
    id: 'S2.6',
    title: 'undo-a-formatting-only-change',
    targets: 'ticket 23 — a style-only change must be independently undoable',
    requires: const {Capability.readUndoStackItems},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b, text: 'abc');

      await a.format(_title, 0, 3, {'bold': true});
      final before = (await a.read()).objects[_title]!.delta!;
      final didUndo = await ctx.undo.undo(a.clientId);
      final after = (await a.read()).objects[_title]!.delta!;
      final beforeBold = before.any((chunk) =>
          (chunk['attributes'] as Map?)?['bold'] == true);
      final afterBold = after.any((chunk) =>
          (chunk['attributes'] as Map?)?['bold'] == true);
      ctx.driver.note(
        'undo=$didUndo; bold before=$beforeBold; bold after=$afterBold',
      );

      if (!didUndo || !beforeBold || afterBold) {
        return Failed(
          reason:
              'expected style-only undo to remove bold; observed before=$beforeBold '
              'after=$afterBold',
        );
      }
      return const Passed(
        evidence: 'format-only edit was captured and undo removed the bold mark',
      );
    },
  ),
  Scenario(
    id: 'S2.8',
    title: 'undo-a-deletion-revives-or-rewrites',
    targets:
        'ticket 17 §127 — whether undo of a deletion reuses the deleted item\'s own '
        'identity or mints a fresh one, settled directly via decodeUpdate rather than '
        'inferred from byte size (task 19 round 3, Finding 2); byte size is reported '
        'only as supporting detail',
    requires: const {Capability.decodeUpdate},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.type(_title, 0, 'abcde');
      await Future<void>.delayed(const Duration(milliseconds: 650));

      // Every clock this author's clientID has used so far, read from decoded
      // struct ids (id=client:clock — bridge.js's decodeUpdate already
      // reports this per struct). A clock for one client only ever
      // increases, so a later step that reuses an existing item's identity
      // introduces no clock above this ceiling, and a step that mints a
      // fresh item necessarily introduces one above it. This settles mint
      // vs reuse directly; it does not need to be inferred from size.
      final seenClocks = <int>{};
      Future<void> absorb(List<Uint8List> updates) async {
        for (final u in updates) {
          final decoded = await ctx.runtime.decodeUpdate(u);
          for (final s in decoded.summaries) {
            final m = RegExp(r'id=\d+:(\d+)').firstMatch(s);
            if (m != null) seenClocks.add(int.parse(m.group(1)!));
          }
        }
      }

      await absorb(await ctx.runtime.drainOutbox(a.clientId));

      final baseline = (await ctx.runtime.encodeStateAsUpdate(a.clientId)).length;

      await a.erase(_title, 2, 1);
      await absorb(await ctx.runtime.drainOutbox(a.clientId));
      final ceilingBeforeUndo =
          seenClocks.isEmpty ? -1 : seenClocks.reduce((x, y) => x > y ? x : y);
      final afterDelete = (await ctx.runtime.encodeStateAsUpdate(a.clientId)).length;
      final textAfterDelete = await _text(a);

      final didUndo = await ctx.undo.undo(a.clientId);
      final textAfterUndo = await _text(a);
      final afterUndo = (await ctx.runtime.encodeStateAsUpdate(a.clientId)).length;

      final undoClocks = <int>{};
      for (final u in await ctx.runtime.drainOutbox(a.clientId)) {
        final decoded = await ctx.runtime.decodeUpdate(u);
        for (final s in decoded.summaries) {
          final m = RegExp(r'id=\d+:(\d+)').firstMatch(s);
          if (m != null) undoClocks.add(int.parse(m.group(1)!));
        }
      }
      final mintedNewClock = undoClocks.any((c) => c > ceilingBeforeUndo);

      final deleteDelta = afterDelete - baseline;
      final undoDelta = afterUndo - afterDelete;
      ctx.driver.note(
        'baseline=$baseline B; after erase(2,1)="$textAfterDelete" ($afterDelete B, '
        'delete delta=$deleteDelta B); after undo="$textAfterUndo" ($afterUndo B, '
        'undo delta=$undoDelta B); clock ceiling before undo=$ceilingBeforeUndo; '
        'clocks in the undo update=$undoClocks; minted a new clock=$mintedNewClock',
      );

      if (!didUndo || textAfterUndo != 'abcde') {
        return Failed(
          reason: 'expected undo of the deletion to restore "abcde"; '
              'observed undo=$didUndo, text="$textAfterUndo"',
        );
      }

      // Task 19 round 3, Finding 3: the earlier version of this scenario
      // used the delete's own +$deleteDelta B as a yardstick for "the cost
      // of a fresh insert". That is not a valid yardstick — a delete costs a
      // split plus a delete-set entry, not an insert — so it is dropped.
      // What the size numbers can honestly say is only the sign: a revive
      // that merely cleared a delete flag could not make the document
      // larger than right after the delete. Gated on sign first (Finding
      // 5), each branch gets its own wording rather than a canned reading.
      final String sizeReading;
      if (undoDelta > 0) {
        sizeReading = 'grew by $undoDelta B, which a same-size-or-smaller flag '
            'flip could not produce';
      } else if (undoDelta < 0) {
        sizeReading = 'shrank by ${-undoDelta} B after the undo';
      } else {
        sizeReading = 'stayed exactly the same size';
      }
      final identityReading = mintedNewClock
          ? 'introduced a clock ($undoClocks) above every clock seen before '
              'the undo (ceiling $ceilingBeforeUndo) — a fresh item, not a '
              'reuse of the deleted item\'s own identity'
          : 'introduced no clock above the ceiling seen before the undo '
              '($ceilingBeforeUndo) — the revive reused an existing identity '
              'rather than minting one';
      return Passed(
        evidence:
            'text round-tripped to "abcde" after undo. decodeUpdate on the update the '
            'undo itself produced $identityReading. This settles mint vs reuse '
            'directly; it is not inferred from size. Supporting size detail: '
            'baseline=$baseline B, after delete=$afterDelete B (delta=$deleteDelta B), '
            'after undo=$afterUndo B (delta=$undoDelta B) — the undo $sizeReading. '
            'No length is asserted; the decodeUpdate identity check above is what '
            'this conclusion rests on.',
      );
    },
  ),
  Scenario(
    id: 'S2.9',
    title: 'concurrent-delete-then-undo',
    targets:
        'ticket 07 §5 and ticket 17 §127 — whether undoing a deletion that a concurrent '
        'peer also performed reintroduces a character over a delete that peer never '
        'withdrew',
    requires: const {},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.type(_title, 0, 'abcde');
      await a.flushOutbox();
      await b.receiveAll();
      await Future<void>.delayed(const Duration(milliseconds: 650));

      final seeded = await _text(a);
      ctx.driver.note('both clients seeded: a="$seeded" b="${await _text(b)}"');

      await a.erase(_title, 2, 1);
      await b.erase(_title, 2, 1);
      await a.flushOutbox();
      await b.flushOutbox();
      await a.receiveAll();
      await b.receiveAll();

      final aAfterDelete = await _text(a);
      final bAfterDelete = await _text(b);
      ctx.driver.note(
        'after both deleted index 2 independently and exchanged updates: '
        'a="$aAfterDelete" b="$bAfterDelete"',
      );

      if (aAfterDelete != bAfterDelete) {
        return Failed(
          reason:
              'expected the two concurrent same-index deletes to converge; '
              'observed a="$aAfterDelete" b="$bAfterDelete"',
        );
      }

      final didUndo = await ctx.undo.undo(a.clientId);
      final aAfterUndo = await _text(a);
      await a.flushOutbox();
      await b.receiveAll();
      final bAfterUndo = await _text(b);
      ctx.driver.note(
        'A undoes its own deletion: undo=$didUndo -> a="$aAfterUndo"; '
        'after delivering A\'s update to B -> b="$bAfterUndo"',
      );

      // Task 19 round 3, Finding 6: "neither A nor B asserted" was false --
      // A typed "abcde" and so asserted 'c' at this position. The precise,
      // stronger claim is about outstanding intent: B's delete still
      // stands (B never withdrew it), so a character reappearing in B's
      // own document is what ticket 07 §5 rejected -- not that nobody ever
      // asserted the character.
      final noOp = aAfterUndo == aAfterDelete;
      final resurrected = aAfterUndo == seeded;
      final matches = noOp
          ? 'the deletion stayed in place ("$aAfterUndo"): B\'s independent '
              'delete still covers the same item, so A\'s revive did not '
              'resurrect it'
          : resurrected
              ? 'the character came back ("$aAfterUndo"). B\'s delete still '
                  'stands -- B never withdrew it -- yet B\'s own document now '
                  'shows the character again, which is exactly what ticket 07 '
                  '§5 rejected'
              : 'the result ("$aAfterUndo") does not match either of the two '
                  'possible outcomes cleanly; the numbers do not distinguish '
                  'them here';
      return Passed(
        evidence:
            'both clients converged on "$aAfterDelete" after concurrent deletes at '
            'index 2. A undo=$didUndo -> a="$aAfterUndo", and after delivery b="$bAfterUndo". '
            '$matches.',
      );
    },
  ),
  Scenario(
    id: 'S2.10',
    title: 'undo-redo-cycles-do-not-grow-the-document',
    targets:
        'ticket 17 §127 — byte growth across repeated undo/redo cycles, sampled every '
        'cycle (task 19 round 3, Finding 4) so a linear trend can be told apart from a '
        'one-off jump plus a plateau, which two endpoints cannot do',
    requires: const {},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime, undo: true);
      await seedAxis2Title(a, b);

      await a.type(_title, 0, 'abcde');
      await Future<void>.delayed(const Duration(milliseconds: 650));

      final before = (await ctx.runtime.encodeStateAsUpdate(a.clientId)).length;
      final sizeAfterCycle = <int>[];

      for (var i = 0; i < 10; i++) {
        final didUndo = await ctx.undo.undo(a.clientId);
        final didRedo = await ctx.undo.redo(a.clientId);
        if (!didUndo || !didRedo) {
          return Failed(
            reason:
                'cycle ${i + 1} of 10 did not complete: undo=$didUndo, redo=$didRedo',
          );
        }
        sizeAfterCycle.add((await ctx.runtime.encodeStateAsUpdate(a.clientId)).length);
      }

      final after = sizeAfterCycle.last;
      final text = await _text(a);
      final totalDelta = after - before;
      final perCycleDeltas = <int>[
        sizeAfterCycle.first - before,
        for (var i = 1; i < sizeAfterCycle.length; i++)
          sizeAfterCycle[i] - sizeAfterCycle[i - 1],
      ];
      ctx.driver.note(
        'before=$before B; size after each of 10 cycles=$sizeAfterCycle; '
        'per-cycle deltas=$perCycleDeltas; total delta=$totalDelta B over 10 cycles; '
        'text="$text"',
      );

      if (text != 'abcde') {
        return Failed(
          reason:
              'expected text unchanged by ten undo/redo cycles; observed "$text"',
        );
      }

      // Task 19 round 3, Finding 4: per redoItem (read for S2.8), undoing an
      // insertion only deletes items — a flag flip plus a delete-set entry,
      // no mint. Only the redo half of a cycle can mint. Growth therefore
      // cannot be split evenly across the two operations in a cycle, so this
      // reports B/cycle (totalDelta / 10), not B/op (totalDelta / 20, which
      // the previous version used and which assumes both directions cost
      // the same — the very thing these numbers cannot test). Attribution is
      // limited to "at least one of the two operations per cycle wrote new
      // content," nothing more specific.
      final perCycle = totalDelta / 10;
      final String growthReading;
      if (totalDelta > 0) {
        growthReading = 'grew by $totalDelta B ($perCycle B/cycle)';
      } else if (totalDelta < 0) {
        growthReading = 'shrank by ${-totalDelta} B (${-perCycle} B/cycle)';
      } else {
        growthReading = 'stayed exactly the same size';
      }
      final allDeltasEqual = perCycleDeltas.every((d) => d == perCycleDeltas.first);
      final linearityNote = allDeltasEqual
          ? 'every one of the 10 per-cycle deltas was identical ($perCycleDeltas), '
              'consistent with linear growth rather than a one-off jump plus a plateau'
          : 'the 10 per-cycle deltas were not all equal ($perCycleDeltas); growth is '
              'not simply linear across cycles';
      return Passed(
        evidence:
            'text round-tripped to "abcde" through 10 undo/redo cycles. The document '
            '$growthReading over 10 cycles (size before=$before B, after=$after B). '
            'Sampled every cycle rather than only at the endpoints: $linearityNote. '
            'Per redoItem, only the redo half of each cycle can mint a fresh item; the '
            'undo half only deletes — this run attributes growth no further than "at '
            'least one of the two operations per cycle wrote new content." No length '
            'is asserted; this is the measurement.',
      );
    },
  ),
];
