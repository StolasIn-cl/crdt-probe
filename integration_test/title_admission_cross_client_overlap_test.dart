// Wayfinder ticket 04 (yrs-native-reject-admission-feasibility) — Verify
// Cross-Client Overlapping Multi-Select Admission Safety.
//
// Standard Flutter `integration_test` harness, matching this repo's `p1`-`p9`
// convention. Runs the exact same scenario functions as
// `tool/cross_client_multiselect_overlap_probe_dart.dart`
// (`lib/prototype/title_admission_native_probe.dart`, shared so the two
// cannot drift), against `YrsRuntime.create()` unchanged.
//
// This file is left in the repo, analyzed clean, as the standard harness for
// whoever can run a Windows Flutter integration test in an unrestricted
// environment. `reports/p9-cross-client-multiselect-overlap-admission.md`'s
// numbers come from the `tool/` script's actual run, not from this file's
// untested completion — this sandboxed environment hangs `flutter test`'s
// Windows-app-to-VM-service socket, the same reason tickets 01-03 each left
// an equivalent Flutter harness unrun alongside their authoritative
// `dart run` evidence (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
//
// Per the map's failure-classification policy, these scenarios don't assert
// a specific accept/refuse outcome or a specific final field value the way
// ticket 02's negative-control scenario does — the point is to report
// whichever outcome actually occurs. `result.passed` here means "the run
// completed and produced concrete evidence", not "matched a hypothesis" —
// see each scenario's `evidence` string for the actual finding.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/prototype/title_admission_native_probe.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  test(
    'ticket 04 cross-client overlap, order A-then-B, runs to completion on native Yrs',
    () async {
      final result = await crossClientOverlapMoveAThenB(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 04 cross-client overlap, order B-then-A, runs to completion on native Yrs',
    () async {
      final result = await crossClientOverlapMoveBThenA(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );
}
