// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility) — Port the
// First Slice of the Title Admission Suite to YrsRuntime.
//
// Standard Flutter `integration_test` harness, matching this repo's `p1`-`p7`
// convention. Runs the exact same scenario functions as
// `tool/title_admission_native_yrs_probe_dart.dart`
// (`lib/prototype/title_admission_native_probe.dart`, shared so the two
// cannot drift), against `YrsRuntime.create()` unchanged.
//
// This file is left in the repo, analyzed clean, as the standard harness for
// whoever can run a Windows Flutter integration test in an unrestricted
// environment. `reports/p7-title-admission-native-yrs.md`'s numbers come
// from the `tool/` script's actual run, not from this file's untested
// completion — this sandboxed environment hangs `flutter test`'s
// Windows-app-to-VM-service socket for a Windows-target Flutter integration
// test (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`), the same reason ticket 01 and
// ticket 03 each left an equivalent Flutter harness unrun alongside their
// authoritative `dart run` evidence.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/prototype/title_admission_native_probe.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  test(
    'ticket 02 scenario 1 (exact-U mode) reproduces the causal-coupling finding on native Yrs',
    () async {
      final result = await independentLocalEditFinding(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );

  test(
    'ticket 02 scenario 2 (semantic mode) replays the surviving command without causal residue on native Yrs',
    () async {
      final result = await semanticReplayAfterRefusal(runtimeFactory);
      expect(result.passed, isTrue, reason: result.evidence);
    },
  );
}
