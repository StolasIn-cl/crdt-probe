import '../runtime/crdt_runtime.dart';
import 'scenario.dart';

/// Renders the markdown a phase's exit criterion asks for. Every row names the
/// claim it is evidence about, so the report can be read without the plan.
String renderReport(
  String phase,
  CrdtRuntime runtime,
  List<Scenario> scenarios,
  Map<String, ScenarioOutcome> results,
  Map<String, List<String>> traces,
) {
  final b = StringBuffer()
    ..writeln('# $phase measurement report')
    ..writeln()
    ..writeln('- Runtime: `${runtime.name}`')
    ..writeln('- Capabilities: ${runtime.capabilities.values.map((c) => c.name).join(', ')}')
    ..writeln()
    ..writeln('| Scenario | Targets | Outcome | Evidence |')
    ..writeln('|---|---|---|---|');

  for (final s in scenarios) {
    final o = results[s.id];
    final (label, evidence) = switch (o) {
      Passed(evidence: final e) => ('pass', e),
      Failed(reason: final r) => ('**fail**', r.split('\n').first),
      Unobservable(missing: final m, runtimeName: final n) => (
          '**unobservable**',
          'on `$n`: missing ${m.map((c) => c.name).join(', ')}'
        ),
      null => ('not run', ''),
    };
    b.writeln('| ${s.id} `${s.title}` | ${s.targets} | $label | ${evidence.replaceAll('|', r'\|')} |');
  }

  b
    ..writeln()
    ..writeln('## Traces')
    ..writeln();
  for (final s in scenarios) {
    final t = traces[s.id];
    if (t == null || t.isEmpty) continue;
    b
      ..writeln('### ${s.id}')
      ..writeln();
    for (final line in t) {
      b.writeln('- $line');
    }
    b.writeln();
  }

  return b.toString();
}
