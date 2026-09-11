// Wayfinder ticket 03 (yrs-native-reject-admission-feasibility) — Verify
// Same-Client Causal Coupling Beyond the First Shape.
//
// Standard Flutter `integration_test` harness, matching this repo's `p1`-`p8`
// convention. Runs the exact same scenario functions as
// `tool/same_client_coupling_shapes_probe_dart.dart`
// (`lib/prototype/title_admission_native_probe.dart`, shared so the two
// cannot drift), against `YrsRuntime.create()` unchanged.
//
// This file is left in the repo, analyzed clean, as the standard harness for
// whoever can run a Windows Flutter integration test in an unrestricted
// environment. `reports/p8-same-client-coupling-shapes.md`'s numbers come
// from the `tool/` script's actual run, not from this file's untested
// completion — this sandboxed environment hangs `flutter test`'s
// Windows-app-to-VM-service socket, the same reason tickets 01 and 02 each
// left an equivalent Flutter harness unrun alongside their authoritative
// `dart run` evidence (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
//
// These scenarios don't assert a specific accept/refuse outcome the way
// ticket 02's negative-control scenario does — per the map's
// failure-classification policy, the point is to report whichever outcome
// actually occurs, not to encode an expectation. `result.passed` here means
// "the run completed and produced concrete evidence", not "matched a
// hypothesis" — see each scenario's `evidence` string for the actual finding.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/prototype/title_admission_native_probe.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  test(
    'ticket 03 shape 1 (format instead of insert) runs to completion on native Yrs',
    () async {
      final result = await formatInsteadOfInsertCoupling(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 03 shape 2 (delete instead of insert) runs to completion on native Yrs',
    () async {
      final result = await deleteInsteadOfInsertCoupling(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 03 shape 3 (insert adjacent to existing content) runs to completion on native Yrs',
    () async {
      final result = await adjacentInsertIntoNonEmptyTextCoupling(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 03 shape 4 (three-command same-client chain) runs to completion on native Yrs',
    () async {
      final result = await threeCommandChainCoupling(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );
}
