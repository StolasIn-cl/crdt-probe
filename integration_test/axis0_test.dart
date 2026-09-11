import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/harness/scenarios/axis0_arrival_order.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('axis 0 runs and every scenario reaches a decided outcome', () async {
    final rt = await YjsRuntime.create();
    final runner = ScenarioRunner();
    final results = await runner.runAll(axis0Scenarios, rt);

    final report = renderReport('P1 axis 0', rt, axis0Scenarios, results, runner.traces);
    File('reports/p1-axis0.md').createSync(recursive: true);
    File('reports/p1-axis0.md').writeAsStringSync(report);
    // ignore: avoid_print
    print(report);

    // A Failed outcome here means the scenario's own convergence check tripped,
    // which is a real finding and must not be swallowed.
    for (final entry in results.entries) {
      expect(entry.value, isNot(isA<Failed>()), reason: 'scenario ${entry.key} failed');
    }

    // Structural assertions per the task-10 ruling: strong enough to be the
    // record for a measurement, but none of them judge which side won.
    // Axis 0 declares `requires: const {}`, so an `Unobservable` outcome here
    // would mean something is badly wrong, not a legitimate result.
    for (final s in axis0Scenarios) {
      final outcome = results[s.id];
      expect(outcome, isA<Passed>(), reason: 'scenario ${s.id} did not Pass');
      final evidence = (outcome as Passed).evidence;
      expect(evidence, isNotEmpty, reason: 'scenario ${s.id} evidence was empty');
      final trace = runner.traces[s.id];
      expect(trace, isNotNull, reason: 'scenario ${s.id} has no trace');
      expect(trace, isNotEmpty, reason: 'scenario ${s.id} trace was empty');
    }
  });
}
