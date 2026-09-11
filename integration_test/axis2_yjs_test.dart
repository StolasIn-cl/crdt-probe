import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenarios/axis2_undo.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Yjs Axis 2 scenarios produce a decided measurement report', () async {
    final runtime = await YjsRuntime.create();
    final runner = ScenarioRunner();
    final results = await runner.runAll(axis2Scenarios, runtime);
    final report = renderReport(
      'P3 Axis 2 — Yjs control group',
      runtime,
      axis2Scenarios,
      results,
      runner.traces,
    );
    File('reports/p3-axis2-yjs.md').writeAsStringSync('$report\n');
    // ignore: avoid_print
    print(report);

    expect(results.keys, containsAll(axis2Scenarios.map((s) => s.id)));

    // A Failed outcome is a real finding and must not be swallowed.
    for (final entry in results.entries) {
      expect(
        entry.value,
        isNot(isA<Failed>()),
        reason: 'scenario ${entry.key} failed',
      );
    }

    // Task 19 round 3, Finding 7: gate on whether Yjs actually covers each
    // scenario's `requires`, not on whether `requires` is empty. Yjs
    // declares both Capability.readUndoStackItems (S2.1-S2.6) and
    // Capability.decodeUpdate (S2.8 as of this round), so every scenario in
    // this list should be covered here and Unobservable would never be
    // legitimate on Yjs. Checking it explicitly, rather than assuming it
    // from `requires.isEmpty`, is what would have caught a false Passed if
    // that assumption were ever wrong.
    for (final s in axis2Scenarios) {
      final missing = runtime.capabilities.missingFrom(s.requires);
      final outcome = results[s.id];
      if (missing.isEmpty) {
        expect(outcome, isA<Passed>(),
            reason: 'scenario ${s.id} covers its requires but did not Pass');
        final evidence = (outcome as Passed).evidence;
        expect(evidence, isNotEmpty, reason: 'scenario ${s.id} evidence was empty');
        final trace = runner.traces[s.id];
        expect(trace, isNotNull, reason: 'scenario ${s.id} has no trace');
        expect(trace, isNotEmpty, reason: 'scenario ${s.id} trace was empty');
      } else {
        expect(outcome, isA<Unobservable>(),
            reason:
                'scenario ${s.id} is missing $missing, so only Unobservable is legitimate');
      }
    }
  });
}
