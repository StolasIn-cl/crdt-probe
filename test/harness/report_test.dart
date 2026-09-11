import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';

import '../fakes/fake_runtime.dart';

void main() {
  test('renders all three outcomes and does not corrupt its table', () {
    final runtime = FakeRuntime(const CapabilitySet.of({Capability.decodeUpdate}));

    final scenarios = [
      Scenario(
        id: 'P.1',
        title: 'passes with a pipe in its evidence',
        targets: 'claim about pipes',
        requires: const {},
        body: (_) async => const Passed(evidence: 'measured a | b'),
      ),
      Scenario(
        id: 'F.1',
        title: 'fails',
        targets: 'claim about failure',
        requires: const {},
        body: (_) async => const Failed(reason: 'boom\nstack trace continues'),
      ),
      Scenario(
        id: 'U.1',
        title: 'unobservable',
        targets: 'claim about tombstones',
        requires: const {Capability.enumerateTombstones},
        body: (_) async => const Passed(evidence: 'never reached'),
      ),
    ];

    final results = <String, ScenarioOutcome>{
      'P.1': const Passed(evidence: 'measured a | b'),
      'F.1': const Failed(reason: 'boom\nstack trace continues'),
      'U.1': const Unobservable(
        missing: {Capability.enumerateTombstones},
        runtimeName: 'fake',
      ),
    };

    final traces = <String, List<String>>{
      'P.1': ['did the thing'],
    };

    final output = renderReport('Phase 0', runtime, scenarios, results, traces);

    // One row per scenario.
    expect(output, contains('P.1'));
    expect(output, contains('F.1'));
    expect(output, contains('U.1'));

    // The Unobservable row names the missing capability and the runtime.
    expect(output, contains('unobservable'));
    expect(output, contains('on `fake`'));
    expect(output, contains('enumerateTombstones'));

    // The Failed row is present too.
    expect(output, contains('**fail**'));
    expect(output, contains('boom'));

    // The literal pipe in the Passed evidence must be escaped, not left raw,
    // or it would be parsed as an extra table column/row boundary.
    expect(output, contains(r'measured a \| b'));

    // Guard against the raw, unescaped form appearing anywhere in the table
    // body (a raw "a | b" would silently split the row into extra columns).
    expect(output, isNot(contains('measured a | b')));

    // Every table row has exactly 5 pipe-delimited boundaries (4 columns),
    // i.e. exactly 4 unescaped '|' characters once escaped ones are removed.
    final tableLines = output
        .split('\n')
        .where((l) => l.trim().startsWith('|') && !l.contains('---'))
        .toList();
    // header + 3 scenario rows
    expect(tableLines.length, 4);
    for (final line in tableLines) {
      final unescaped = line.replaceAll(r'\|', '');
      expect('|'.allMatches(unescaped).length, 5,
          reason: 'row must keep exactly 4 columns: $line');
    }
  });
}
