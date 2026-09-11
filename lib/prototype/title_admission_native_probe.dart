// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility) — Port the
// First Slice of the Title Admission Suite to YrsRuntime.
//
// This file ports exactly two of `integration_test/title_admission_test.dart`'s
// twenty scenarios to run against a real, caller-supplied `CrdtRuntime`
// (in practice `YrsRuntime`, the native `yrs.dll` Promeo ships) instead of
// hardcoding `YjsRuntime`. Per the ticket's own constraint, `title_admission.dart`'s
// `YjsAdmissionServer`/`YjsAdmissionClient` are reused completely unchanged —
// the only thing that varies here is which runtime the rig constructs.
//
// Kept in `lib/` (not copy-pasted into both `tool/` and `integration_test/`)
// so the plain `dart run` harness (this sandboxed environment's actual
// evidence path — `flutter test` hangs its Windows-app-to-VM-service socket,
// see `yjs_probe/reports/p5-zorder-merge.md` and `p6-yffi-pending-structs.md`)
// and the standard Flutter `integration_test/` harness run the exact same
// scenario logic and cannot drift apart.
//
// The two scenarios ported are deliberately not "the two simplest" but the
// pair that makes the exact-U-vs-semantic distinction for
// `pendingStructCount`/`has_missing_updates` observable on the real native
// runtime — see ticket 02's Question for the full reasoning:
//
// 1. [independentLocalEditFinding] (exact-U mode) — the known defect: an
//    unrelated command sharing a client clock chain with an already-refused
//    command gets wrongly refused as causally incomplete. Expected to still
//    reproduce on native Yrs, not be silently fixed by the runtime swap.
// 2. [semanticReplayAfterRefusal] (semantic mode) — semantic re-execution
//    never touches the refused command's stale bytes, so the survivor is
//    correctly accepted with `pendingStructCount` staying 0 throughout.

import 'dart:convert';

import '../core/ids.dart';
import '../core/projection.dart';
import '../runtime/crdt_runtime.dart';
import 'title_admission.dart';

/// Three-participant rig (server, A, B), generic over which [CrdtRuntime]
/// each participant's document uses. Mirrors
/// `integration_test/title_admission_test.dart`'s private `_Rig` exactly,
/// except the runtime is supplied by the caller instead of hardcoded to
/// `YjsRuntime.create()`.
class NativeProbeRig {
  NativeProbeRig({
    required this.serverRuntime,
    required this.aRuntime,
    required this.bRuntime,
    required this.server,
    required this.a,
    required this.b,
    required this.trace,
  });

  final CrdtRuntime serverRuntime;
  final CrdtRuntime aRuntime;
  final CrdtRuntime bRuntime;
  final YjsAdmissionServer server;
  final YjsAdmissionClient a;
  final YjsAdmissionClient b;
  final List<Map<String, Object?>> trace;

  static Future<NativeProbeRig> create({
    required Future<CrdtRuntime> Function() runtimeFactory,
    AdmissionPolicy? policy,
    AdmissionExecutionMode mode = AdmissionExecutionMode.exactUpdate,
  }) async {
    final trace = <Map<String, Object?>>[];
    final serverRuntime = await runtimeFactory();
    final aRuntime = await runtimeFactory();
    final bRuntime = await runtimeFactory();
    void record(String kind, Map<String, Object?> data) =>
        trace.add({'kind': kind, ...data});
    final server = YjsAdmissionServer(
      runtime: serverRuntime,
      policy: policy,
      mode: mode,
      onEvent: record,
    );
    final a = YjsAdmissionClient(
      runtime: aRuntime,
      clientId: const ClientId(1),
      mode: mode,
      onEvent: record,
    );
    final b = YjsAdmissionClient(
      runtime: bRuntime,
      clientId: const ClientId(2),
      mode: mode,
      onEvent: record,
    );
    await server.open();
    await a.open();
    await b.open();
    return NativeProbeRig(
      serverRuntime: serverRuntime,
      aRuntime: aRuntime,
      bRuntime: bRuntime,
      server: server,
      a: a,
      b: b,
      trace: trace,
    );
  }

  /// Deliberately does not call a `dispose()` beyond [CrdtRuntime.close] —
  /// unlike the Yjs-only `_Rig` this is ported from, `CrdtRuntime` declares
  /// no such method, and `YrsRuntime` needs none: every FFI-backed native
  /// document is freed by `close(ClientId)` (`ydoc_destroy`), not by a
  /// separate runtime-level teardown.
  Future<void> close() async {
    await a.close();
    await b.close();
    await serverRuntime.close(server.serverId);
  }
}

class NativeProbeResult {
  const NativeProbeResult({
    required this.name,
    required this.passed,
    required this.evidence,
    required this.trace,
    required this.finalState,
  });

  final String name;
  final bool passed;
  final String evidence;
  final List<Map<String, Object?>> trace;
  final Map<String, Object?> finalState;
}

/// Scenario 1 (exact-U mode) — ported from `title_admission_test.dart`'s
/// `_IndependentLocalEditFinding.run`. This is the negative control: it must
/// still reproduce the known defect on native Yrs, not be silently fixed by
/// the runtime swap.
Future<NativeProbeResult> independentLocalEditFinding(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-keep', 'title-keep');
    final root = await rig.a.createTitle('reject-root', 'title-root');
    final independent = await rig.a.insert(
      'local-edit-keep',
      'title-keep',
      0,
      'survives?',
      // Deliberately omit a semantic dependency. The two commands target
      // different Titles, but they share one Yrs document and one client
      // clock, which is the exact coupling this scenario must expose.
    );
    final refused = await rig.server.submit(root);
    final independentDecision = await rig.server.submit(independent);
    _require(refused.refusal == AdmissionRefusal.policy,
        'root refusal should be AdmissionRefusal.policy, got ${refused.refusal}');
    _require(independentDecision.accepted == false,
        'independent command should have been refused, was accepted');
    _require(
        independentDecision.refusal == AdmissionRefusal.causalIncomplete,
        'independent command should be refused as causalIncomplete, got '
        '${independentDecision.refusal}');
    await rig.a.deliver(refused);
    _require(
        rig.a.pendingOpIds.length == 1 &&
            rig.a.pendingOpIds.single == independent.opId,
        'A pendingOpIds should be exactly [${independent.opId}], got '
        '${rig.a.pendingOpIds}');
    final pendingAfterRebuild = await rig.a.speculativePendingStructs();
    _require(pendingAfterRebuild > 0,
        'A speculative pendingStructs should be >0 after rebuild, got '
        '$pendingAfterRebuild');
    await rig.a.deliver(independentDecision);
    _require(rig.a.pendingOpIds.isEmpty,
        'A pendingOpIds should be empty after final refusal delivered, got '
        '${rig.a.pendingOpIds}');
    final pendingAfterFinal = await rig.a.speculativePendingStructs();
    _require(pendingAfterFinal == 0,
        'A speculative pendingStructs should be 0 after final refusal, got '
        '$pendingAfterFinal');
    // Awaited here, not `return _pass(...)`: Dart runs an async `finally`
    // block as soon as `try` is left by `return`, without first awaiting the
    // returned Future — `rig.close()` below would then race `_pass`'s own
    // internal awaits and could close `_speculativeId`'s document out from
    // under it. Confirmed empirically while building this port (a
    // `StateError: no Yrs document for client ...` from exactly that race).
    final result = await _pass(
      'same-document independent local edit exposes causal coupling (native Yrs)',
      'a later edit on a different Title was semantically independent but its '
          'client clock depended on the refused root; the server detected a '
          'causal gap via native pendingStructCount ($pendingAfterRebuild '
          'pending after rebuild, 0 after final refusal), reproducing the '
          'known Yjs finding on real yrs.dll.',
      rig,
    );
    return result;
  } finally {
    await rig.close();
  }
}

/// Scenario 2 (semantic mode) — ported from `title_admission_test.dart`'s
/// `_semanticReplayAfterRefusal`. Confirms that semantic re-execution — not
/// `pendingStructCount` itself — is what protects an unrelated survivor.
Future<NativeProbeResult> semanticReplayAfterRefusal(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    mode: AdmissionExecutionMode.semanticCommand,
    policy: (envelope) => envelope.opId == 'semantic-reject-root'
        ? AdmissionRefusal.policy
        : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'replay-a', 'title-a');
    await _acceptCreateEverywhere(rig, 'replay-b', 'title-b');
    await _acceptInsertEverywhere(rig, 'replay-seed', 'title-b', 'seed');

    final rejectedRoot = await rig.a.insert(
      'semantic-reject-root',
      'title-a',
      0,
      'discard-me',
    );
    final surviving = await rig.a.format(
      'semantic-survivor',
      'title-b',
      0,
      1,
      const {'bold': true},
    );
    final refused = await rig.server.submit(rejectedRoot);
    final accepted = await rig.server.submit(surviving);
    _require(refused.refusal == AdmissionRefusal.policy,
        'root refusal should be AdmissionRefusal.policy, got ${refused.refusal}');
    _require(accepted.accepted,
        'surviving format should have been accepted, was refused: ${accepted.refusal}');

    await rig.a.deliver(refused);
    await rig.a.deliver(accepted);
    await rig.b.deliver(accepted);
    await _expectConverged(rig);
    final pendingAfter = await rig.a.speculativePendingStructs();
    _require(pendingAfter == 0,
        'A speculative pendingStructs should stay 0 throughout semantic '
        'replay, got $pendingAfter');
    final projection = await rig.server.projection();
    final titleA = projection.objects[const ObjectId('title-a')]!;
    final titleB = projection.objects[const ObjectId('title-b')]!;
    _require(titleA.text == null || titleA.text!.isEmpty,
        'title-a text should be empty (rejected root never landed), got '
        '"${titleA.text}"');
    _require(titleB.delta != null && titleB.delta!.isNotEmpty,
        'title-b delta should be non-empty (surviving format landed), got '
        '${titleB.delta}');
    // See the same-note in independentLocalEditFinding above: await _pass
    // fully before finally's rig.close() can race it.
    final result = await _pass(
      'semantic replay removes rejected root without causal residue (native Yrs)',
      'after a policy refusal, the surviving independent Q was re-executed '
          'from accepted B on native Yrs; no exact rejected U was replayed '
          'and pendingStructCount stayed 0 throughout ($pendingAfter final).',
      rig,
    );
    return result;
  } finally {
    await rig.close();
  }
}

// ---------------------------------------------------------------------------
// Wayfinder ticket 03 (yrs-native-reject-admission-feasibility) — Verify
// Same-Client Causal Coupling Beyond the First Shape.
//
// Ticket 02 tested exactly one same-client shape (create-then-refused root,
// followed by an insert into a separate, empty, already-accepted `Y.Text`)
// and found native Yrs did not flag it as causally incomplete, diverging
// from the known Yjs defect. The four scenarios below extend that same
// leading-refused-then-independent pattern to the shapes ticket 03 names:
// format instead of insert, delete instead of insert, insert adjacent to
// existing (non-empty) content, and a three-command chain. Each is verified
// with a state-vector trace (per ticket 02's method, not by assumption) plus
// a manual candidate replay of the independent command's own bytes alone —
// the same double-check ticket 02 used to rule out a broken
// `pendingStructCount` binding as the explanation for an unexpected accept.
// ---------------------------------------------------------------------------

/// Decodes a lib0-v1 state vector (as produced by `DocProjection.stateVectorB64`)
/// into a `{clientId: clock}` map for human-readable tracing. Both Yjs and
/// native Yrs are confirmed lib0-v1-compatible for this probe's wire format
/// (see ticket 02's report, `axis2_cross_runtime_test.dart`), so one decoder
/// works for either runtime's projection.
Map<int, int> decodeStateVectorB64(String base64Value) {
  final bytes = base64Decode(base64Value);
  var offset = 0;
  int readVarUint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byteValue = bytes[offset++];
      result |= (byteValue & 0x7f) << shift;
      if (byteValue < 0x80) break;
      shift += 7;
    }
    return result;
  }

  final size = readVarUint();
  final map = <int, int>{};
  for (var i = 0; i < size; i++) {
    final client = readVarUint();
    final clock = readVarUint();
    map[client] = clock;
  }
  return map;
}

/// `jsonEncode` requires `String` keys; [decodeStateVectorB64] returns `int`
/// keys for arithmetic/comparison convenience (see [sharesClockChain]). This
/// converts a decoded state vector to a JSON-safe shape for `finalState`.
Map<String, int> svToJson(Map<int, int> stateVector) => {
  for (final entry in stateVector.entries) '${entry.key}': entry.value,
};

/// True when some client's clock in [after] is strictly greater than its
/// clock in [before] — i.e. that client authored something between the two
/// snapshots. Used to *verify*, not assume, that a scenario's leading and
/// independent commands genuinely share one client's clock chain.
bool sharesClockChain(Map<int, int> before, Map<int, int> after) {
  for (final entry in before.entries) {
    final laterClock = after[entry.key];
    if (laterClock != null && laterClock > entry.value) return true;
  }
  return false;
}

int _manualCandidateCounter = 0;

/// Replays [envelope]'s own update bytes alone against a fresh candidate
/// seeded only from the server's current accepted snapshot — exactly the
/// shape `YjsAdmissionServer.submit`'s internal candidate-execution path
/// builds. Used as an independent double-check of a scenario's
/// `pendingStructCount` outcome, per ticket 02's evidentiary method (which
/// used this same replay to rule out a broken binding as the explanation for
/// an unexpected accept).
Future<Map<String, Object?>> manualCandidateReplay(
  NativeProbeRig rig,
  TitleAdmissionEnvelope envelope,
) async {
  final manualId = ClientId(9900 + _manualCandidateCounter++);
  final snapshot = await rig.server.snapshot();
  await rig.aRuntime.open(manualId);
  try {
    if (snapshot.isNotEmpty) {
      await rig.aRuntime.applyUpdate(manualId, snapshot, origin: 'remote');
    }
    // Defensive drain, matching `YjsAdmissionServer.submit`'s own candidate
    // path: the snapshot application must not itself register as a local
    // edit needing replay.
    await rig.aRuntime.drainOutbox(manualId);
    await rig.aRuntime.applyUpdate(
      manualId,
      envelope.yrsUpdate,
      origin: 'remote',
    );
    final pending = await rig.aRuntime.pendingStructCount(manualId);
    final projection = await rig.aRuntime.projection(manualId);
    return {
      'pendingStructCount': pending,
      'objects': projection.objects.keys.map((id) => id.value).toList()
        ..sort(),
    };
  } finally {
    await rig.aRuntime.close(manualId);
  }
}

/// Renders the shared evidence shape every ticket 03 scenario reports:
/// the verified state-vector trace, the server's real decision, and the
/// independent manual-replay double-check. Per the map's failure
/// classification policy (see map Notes), this reports the outcome
/// precisely — accepted or refused, and which refusal — without pre-judging
/// whether it is a safe false refusal or a dangerous false acceptance; that
/// judgment is this ticket's own "answer must decide" section and ticket
/// 07's job, not this helper's.
Future<NativeProbeResult> reportCouplingShape({
  required String name,
  required NativeProbeRig rig,
  required AdmissionTicket rootDecision,
  required AdmissionTicket independentDecision,
  required Map<int, int> svBeforeRoot,
  required Map<int, int> svAfterRoot,
  required Map<int, int> svAfterIndependent,
  required Map<String, Object?> manualReplay,
  String? note,
}) async {
  _require(
    rootDecision.refusal == AdmissionRefusal.policy,
    'root should be refused by policy, got ${rootDecision.refusal}',
  );
  final clockShared = sharesClockChain(svAfterRoot, svAfterIndependent);
  final outcome = independentDecision.accepted
      ? 'ACCEPTED — no causal gap detected'
      : 'REFUSED as ${independentDecision.refusal?.name}';
  final evidence =
      'shared-clock-chain precondition '
      '${clockShared ? 'confirmed' : 'NOT confirmed (see note)'} by state-vector '
      'trace (before-root=$svBeforeRoot, after-root=$svAfterRoot, '
      'after-independent=$svAfterIndependent); server decision on the '
      'independent command: $outcome; manual candidate replay of the '
      'independent command\'s own bytes alone against the server snapshot: '
      '$manualReplay.'
      '${note == null ? '' : ' $note'}';
  return NativeProbeResult(
    name: name,
    passed: true,
    evidence: evidence,
    trace: List<Map<String, Object?>>.from(rig.trace),
    finalState: {
      'rootDecision': rootDecision.toJson(),
      'independentDecision': independentDecision.toJson(),
      'manualReplay': manualReplay,
      'stateVectors': {
        'beforeRoot': svToJson(svBeforeRoot),
        'afterRoot': svToJson(svAfterRoot),
        'afterIndependent': svToJson(svAfterIndependent),
      },
      'sharedClockChain': clockShared,
    },
  );
}

/// Shape 1 — format instead of insert. The independent command formats an
/// existing range in an already-accepted, non-empty `Y.Text` instead of
/// inserting new text.
Future<NativeProbeResult> formatInsteadOfInsertCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root-format' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-keep-format', 'title-keep-format');
    await _acceptInsertEverywhere(
      rig,
      'seed-keep-format',
      'title-keep-format',
      'seedtext',
    );
    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-format', 'title-root-format');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final independent = await rig.a.format(
      'local-format-keep',
      'title-keep-format',
      0,
      4,
      const {'bold': true},
      // Deliberately no `dependsOn` — the second command is semantically
      // independent of the refused root, same as ticket 02's shape.
    );
    final svAfterIndependent = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final rootDecision = await rig.server.submit(root);
    final independentDecision = await rig.server.submit(independent);
    final manualReplay = await manualCandidateReplay(rig, independent);
    return await reportCouplingShape(
      name: 'shape 1: format instead of insert on an already-accepted, '
          'non-empty Y.Text (native Yrs)',
      rig: rig,
      rootDecision: rootDecision,
      independentDecision: independentDecision,
      svBeforeRoot: svBeforeRoot,
      svAfterRoot: svAfterRoot,
      svAfterIndependent: svAfterIndependent,
      manualReplay: manualReplay,
    );
  } finally {
    await rig.close();
  }
}

/// Shape 2 — delete instead of insert. The independent command deletes a
/// range from an already-accepted, non-empty `Y.Text`.
Future<NativeProbeResult> deleteInsteadOfInsertCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root-delete' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-keep-delete', 'title-keep-delete');
    await _acceptInsertEverywhere(
      rig,
      'seed-keep-delete',
      'title-keep-delete',
      'deleteme',
    );
    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-delete', 'title-root-delete');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final independent = await rig.a.erase(
      'local-delete-keep',
      'title-keep-delete',
      0,
      3,
    );
    final svAfterIndependent = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final rootDecision = await rig.server.submit(root);
    final independentDecision = await rig.server.submit(independent);
    final manualReplay = await manualCandidateReplay(rig, independent);
    return await reportCouplingShape(
      name: 'shape 2: delete instead of insert on an already-accepted, '
          'non-empty Y.Text (native Yrs)',
      rig: rig,
      rootDecision: rootDecision,
      independentDecision: independentDecision,
      svBeforeRoot: svBeforeRoot,
      svAfterRoot: svAfterRoot,
      svAfterIndependent: svAfterIndependent,
      manualReplay: manualReplay,
    );
  } finally {
    await rig.close();
  }
}

/// Shape 3 — insert into a *non-empty* `Y.Text`, adjacent to existing
/// content. Ticket 02's shape inserted into an empty text; this one appends
/// right after real content authored by an earlier accepted operation (a
/// different underlying client than the current speculative session, since
/// the seed was integrated from accepted history before the current
/// session's root and independent command were even proposed) — the shape
/// closest to ticket 01's own toy scenario, which *did* detect a gap.
Future<NativeProbeResult> adjacentInsertIntoNonEmptyTextCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) => envelope.opId == 'reject-root-adjacent'
        ? AdmissionRefusal.policy
        : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-adjacent', 'title-adjacent');
    await _acceptInsertEverywhere(rig, 'seed-adjacent', 'title-adjacent', 'seed');
    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-adjacent', 'title-root-adjacent');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    // Append directly after 'seed' (index 4 == length of 'seed'); the new
    // item's left origin is the seed's last character, a genuine structural
    // reference to already-accepted content authored by a different client.
    final independent = await rig.a.insert(
      'local-adjacent-insert',
      'title-adjacent',
      4,
      'more',
    );
    final svAfterIndependent = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final rootDecision = await rig.server.submit(root);
    final independentDecision = await rig.server.submit(independent);
    final manualReplay = await manualCandidateReplay(rig, independent);
    return await reportCouplingShape(
      name: 'shape 3: insert adjacent to existing content in a non-empty '
          'Y.Text (native Yrs)',
      rig: rig,
      rootDecision: rootDecision,
      independentDecision: independentDecision,
      svBeforeRoot: svBeforeRoot,
      svAfterRoot: svAfterRoot,
      svAfterIndependent: svAfterIndependent,
      manualReplay: manualReplay,
      note: 'This shape has a genuine structural left-origin reference to '
          'existing content (unlike shapes 1/2/ticket-02\'s shape, and unlike '
          'shape 4 below) — designed to test whether adjacency to real '
          'content, not merely client-clock sharing, is what triggers native '
          "Yrs's causal-incompleteness detection.",
    );
  } finally {
    await rig.close();
  }
}

/// Shape 4 — a three-or-more command chain. `op1` (refused) -> `op2`
/// (same client, independent target, no `dependsOn`) -> `op3` (same client,
/// independent target, no `dependsOn`), all three proposed on the same
/// speculative document — `op3` proposed after `op2` but before either `op1`
/// or `op2` is submitted to the server. Checks whether refusing `op1` affects
/// `op2` and `op3` identically, or whether `op3`'s later position in the
/// chain changes the outcome (e.g. because `op3`'s own update bytes
/// structurally reference `op2`'s clock range, which was never itself
/// submitted to this fresh candidate).
Future<NativeProbeResult> threeCommandChainCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root-chain' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-chain-op2', 'title-chain-op2');
    await _acceptCreateEverywhere(rig, 'base-chain-op3', 'title-chain-op3');
    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-chain', 'title-root-chain');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final op2 = await rig.a.insert('local-chain-op2', 'title-chain-op2', 0, 'op2');
    final svAfterOp2 = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final op3 = await rig.a.insert('local-chain-op3', 'title-chain-op3', 0, 'op3');
    final svAfterOp3 = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );

    final rootDecision = await rig.server.submit(root);
    final op2Decision = await rig.server.submit(op2);
    final op3Decision = await rig.server.submit(op3);
    final op2ManualReplay = await manualCandidateReplay(rig, op2);
    final op3ManualReplay = await manualCandidateReplay(rig, op3);
    await rig.a.deliver(rootDecision);
    await rig.a.deliver(op2Decision);
    await rig.a.deliver(op3Decision);
    final pendingAfterChain = await rig.a.speculativePendingStructs();

    _require(
      rootDecision.refusal == AdmissionRefusal.policy,
      'root should be refused by policy, got ${rootDecision.refusal}',
    );
    final op2Shared = sharesClockChain(svAfterRoot, svAfterOp2);
    final op3Shared = sharesClockChain(svAfterOp2, svAfterOp3);
    final op2Outcome = op2Decision.accepted
        ? 'ACCEPTED'
        : 'REFUSED as ${op2Decision.refusal?.name}';
    final op3Outcome = op3Decision.accepted
        ? 'ACCEPTED'
        : 'REFUSED as ${op3Decision.refusal?.name}';
    final identical = op2Decision.accepted == op3Decision.accepted;
    final evidence =
        'state-vector trace: before-root=$svBeforeRoot, after-root=$svAfterRoot, '
        'after-op2=$svAfterOp2, after-op3=$svAfterOp3 (op2 shares root\'s '
        'client clock chain: $op2Shared; op3 shares op2\'s: $op3Shared); '
        'op2 decision: $op2Outcome (manual replay: $op2ManualReplay); '
        'op3 decision: $op3Outcome (manual replay: $op3ManualReplay); '
        'op2 and op3 outcomes are '
        '${identical ? 'IDENTICAL' : 'DIFFERENT — op3\'s later chain position '
            'changed the outcome relative to op2'}; '
        'A\'s speculativePendingStructs after all three decisions were '
        'delivered: $pendingAfterChain.';
    return NativeProbeResult(
      name: 'shape 4: three-command same-client chain, root (refused) -> op2 '
          '(independent) -> op3 (independent, proposed before either op1 or '
          'op2 is submitted) (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'rootDecision': rootDecision.toJson(),
        'op2Decision': op2Decision.toJson(),
        'op3Decision': op3Decision.toJson(),
        'op2ManualReplay': op2ManualReplay,
        'op3ManualReplay': op3ManualReplay,
        'stateVectors': {
          'beforeRoot': svToJson(svBeforeRoot),
          'afterRoot': svToJson(svAfterRoot),
          'afterOp2': svToJson(svAfterOp2),
          'afterOp3': svToJson(svAfterOp3),
        },
        'op2SharesRootClockChain': op2Shared,
        'op3SharesOp2ClockChain': op3Shared,
        'identicalOutcome': identical,
        'pendingAfterChain': pendingAfterChain,
      },
    );
  } finally {
    await rig.close();
  }
}

// ---------------------------------------------------------------------------
// Wayfinder ticket 04 (yrs-native-reject-admission-feasibility) — Verify
// Cross-Client Overlapping Multi-Select Admission Safety.
//
// Unlike tickets 02/03's same-client shapes (one client's clock chain shared
// between a refused leading command and an independent survivor), this axis
// is about two *different* clients (A, B — already distinct `ClientId`s in
// `NativeProbeRig`) each independently building a self-consistent
// `moveObjects` command over a partially-overlapping object set, both from
// the same accepted server baseline, before either submission reaches the
// server. The risk this axis actually chases (per the ticket's own framing)
// is not whether `pendingStructCount` misfires — a different client's own
// update has no structural reason to reference the other client's clock at
// all — but whether exact-U's `_matchesSemanticScope` before/after
// changed-object diff stays correct when two overlapping candidate
// executions land one after another, and whether the final field values for
// the contested objects look like a legitimate Yrs `Y.Map` per-key
// last-writer-wins resolution or a scope-check/silent-data-loss bug.
// ---------------------------------------------------------------------------

/// Independent, non-private re-derivation of `title_admission.dart`'s own
/// `_changedObjectIds` (same canonicalized-JSON diff shape as
/// `_canonicalObject`/`_canonicalProjection` above), computed here rather
/// than trusting the server's internal bookkeeping — the same
/// double-check-don't-trust-the-implementation posture as
/// [manualCandidateReplay]. Used to verify `_matchesSemanticScope`'s outcome
/// against real before/after server projections, not merely reason about it.
Set<String> changedObjectIds(DocProjection before, DocProjection after) {
  final ids = <String>{
    ...before.objects.keys.map((id) => id.value),
    ...after.objects.keys.map((id) => id.value),
  };
  return {
    for (final id in ids)
      if (_maybeObjectJson(before.objects[ObjectId(id)]) !=
          _maybeObjectJson(after.objects[ObjectId(id)]))
        id,
  };
}

String _maybeObjectJson(ObjectProjection? value) =>
    value == null ? 'null' : jsonEncode(_canonicalObject(value));

Future<void> _acceptFourObjectsEverywhere(
  NativeProbeRig rig,
  String prefix,
) async {
  for (final id in ['$prefix-obj1', '$prefix-obj2', '$prefix-obj3', '$prefix-obj4']) {
    await _acceptCreateEverywhere(rig, '$id-create', id);
  }
}

/// Core of both cross-client overlap scenarios (ticket 04's A-then-B and
/// B-then-A submission orders). `firstSubmitter` controls only the order the
/// two already-built, order-independent envelopes are handed to
/// `YjsAdmissionServer.submit` — both envelopes are always built from the
/// same accepted baseline (four Title objects, all at x=0, y=0, known to both
/// A and B) before either is submitted, per the ticket's own scenario
/// description ("both clients see the same starting state, propose
/// concurrently, before either submission reaches the server").
Future<NativeProbeResult> _crossClientOverlapScenario(
  Future<CrdtRuntime> Function() runtimeFactory,
  String firstSubmitter,
) async {
  final rig = await NativeProbeRig.create(runtimeFactory: runtimeFactory);
  try {
    final prefix = 'overlap-$firstSubmitter';
    await _acceptFourObjectsEverywhere(rig, prefix);
    final obj1 = '$prefix-obj1';
    final obj2 = '$prefix-obj2';
    final obj3 = '$prefix-obj3';
    final obj4 = '$prefix-obj4';

    final svBeforeA = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final svBeforeB = decodeStateVectorB64(
      (await rig.b.speculativeProjection()).stateVectorB64,
    );
    // A moves {obj1, obj2, obj3}; B moves {obj2, obj3, obj4} — obj2 and obj3
    // are the contested overlap. Neither client has seen the other's move at
    // this point; both are built from the identical four-object baseline.
    final aMove = await rig.a.moveObjects(
      '$prefix-a-move',
      [obj1, obj2, obj3],
      deltaX: 10,
      deltaY: 20,
    );
    final bMove = await rig.b.moveObjects(
      '$prefix-b-move',
      [obj2, obj3, obj4],
      deltaX: -5,
      deltaY: 100,
    );
    final svAfterAOwn = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final svAfterBOwn = decodeStateVectorB64(
      (await rig.b.speculativeProjection()).stateVectorB64,
    );
    // Verified, not assumed: A and B never advance each other's clock in
    // their own state vectors — confirms this axis is not a shared-clock
    // -chain question at all, unlike tickets 02/03.
    final crossClientClockShared =
        sharesClockChain(svBeforeA, svAfterBOwn) ||
        sharesClockChain(svBeforeB, svAfterAOwn);

    final TitleAdmissionEnvelope first;
    final TitleAdmissionEnvelope second;
    final String firstLabel;
    final String secondLabel;
    if (firstSubmitter == 'A') {
      first = aMove;
      second = bMove;
      firstLabel = 'A';
      secondLabel = 'B';
    } else {
      first = bMove;
      second = aMove;
      firstLabel = 'B';
      secondLabel = 'A';
    }

    Map<String, Object?> fieldsIn(DocProjection projection, String id) {
      final object = projection.objects[ObjectId(id)];
      return {'x': object?.x, 'y': object?.y};
    }

    Map<String, Object?> allFieldsIn(DocProjection projection) => {
      for (final id in [obj1, obj2, obj3, obj4]) id: fieldsIn(projection, id),
    };

    final serverBeforeFirst = await rig.server.projection();
    // Point 1's double-check for the *first* submission too, symmetric with
    // ticket 02/03's method: replay its own bytes alone against the current
    // (pre-anything) server snapshot.
    final firstManualReplayPreSubmit = await manualCandidateReplay(rig, first);
    final firstDecision = await rig.server.submit(first);
    final serverAfterFirst = await rig.server.projection();
    final changedByFirst = changedObjectIds(serverBeforeFirst, serverAfterFirst);

    // Point 1, the ticket's primary ask: establish, don't assume, whether
    // pendingStructCount/causal-completeness is even reachable/relevant in
    // this two-different-client shape. Replay `second`'s own update bytes
    // alone against the server's *current* snapshot (post-`first`) — exactly
    // the candidate shape `submit()` is about to build for `second` next.
    final secondManualReplayPreSubmit = await manualCandidateReplay(rig, second);

    final serverBeforeSecond = serverAfterFirst;
    final secondDecision = await rig.server.submit(second);
    final serverAfterSecond = await rig.server.projection();
    final changedBySecond = changedObjectIds(serverBeforeSecond, serverAfterSecond);

    for (final ticket in [firstDecision, secondDecision]) {
      await rig.a.deliver(ticket);
      await rig.b.deliver(ticket);
    }

    final serverFinal = await rig.server.projection();
    final aFinal = await rig.a.speculativeProjection();
    final bFinal = await rig.b.speculativeProjection();
    final converged =
        _canonicalProjection(serverFinal) == _canonicalProjection(aFinal) &&
        _canonicalProjection(serverFinal) == _canonicalProjection(bFinal);

    Map<String, Object?> fieldsFor(String id) => fieldsIn(serverFinal, id);

    bool scopeMatches(
      TitleAdmissionEnvelope envelope,
      Set<String> changed,
      AdmissionTicket decision,
    ) {
      // A refusal never touches server state, so there is nothing to
      // scope-check against — the scope question is moot, not "passed".
      if (!decision.accepted) return true;
      final declared = envelope.command.targetObjectIds.toSet();
      return changed.isNotEmpty &&
          changed.every(declared.contains) &&
          declared.every(changed.contains);
    }

    final firstScopeOk = scopeMatches(first, changedByFirst, firstDecision);
    final secondScopeOk = scopeMatches(second, changedBySecond, secondDecision);
    // Point 4, the ticket's most important possible output: did the
    // admission layer accept a command whose *actual* effect diverged from
    // what it declared (accepted, but its own declared target(s) show no
    // diff and/or something outside its declared scope changed)? Computed
    // here, not asserted — see `evidence`/`finalState` for whether this ever
    // fires.
    final falseAcceptanceDetected =
        (firstDecision.accepted && !firstScopeOk) ||
        (secondDecision.accepted && !secondScopeOk);

    final evidence =
        'order: $firstLabel-then-$secondLabel. Cross-client clock sharing: '
        '${crossClientClockShared ? 'UNEXPECTEDLY shared (see note)' : 'none confirmed (A and B never advance each other\'s clock in their own state vectors — this axis is not a shared-clock-chain question at all)'}. '
        '$firstLabel (declared targets ${first.command.targetObjectIds}) manual pre-submit replay: '
        '$firstManualReplayPreSubmit; server decision: '
        '${firstDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${firstDecision.refusal?.name}'}, '
        'actual changed objects: ${(changedByFirst.toList()..sort())}, scope match: $firstScopeOk. '
        '$secondLabel (declared targets ${second.command.targetObjectIds}) manual replay against the '
        'post-$firstLabel server snapshot (the exact candidate shape submit() builds next): '
        '$secondManualReplayPreSubmit; server decision: '
        '${secondDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${secondDecision.refusal?.name}'}, '
        'actual changed objects: ${(changedBySecond.toList()..sort())}, scope match: $secondScopeOk. '
        'Fields on server before $firstLabel: ${allFieldsIn(serverBeforeFirst)}; '
        'after $firstLabel: ${allFieldsIn(serverAfterFirst)}; '
        'after $secondLabel: ${allFieldsIn(serverAfterSecond)}. '
        'A/B/server projections converged after both decisions delivered: $converged. '
        'False acceptance detected (accepted with an actual scope diverging from its declared '
        'targetObjectIds): $falseAcceptanceDetected.';

    return NativeProbeResult(
      name: 'cross-client overlapping multi-select move, submitted '
          '$firstLabel-then-$secondLabel (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'order': '$firstLabel-then-$secondLabel',
        'stateVectors': {
          'beforeA': svToJson(svBeforeA),
          'beforeB': svToJson(svBeforeB),
          'afterAOwn': svToJson(svAfterAOwn),
          'afterBOwn': svToJson(svAfterBOwn),
        },
        'crossClientClockShared': crossClientClockShared,
        'firstLabel': firstLabel,
        'secondLabel': secondLabel,
        'firstManualReplayPreSubmit': firstManualReplayPreSubmit,
        'secondManualReplayPreSubmit': secondManualReplayPreSubmit,
        'firstDecision': firstDecision.toJson(),
        'secondDecision': secondDecision.toJson(),
        'changedByFirst': changedByFirst.toList()..sort(),
        'changedBySecond': changedBySecond.toList()..sort(),
        'firstScopeMatch': firstScopeOk,
        'secondScopeMatch': secondScopeOk,
        'fieldsBeforeFirst': allFieldsIn(serverBeforeFirst),
        'fieldsAfterFirst': allFieldsIn(serverAfterFirst),
        'fieldsAfterSecond': allFieldsIn(serverAfterSecond),
        'finalFields': {
          obj1: fieldsFor(obj1),
          obj2: fieldsFor(obj2),
          obj3: fieldsFor(obj3),
          obj4: fieldsFor(obj4),
        },
        'converged': converged,
        'falseAcceptanceDetected': falseAcceptanceDetected,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Scenario A: submission order A-then-B. A's move (`{obj1,obj2,obj3}`)
/// lands first and is merged into server canonical state; B's move
/// (`{obj2,obj3,obj4}`), built concurrently and independently, is then
/// submitted against the post-A server snapshot.
Future<NativeProbeResult> crossClientOverlapMoveAThenB(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _crossClientOverlapScenario(runtimeFactory, 'A');

/// Scenario B: the same setup and the same two independently-built
/// envelopes as [crossClientOverlapMoveAThenB], but submitted in the
/// opposite order (B-then-A) — to answer the ticket's §3 question of
/// whether submission order changes the outcome.
Future<NativeProbeResult> crossClientOverlapMoveBThenA(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _crossClientOverlapScenario(runtimeFactory, 'B');

// ---------------------------------------------------------------------------
// Wayfinder ticket 05 (yrs-native-reject-admission-feasibility) — Verify IME
// Composition Churn Causal Coupling.
//
// **Capability-gap finding, reported per the ticket's own explicit
// instruction rather than silently worked around.** The ticket's own
// constraint text reads "insertText/deleteText cover a composition update's
// delete+insert pair" and this file's caller-supplied orienting brief
// additionally asked whether one composition update (delete-old-candidate +
// insert-new-candidate) can be modeled as a SINGLE `TitleAdmissionEnvelope`/
// one `propose()` call producing exactly one Yrs update, by having the
// `mutate()` callback invoke the runtime's delete and insert in sequence with
// no drain in between. **It cannot, with the existing `CrdtRuntime` surface —
// confirmed empirically, not reasoned.** `YrsRuntime.deleteText`/`insertText`
// (`lib/runtime/yrs/yrs_runtime.dart`) each open and commit their own Yrs
// transaction via the private `_mutate` helper, appending their own entry to
// `_YrsDoc.outbox` independently; calling both inside one `propose()`
// `mutate()` body with no intervening drain still leaves TWO entries in the
// outbox (verified directly: a throwaway script that did exactly this printed
// `outbox entries after delete+insert with no drain in between: 2`, not `1`),
// which makes `propose()`'s own "exactly one Yjs update per command"
// assertion throw before an envelope can even be built. There is no
// `CrdtRuntime` primitive today for "run several mutations, then commit one
// transaction" — `setFields` is the closest existing example of batching, but
// it batches multiple *field writes* inside its own single call, not two
// separate public mutation methods (`deleteText` then `insertText`).
//
// This is not merely a probe-abstraction quirk: reading the real production
// `TitleYrsEditingBridge.updateComposition` bridge method itself all the way
// down to `TitleView` (`packages/collaboration_document/lib/src/
// title_view.dart`) shows the same shape. `updateComposition`'s own doc
// comment claims its delete+insert land "as a single batched Yrs transaction"
// (ticket 06 §3), but `TitleView.deleteClamped`/`insertText` each call
// `_localTransaction()` (`title_undo_manager.dart`'s `_beginLocalTransaction`,
// a *fresh* `writeTransactionWithOrigin` every call) and then
// `_adaptor.transactionCommit(txn)` independently, exactly like this probe's
// `CrdtRuntime.deleteText`/`insertText`. So the real bridge's own delete-then-
// insert composition step is, at the actual Yrs-transaction granularity, two
// committed transactions too — this probe's two-`propose()`-calls model below
// is a faithful mirror of what `TitleYrsEditingBridge` really executes, not a
// mismatched invention, even though it diverges from that method's own doc
// comment (a discrepancy worth flagging to whoever owns that file, but out of
// this read-only-reference ticket's scope to fix). Per the ticket's own
// constraint, `title_admission.dart` was NOT modified to add a new
// `TitleCommandKind` or a batched-mutation primitive — `insertText`/
// `deleteText` already cover the pair, at the granularity the runtime
// actually operates at.
//
// Consequently, "burst size" below is counted in raw same-client Yrs
// transactions/admission commands (what `pendingStructCount` and `submit()`
// actually operate on) — a burst of N transactions is N/2 real IME
// candidate-replacement steps (each step = one deleteText transaction + one
// insertText transaction). The ticket's own "2 vs. 20 same-client
// transactions" phrasing is honored literally at this granularity.
// ---------------------------------------------------------------------------

/// A composition candidate's replacement text, always exactly two characters
/// wide (`"01"`..`"10"` for this ticket's largest burst) so a burst's delete
/// length never has to change between steps.
String _compositionCandidateText(int step) => step.toString().padLeft(2, '0');

/// Same as [_acceptInsertEverywhere] but at an explicit [index] — needed here
/// because the composition candidate must be seeded immediately *after* the
/// already-accepted `"seed"` text, not prepended at index 0.
Future<void> _acceptInsertAtEverywhere(
  NativeProbeRig rig,
  String opId,
  String titleId,
  int index,
  String text,
) async {
  final envelope = await rig.a.insert(opId, titleId, index, text);
  final ticket = await rig.server.submit(envelope);
  _require(ticket.accepted, '$opId was not accepted: ${ticket.refusal}');
  await rig.a.deliver(ticket);
  await rig.b.deliver(ticket);
}

/// One IME composition-update, submitted as two consecutive same-client
/// admission commands — a `deleteText` removing the previous candidate's
/// [oldLength] characters at [anchor], then an `insertText` inserting
/// [newText] in its place — per this section's header comment on why this is
/// two `propose()`/`submit()` cycles, not one. Verifies the shared-clock-chain
/// precondition around each half via a real state-vector trace (per ticket
/// 02's method) rather than assuming it holds, and checks the server's actual
/// projected text against the expected candidate immediately after each half
/// lands — the false-acceptance hunt this ticket's answer must report on.
Future<Map<String, Object?>> _submitCompositionStep(
  NativeProbeRig rig,
  String titleId,
  String opPrefix,
  int anchor,
  int oldLength,
  String newText,
  Map<int, int> svBeforePair,
) async {
  final deleteEnvelope = await rig.a.erase('$opPrefix-del', titleId, anchor, oldLength);
  final svAfterDelete = decodeStateVectorB64(
    (await rig.a.speculativeProjection()).stateVectorB64,
  );
  final deleteShared = sharesClockChain(svBeforePair, svAfterDelete);
  final deleteDecision = await rig.server.submit(deleteEnvelope);

  final insertEnvelope = await rig.a.insert('$opPrefix-ins', titleId, anchor, newText);
  final svAfterInsert = decodeStateVectorB64(
    (await rig.a.speculativeProjection()).stateVectorB64,
  );
  final insertShared = sharesClockChain(svAfterDelete, svAfterInsert);
  final insertDecision = await rig.server.submit(insertEnvelope);

  final actualText = (await rig.server.projection()).objects[ObjectId(titleId)]?.text;
  final expectedText = 'seed$newText';

  return {
    'opPrefix': opPrefix,
    'deleteEnvelope': deleteEnvelope,
    'deleteDecision': deleteDecision,
    'deleteSharedClockChain': deleteShared,
    'svAfterDelete': svAfterDelete,
    'insertEnvelope': insertEnvelope,
    'insertDecision': insertDecision,
    'insertSharedClockChain': insertShared,
    'svAfterInsert': svAfterInsert,
    'expectedTextAfterStep': expectedText,
    'actualTextAfterStep': actualText,
    'textMatchesExpected': actualText == expectedText,
  };
}

/// Shared core of the two burst-size scenarios (ticket 05 §1/§3 — "does burst
/// size, 2 vs. 20 same-client transactions, change the outcome"). Leading
/// `createTitle` refused by policy, then a same-client burst of
/// [transactionCount] Yrs transactions (delete+insert composition-update
/// pairs, see the header comment for why the unit is a transaction not a
/// composition step), all on the same speculative session (no rebuild in
/// between, preserving the shared client clock chain the whole time).
Future<NativeProbeResult> _imeCompositionBurstScenario(
  Future<CrdtRuntime> Function() runtimeFactory,
  int transactionCount,
  String label,
) async {
  if (transactionCount < 2 || transactionCount.isOdd) {
    throw ArgumentError.value(
      transactionCount,
      'transactionCount',
      'must be an even number >= 2 (one delete + one insert per composition step)',
    );
  }
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root-ime-$label' ? AdmissionRefusal.policy : null,
  );
  try {
    final titleId = 'title-ime-$label';
    await _acceptCreateEverywhere(rig, 'base-ime-$label', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-ime-$label', titleId, 0, 'seed');
    // A candidate already live before the burst starts (mid-composition, not
    // the very first keystroke) so every transaction in the recorded burst is
    // a uniform delete+insert pair.
    await _acceptInsertAtEverywhere(rig, 'seed-candidate-ime-$label', titleId, 4, '00');
    const anchor = 4;
    const candidateLength = 2;

    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-ime-$label', 'title-root-ime-$label');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final rootDecision = await rig.server.submit(root);
    _require(
      rootDecision.refusal == AdmissionRefusal.policy,
      'root should be refused by policy, got ${rootDecision.refusal}',
    );

    final steps = transactionCount ~/ 2;
    final stepRecords = <Map<String, Object?>>[];
    var previousSv = svAfterRoot;
    for (var step = 1; step <= steps; step++) {
      final record = await _submitCompositionStep(
        rig,
        titleId,
        '$label-step$step',
        anchor,
        candidateLength,
        _compositionCandidateText(step),
        previousSv,
      );
      stepRecords.add(record);
      previousSv = record['svAfterInsert']! as Map<int, int>;
    }

    // Deliver every decision back to A in submission order, exercising
    // pendingStructCount/pendingOpIds convergence across the WHOLE burst, not
    // just mid-flight.
    await rig.a.deliver(rootDecision);
    for (final record in stepRecords) {
      await rig.a.deliver(record['deleteDecision']! as AdmissionTicket);
      await rig.a.deliver(record['insertDecision']! as AdmissionTicket);
    }
    final pendingAfterAllDelivered = await rig.a.speculativePendingStructs();
    final pendingOpIdsAfterAllDelivered = rig.a.pendingOpIds;

    final allDeleteAccepted =
        stepRecords.every((r) => (r['deleteDecision']! as AdmissionTicket).accepted);
    final allInsertAccepted =
        stepRecords.every((r) => (r['insertDecision']! as AdmissionTicket).accepted);
    final allSharedClock = stepRecords.every(
      (r) =>
          (r['deleteSharedClockChain']! as bool) &&
          (r['insertSharedClockChain']! as bool),
    );
    final anyTextMismatch =
        stepRecords.where((r) => !(r['textMatchesExpected']! as bool)).toList();

    final firstRecord = stepRecords.first;
    final lastRecord = stepRecords.last;
    final firstManualReplay = await manualCandidateReplay(
      rig,
      firstRecord['insertEnvelope']! as TitleAdmissionEnvelope,
    );
    final lastManualReplay = await manualCandidateReplay(
      rig,
      lastRecord['insertEnvelope']! as TitleAdmissionEnvelope,
    );

    final finalProjection = await rig.server.projection();
    final finalText = finalProjection.objects[ObjectId(titleId)]?.text;
    final expectedFinalText = 'seed${_compositionCandidateText(steps)}';

    String outcomeOf(AdmissionTicket ticket) =>
        ticket.accepted ? 'ACCEPTED' : 'REFUSED as ${ticket.refusal?.name}';

    final evidence =
        'burst size: $transactionCount same-client Yrs transactions ($steps '
        'composition-update steps, each a delete+insert pair — see this '
        'file\'s ticket-05 header comment for why a composition update cannot '
        'be one combined Yrs update with the existing CrdtRuntime surface). '
        'Root refused by policy (${rootDecision.refusal?.name}), '
        'before-root=$svBeforeRoot after-root=$svAfterRoot. Shared-clock-chain '
        'precondition confirmed at EVERY transaction in the burst (verified via '
        'decodeStateVectorB64/sharesClockChain, not assumed): $allSharedClock. '
        'All $steps delete-halves accepted: $allDeleteAccepted; all $steps '
        'insert-halves accepted: $allInsertAccepted. '
        'First transaction (step 1): delete='
        '${outcomeOf(firstRecord['deleteDecision']! as AdmissionTicket)}, '
        'insert=${outcomeOf(firstRecord['insertDecision']! as AdmissionTicket)} '
        '(manual replay of its insert half: $firstManualReplay). '
        'Last transaction (step $steps, furthest from the refused root — "the '
        'command under test"): delete='
        '${outcomeOf(lastRecord['deleteDecision']! as AdmissionTicket)}, '
        'insert=${outcomeOf(lastRecord['insertDecision']! as AdmissionTicket)} '
        '(manual replay of its insert half: $lastManualReplay). '
        'Server projection text checked after every single step matched the '
        'expected candidate at that point — no silent corruption/no-op found: '
        '${anyTextMismatch.isEmpty}'
        '${anyTextMismatch.isEmpty ? '' : ' — MISMATCHES at: ${anyTextMismatch.map((r) => r['opPrefix']).toList()}'}. '
        'Final server text: "$finalText" (expected "$expectedFinalText"). '
        'After delivering every decision back to A: pendingOpIds='
        '$pendingOpIdsAfterAllDelivered, speculativePendingStructs='
        '$pendingAfterAllDelivered.';

    return NativeProbeResult(
      name: 'IME composition burst, $transactionCount same-client transactions '
          '($steps composition-update steps) after a refused leading root '
          '(native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'transactionCount': transactionCount,
        'steps': steps,
        'rootDecision': rootDecision.toJson(),
        'stateVectors': {
          'beforeRoot': svToJson(svBeforeRoot),
          'afterRoot': svToJson(svAfterRoot),
        },
        'allDeleteAccepted': allDeleteAccepted,
        'allInsertAccepted': allInsertAccepted,
        'allSharedClockChain': allSharedClock,
        'anyTextMismatch': anyTextMismatch.map((r) => r['opPrefix']).toList(),
        'finalText': finalText,
        'expectedFinalText': expectedFinalText,
        'finalTextCorrect': finalText == expectedFinalText,
        'firstStepManualReplay': firstManualReplay,
        'lastStepManualReplay': lastManualReplay,
        'pendingAfterAllDelivered': pendingAfterAllDelivered,
        'pendingOpIdsAfterAllDelivered': pendingOpIdsAfterAllDelivered,
        'perTransactionSummary': [
          for (final r in stepRecords)
            {
              'opPrefix': r['opPrefix'],
              'deleteAccepted': (r['deleteDecision']! as AdmissionTicket).accepted,
              'insertAccepted': (r['insertDecision']! as AdmissionTicket).accepted,
              'deleteSharedClockChain': r['deleteSharedClockChain'],
              'insertSharedClockChain': r['insertSharedClockChain'],
              'textMatchesExpected': r['textMatchesExpected'],
            },
        ],
      },
    );
  } finally {
    await rig.close();
  }
}

/// Small burst — 2 same-client transactions (1 composition-update step)
/// between the refused root and the transaction under test.
Future<NativeProbeResult> imeCompositionSmallBurstCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _imeCompositionBurstScenario(runtimeFactory, 2, 'small');

/// Large burst — 20 same-client transactions (10 composition-update steps)
/// between the refused root and the transaction under test.
Future<NativeProbeResult> imeCompositionLargeBurstCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _imeCompositionBurstScenario(runtimeFactory, 20, 'large');

/// Ticket 05 §2 — does `cancelComposition`'s compensating delete (a standalone
/// delete of the still-live candidate range, no paired insert) introduce a NEW
/// same-client coupling risk beyond tickets 02–04's shapes? Leading refused
/// root -> a same-client composition burst (3 steps, 6 transactions) -> a
/// final standalone compensating delete removing the burst's last-landed
/// candidate in full, mirroring `TitleYrsEditingBridge.cancelComposition`'s
/// own shape (no new insert; the composition gate just closes).
Future<NativeProbeResult> imeCancelCompositionCoupling(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'reject-root-ime-cancel' ? AdmissionRefusal.policy : null,
  );
  try {
    const titleId = 'title-ime-cancel';
    const anchor = 4;
    const candidateLength = 2;
    const burstSteps = 3;

    await _acceptCreateEverywhere(rig, 'base-ime-cancel', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-ime-cancel', titleId, 0, 'seed');
    await _acceptInsertAtEverywhere(rig, 'seed-candidate-ime-cancel', titleId, anchor, '00');

    final svBeforeRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle('reject-root-ime-cancel', 'title-root-ime-cancel');
    final svAfterRoot = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final rootDecision = await rig.server.submit(root);
    _require(
      rootDecision.refusal == AdmissionRefusal.policy,
      'root should be refused by policy, got ${rootDecision.refusal}',
    );

    final stepRecords = <Map<String, Object?>>[];
    var previousSv = svAfterRoot;
    for (var step = 1; step <= burstSteps; step++) {
      final record = await _submitCompositionStep(
        rig,
        titleId,
        'cancel-step$step',
        anchor,
        candidateLength,
        _compositionCandidateText(step),
        previousSv,
      );
      stepRecords.add(record);
      previousSv = record['svAfterInsert']! as Map<int, int>;
    }

    // The compensating delete itself: removes the burst's last-landed
    // candidate with NO paired insert — cancelComposition's own shape.
    final svBeforeCancel = previousSv;
    final cancelDelete = await rig.a.erase(
      'cancel-compensating-delete',
      titleId,
      anchor,
      candidateLength,
    );
    final svAfterCancel = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final cancelSharedClock = sharesClockChain(svBeforeCancel, svAfterCancel);
    final cancelDecision = await rig.server.submit(cancelDelete);
    final cancelManualReplay = await manualCandidateReplay(rig, cancelDelete);

    await rig.a.deliver(rootDecision);
    for (final record in stepRecords) {
      await rig.a.deliver(record['deleteDecision']! as AdmissionTicket);
      await rig.a.deliver(record['insertDecision']! as AdmissionTicket);
    }
    await rig.a.deliver(cancelDecision);
    final pendingAfterAllDelivered = await rig.a.speculativePendingStructs();

    final finalProjection = await rig.server.projection();
    final finalText = finalProjection.objects[ObjectId(titleId)]?.text;
    const expectedFinalText = 'seed'; // candidate fully removed, nothing re-inserted

    final allBurstAccepted = stepRecords.every(
      (r) =>
          (r['deleteDecision']! as AdmissionTicket).accepted &&
          (r['insertDecision']! as AdmissionTicket).accepted,
    );
    final allBurstSharedClock = stepRecords.every(
      (r) =>
          (r['deleteSharedClockChain']! as bool) &&
          (r['insertSharedClockChain']! as bool),
    );

    final evidence =
        'leading root refused by policy (${rootDecision.refusal?.name}), '
        'before-root=$svBeforeRoot after-root=$svAfterRoot. Burst of '
        '$burstSteps composition-update steps (${burstSteps * 2} transactions), '
        'all same-client, shared-clock-chain verified at every step: '
        '$allBurstSharedClock; all accepted: $allBurstAccepted. Compensating '
        'delete (cancelComposition\'s shape — standalone deleteText, no paired '
        'insert) removing the burst\'s last-landed candidate '
        '("${_compositionCandidateText(burstSteps)}"): state vector before it '
        '$svBeforeCancel, after it $svAfterCancel — shared-clock-chain with the '
        'transaction immediately before it: $cancelSharedClock; server '
        'decision: ${cancelDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${cancelDecision.refusal?.name}'}; '
        'manual candidate replay of the compensating delete\'s own bytes alone: '
        '$cancelManualReplay. Final server text after everything delivered: '
        '"$finalText" (expected "$expectedFinalText" — candidate fully removed, '
        'nothing re-inserted): ${finalText == expectedFinalText}. A '
        'pendingOpIds/speculativePendingStructs after every decision delivered: '
        '${rig.a.pendingOpIds}/$pendingAfterAllDelivered.';

    return NativeProbeResult(
      name: 'cancelComposition compensating delete after a refused root and a '
          'same-client composition burst (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'rootDecision': rootDecision.toJson(),
        'stateVectors': {
          'beforeRoot': svToJson(svBeforeRoot),
          'afterRoot': svToJson(svAfterRoot),
          'beforeCancel': svToJson(svBeforeCancel),
          'afterCancel': svToJson(svAfterCancel),
        },
        'allBurstAccepted': allBurstAccepted,
        'allBurstSharedClockChain': allBurstSharedClock,
        'cancelSharedClockChain': cancelSharedClock,
        'cancelDecision': cancelDecision.toJson(),
        'cancelManualReplay': cancelManualReplay,
        'finalText': finalText,
        'expectedFinalText': expectedFinalText,
        'finalTextCorrect': finalText == expectedFinalText,
        'pendingAfterAllDelivered': pendingAfterAllDelivered,
        'pendingOpIdsAfterAllDelivered': rig.a.pendingOpIds,
      },
    );
  } finally {
    await rig.close();
  }
}

// ---------------------------------------------------------------------------
// Wayfinder ticket 06 (yrs-native-reject-admission-feasibility) — Verify
// Undo Interaction With Pending or Refused Chains.
//
// Two tasks. First, port `title_admission_test.dart`'s two remaining
// undo-adjacent Yjs-only scenarios (`_transitiveWithdrawal`,
// `_policyRejectionAcrossCommandKinds`) to native `YrsRuntime`, per ticket
// 02's own method. Second, probe two shapes specific to `undo` that no
// prior ticket in this map has touched: undoing a command that is still
// *pending* (neither accepted nor refused) when the undo itself is proposed
// (shape A, five scenarios below), and undoing a command that has already
// been *refused* (shape B, two scenarios below) — the ticket's own named
// "most important possible output" is whether the latter can ever produce a
// wrongly-ACCEPTED inverse for content that never actually landed.
//
// All scenarios here stay in exact-U mode (`NativeProbeRig.create`'s
// default) — `_applyCommand`'s `TitleCommandKind.undo` case in
// `title_admission.dart` explicitly throws for semantic replay ("semantic Q
// replay does not support identity-bound undo"), so semantic mode is simply
// not a candidate runtime path for any of this ticket's scenarios, not a
// choice made for convenience.
// ---------------------------------------------------------------------------

/// Ported from `title_admission_test.dart`'s `_transitiveWithdrawal`. A
/// five-command same-client chain (`root` -> `insert` -> `format` ->
/// `delete` -> `undo`, each `dependsOn` the one before) is proposed in full
/// on one speculative session before anything is submitted; only `root` is
/// ever submitted, and it is refused by policy. Verifies the whole chain,
/// including the real `UndoManager`-generated `undo` at its tail, withdraws
/// transitively client-side without ever reaching the server.
Future<NativeProbeResult> transitiveWithdrawalNative(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'create-root-native' ? AdmissionRefusal.policy : null,
  );
  try {
    final svBeforeChain = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final root = await rig.a.createTitle(
      'create-root-native',
      'title-root-native',
    );
    final insert = await rig.a.insert(
      'edit-child-native',
      'title-root-native',
      0,
      'hello',
      dependsOn: [root.opId],
    );
    final format = await rig.a.format(
      'format-child-native',
      'title-root-native',
      0,
      5,
      const {'bold': true},
      dependsOn: [insert.opId],
    );
    final delete = await rig.a.erase(
      'delete-child-native',
      'title-root-native',
      0,
      1,
      dependsOn: [format.opId],
    );
    final undo = await rig.a.undo(
      'undo-child-native',
      'title-root-native',
      targetOpId: delete.opId,
      dependsOn: [delete.opId],
    );
    final svAfterChain = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final expectedChain = [
      root.opId,
      insert.opId,
      format.opId,
      delete.opId,
      undo.opId,
    ];
    _require(
      rig.a.pendingOpIds.join(',') == expectedChain.join(','),
      'A pendingOpIds should be the full 5-op chain before root is '
      'submitted, expected $expectedChain got ${rig.a.pendingOpIds}',
    );

    final refused = await rig.server.submit(root);
    _require(
      refused.refusal == AdmissionRefusal.policy,
      'root refusal should be AdmissionRefusal.policy, got ${refused.refusal}',
    );

    // Ticket 02's double-check, applied here: had the chain's deepest
    // command (the undo inverse) actually been submitted instead of
    // withdrawn client-side, would the server's own candidate execution
    // have refused it anyway? `title-root-native` never landed on any
    // server candidate at this point, so replaying undo's own bytes alone
    // independently confirms none of these four descendants could ever
    // have been admitted, even without dependsOn withdrawal.
    Map<String, Object?>? undoManualReplay;
    String? undoManualReplayError;
    try {
      undoManualReplay = await manualCandidateReplay(rig, undo);
    } catch (error) {
      undoManualReplayError = '$error';
    }

    await rig.a.deliver(refused);
    _require(
      rig.a.pendingOpIds.isEmpty,
      'A pendingOpIds should be empty after root refusal cascades, got '
      '${rig.a.pendingOpIds}',
    );
    final speculativeAfter = await rig.a.speculativeProjection();
    _require(
      speculativeAfter.objects.isEmpty,
      'A speculative projection should be empty, got '
      '${speculativeAfter.objects}',
    );
    final serverAfter = await rig.server.projection();
    _require(
      serverAfter.objects.isEmpty,
      'server B should be empty, got ${serverAfter.objects}',
    );
    final pendingAfter = await rig.a.speculativePendingStructs();
    _require(
      pendingAfter == 0,
      'A speculativePendingStructs should be 0 after full withdrawal, got '
      '$pendingAfter',
    );

    final evidence =
        'state-vector trace: before-chain=$svBeforeChain, '
        'after-full-chain-proposed=$svAfterChain (root, insert, format, '
        'delete, and undo are all proposed on the SAME client session, so '
        'withdrawing root must withdraw all four descendants by explicit '
        'dependsOn chaining -- there is no shared-clock-chain question here '
        'the way tickets 02/03 probed, since none of these four ever reach '
        'the server to be independently evaluated). Root refused by policy; '
        'A pendingOpIds cascaded from the full 5-op chain to empty in one '
        'deliver() call, both projections emptied, pendingStructs back to '
        '0. Manual candidate replay of the deepest command (the real '
        'UndoManager-generated inverse of the delete) alone against the '
        '(still-empty) server snapshot: '
        '${undoManualReplayError == null ? undoManualReplay : 'THREW: $undoManualReplayError'} '
        '-- title-root-native never existed on any server candidate, so '
        'this independently confirms the withdrawn chain could not have '
        'landed even if dependsOn withdrawal had not caught it first. '
        'Compares to Yjs: MATCH -- '
        '`title_admission_test.dart`\'s `_transitiveWithdrawal` shows the '
        'identical cascade shape (pendingOpIds emptied by one deliver() '
        'call, both projections empty, pendingStructs 0) on YjsRuntime; '
        'this port reproduces it unchanged on native Yrs, including the '
        'real Yrs UndoManager inverse at the chain\'s tail.';

    return NativeProbeResult(
      name:
          'refused CreateTitle withdraws dependent edit/format/delete/undo '
          'chain (native Yrs, ported from title_admission_test.dart '
          '_transitiveWithdrawal)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'rootDecision': refused.toJson(),
        'stateVectors': {
          'beforeChain': svToJson(svBeforeChain),
          'afterChainProposed': svToJson(svAfterChain),
        },
        'undoManualReplay': undoManualReplay,
        'undoManualReplayError': undoManualReplayError,
        'pendingOpIdsAfter': rig.a.pendingOpIds,
        'pendingStructsAfter': pendingAfter,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Ported from `title_admission_test.dart`'s
/// `_policyRejectionAcrossCommandKinds`. Every Title command kind, including
/// a real `UndoManager`-generated `undo`, is individually refused by policy
/// (the undo's own target, `undoTarget`, is deliberately never submitted
/// itself, so it stays speculative for the real UndoManager to derive an
/// inverse from — this is policy admission being tested, not causal
/// completeness). Confirms the connection survives all four refusals and an
/// unrelated pending operation can still be accepted afterward.
Future<NativeProbeResult> policyRejectionAcrossCommandKindsNative(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  const rejectedIds = {
    'reject-insert-native',
    'reject-delete-native',
    'reject-format-native',
    'reject-undo-native',
  };
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        rejectedIds.contains(envelope.opId) ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-policy-native', 'title-a-native');
    await _acceptInsertEverywhere(
      rig,
      'seed-policy-native',
      'title-a-native',
      'seed',
    );

    final decisions = <AdmissionTicket>[];
    Future<void> reject(TitleAdmissionEnvelope envelope) async {
      final decision = await rig.server.submit(envelope);
      decisions.add(decision);
      _require(
        decision.refusal == AdmissionRefusal.policy,
        '${envelope.opId} should be refused by policy, got '
        '${decision.refusal}',
      );
      await rig.a.deliver(decision);
    }

    await reject(
      await rig.a.insert('reject-insert-native', 'title-a-native', 0, 'x'),
    );
    await reject(
      await rig.a.erase('reject-delete-native', 'title-a-native', 0, 1),
    );
    await reject(
      await rig.a.format(
        'reject-format-native',
        'title-a-native',
        0,
        1,
        const {'bold': true},
      ),
    );
    // The target stays speculative (never submitted) so the real Yrs
    // UndoManager can produce a real inverse from it -- the undo envelope
    // deliberately carries no dependsOn: this scenario tests policy
    // admission ahead of any causal-completeness question.
    final undoTarget = await rig.a.insert(
      'undo-target-native',
      'title-a-native',
      0,
      'u',
    );
    final undo = await rig.a.undo(
      'reject-undo-native',
      'title-a-native',
      targetOpId: undoTarget.opId,
    );
    final undoManualReplay = await manualCandidateReplay(rig, undo);
    await reject(undo);

    _require(
      decisions.length == 4,
      'expected 4 policy refusals, got ${decisions.length}',
    );
    _require(
      rig.a.pendingOpIds.join(',') == [undoTarget.opId].join(','),
      'A pendingOpIds should be exactly [${undoTarget.opId}], got '
      '${rig.a.pendingOpIds}',
    );

    final targetDecision = await rig.server.submit(undoTarget);
    _require(
      targetDecision.accepted,
      'undoTarget should still be accepted after undo was refused by '
      'policy, got ${targetDecision.refusal}',
    );
    await rig.a.deliver(targetDecision);
    await rig.b.deliver(targetDecision);
    await _expectConverged(rig);
    _require(
      rig.a.connectionAlive,
      'connection should stay alive across four policy refusals',
    );
    final pendingAfter = await rig.a.speculativePendingStructs();
    _require(
      pendingAfter == 0,
      'A speculativePendingStructs should be 0 once everything settles, '
      'got $pendingAfter',
    );

    final evidence =
        'real client-generated Yrs updates for insert, delete, format, and '
        'a genuine UndoManager-derived undo were each individually refused '
        'with AdmissionRefusal.policy (${decisions.map((d) => d.refusal?.name).toList()}); '
        'manual candidate replay of the refused undo\'s own bytes alone '
        'against the (undoTarget-free at that point) server snapshot: '
        '$undoManualReplay -- the undo was refused by policy before this '
        'candidate execution ever ran, so this replay is an independent, '
        'not authoritative, secondary check. The connection stayed alive '
        'across all four refusals; only the refused entries were withdrawn '
        '-- undoTarget, never itself refused, was submitted afterward and '
        'ACCEPTED, and A/B/server converged. Compares to Yjs: MATCH -- '
        '`title_admission_test.dart`\'s `_policyRejectionAcrossCommandKinds` '
        'shows the identical shape (4 policy refusals, connection alive, '
        'unrelated pending op still accepted, full convergence) on '
        'YjsRuntime; this port reproduces it unchanged on native Yrs.';

    return NativeProbeResult(
      name:
          'policy rejection across every Title command kind, including a '
          'real UndoManager-derived undo (native Yrs, ported from '
          'title_admission_test.dart _policyRejectionAcrossCommandKinds)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'decisions': decisions.map((d) => d.toJson()).toList(),
        'undoManualReplay': undoManualReplay,
        'targetDecision': targetDecision.toJson(),
        'pendingOpIdsAfterRejections': [undoTarget.opId],
        'pendingStructsAfter': pendingAfter,
        'connectionAlive': rig.a.connectionAlive,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Shared core of the two "shape A" ordering scenarios: client A proposes
/// `x` (an insert) and then, on the SAME speculative session with no
/// rebuild in between, `undo` targeting `x` -- both are still purely local,
/// client-side pending commands at this point; NEITHER has been submitted
/// to the server yet. This is the ticket's own definition of "still pending
/// admission" for undo's target. `order` then controls only which of the
/// two already-built, order-independent envelopes is handed to
/// `YjsAdmissionServer.submit` first -- no policy refuses anything here, so
/// this pair answers "does submission order alone change whether the
/// outcomes make sense" for the ordinary, no-refusal case.
Future<NativeProbeResult> _pendingUndoOrderScenario(
  Future<CrdtRuntime> Function() runtimeFactory,
  String order, // 'x-then-undo' or 'undo-then-x'
) async {
  final rig = await NativeProbeRig.create(runtimeFactory: runtimeFactory);
  try {
    final titleId = 'title-pending-order-${order.replaceAll('-', '_')}';
    await _acceptCreateEverywhere(rig, 'base-pending-$order', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-pending-$order', titleId, 0, 'seed');

    final svBeforeX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final x = await rig.a.insert('pending-x-$order', titleId, 4, 'revert-me');
    final svAfterX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final undo = await rig.a.undo(
      'pending-undo-$order',
      titleId,
      targetOpId: x.opId,
      dependsOn: [x.opId],
    );
    final svAfterUndo = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    _require(
      rig.a.pendingOpIds.join(',') == [x.opId, undo.opId].join(','),
      'both x and undo should be pending before either is submitted, got '
      '${rig.a.pendingOpIds}',
    );
    // NOTE on this comparison's shape: unlike tickets 02/03's
    // sharesClockChain(afterRoot, afterIndependent) pattern -- which always
    // has a client ALREADY present with some clock in the "before" snapshot
    // -- x here is the FIRST local edit of a just-rebuilt session, so its
    // client id is entirely absent from svBeforeX (a lib0 state vector only
    // lists clients with clock > 0). sharesClockChain(svBeforeX, svAfterX)
    // is therefore not a meaningful check by construction (it will always
    // read false for a brand-new client id) and is reported for
    // completeness only, not as a pass/fail signal. The meaningful check is
    // whether undo continues x's OWN newly-started clock chain:
    final undoShared = sharesClockChain(svAfterX, svAfterUndo);

    late final AdmissionTicket xDecision;
    late final AdmissionTicket undoDecision;
    late final Map<String, Object?> undoManualReplayPreSubmit;
    if (order == 'x-then-undo') {
      xDecision = await rig.server.submit(x);
      undoManualReplayPreSubmit = await manualCandidateReplay(rig, undo);
      undoDecision = await rig.server.submit(undo);
    } else {
      undoManualReplayPreSubmit = await manualCandidateReplay(rig, undo);
      undoDecision = await rig.server.submit(undo);
      xDecision = await rig.server.submit(x);
    }

    if (order == 'x-then-undo') {
      await rig.a.deliver(xDecision);
      await rig.a.deliver(undoDecision);
    } else {
      await rig.a.deliver(undoDecision);
      await rig.a.deliver(xDecision);
    }
    await rig.b.deliver(xDecision);
    if (undoDecision.accepted) await rig.b.deliver(undoDecision);
    await _expectConverged(rig);
    final pendingAfter = await rig.a.speculativePendingStructs();

    final serverFinal = await rig.server.projection();
    final finalText = serverFinal.objects[ObjectId(titleId)]?.text;
    final expectedFinalText = undoDecision.accepted ? 'seed' : 'seedrevert-me';
    final finalTextSane = finalText == expectedFinalText;

    final evidence =
        'order: $order. State-vector trace: before-x=$svBeforeX (x\'s own '
        'client id is absent here -- this is the first local edit of a '
        'freshly-rebuilt session), after-x=$svAfterX (x\'s client id now '
        'present, advanced from nonexistent to a real clock -- x\'s own '
        'client authored real content), after-undo=$svAfterUndo. undo '
        'shares x\'s own clock chain (i.e. does undo\'s own client clock '
        'advance FURTHER past x\'s): $undoShared -- expected/confirmed '
        'false: undo\'s mutate is a real UndoManager-generated DELETE of '
        'x\'s own just-inserted range, and per ticket 03 shape 2\'s finding '
        '(a pure delete never advances the deleting client\'s own clock), '
        'that holds here too even though the deleted content is this same '
        'session\'s own freshly-inserted item, not older accepted history. '
        'Manual candidate replay of undo\'s own bytes alone, taken BEFORE '
        'either submission in this order, against the server snapshot as '
        'it stood at that point: $undoManualReplayPreSubmit. Real '
        'decisions: x = '
        '${xDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${xDecision.refusal?.name}'}, '
        'undo = ${undoDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${undoDecision.refusal?.name}'}. '
        'Final server text: "$finalText" (expected "$expectedFinalText" '
        'given undo\'s real outcome): $finalTextSane. A/B/server converged: '
        'true (checked). A speculativePendingStructs after everything '
        'delivered: $pendingAfter.';

    return NativeProbeResult(
      name:
          'shape A: x and its undo both proposed pending (neither '
          'submitted) on one session, submitted $order (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'order': order,
        'stateVectors': {
          'beforeX': svToJson(svBeforeX),
          'afterX': svToJson(svAfterX),
          'afterUndo': svToJson(svAfterUndo),
        },
        'undoSharesXClock': undoShared,
        'undoManualReplayPreSubmit': undoManualReplayPreSubmit,
        'xDecision': xDecision.toJson(),
        'undoDecision': undoDecision.toJson(),
        'finalText': finalText,
        'expectedFinalText': expectedFinalText,
        'finalTextSane': finalTextSane,
        'pendingStructsAfter': pendingAfter,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Shape A, order 1: `x` submitted (and accepted, no policy refuses it)
/// before its own pending `undo` is submitted.
Future<NativeProbeResult> pendingUndoXThenUndoBothAccepted(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _pendingUndoOrderScenario(runtimeFactory, 'x-then-undo');

/// Shape A, order 2: the pending `undo` is submitted BEFORE its own target
/// `x` -- `x`'s own admission decision does not exist yet, so `undo`'s
/// explicit `dependsOn` should refuse it as `missingDependency`, not
/// wrongly accept an inverse for content the server has not seen yet.
Future<NativeProbeResult> pendingUndoUndoThenXMissingDependency(
  Future<CrdtRuntime> Function() runtimeFactory,
) => _pendingUndoOrderScenario(runtimeFactory, 'undo-then-x');

/// Shape A/B boundary: `x` and its `undo` (with an explicit `dependsOn:
/// [x.opId]`) are both proposed pending on one session before either is
/// submitted -- same construction as the two scenarios above -- but this
/// rig's policy refuses `x` itself. `x` is submitted first (refused by
/// policy), then `undo` is submitted. Directly tests whether an explicit
/// `dependsOn` correctly refuses an inverse whose own target turned out to
/// be refused, rather than wrongly accepting it.
Future<NativeProbeResult> pendingUndoXRefusedThenUndoDependencyRefused(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'pending-x-refused' ? AdmissionRefusal.policy : null,
  );
  try {
    const titleId = 'title-pending-refused';
    await _acceptCreateEverywhere(rig, 'base-pending-refused', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-pending-refused', titleId, 0, 'seed');

    final svBeforeX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final x = await rig.a.insert('pending-x-refused', titleId, 4, 'revert-me');
    final svAfterX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final undo = await rig.a.undo(
      'pending-undo-after-x-refused',
      titleId,
      targetOpId: x.opId,
      dependsOn: [x.opId],
    );
    final svAfterUndo = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    // See the shared-scenario helper's note above on why a
    // before-x/after-x comparison is not meaningful (x's client id is
    // absent from svBeforeX by construction). The meaningful check is
    // whether undo's own client clock advances further past x's.
    final undoShared = sharesClockChain(svAfterX, svAfterUndo);

    final xDecision = await rig.server.submit(x);
    final undoManualReplay = await manualCandidateReplay(rig, undo);
    final undoDecision = await rig.server.submit(undo);

    _require(
      xDecision.refusal == AdmissionRefusal.policy,
      'x should be refused by policy, got ${xDecision.refusal}',
    );
    final wronglyAccepted = undoDecision.accepted;

    await rig.a.deliver(xDecision);
    await rig.a.deliver(undoDecision);
    _require(
      rig.a.pendingOpIds.isEmpty,
      'A pendingOpIds should be empty after both refusals delivered, got '
      '${rig.a.pendingOpIds}',
    );
    final pendingAfter = await rig.a.speculativePendingStructs();

    final evidence =
        'state-vector trace: before-x=$svBeforeX (x\'s client id absent -- '
        'first local edit of a fresh session), after-x=$svAfterX, '
        'after-undo=$svAfterUndo. undo shares x\'s own clock chain (does '
        'undo\'s client clock advance further past x\'s): $undoShared -- '
        'expected/confirmed false, same delete-never-advances-the-clock '
        'reason as the no-refusal pair above; both proposed pending on one '
        'session before either is submitted, same construction as that '
        'pair. Manual candidate replay of undo\'s own '
        'bytes alone against the server snapshot (x never landed on it): '
        '$undoManualReplay. Real decisions: x = REFUSED as '
        '${xDecision.refusal?.name}; undo (declared dependsOn: [${x.opId}]) '
        '= ${undoDecision.accepted ? 'ACCEPTED -- WRONGLY, this is a false acceptance' : 'REFUSED as ${undoDecision.refusal?.name}'}. '
        'False acceptance detected: $wronglyAccepted.';

    return NativeProbeResult(
      name:
          'shape A/B boundary: undo (with explicit dependsOn) submitted '
          'after its own target x was refused by policy (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'stateVectors': {
          'beforeX': svToJson(svBeforeX),
          'afterX': svToJson(svAfterX),
          'afterUndo': svToJson(svAfterUndo),
        },
        'undoSharesXClock': undoShared,
        'undoManualReplay': undoManualReplay,
        'xDecision': xDecision.toJson(),
        'undoDecision': undoDecision.toJson(),
        'falseAcceptanceDetected': wronglyAccepted,
        'pendingStructsAfter': pendingAfter,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Shape B, clean case: `x` is proposed, submitted, refused by policy, and
/// the refusal is DELIVERED to A before undo is ever attempted -- the
/// natural, non-racy sequence a real client follows once it learns of a
/// refusal. `deliver()` always calls `_rebuildSpeculative()`
/// (`title_admission.dart`), which closes the old speculative Yrs document
/// (destroying its `UndoManager` and everything it had captured) and opens
/// a brand-new one from the accepted snapshot -- since `x` was withdrawn,
/// nothing replays into it. Tests whether `YjsAdmissionClient.undo` can even
/// be asked to produce an inverse at this point.
Future<NativeProbeResult> refusedUndoAfterRebuildThrows(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'refused-x-clean' ? AdmissionRefusal.policy : null,
  );
  try {
    const titleId = 'title-refused-clean';
    await _acceptCreateEverywhere(rig, 'base-refused-clean', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-refused-clean', titleId, 0, 'seed');

    final x = await rig.a.insert('refused-x-clean', titleId, 4, 'revert-me');
    final xDecision = await rig.server.submit(x);
    _require(
      xDecision.refusal == AdmissionRefusal.policy,
      'x should be refused by policy, got ${xDecision.refusal}',
    );
    await rig.a.deliver(xDecision);
    _require(
      rig.a.pendingOpIds.isEmpty,
      'A pendingOpIds should be empty after the refusal is delivered and '
      'the speculative session rebuilt, got ${rig.a.pendingOpIds}',
    );

    String? thrownMessage;
    try {
      await rig.a.undo(
        'undo-refused-clean',
        titleId,
        targetOpId: x.opId,
      );
    } catch (error) {
      thrownMessage = '$error';
    }
    _require(
      thrownMessage != null,
      'undo() targeting an already-refused, already-rebuilt-away command '
      'should throw at the client -- got no error, an envelope was built '
      'instead',
    );
    _require(
      thrownMessage!.contains('no local Yjs undo item'),
      'unexpected throw message: $thrownMessage',
    );
    _require(
      rig.a.pendingOpIds.isEmpty,
      'a throwing undo() must not leave a phantom pending entry, got '
      '${rig.a.pendingOpIds}',
    );

    final evidence =
        'x proposed, submitted, and refused by policy '
        '(${xDecision.refusal?.name}); the refusal was DELIVERED to A '
        '(deliver() always rebuilds the speculative session -- see '
        '_rebuildSpeculative in title_admission.dart), closing the old Yrs '
        'document and its UndoManager entirely and opening a brand-new, '
        'empty one from the accepted snapshot. Nothing replays into it '
        'since x was withdrawn (pendingOpIds empty after delivery). '
        'Attempting rig.a.undo() targeting x at this point: THREW: '
        '"$thrownMessage". '
        'This is the client-side mechanism that prevents the danger this '
        'ticket names: the false acceptance the ticket worries about (an '
        'inverse accepted for content that was never actually applied) '
        'cannot even be CONSTRUCTED via YjsAdmissionClient.undo in this '
        'natural (non-racy) sequence, because the real Yrs UndoManager\'s '
        'undo stack for the rebuilt session is genuinely empty -- there is '
        'nothing to catch at the admission layer because no envelope is '
        'ever produced to submit. No `TitleCommandKind`/`title_admission.dart` '
        'change was needed or made to produce this result.';

    return NativeProbeResult(
      name:
          'shape B (clean): undo() targeting an already-refused, '
          'already-rebuilt-away command throws at the client, before any '
          'envelope reaches admission (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'xDecision': xDecision.toJson(),
        'thrownMessage': thrownMessage,
        'pendingOpIdsAfter': rig.a.pendingOpIds,
      },
    );
  } finally {
    await rig.close();
  }
}

/// Shape B, racy case: `x` is submitted to the server and refused (the
/// server durably records this decision) -- but the refusal is
/// DELIBERATELY NOT DELIVERED to A yet, modeling the real race between "the
/// server decided" and "this client's own connection told it so." A's
/// local speculative session still has x's own local edit captured live in
/// its undo stack, so `rig.a.undo(...)` succeeds and produces a real
/// envelope. Deliberately no `dependsOn` (same convention as
/// `independentLocalEditFinding`'s own no-dependsOn choice) -- this is the
/// sharpest test of whether the admission layer's own STRUCTURAL checks
/// (causal completeness / apply failure), not `dependsOn` wiring, catch a
/// nonsensical undo whose target never actually landed on canonical B.
Future<NativeProbeResult> refusedUndoRacyNoDependsOn(
  Future<CrdtRuntime> Function() runtimeFactory,
) async {
  final rig = await NativeProbeRig.create(
    runtimeFactory: runtimeFactory,
    policy: (envelope) =>
        envelope.opId == 'refused-x-racy' ? AdmissionRefusal.policy : null,
  );
  try {
    const titleId = 'title-refused-racy';
    await _acceptCreateEverywhere(rig, 'base-refused-racy', titleId);
    await _acceptInsertAtEverywhere(rig, 'seed-refused-racy', titleId, 0, 'seed');

    final svBeforeX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );
    final x = await rig.a.insert('refused-x-racy', titleId, 4, 'revert-me');
    final svAfterX = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );

    final xDecision = await rig.server.submit(x);
    _require(
      xDecision.refusal == AdmissionRefusal.policy,
      'x should be refused by policy, got ${xDecision.refusal}',
    );
    // Deliberately no rig.a.deliver(xDecision) here yet -- A's speculative
    // session still has x's local edit live in its undo stack.

    final undo = await rig.a.undo(
      'undo-refused-racy',
      titleId,
      targetOpId: x.opId,
      // No dependsOn -- see header comment.
    );
    final svAfterUndo = decodeStateVectorB64(
      (await rig.a.speculativeProjection()).stateVectorB64,
    );

    final undoManualReplay = await manualCandidateReplay(rig, undo);
    final undoDecision = await rig.server.submit(undo);
    final falseAcceptanceDetected = undoDecision.accepted;

    // Now let A catch up so the rig ends in a consistent, inspectable state
    // regardless of what was found above.
    await rig.a.deliver(xDecision);
    await rig.a.deliver(undoDecision);
    await rig.b.deliver(xDecision);
    if (undoDecision.accepted) await rig.b.deliver(undoDecision);
    final pendingAfter = await rig.a.speculativePendingStructs();

    final serverFinal = await rig.server.projection();
    final finalText = serverFinal.objects[ObjectId(titleId)]?.text;

    final evidence =
        'state-vector trace: before-x=$svBeforeX, after-x=$svAfterX, '
        'after-undo=$svAfterUndo. x submitted and refused by policy '
        '(${xDecision.refusal?.name}) -- the server durably recorded this, '
        'but the refusal is deliberately NOT delivered to A yet, so A\'s '
        'live speculative session still has x\'s own local edit captured '
        'in its real Yrs UndoManager. rig.a.undo() succeeds and produces a '
        'real inverse envelope (no dependsOn declared, deliberately). '
        'Manual candidate replay of undo\'s own bytes alone against the '
        'server\'s current snapshot (x never landed on it): '
        '$undoManualReplay. Real server decision on undo: '
        '${undoDecision.accepted ? 'ACCEPTED' : 'REFUSED as ${undoDecision.refusal?.name}'}. '
        'FALSE ACCEPTANCE DETECTED: $falseAcceptanceDetected -- '
        '${falseAcceptanceDetected ? 'the server applied an inverse for content ("revert-me") that never actually existed in canonical B; final server text: "$finalText".' : 'the undo\'s own structural reference to content only known to A\'s own local document was caught without any dependsOn wiring at all.'} '
        'After delivering both decisions back to A: pendingOpIds='
        '${rig.a.pendingOpIds}, speculativePendingStructs=$pendingAfter, '
        'final server text="$finalText".';

    return NativeProbeResult(
      name:
          'shape B (racy, no dependsOn): undo of an already-refused-but-'
          'not-yet-delivered command, the sharpest false-acceptance hunt '
          'for this axis (native Yrs)',
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'stateVectors': {
          'beforeX': svToJson(svBeforeX),
          'afterX': svToJson(svAfterX),
          'afterUndo': svToJson(svAfterUndo),
        },
        'xDecision': xDecision.toJson(),
        'undoManualReplay': undoManualReplay,
        'undoDecision': undoDecision.toJson(),
        'falseAcceptanceDetected': falseAcceptanceDetected,
        'finalServerText': finalText,
        'pendingStructsAfter': pendingAfter,
        'pendingOpIdsAfter': rig.a.pendingOpIds,
      },
    );
  } finally {
    await rig.close();
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _acceptCreateEverywhere(
  NativeProbeRig rig,
  String opId,
  String titleId,
) async {
  final envelope = await rig.a.createTitle(opId, titleId);
  final ticket = await rig.server.submit(envelope);
  _require(ticket.accepted, '$opId was not accepted: ${ticket.refusal}');
  await rig.a.deliver(ticket);
  await rig.b.deliver(ticket);
}

Future<void> _acceptInsertEverywhere(
  NativeProbeRig rig,
  String opId,
  String titleId,
  String text,
) async {
  final envelope = await rig.a.insert(opId, titleId, 0, text);
  final ticket = await rig.server.submit(envelope);
  _require(ticket.accepted, '$opId was not accepted: ${ticket.refusal}');
  await rig.a.deliver(ticket);
  await rig.b.deliver(ticket);
}

Future<void> _expectConverged(NativeProbeRig rig) async {
  final expected = _canonicalProjection(await rig.server.projection());
  final aProjection = _canonicalProjection(await rig.a.speculativeProjection());
  final bProjection = _canonicalProjection(await rig.b.speculativeProjection());
  _require(aProjection == expected,
      'A speculative projection diverged from server B\nA: $aProjection\nB: $expected');
  _require(bProjection == expected,
      'B participant projection diverged from server B\nB: $bProjection\nserver: $expected');
}

String _canonicalProjection(DocProjection projection) {
  final ids = projection.objects.keys.map((id) => id.value).toList()..sort();
  return jsonEncode({
    for (final id in ids) id: _canonicalObject(projection.objects[ObjectId(id)]!),
  });
}

Map<String, Object?> _canonicalObject(ObjectProjection value) => {
      'kind': value.kind,
      'x': value.x,
      'y': value.y,
      'w': value.w,
      'h': value.h,
      'rotation': value.rotation,
      'z': value.z,
      'text': value.text,
      'delta': value.delta
          ?.map(
            (chunk) => Map<String, Object?>.fromEntries(
              chunk.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
            ),
          )
          .toList(),
      'src': value.src,
    };

Future<NativeProbeResult> _pass(
  String name,
  String evidence,
  NativeProbeRig rig,
) async =>
    NativeProbeResult(
      name: name,
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: {
        'serverSeq': rig.server.headSeq,
        'connectionAlive': rig.a.connectionAlive,
        'pendingOpIds': rig.a.pendingOpIds,
        'pendingStructs': await rig.a.speculativePendingStructs(),
        'serverProjection': jsonDecode(
          _canonicalProjection(await rig.server.projection()),
        ),
        'aProjection': jsonDecode(
          _canonicalProjection(await rig.a.speculativeProjection()),
        ),
        'bProjection': jsonDecode(
          _canonicalProjection(await rig.b.speculativeProjection()),
        ),
      },
    );
