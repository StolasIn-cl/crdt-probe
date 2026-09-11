import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/driver/script_driver.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/harness/scenarios/axis0_arrival_order.dart';
import 'package:yjs_probe/harness/scenarios/promeo_rule_a.dart';
import 'package:yjs_probe/runtime/promeo/promeo_runtime.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

String _contiguityTable(String runtimeName, List<ContiguityRunResult> results) {
  final b = StringBuffer()
    ..writeln('### Contiguity -- `$runtimeName`')
    ..writeln()
    ..writeln(
        'Two writers each type a 3-character burst ("P","Q","R" and "X","Y","Z") '
        'at the same anchor. Contiguous: "PQR" and "XYZ" each appear as one '
        'unbroken, in-order substring (the two runs may interleave as whole '
        'blocks in either order). Shredded: anything else -- one writer\'s '
        'characters broken open by the other\'s, e.g. "PXQYRZ" or "PQXYRZ".')
    ..writeln()
    ..writeln('| # | server interleaving (1=P/Q/R writer, 2=X/Y/Z writer) | resulting string | PQR contiguous | XYZ contiguous |')
    ..writeln('|---|---|---|---|---|');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    b.writeln('| ${i + 1} | ${r.pattern} | `${r.text}` | ${r.w1Contiguous} | ${r.w2Contiguous} |');
  }
  final anyShredded = results.any((r) => r.shredded);
  b
    ..writeln()
    ..writeln(
        '**Verdict:** ${results.length} interleavings run; '
        '${anyShredded ? "AT LEAST ONE SHREDDED -- see the marked row(s) above" : "all stayed contiguous"}.')
    ..writeln();
  return b.toString();
}

String _reflowSection(String runtimeName, String label, List<String> trace, Map<String, String> finalViews) {
  final b = StringBuffer()
    ..writeln('### Reflow ($label) -- `$runtimeName`')
    ..writeln()
    ..writeln('Final: you="${finalViews["you"]}", peer="${finalViews["peer"]}"'
        ' -- ${finalViews["you"] == finalViews["peer"] ? "CONVERGED" : "DID NOT CONVERGE"}')
    ..writeln();
  for (final line in trace) {
    b.writeln('- $line');
  }
  b.writeln();
  return b.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('yata-core ticket 01: Rule A prototype -- contiguity, reflow, and S0.3', () async {
    final promeo = await PromeoRuntime.create();
    final yjs = await YjsRuntime.create();

    // --- 2 & 4: contiguity, both runtimes -------------------------------
    final promeoContiguity = await runContiguityScenario(promeo);
    final yjsContiguity = await runContiguityScenario(yjs);

    // --- 3 & 4: reflow (single-char and burst), both runtimes -----------
    final promeoSingleDriver = ScriptDriver();
    final promeoSingleFinal = await runReflowSingleChar(promeo, promeoSingleDriver);
    final promeoBurstDriver = ScriptDriver();
    final promeoBurstFinal = await runReflowBurst(promeo, promeoBurstDriver);

    final yjsSingleDriver = ScriptDriver();
    final yjsSingleFinal = await runReflowSingleChar(yjs, yjsSingleDriver);
    final yjsBurstDriver = ScriptDriver();
    final yjsBurstFinal = await runReflowBurst(yjs, yjsBurstDriver);

    // --- 5: S0.3 re-run against PromeoRuntime ---------------------------
    final s03 = axis0Scenarios.firstWhere((s) => s.id == 'S0.3');
    final s03Runner = ScenarioRunner();
    final s03Outcome = await s03Runner.run(s03, promeo);
    final s03Trace = s03Runner.traces[s03.id] ?? const <String>[];
    final s03Evidence = s03Outcome is Passed ? s03Outcome.evidence : '(did not Pass)';
    final s03MatchesPrediction = s03Outcome is Passed && s03Outcome.evidence.contains('"aBAbc"');

    // --- compose the report ---------------------------------------------
    final report = StringBuffer()
      ..writeln('# P4 Rule A prototype (yata-core ticket 01)')
      ..writeln()
      ..writeln(
          'Prototypes `PromeoRuntime` (Rule A: an insertion lands immediately '
          'right of its anchor, applied in server sequence order -- no YATA '
          'integration loop, no clientID tie-break) and measures the '
          'contiguity claim and the pre-acknowledgement reflow ticket 15 §2 '
          'only reasoned about, plus a re-run of S0.3 against an actual Rule '
          'A implementation.')
      ..writeln()
      ..writeln('## 1. Contiguity scenario')
      ..writeln()
      ..writeln(_contiguityTable(promeo.name, promeoContiguity))
      ..writeln(_contiguityTable(yjs.name, yjsContiguity))
      ..writeln('## 2. Reflow scenario')
      ..writeln()
      ..writeln(_reflowSection(promeo.name, 'single-character', promeoSingleDriver.trace, promeoSingleFinal))
      ..writeln(_reflowSection(promeo.name, 'burst', promeoBurstDriver.trace, promeoBurstFinal))
      ..writeln(_reflowSection(yjs.name, 'single-character', yjsSingleDriver.trace, yjsSingleFinal))
      ..writeln(_reflowSection(yjs.name, 'burst', yjsBurstDriver.trace, yjsBurstFinal))
      ..writeln('## 3. S0.3 re-run against PromeoRuntime')
      ..writeln()
      ..writeln('Ticket 15 §2 predicts "aBAbc" for seed "abc", both writers '
          'inserting at index 1, w1 sequenced first. `reports/p1-axis0.md` '
          'already measured that Yjs instead produces "aABbc" '
          '(CONTRADICTING that half of ticket 15 §2). This re-runs the same '
          'S0.3 scenario, unmodified, against `PromeoRuntime`.')
      ..writeln()
      ..writeln('- Outcome: `${s03Outcome.runtimeType}`')
      ..writeln('- Evidence: $s03Evidence')
      ..writeln('- Matches ticket 15 §2\'s "aBAbc" prediction: $s03MatchesPrediction')
      ..writeln()
      ..writeln('### S0.3 trace')
      ..writeln();
    for (final line in s03Trace) {
      report.writeln('- $line');
    }

    final reportText = report.toString();
    File('reports/p4-rule-a-prototype.md').createSync(recursive: true);
    File('reports/p4-rule-a-prototype.md').writeAsStringSync(reportText);
    // ignore: avoid_print
    print(reportText);

    // --- structural assertions -------------------------------------------
    // Contiguity: this is the one result that could kill Rule A outright
    // (ticket 01's own words), so it is asserted, not merely reported.
    expect(promeoContiguity.length, 20, reason: 'C(6,3) = 20 interleavings expected');
    for (final r in promeoContiguity) {
      expect(r.shredded, isFalse,
          reason: 'PromeoRuntime shredded on interleaving ${r.pattern}: "${r.text}"');
    }
    for (final r in yjsContiguity) {
      expect(r.shredded, isFalse,
          reason: 'Yjs shredded on interleaving ${r.pattern}: "${r.text}"');
    }

    // Reflow: both participants must converge on both runtimes, on both
    // the single-character and burst cases -- convergence is a settled
    // premise this prototype must not contradict even while it measures
    // the shift itself.
    expect(promeoSingleFinal['you'], promeoSingleFinal['peer']);
    expect(promeoBurstFinal['you'], promeoBurstFinal['peer']);
    expect(yjsSingleFinal['you'], yjsSingleFinal['peer']);
    expect(yjsBurstFinal['you'], yjsBurstFinal['peer']);

    // S0.3 must at least reach a decided outcome; whether it matches the
    // ticket 15 §2 prediction is reported above, not gated here -- a
    // mismatch would itself be the finding, not a broken test.
    expect(s03Outcome, isA<Passed>());
  });
}
