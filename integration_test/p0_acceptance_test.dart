import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/ui/probe_app.dart';

/// Drives the real [ProbeApp] (booting the real QuickJS-backed [YjsRuntime])
/// through the six checks P0's acceptance gate asks a human to confirm by
/// hand. Runs as an integration test — not a plain widget test — because
/// [ProbeApp] boots `YjsRuntime.create()`, which loads the native QuickJS
/// library and the `yjs_bridge.js` asset.

/// The label `Text` and its value/note `Text` inside one Inspector `_row`,
/// found by that row's `Key`. Scoping to the row (rather than searching the
/// whole tree for the unobservable string) is what lets this test tell
/// "this row is gated" from "some row somewhere is gated" — a global count
/// would still pass if the wrong two of the five gated-or-not rows were
/// swapped.
List<Text> rowTexts(WidgetTester tester, String rowKey) => tester
    .widgetList<Text>(find.descendant(
      of: find.byKey(Key(rowKey)),
      matching: find.byType(Text),
    ))
    .toList();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('P0 acceptance: two panes, post office, capability-honest inspector',
      (tester) async {
    await tester.pumpWidget(const ProbeApp());
    await tester.pumpAndSettle();

    // --- 1. Tapping "+ title" in the left pane makes a box appear there,
    // and an envelope appear in the right pane's inbox list. ---
    await tester.tap(find.byKey(const Key('pane-1-add-title')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-1-object-o0')), findsOneWidget,
        reason: 'the new title should appear as a box in the left pane');

    final releaseButton2 =
        tester.widget<TextButton>(find.byKey(const Key('inbox-2-release')));
    expect(releaseButton2.onPressed, isNotNull,
        reason: "the right pane's inbox should hold the envelope for o0");

    // --- 2. Tapping Release on the right inbox delivers it. ---
    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-2-object-o0')), findsOneWidget,
        reason: 'releasing the inbox should make the title appear in the right pane too');

    // --- 3. A drag on the left pane's title, then Release on the right,
    // leaves both panes reporting the same x AND y. The drag offset moves
    // both axes and _move issues a separate setField for each, so a
    // regression that broke only one axis must be caught. ---
    await tester.drag(find.byKey(const Key('pane-1-object-o0')), const Offset(37, 11));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();

    final leftBox = tester.widget<Positioned>(find.byKey(const Key('pane-1-object-o0')));
    final rightBox = tester.widget<Positioned>(find.byKey(const Key('pane-2-object-o0')));
    expect(rightBox.left, leftBox.left,
        reason: 'after syncing the drag, both panes should agree on x');
    expect(rightBox.top, leftBox.top,
        reason: 'after syncing the drag, both panes should agree on y');

    // --- 4. With the right pane toggled offline, an edit on the left
    // followed by Release delivers nothing. Proving non-delivery is only
    // meaningful if the envelope genuinely reached the held recipient's
    // queue first -- otherwise this step cannot distinguish "enqueued then
    // blocked" from "never sent" -- so check presence before demonstrating
    // the block, the same way step 1 does. ---
    await tester.tap(find.byKey(const Key('pane-2-online-toggle')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pane-1-add-title')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-1-object-o1')), findsOneWidget,
        reason: "the left pane creates o1 regardless of the right pane's connectivity");

    final releaseButton2WhileHeld =
        tester.widget<TextButton>(find.byKey(const Key('inbox-2-release')));
    expect(releaseButton2WhileHeld.onPressed, isNotNull,
        reason: "the envelope for o1 must have reached the held recipient's queue -- "
            "send() ignores hold, only take() blocks -- otherwise \"Release delivers "
            "nothing\" would be indistinguishable from \"nothing was ever sent\"");

    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-2-object-o1')), findsNothing,
        reason: 'a held recipient must receive nothing from Release');

    // --- 5. Toggling back online, then Drop, then Resync, catches the
    // right pane up from the server log. resyncFromServer pulls
    // unconditionally from the server log regardless of the client's own
    // queue, so "Drop then Resync succeeds" only proves the catch-up came
    // from the log -- rather than the queued envelope having been there all
    // along -- if Drop is shown to have actually emptied the queue first. ---
    await tester.tap(find.byKey(const Key('pane-2-online-toggle')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('inbox-2-drop')));
    await tester.pumpAndSettle();

    final releaseButton2AfterDrop =
        tester.widget<TextButton>(find.byKey(const Key('inbox-2-release')));
    expect(releaseButton2AfterDrop.onPressed, isNull,
        reason: 'Drop must actually empty the queue -- otherwise a later Resync succeeding '
            'would not prove the catch-up came from the server log rather than from the '
            'queued envelope having been there all along');

    await tester.tap(find.byKey(const Key('inbox-2-resync')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pane-2-object-o1')), findsOneWidget,
        reason: 'resync should pull o1 from the server log even though the queued '
            'envelope was dropped');

    // --- 6. The Inspector shows the three runtime-unsupported capabilities
    // as an explicit, non-blank "unobservable on <runtime>" note -- and,
    // just as importantly, the two supported capabilities do NOT. A count
    // alone cannot tell "these three rows are gated" from "some other three
    // of the five rows are gated"; scoping to each row by key can. ---
    const unobservable = 'unobservable on yjs-quickjs';

    for (final rowKey in [
      'inspector-row-tombstones',
      'inspector-row-per-character-identity',
    ]) {
      final texts = rowTexts(tester, rowKey);
      expect(texts.length, 2, reason: '$rowKey should have a label and one value/note');
      expect(texts[1].data, unobservable,
          reason: '$rowKey lacks the capability and must render the explicit '
              'unobservable note, never a blank value');
    }

    final undoTexts = rowTexts(tester, 'inspector-row-undo-stack-items');
    expect(undoTexts.length, 2,
        reason: 'undo stack row should have a label and one value');
    expect(undoTexts[1].data, matches(RegExp(r'^undo \d+ / redo \d+$')),
        reason: 'Yjs now exposes measurable undo and redo stack lengths');
    expect(find.byKey(const Key('inspector-undo')), findsOneWidget);
    expect(find.byKey(const Key('inspector-redo')), findsOneWidget);

    for (final rowKey in ['inspector-row-state-vector', 'inspector-row-format-markers']) {
      final texts = rowTexts(tester, rowKey);
      expect(texts.length, 2, reason: '$rowKey should have a label and one value/note');
      expect(texts[1].data, isNot(unobservable),
          reason: '$rowKey has the capability and must render its (possibly empty) '
              'value, not the unobservable note meant for capabilities the runtime lacks');
    }
  });
}
