import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/harness/scenarios/axis6_formatting_marks.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('axis 6 runs and every scenario reaches a decided outcome', () async {
    final runtime = await YjsRuntime.create();
    final runner = ScenarioRunner();
    final results = await runner.runAll(axis6Scenarios, runtime);
    final report = [
      '## Scope',
      '',
      'This is Yjs-only evidence from the QuickJS probe. It does not assert '
          'Yrs parity and does not reopen runtime adoption.',
      '',
      renderReport(
        'P2 axis 6',
        runtime,
        axis6Scenarios,
        results,
        runner.traces,
      ),
    ].join('\n');
    File('reports/p2-axis6.md').createSync(recursive: true);
    File('reports/p2-axis6.md').writeAsStringSync('${report.trimRight()}\n');
    // ignore: avoid_print
    print(report);

    expect(
      axis6Scenarios.map((s) => s.id),
      containsAll(<String>[
        'S6.1',
        'S6.2',
        'S6.3',
        'S6.4',
        'S6.5',
        'S6.6',
        'S6.7',
      ]),
    );
    final inserted = results['S6.3'];
    expect(inserted, isA<Passed>());
    expect(
      (inserted! as Passed).evidence,
      contains('inserted X inherits bold=true'),
    );

    final markerGrowth = results['S6.7'];
    expect(markerGrowth, isA<Passed>());
    expect(
      (markerGrowth! as Passed).evidence,
      matches(RegExp(r'first=\d+B/[1-9]\d* ContentFormat')),
    );
    for (final entry in results.entries) {
      expect(
        entry.value,
        isNot(isA<Failed>()),
        reason: 'scenario ${entry.key} failed',
      );
    }
  });
}
