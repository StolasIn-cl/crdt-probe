import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/harness/scenarios/axis5_surviving_objections.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('axis 5 runs and every scenario reaches a decided outcome', () async {
    final rt = await YjsRuntime.create();
    final runner = ScenarioRunner();
    final results = await runner.runAll(axis5Scenarios, rt);

    final report = renderReport(
      'P1 axis 5',
      rt,
      axis5Scenarios,
      results,
      runner.traces,
    );
    File('reports/p1-axis5.md').createSync(recursive: true);
    File('reports/p1-axis5.md').writeAsStringSync('${report.trimRight()}\n');
    // ignore: avoid_print
    print(report);

    for (final entry in results.entries) {
      expect(
        entry.value,
        isNot(isA<Failed>()),
        reason: 'scenario ${entry.key} failed',
      );
    }
  });
}
