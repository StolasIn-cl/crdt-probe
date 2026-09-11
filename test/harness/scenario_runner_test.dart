import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';

import '../fakes/fake_runtime.dart';

void main() {
  test('a scenario whose requirement is unmet is Unobservable and its body never runs', () async {
    var bodyRan = false;
    final scenario = Scenario(
      id: 'X.1',
      title: 'needs tombstones',
      targets: 'nothing',
      requires: {Capability.enumerateTombstones},
      body: (_) async {
        bodyRan = true;
        return const Passed(evidence: 'should never be reached');
      },
    );

    final outcome = await ScenarioRunner().run(
      scenario,
      FakeRuntime(const CapabilitySet.of({Capability.decodeUpdate})),
    );

    expect(bodyRan, isFalse, reason: 'the body must not run when a capability is missing');
    expect(outcome, isA<Unobservable>());
    expect((outcome as Unobservable).missing, {Capability.enumerateTombstones});
  });

  test('a scenario whose requirements are met runs and reports its own outcome', () async {
    final scenario = Scenario(
      id: 'X.2',
      title: 'needs decode',
      targets: 'nothing',
      requires: {Capability.decodeUpdate},
      body: (_) async => const Passed(evidence: '3 structs'),
    );

    final outcome = await ScenarioRunner().run(
      scenario,
      FakeRuntime(const CapabilitySet.of({Capability.decodeUpdate})),
    );

    expect(outcome, isA<Passed>());
    expect((outcome as Passed).evidence, '3 structs');
  });

  test('a throwing body becomes Failed rather than escaping', () async {
    final scenario = Scenario(
      id: 'X.3',
      title: 'throws',
      targets: 'nothing',
      requires: const {},
      body: (_) async => throw StateError('boom'),
    );

    final outcome = await ScenarioRunner().run(scenario, FakeRuntime(const CapabilitySet.of({})));
    expect(outcome, isA<Failed>());
    expect((outcome as Failed).reason, contains('boom'));
  });

  test('runAll returns one outcome per scenario, keyed by id, and populates a trace for each',
      () async {
    final scenarios = [
      Scenario(
        id: 'A.1',
        title: 'first',
        targets: 'nothing',
        requires: {Capability.decodeUpdate},
        body: (ctx) async {
          await ctx.driver.step('do A.1 thing', () async {});
          return const Passed(evidence: 'a.1 done');
        },
      ),
      Scenario(
        id: 'A.2',
        title: 'second',
        targets: 'nothing',
        requires: {Capability.decodeUpdate},
        body: (ctx) async {
          await ctx.driver.step('do A.2 thing', () async {});
          return const Passed(evidence: 'a.2 done');
        },
      ),
    ];

    final runner = ScenarioRunner();
    final results = await runner.runAll(
      scenarios,
      FakeRuntime(const CapabilitySet.of({Capability.decodeUpdate})),
    );

    expect(results.keys, {'A.1', 'A.2'});
    expect((results['A.1'] as Passed).evidence, 'a.1 done');
    expect((results['A.2'] as Passed).evidence, 'a.2 done');

    expect(runner.traces['A.1'], contains('do A.1 thing'));
    expect(runner.traces['A.2'], contains('do A.2 thing'));
  });

  test('a second runAll does not carry the first set\'s traces', () async {
    final runtime = FakeRuntime(const CapabilitySet.of({Capability.decodeUpdate}));
    final runner = ScenarioRunner();

    final firstSet = [
      Scenario(
        id: 'A.1',
        title: 'first set scenario',
        targets: 'nothing',
        requires: {Capability.decodeUpdate},
        body: (ctx) async {
          await ctx.driver.step('first set step', () async {});
          return const Passed(evidence: 'first');
        },
      ),
    ];

    await runner.runAll(firstSet, runtime);
    expect(runner.traces.keys, {'A.1'}, reason: 'sanity check that the first run recorded a trace');

    final secondSet = [
      Scenario(
        id: 'B.1',
        title: 'second set scenario',
        targets: 'nothing',
        requires: {Capability.decodeUpdate},
        body: (ctx) async {
          await ctx.driver.step('second set step', () async {});
          return const Passed(evidence: 'second');
        },
      ),
    ];

    await runner.runAll(secondSet, runtime);

    expect(
      runner.traces.keys,
      {'B.1'},
      reason: 'the second runAll must not carry the first set\'s traces forward',
    );
    expect(runner.traces.containsKey('A.1'), isFalse,
        reason: 'A.1\'s trace from the first run must be gone, not just overshadowed');
  });
}
