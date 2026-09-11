// Wayfinder ticket 06 (yrs-native-reject-admission-feasibility) — Verify
// Undo Interaction With Pending or Refused Chains.
//
// Standard Flutter `integration_test` harness, matching this repo's `p1`-`p10`
// convention. Runs the exact same scenario functions as
// `tool/undo_pending_refused_interaction_probe_dart.dart`
// (`lib/prototype/title_admission_native_probe.dart`, shared so the two
// cannot drift), against `YrsRuntime.create()` unchanged.
//
// This file is left in the repo, analyzed clean, as the standard harness for
// whoever can run a Windows Flutter integration test in an unrestricted
// environment. `reports/p11-undo-pending-refused-interaction.md`'s numbers
// come from the `tool/` script's actual run, not from this file's untested
// completion — this sandboxed environment hangs `flutter test`'s
// Windows-app-to-VM-service socket, the same reason tickets 01-05 each left
// an equivalent Flutter harness unrun alongside their authoritative
// `dart run` evidence (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
//
// These scenarios don't assert one hypothesized accept/refuse outcome for
// every case — per the map's failure-classification policy, the point is to
// report whichever outcome actually occurs, not to encode a hypothesis.
// `result.passed` here means "the run completed and produced concrete
// evidence", not "matched a hypothesis" — see each scenario's `evidence`
// string for the actual finding, including whether any false acceptance was
// detected.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/prototype/title_admission_native_probe.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  test(
    'ticket 06 port 1/2 (_transitiveWithdrawal, including a real undo at the '
    'chain\'s tail) runs to completion on native Yrs',
    () async {
      final result = await transitiveWithdrawalNative(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 port 2/2 (_policyRejectionAcrossCommandKinds, including a real '
    'undo) runs to completion on native Yrs',
    () async {
      final result =
          await policyRejectionAcrossCommandKindsNative(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 shape A, order 1 (x-then-undo, both pending before either is '
    'submitted) runs to completion on native Yrs',
    () async {
      final result = await pendingUndoXThenUndoBothAccepted(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 shape A, order 2 (undo-then-x, both pending before either is '
    'submitted) runs to completion on native Yrs',
    () async {
      final result =
          await pendingUndoUndoThenXMissingDependency(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 shape A/B boundary (undo, dependsOn wired, submitted after '
    'its own x was refused by policy) runs to completion on native Yrs',
    () async {
      final result =
          await pendingUndoXRefusedThenUndoDependencyRefused(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 shape B, clean (undo() targeting an already-refused, '
    'already-rebuilt-away command) runs to completion on native Yrs',
    () async {
      final result = await refusedUndoAfterRebuildThrows(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 06 shape B, racy/no-dependsOn (the sharpest false-acceptance '
    'hunt for this axis) runs to completion on native Yrs',
    () async {
      final result = await refusedUndoRacyNoDependsOn(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );
}
