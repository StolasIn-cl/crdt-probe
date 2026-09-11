import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/core/projection.dart';
import 'package:yjs_probe/prototype/title_admission.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ticket 05 measures Yjs admission, refusal, and replay invariants',
    () async {
      final results = <_ScenarioResult>[];
      final scenarios = <String, Future<_ScenarioResult> Function()>{
        'ordinary acceptance, self-echo, and duplicate': _ordinaryAcceptance,
        'acceptance and refusal replies arrive out of order':
            _outOfOrderReplies,
        'direct refusal keeps the session alive': _directRefusal,
        'refused CreateTitle withdraws dependent edit/delete/undo/format':
            _transitiveWithdrawal,
        'same-document independent local edit exposes Yjs causal coupling':
            _IndependentLocalEditFinding.run,
        'accepted insert survives a refused format': _refusedFormat,
        'remote accepted update before local reply': _remoteBeforeLocalReply,
        'concurrent insert, delete, and range formatting converge':
            _concurrentEdits,
        'reconnect snapshot plus pending journal and duplicate replay':
            _reconnectAndDuplicate,
        'malformed, causally incomplete, and mismatched envelopes':
            _invalidEnvelopes,
        'policy rejection across every Title command kind':
            _policyRejectionAcrossCommandKinds,
        'dependency refusal after a refused root': _dependencyRefusalAfterRoot,
        'same-op retry after refusal is idempotent': _refusedRetryIsIdempotent,
        'future base refusal does not mutate server B': _futureBaseRefusal,
        'server restart restores accepted history and dedup ledger':
            _serverRestartRecovery,
        'remote acceptance remains visible around a local refusal':
            _remoteAroundLocalRefusal,
        'delivery permutations preserve the same accepted projection':
            _deliveryPermutations,
        'semantic Q is re-executed on canonical server B':
            _semanticCanonicalReexecution,
        'semantic multi-select command is one atomic admission unit':
            _semanticMultiSelectAtomicity,
        'semantic replay removes rejected root without causal residue':
            _semanticReplayAfterRefusal,
      };

      for (final entry in scenarios.entries) {
        final result = await entry.value();
        results.add(result);
        expect(result.passed, isTrue, reason: result.evidence);
      }

      final report = _renderReport(results);
      Directory('reports').createSync(recursive: true);
      File('reports/p4-title-admission.md').writeAsStringSync('$report\n');
      Directory('docs/architecture').createSync(recursive: true);
      final architectureReport = _renderArchitectureHtml(results);
      // Mermaid reads the diagram source from the HTML text node. Arrow
      // entities here are not Mermaid syntax and regress the flow diagram.
      expect(
        architectureReport,
        contains(
          'Client->>C: append Q, targets, baseSeq, optional optimistic U',
        ),
      );
      expect(architectureReport, isNot(contains('-&gt;')));
      File(
        'docs/architecture/ticket-05-yjs-title-admission.html',
      ).writeAsStringSync(architectureReport);
      // ignore: avoid_print
      print(report);
    },
  );
}

class _Rig {
  _Rig({
    required this.serverRuntime,
    required this.aRuntime,
    required this.bRuntime,
    required this.server,
    required this.a,
    required this.b,
    required this.trace,
  });

  final YjsRuntime serverRuntime;
  final YjsRuntime aRuntime;
  final YjsRuntime bRuntime;
  final YjsAdmissionServer server;
  final YjsAdmissionClient a;
  final YjsAdmissionClient b;
  final List<Map<String, Object?>> trace;

  static Future<_Rig> create({
    AdmissionPolicy? policy,
    AdmissionExecutionMode mode = AdmissionExecutionMode.exactUpdate,
  }) async {
    final trace = <Map<String, Object?>>[];
    final serverRuntime = await YjsRuntime.create();
    final aRuntime = await YjsRuntime.create();
    final bRuntime = await YjsRuntime.create();
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
    return _Rig(
      serverRuntime: serverRuntime,
      aRuntime: aRuntime,
      bRuntime: bRuntime,
      server: server,
      a: a,
      b: b,
      trace: trace,
    );
  }

  Future<void> close() async {
    await a.close();
    await b.close();
    await serverRuntime.close(server.serverId);
    aRuntime.dispose();
    bRuntime.dispose();
    serverRuntime.dispose();
  }
}

class _ScenarioResult {
  const _ScenarioResult({
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

class _StateSnapshot {
  const _StateSnapshot({
    required this.serverSeq,
    required this.connectionAlive,
    required this.pendingOpIds,
    required this.pendingStructs,
    required this.serverProjection,
    required this.aProjection,
    required this.bProjection,
  });

  final int serverSeq;
  final bool connectionAlive;
  final List<String> pendingOpIds;
  final int pendingStructs;
  final Map<String, Object?> serverProjection;
  final Map<String, Object?> aProjection;
  final Map<String, Object?> bProjection;

  Map<String, Object?> toJson() => {
    'serverSeq': serverSeq,
    'connectionAlive': connectionAlive,
    'pendingOpIds': pendingOpIds,
    'pendingStructs': pendingStructs,
    'serverProjection': serverProjection,
    'aProjection': aProjection,
    'bProjection': bProjection,
  };
}

Future<_ScenarioResult> _ordinaryAcceptance() async {
  final rig = await _Rig.create();
  try {
    final envelope = await rig.a.createTitle('create-1', 'title-a');
    final accepted = await rig.server.submit(envelope);
    final duplicate = await rig.server.submit(envelope);
    final conflict = TitleAdmissionEnvelope(
      opId: envelope.opId,
      titleId: 'title-other',
      command: const TitleCommand(
        kind: TitleCommandKind.createTitle,
        titleId: 'title-other',
      ),
      yrsUpdate: envelope.yrsUpdate,
      dependsOn: const [],
      baseSeq: 0,
    );
    final identityConflict = await rig.server.submit(conflict);
    expect(accepted.accepted, isTrue);
    expect(accepted.serverSeq, 1);
    expect(duplicate.accepted, isTrue);
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.serverSeq, 1);
    expect(identityConflict.refusal, AdmissionRefusal.identityConflict);
    expect(rig.server.headSeq, 1);
    await rig.a.deliver(accepted);
    await rig.b.deliver(accepted);
    await _expectConverged(rig);
    expect(rig.a.pendingOpIds, isEmpty);
    expect(await rig.a.speculativePendingStructs(), 0);
    return _pass(
      'ordinary acceptance, self-echo, and duplicate',
      'one accepted serverSeq=1; duplicate returned the same ticket; a same-opId/different-hash payload was refused; A, B, and server converged; no pending Yjs structs remained.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _outOfOrderReplies() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'reject-independent' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base-a', 'title-a');
    await _acceptCreateEverywhere(rig, 'base-b', 'title-b');
    await _acceptInsertEverywhere(rig, 'base-b-text', 'title-b', 'B');
    final acceptedEnvelope = await rig.a.insert(
      'accept-independent',
      'title-a',
      0,
      'A',
    );
    final refusedEnvelope = await rig.a.format(
      'reject-independent',
      'title-b',
      0,
      1,
      {'bold': true},
    );
    final accepted = await rig.server.submit(acceptedEnvelope);
    final refused = await rig.server.submit(refusedEnvelope);
    expect(accepted.accepted, isTrue);
    expect(refused.refusal, AdmissionRefusal.policy);

    await rig.a.deliver(refused);
    expect(rig.a.pendingOpIds, [acceptedEnvelope.opId]);
    await rig.a.deliver(accepted);
    await rig.b.deliver(accepted);
    await _expectConverged(rig);
    expect(rig.a.connectionAlive, isTrue);
    expect(rig.a.pendingOpIds, isEmpty);
    return _pass(
      'acceptance and refusal replies arrive out of order',
      'the refusal removed only its named independent entry; the accepted reply then advanced B by contiguous server sequence and replayed A deterministically.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _directRefusal() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'reject-create' ? AdmissionRefusal.policy : null,
  );
  try {
    final envelope = await rig.a.createTitle('reject-create', 'title-refused');
    final refused = await rig.server.submit(envelope);
    expect(refused.accepted, isFalse);
    expect(refused.refusal, AdmissionRefusal.policy);
    await rig.a.deliver(refused);
    expect(rig.a.connectionAlive, isTrue);
    expect(rig.a.pendingOpIds, isEmpty);
    expect((await rig.server.projection()).objects, isEmpty);
    expect((await rig.a.speculativeProjection()).objects, isEmpty);
    expect(await rig.a.speculativePendingStructs(), 0);
    return _pass(
      'direct refusal keeps the session alive',
      'the refused CreateTitle produced no server sequence, no server object, no local pending entry, and no disconnect.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _transitiveWithdrawal() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'create-root' ? AdmissionRefusal.policy : null,
  );
  try {
    final root = await rig.a.createTitle('create-root', 'title-root');
    final insert = await rig.a.insert(
      'edit-child',
      'title-root',
      0,
      'hello',
      dependsOn: [root.opId],
    );
    final format = await rig.a.format(
      'format-child',
      'title-root',
      0,
      5,
      {'bold': true},
      dependsOn: [insert.opId],
    );
    final delete = await rig.a.erase(
      'delete-child',
      'title-root',
      0,
      1,
      dependsOn: [format.opId],
    );
    await rig.a.undo(
      'undo-child',
      'title-root',
      targetOpId: delete.opId,
      dependsOn: [delete.opId],
    );
    expect(rig.a.pendingOpIds, [
      root.opId,
      insert.opId,
      format.opId,
      delete.opId,
      'undo-child',
    ]);

    final refused = await rig.server.submit(root);
    await rig.a.deliver(refused);
    expect(rig.a.pendingOpIds, isEmpty);
    expect((await rig.a.speculativeProjection()).objects, isEmpty);
    expect((await rig.server.projection()).objects, isEmpty);
    expect(await rig.a.speculativePendingStructs(), 0);
    return _pass(
      'refused CreateTitle withdraws dependent edit/delete/undo/format',
      'removing the root from C withdrew the transitive semantic descendants; A was rebuilt from empty B without an inverse Yjs update or pending causal residue.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

class _IndependentLocalEditFinding {
  static Future<_ScenarioResult> run() async {
    final rig = await _Rig.create(
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
        // different Titles, but they share one Yjs document and one client
        // clock, which is the exact coupling this ticket must expose.
      );
      final refused = await rig.server.submit(root);
      final independentDecision = await rig.server.submit(independent);
      expect(refused.refusal, AdmissionRefusal.policy);
      expect(independentDecision.accepted, isFalse);
      expect(independentDecision.refusal, AdmissionRefusal.causalIncomplete);
      await rig.a.deliver(refused);
      expect(rig.a.pendingOpIds, [independent.opId]);
      final pendingAfterRebuild = await rig.a.speculativePendingStructs();
      expect(pendingAfterRebuild, greaterThan(0));
      await rig.a.deliver(independentDecision);
      expect(rig.a.pendingOpIds, isEmpty);
      expect(await rig.a.speculativePendingStructs(), 0);
      return _pass(
        'same-document independent local edit exposes Yjs causal coupling',
        'a later edit on a different Title was semantically independent but its Yjs client clock depended on the refused root; the server detected a causal gap, and A exposed pending structs until the edit was also refused. Explicit semantic dependsOn alone is insufficient in one shared Yjs document.',
        rig,
      );
    } finally {
      await rig.close();
    }
  }
}

Future<_ScenarioResult> _refusedFormat() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'format-refused' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    final insert = await rig.a.insert('insert-a', 'title-a', 0, 'plain');
    final insertDecision = await rig.server.submit(insert);
    expect(insertDecision.accepted, isTrue);
    final format = await rig.a.format(
      'format-refused',
      'title-a',
      0,
      5,
      {'bold': true},
      dependsOn: [insert.opId],
    );
    final formatDecision = await rig.server.submit(format);
    expect(formatDecision.refusal, AdmissionRefusal.policy);
    await rig.a.deliver(formatDecision);
    expect(rig.a.pendingOpIds, [insert.opId]);
    expect(await rig.a.speculativePendingStructs(), 0);
    await rig.a.deliver(insertDecision);
    await rig.b.deliver(insertDecision);
    await _expectConverged(rig);
    final title =
        (await rig.server.projection()).objects[const ObjectId('title-a')]!;
    expect(title.text, 'plain');
    return _pass(
      'accepted insert survives a refused format',
      'the refusal removed only the formatting command; the accepted insert remained in B and replayed cleanly in A.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _remoteBeforeLocalReply() async {
  final rig = await _Rig.create();
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    final local = await rig.a.insert('local-a', 'title-a', 0, 'A');
    final remote = await rig.b.insert('remote-b', 'title-a', 0, 'B');
    final remoteDecision = await rig.server.submit(remote);
    expect(remoteDecision.accepted, isTrue);
    await rig.b.deliver(remoteDecision);
    await rig.a.deliverRemote(remoteDecision);
    final visibleBeforeLocalReply = (await rig.a.speculativeProjection())
        .objects[const ObjectId('title-a')]!;
    expect(visibleBeforeLocalReply.text, contains('B'));
    expect(rig.a.pendingOpIds, [local.opId]);

    final localDecision = await rig.server.submit(local);
    expect(localDecision.accepted, isTrue);
    await rig.b.deliverRemote(localDecision);
    await rig.a.deliver(localDecision);
    await _expectConverged(rig);
    return _pass(
      'remote accepted update before local reply',
      'A advanced B with the remote accepted update, re-derived A with its own pending edit still visible, then settled the local ticket without an inverse or duplicate sequence.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _concurrentEdits() async {
  final rig = await _Rig.create();
  try {
    await _acceptCreateEverywhere(rig, 'base-create', 'title-a');
    final seed = await rig.a.insert('base-text', 'title-a', 0, 'abc');
    final seedDecision = await rig.server.submit(seed);
    await rig.a.deliver(seedDecision);
    await rig.b.deliver(seedDecision);

    final aInsert = await rig.a.insert(
      'concurrent-insert-a',
      'title-a',
      1,
      'A',
    );
    final bInsert = await rig.b.insert(
      'concurrent-insert-b',
      'title-a',
      1,
      'B',
    );
    final aInsertDecision = await rig.server.submit(aInsert);
    final bInsertDecision = await rig.server.submit(bInsert);
    await rig.b.deliver(aInsertDecision);
    await rig.a.deliver(bInsertDecision);
    await rig.b.deliver(bInsertDecision);
    await rig.a.deliver(aInsertDecision);
    await _expectConverged(rig);

    final aDelete = await rig.a.erase('concurrent-delete-a', 'title-a', 0, 1);
    final bFormat = await rig.b.format('concurrent-format-b', 'title-a', 0, 2, {
      'bold': true,
    });
    final aDeleteDecision = await rig.server.submit(aDelete);
    final bFormatDecision = await rig.server.submit(bFormat);
    await rig.a.deliver(bFormatDecision);
    await rig.b.deliver(aDeleteDecision);
    await rig.a.deliver(aDeleteDecision);
    await rig.b.deliver(bFormatDecision);
    await _expectConverged(rig);
    expect(await rig.a.speculativePendingStructs(), 0);
    expect(await rig.b.speculativePendingStructs(), 0);
    return _pass(
      'concurrent insert, delete, and range formatting converge',
      'independent client IDs allowed Yjs to merge concurrent inserts and then a concurrent delete/range-format pair; delivery was intentionally reversed and all three projections still matched.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _reconnectAndDuplicate() async {
  final rig = await _Rig.create();
  YjsRuntime? restartedRuntime;
  YjsAdmissionClient? restarted;
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    final pending = await rig.a.insert('unsubmitted-local', 'title-a', 0, 'P');
    final snapshotBeforeSubmit = await rig.server.snapshot();

    restartedRuntime = await YjsRuntime.create();
    restarted = YjsAdmissionClient(
      runtime: restartedRuntime,
      clientId: const ClientId(1),
    );
    await restarted.open();
    await restarted.reconnectFromSnapshot(
      snapshotBeforeSubmit,
      serverSeq: rig.server.headSeq,
      outstanding: [pending],
    );
    expect(restarted.pendingOpIds, [pending.opId]);
    final firstDecision = await rig.server.submit(pending);
    expect(firstDecision.accepted, isTrue);

    // Simulate ack loss after the server durably accepted it. A second retry
    // uses the exact same opId and bytes and must recover the original seq.
    final lostAckSnapshot = await rig.server.snapshot();
    final restartedAfterAckLossRuntime = await YjsRuntime.create();
    final restartedAfterAckLoss = YjsAdmissionClient(
      runtime: restartedAfterAckLossRuntime,
      clientId: const ClientId(1),
    );
    await restartedAfterAckLoss.open();
    await restartedAfterAckLoss.reconnectFromSnapshot(
      lostAckSnapshot,
      serverSeq: rig.server.headSeq,
      outstanding: [pending],
    );
    final duplicate = await rig.server.submit(pending);
    expect(duplicate.accepted, isTrue);
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.serverSeq, firstDecision.serverSeq);
    await restartedAfterAckLoss.deliver(duplicate);
    expect(restartedAfterAckLoss.pendingOpIds, isEmpty);
    expect(await restartedAfterAckLoss.speculativePendingStructs(), 0);
    expect(
      _canonicalProjection(await restartedAfterAckLoss.speculativeProjection()),
      _canonicalProjection(await rig.server.projection()),
    );
    await restartedAfterAckLoss.close();
    restartedAfterAckLossRuntime.dispose();

    // The first restarted client still has its outstanding C entry. Delivering
    // the original acceptance also settles it through the normal sequence path.
    await restarted.deliver(firstDecision);
    expect(restarted.pendingOpIds, isEmpty);
    expect(await restarted.speculativePendingStructs(), 0);
    return _pass(
      'reconnect snapshot plus pending journal and duplicate replay',
      'a fresh client restored accepted snapshot + outstanding C, then both first delivery and same-opId retry settled exactly once; server history stayed at one accepted sequence.',
      rig,
    );
  } finally {
    if (restarted != null) await restarted.close();
    restartedRuntime?.dispose();
    await rig.close();
  }
}

Future<_ScenarioResult> _invalidEnvelopes() async {
  final rig = await _Rig.create();
  YjsRuntime? rawSource;
  YjsRuntime? rawReceiver;
  try {
    await _acceptCreateEverywhere(rig, 'base-a', 'title-a');
    await _acceptCreateEverywhere(rig, 'base-b', 'title-b');

    final malformed = TitleAdmissionEnvelope(
      opId: 'malformed-empty',
      titleId: 'title-a',
      command: const TitleCommand(
        kind: TitleCommandKind.insertText,
        titleId: 'title-a',
        index: 0,
        text: 'x',
      ),
      yrsUpdate: Uint8List(0),
      dependsOn: const [],
      baseSeq: rig.server.headSeq,
    );
    final malformedDecision = await rig.server.submit(malformed);
    expect(malformedDecision.refusal, AdmissionRefusal.malformed);

    final invalidBytes = TitleAdmissionEnvelope(
      opId: 'malformed-invalid-bytes',
      titleId: 'title-a',
      command: const TitleCommand(
        kind: TitleCommandKind.insertText,
        titleId: 'title-a',
        index: 0,
        text: 'x',
      ),
      yrsUpdate: Uint8List.fromList([1, 2, 3]),
      dependsOn: const [],
      baseSeq: rig.server.headSeq,
    );
    final invalidBytesDecision = await rig.server.submit(invalidBytes);
    expect(invalidBytesDecision.accepted, isFalse);

    final missingDependency = await rig.a.insert(
      'causal-child-first',
      'title-a',
      0,
      'child',
      dependsOn: const ['not-accepted-yet'],
    );
    final missingDecision = await rig.server.submit(missingDependency);
    expect(missingDecision.refusal, AdmissionRefusal.missingDependency);
    await rig.a.deliver(missingDecision);

    final root = await rig.a.createTitle('causal-root', 'title-c');
    final child = await rig.a.insert(
      'causal-child',
      'title-c',
      0,
      'child',
      dependsOn: [root.opId],
    );
    final childFirst = await rig.server.submit(child);
    expect(childFirst.refusal, AdmissionRefusal.missingDependency);
    final rootAccepted = await rig.server.submit(root);
    expect(rootAccepted.accepted, isTrue);
    await rig.a.deliver(childFirst);
    await rig.a.deliver(rootAccepted);
    await rig.b.deliver(rootAccepted);

    final wrongUpdate = await rig.a.insert('actual-title-b', 'title-b', 0, 'B');
    final mismatched = TitleAdmissionEnvelope(
      opId: 'declared-title-a-actual-title-b',
      titleId: 'title-a',
      command: const TitleCommand(
        kind: TitleCommandKind.insertText,
        titleId: 'title-a',
        index: 0,
        text: 'B',
      ),
      yrsUpdate: wrongUpdate.yrsUpdate,
      dependsOn: const [],
      baseSeq: rig.server.headSeq,
    );
    final beforeMismatch = await rig.server.projection();
    final mismatchDecision = await rig.server.submit(mismatched);
    final afterMismatch = await rig.server.projection();
    expect(mismatchDecision.refusal, AdmissionRefusal.semanticMismatch);
    expect(
      _canonicalProjection(afterMismatch),
      _canonicalProjection(beforeMismatch),
    );

    rawSource = await YjsRuntime.create();
    rawReceiver = await YjsRuntime.create();
    const sourceId = ClientId(7101);
    const receiverId = ClientId(7102);
    await rawSource.open(sourceId);
    await rawReceiver.open(receiverId);
    await rawSource.createObject(
      sourceId,
      const ObjectId('raw-title'),
      ObjectKind.title,
      x: 0,
      y: 0,
      w: 100,
      h: 40,
    );
    final rootUpdate = (await rawSource.drainOutbox(sourceId)).single;
    await rawSource.insertText(sourceId, const ObjectId('raw-title'), 0, 'raw');
    final childUpdate = (await rawSource.drainOutbox(sourceId)).single;
    await rawReceiver.applyUpdate(receiverId, childUpdate, origin: 'remote');
    final pendingAtGap = await rawReceiver.pendingStructCount(receiverId);
    await rawReceiver.applyUpdate(receiverId, rootUpdate, origin: 'remote');
    final pendingAfterParent = await rawReceiver.pendingStructCount(receiverId);
    final rawText = (await rawReceiver.projection(
      receiverId,
    )).objects[const ObjectId('raw-title')]!.text;
    expect(pendingAtGap, greaterThan(0));
    expect(pendingAfterParent, 0);
    expect(rawText, 'raw');

    return _pass(
      'malformed, causally incomplete, and mismatched envelopes',
      'empty and invalid U were refused before B mutation; a child-before-parent was refused without server mutation; Q naming Title A while U changed Title B was refused by candidate projection; direct Yjs observation showed child-first delivery leaves pending structs until its parent arrives.',
      rig,
    );
  } finally {
    if (rawSource != null) rawSource.dispose();
    if (rawReceiver != null) rawReceiver.dispose();
    await rig.close();
  }
}

Future<_ScenarioResult> _policyRejectionAcrossCommandKinds() async {
  const rejectedIds = {
    'reject-insert',
    'reject-delete',
    'reject-format',
    'reject-undo',
  };
  final rig = await _Rig.create(
    policy: (envelope) =>
        rejectedIds.contains(envelope.opId) ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    await _acceptInsertEverywhere(rig, 'seed', 'title-a', 'seed');

    final decisions = <AdmissionTicket>[];

    Future<void> reject(TitleAdmissionEnvelope envelope) async {
      final decision = await rig.server.submit(envelope);
      decisions.add(decision);
      expect(decision.refusal, AdmissionRefusal.policy);
      await rig.a.deliver(decision);
    }

    await reject(await rig.a.insert('reject-insert', 'title-a', 0, 'x'));
    await reject(await rig.a.erase('reject-delete', 'title-a', 0, 1));
    await reject(
      await rig.a.format('reject-format', 'title-a', 0, 1, {'bold': true}),
    );
    // The target stays speculative so a real Yjs UndoManager can create the
    // inverse update. The undo envelope intentionally has no semantic
    // dependsOn: policy admission is tested before candidate causality.
    final undoTarget = await rig.a.insert('undo-target', 'title-a', 0, 'u');
    final undo = await rig.a.undo(
      'reject-undo',
      'title-a',
      targetOpId: undoTarget.opId,
    );
    await reject(undo);
    expect(decisions, hasLength(4));
    expect(rig.a.pendingOpIds, [undoTarget.opId]);

    final targetDecision = await rig.server.submit(undoTarget);
    expect(targetDecision.accepted, isTrue);
    await rig.a.deliver(targetDecision);
    await rig.b.deliver(targetDecision);
    await _expectConverged(rig);
    expect(rig.a.connectionAlive, isTrue);
    expect(await rig.a.speculativePendingStructs(), 0);
    return _pass(
      'policy rejection across every Title command kind',
      'real client-generated Yjs updates for insert, delete, format, and undo were each refused with policy; the connection stayed alive, only the refused entries were withdrawn, and an unrelated pending operation could still be accepted afterward.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _dependencyRefusalAfterRoot() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'root-refused' ? AdmissionRefusal.policy : null,
  );
  try {
    final root = await rig.a.createTitle('root-refused', 'title-a');
    final child = await rig.a.insert(
      'child-first',
      'title-a',
      0,
      'child',
      dependsOn: [root.opId],
    );
    final childFirst = await rig.server.submit(child);
    expect(childFirst.refusal, AdmissionRefusal.missingDependency);

    final rootDecision = await rig.server.submit(root);
    expect(rootDecision.refusal, AdmissionRefusal.policy);
    await rig.a.deliver(rootDecision);

    // A new operation identity is needed: the first child already has a
    // durable missing-dependency decision and therefore must remain replayable
    // as that exact decision.
    final retry = TitleAdmissionEnvelope(
      opId: 'child-after-root-refusal',
      titleId: child.titleId,
      command: child.command,
      yrsUpdate: child.yrsUpdate,
      dependsOn: [root.opId],
      baseSeq: child.baseSeq,
    );
    final retryDecision = await rig.server.submit(retry);
    expect(retryDecision.refusal, AdmissionRefusal.dependencyRefused);
    expect(rig.server.headSeq, 0);
    expect((await rig.server.projection()).objects, isEmpty);
    expect(rig.a.connectionAlive, isTrue);
    return _pass(
      'dependency refusal after a refused root',
      'child-before-parent received missingDependency; after the root was durably refused, a new retry received dependencyRefused; no refusal consumed serverSeq and B stayed empty.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _refusedRetryIsIdempotent() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'reject-once' ? AdmissionRefusal.policy : null,
  );
  try {
    final envelope = await rig.a.createTitle('reject-once', 'title-a');
    final first = await rig.server.submit(envelope);
    final retry = await rig.server.submit(envelope);
    expect(first.refusal, AdmissionRefusal.policy);
    expect(retry.refusal, AdmissionRefusal.policy);
    expect(retry.duplicate, isTrue);
    expect(retry.serverSeq, isNull);
    await rig.a.deliver(first);
    await rig.a.deliver(retry);
    expect(rig.a.pendingOpIds, isEmpty);
    expect(rig.a.connectionAlive, isTrue);
    expect(rig.server.headSeq, 0);
    return _pass(
      'same-op retry after refusal is idempotent',
      'the same rejected envelope returned the original refusal on retry with duplicate=true, no serverSeq, no second mutation, and no connection loss.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _futureBaseRefusal() async {
  final rig = await _Rig.create();
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    final candidate = await rig.a.insert('future-base', 'title-a', 0, 'x');
    final future = TitleAdmissionEnvelope(
      opId: candidate.opId,
      titleId: candidate.titleId,
      command: candidate.command,
      yrsUpdate: candidate.yrsUpdate,
      dependsOn: candidate.dependsOn,
      baseSeq: rig.server.headSeq + 10,
    );
    final before = _canonicalProjection(await rig.server.projection());
    final decision = await rig.server.submit(future);
    final after = _canonicalProjection(await rig.server.projection());
    expect(decision.refusal, AdmissionRefusal.futureBase);
    expect(after, before);
    expect(rig.server.headSeq, 1);
    await rig.a.deliver(decision);
    expect(rig.a.pendingOpIds, isEmpty);
    expect(await rig.a.speculativePendingStructs(), 0);
    return _pass(
      'future base refusal does not mutate server B',
      'a future baseSeq was rejected before candidate apply; B projection and serverSeq were unchanged, and A removed the local entry without leaving pending structs.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _serverRestartRecovery() async {
  final rig = await _Rig.create();
  YjsRuntime? restartedRuntime;
  YjsAdmissionServer? restartedServer;
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    final acceptedInsert = await rig.a.insert(
      'accepted-before-restart',
      'title-a',
      0,
      'before',
    );
    final acceptedTicket = await rig.server.submit(acceptedInsert);
    expect(acceptedTicket.accepted, isTrue);
    await rig.a.deliver(acceptedTicket);
    await rig.b.deliver(acceptedTicket);

    final snapshot = await rig.server.snapshot();
    restartedRuntime = await YjsRuntime.create();
    restartedServer = YjsAdmissionServer(
      runtime: restartedRuntime,
      serverId: const ClientId(9010),
      onEvent: (kind, data) => rig.trace.add({'kind': kind, ...data}),
    );
    await restartedServer.open();
    await restartedServer.restoreAcceptedState(
      snapshot: snapshot,
      acceptedHistory: rig.server.acceptedHistory,
      headSeq: rig.server.headSeq,
    );

    final duplicate = await restartedServer.submit(acceptedInsert);
    expect(duplicate.accepted, isTrue);
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.serverSeq, acceptedTicket.serverSeq);

    final afterRestart = await rig.a.insert(
      'accepted-after-restart',
      'title-a',
      6,
      '!',
    );
    final afterRestartTicket = await restartedServer.submit(afterRestart);
    expect(afterRestartTicket.accepted, isTrue);
    expect(afterRestartTicket.serverSeq, 3);
    // Keep the rig's reporting server aligned as well; the restarted server
    // is the authority under test, while the original instance is only the
    // report/state fixture used by _pass.
    final reportTicket = await rig.server.submit(afterRestart);
    expect(reportTicket.accepted, isTrue);
    expect(reportTicket.serverSeq, afterRestartTicket.serverSeq);
    await rig.a.deliver(afterRestartTicket);
    await rig.b.deliver(afterRestartTicket);
    await _expectConvergedAgainst(rig, restartedServer);
    return _pass(
      'server restart restores accepted history and dedup ledger',
      'a fresh server runtime restored B, accepted history, and headSeq; retrying an already accepted op returned the original sequence, while a new command continued at the next sequence.',
      rig,
    );
  } finally {
    if (restartedServer != null) {
      await restartedRuntime!.close(restartedServer.serverId);
    }
    restartedRuntime?.dispose();
    await rig.close();
  }
}

Future<_ScenarioResult> _remoteAroundLocalRefusal() async {
  final rig = await _Rig.create(
    policy: (envelope) =>
        envelope.opId == 'local-refused' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'base', 'title-a');
    await _acceptInsertEverywhere(rig, 'base-text', 'title-a', 'seed');
    final local = await rig.a.format('local-refused', 'title-a', 0, 1, {
      'bold': true,
    });
    final remote = await rig.b.insert('remote-accepted', 'title-a', 0, 'R');
    final localDecision = await rig.server.submit(local);
    final remoteDecision = await rig.server.submit(remote);
    expect(localDecision.refusal, AdmissionRefusal.policy);
    expect(remoteDecision.accepted, isTrue);
    await rig.b.deliver(remoteDecision);
    await rig.a.deliverRemote(remoteDecision);
    expect(rig.a.pendingOpIds, [local.opId]);
    expect(
      (await rig.a.speculativeProjection())
          .objects[const ObjectId('title-a')]!
          .text,
      contains('R'),
    );
    await rig.a.deliver(localDecision);
    expect(rig.a.pendingOpIds, isEmpty);
    await _expectConverged(rig);
    return _pass(
      'remote acceptance remains visible around a local refusal',
      'A integrated a remote accepted update while the local command was still pending, then removed only the refused local entry; the remote text remained in B and A.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _deliveryPermutations() async {
  final orders = <List<int>>[
    [0, 1],
    [1, 0],
    [0, 1, 1, 0],
  ];
  _Rig? lastRig;
  try {
    for (final order in orders) {
      final rig = await _Rig.create();
      lastRig = rig;
      await _acceptCreateEverywhere(
        rig,
        'base-${order.join()}'.replaceAll(',', ''),
        'title-a',
      );
      final aInsert = await rig.a.insert(
        'perm-a-${order.join()}',
        'title-a',
        0,
        'A',
      );
      final bInsert = await rig.b.insert(
        'perm-b-${order.join()}',
        'title-a',
        0,
        'B',
      );
      final aTicket = await rig.server.submit(aInsert);
      final bTicket = await rig.server.submit(bInsert);
      final tickets = [aTicket, bTicket];
      for (final index in order) {
        await rig.a.deliver(tickets[index]);
        await rig.b.deliver(tickets[index]);
      }
      await _expectConverged(rig);
      expect(await rig.a.speculativePendingStructs(), 0);
      expect(await rig.b.speculativePendingStructs(), 0);
      if (order != orders.last) {
        await rig.close();
        lastRig = null;
      }
    }
    return _pass(
      'delivery permutations preserve the same accepted projection',
      'three delivery schedules, including reverse delivery and duplicate ticket delivery, converged to the same server projection with contiguous serverSeq handling and no pending structs.',
      lastRig!,
    );
  } finally {
    if (lastRig != null) await lastRig.close();
  }
}

Future<_ScenarioResult> _semanticCanonicalReexecution() async {
  final rig = await _Rig.create(mode: AdmissionExecutionMode.semanticCommand);
  try {
    await _acceptCreateEverywhere(rig, 'semantic-base', 'title-a');

    // B_server advances while A is offline from the accepted reply. The
    // local Q still uses the last accepted base, but the server executes it
    // against the newer canonical text.
    final remote = await rig.b.insert('semantic-remote', 'title-a', 0, 'R');
    final remoteTicket = await rig.server.submit(remote);
    expect(remoteTicket.accepted, isTrue);
    await rig.b.deliver(remoteTicket);

    final local = await rig.a.insert('semantic-local', 'title-a', 0, 'L');
    final canonicalTicket = await rig.server.submit(local);
    expect(canonicalTicket.accepted, isTrue);
    expect(canonicalTicket.canonicalUpdate, isNotNull);
    expect(
      base64Encode(canonicalTicket.canonicalUpdate!),
      isNot(base64Encode(local.yrsUpdate)),
      reason: 'server Q must produce a canonical update, not echo client U',
    );

    // Deliver in server order. The local ticket can arrive before the remote
    // accepted update, but the client must buffer it by serverSeq.
    await rig.a.deliver(remoteTicket);
    await rig.a.deliver(canonicalTicket);
    await rig.b.deliver(canonicalTicket);
    await _expectConverged(rig);
    expect(await rig.a.speculativePendingStructs(), 0);
    expect(
      (await rig.server.projection()).objects[ObjectId('title-a')]!.text,
      'LR',
    );
    return _pass(
      'semantic Q is re-executed on canonical server B',
      'the client showed an optimistic insert against stale B_client; the server re-executed the same Q against newer B_server, returned a different canonical U, and A converged after canonical integration plus semantic replay.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _semanticMultiSelectAtomicity() async {
  final rig = await _Rig.create(
    mode: AdmissionExecutionMode.semanticCommand,
    policy: (envelope) =>
        envelope.opId == 'group-policy-reject' ? AdmissionRefusal.policy : null,
  );
  try {
    await _acceptCreateEverywhere(rig, 'group-a', 'title-a');
    await _acceptCreateEverywhere(rig, 'group-b', 'title-b');

    final move = await rig.a.moveObjects(
      'group-move',
      const ['title-a', 'title-b'],
      deltaX: 10,
      deltaY: 20,
    );
    final accepted = await rig.server.submit(move);
    expect(accepted.accepted, isTrue);
    await rig.a.deliver(accepted);
    await rig.b.deliver(accepted);
    final moved = await rig.server.projection();
    expect(moved.objects[ObjectId('title-a')]!.x, 10);
    expect(moved.objects[ObjectId('title-a')]!.y, 20);
    expect(moved.objects[ObjectId('title-b')]!.x, 10);
    expect(moved.objects[ObjectId('title-b')]!.y, 20);

    final rejectedGroup = await rig.a.moveObjects(
      'group-policy-reject',
      const ['title-a', 'title-b'],
      deltaX: 5,
      deltaY: 5,
    );
    final refused = await rig.server.submit(rejectedGroup);
    expect(refused.accepted, isFalse);
    expect(refused.refusal, AdmissionRefusal.policy);
    await rig.a.deliver(refused);
    await _expectConverged(rig);
    expect(await rig.a.speculativePendingStructs(), 0);
    expect((await rig.server.projection()).objects[ObjectId('title-a')]!.x, 10);
    return _pass(
      'semantic multi-select command is one atomic admission unit',
      'one moveObjects Q updated every selected object together; a policy-refused group was removed as one opId and did not partially commit either target.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<_ScenarioResult> _semanticReplayAfterRefusal() async {
  final rig = await _Rig.create(
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
    expect(refused.refusal, AdmissionRefusal.policy);
    expect(accepted.accepted, isTrue);

    await rig.a.deliver(refused);
    await rig.a.deliver(accepted);
    await rig.b.deliver(accepted);
    await _expectConverged(rig);
    expect(await rig.a.speculativePendingStructs(), 0);
    final projection = await rig.server.projection();
    expect(projection.objects[ObjectId('title-a')]!.text, isEmpty);
    expect(projection.objects[ObjectId('title-b')]!.delta, isNotEmpty);
    return _pass(
      'semantic replay removes rejected root without causal residue',
      'after a policy refusal, the surviving independent Q was re-executed from accepted B; no exact rejected U was replayed and Yjs pendingStructs stayed zero.',
      rig,
    );
  } finally {
    await rig.close();
  }
}

Future<void> _acceptCreateEverywhere(
  _Rig rig,
  String opId,
  String titleId,
) async {
  final envelope = await rig.a.createTitle(opId, titleId);
  final ticket = await rig.server.submit(envelope);
  expect(ticket.accepted, isTrue, reason: '$opId was not accepted');
  await rig.a.deliver(ticket);
  await rig.b.deliver(ticket);
}

Future<void> _acceptInsertEverywhere(
  _Rig rig,
  String opId,
  String titleId,
  String text,
) async {
  final envelope = await rig.a.insert(opId, titleId, 0, text);
  final ticket = await rig.server.submit(envelope);
  expect(ticket.accepted, isTrue, reason: '$opId was not accepted');
  await rig.a.deliver(ticket);
  await rig.b.deliver(ticket);
}

Future<void> _expectConverged(_Rig rig) async {
  final expected = _canonicalProjection(await rig.server.projection());
  expect(
    _canonicalProjection(await rig.a.speculativeProjection()),
    expected,
    reason: 'A speculative projection diverged from server B',
  );
  expect(
    _canonicalProjection(await rig.b.speculativeProjection()),
    expected,
    reason: 'B participant projection diverged from server B',
  );
}

Future<void> _expectConvergedAgainst(
  _Rig rig,
  YjsAdmissionServer server,
) async {
  final expected = _canonicalProjection(await server.projection());
  expect(
    _canonicalProjection(await rig.a.speculativeProjection()),
    expected,
    reason: 'A speculative projection diverged from the restarted server B',
  );
  expect(
    _canonicalProjection(await rig.b.speculativeProjection()),
    expected,
    reason: 'B participant projection diverged from the restarted server B',
  );
}

Future<_ScenarioResult> _pass(String name, String evidence, _Rig rig) async =>
    _ScenarioResult(
      name: name,
      passed: true,
      evidence: evidence,
      trace: List<Map<String, Object?>>.from(rig.trace),
      finalState: (await _captureState(rig)).toJson(),
    );

Future<_StateSnapshot> _captureState(_Rig rig) async => _StateSnapshot(
  serverSeq: rig.server.headSeq,
  connectionAlive: rig.a.connectionAlive,
  pendingOpIds: rig.a.pendingOpIds,
  pendingStructs: await rig.a.speculativePendingStructs(),
  serverProjection: _projectionMap(await rig.server.projection()),
  aProjection: _projectionMap(await rig.a.speculativeProjection()),
  bProjection: _projectionMap(await rig.b.speculativeProjection()),
);

Map<String, Object?> _projectionMap(DocProjection projection) =>
    Map<String, Object?>.from(
      jsonDecode(_canonicalProjection(projection)) as Map,
    );

String _canonicalProjection(DocProjection projection) {
  final ids = projection.objects.keys.map((id) => id.value).toList()..sort();
  return jsonEncode({
    for (final id in ids)
      id: _canonicalObject(projection.objects[ObjectId(id)]!),
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

String _renderReport(List<_ScenarioResult> results) {
  final refusalCount = results
      .expand(_decisionEvents)
      .where((event) => event['kind'] == 'server.refused')
      .length;
  final semanticScenarioCount = results
      .where((result) => result.name.startsWith('semantic '))
      .length;
  final buffer = StringBuffer()
    ..writeln('# Ticket 05 — Yjs Title admission/refusal probe')
    ..writeln()
    ..writeln(
      '這是 `yjs_probe` 的 disposable integration harness；它使用真實 Yjs update bytes、`YjsRuntime` projection 與 `pendingStructs`，不修改 production collaboration code。',
    )
    ..writeln()
    ..writeln('## 測試結論')
    ..writeln()
    ..writeln(
      '- 本輪從 10 個 smoke cases 擴成 ${results.length} 個 scenario，涵蓋 $refusalCount 筆實際 server refusal trace、四種 Title command kind 的 policy reject、dependency reject、future base、restart recovery、delivery permutation，以及 $semanticScenarioCount 個 semantic-Q/canonical-B scenario。',
    )
    ..writeln(
      '- 每一筆拒絕都保留 `opId`、Title、Q command、U bytes、`dependsOn`、`baseSeq`、refusal reason、`serverSeq` 與 duplicate 狀態；拒絕不得改變 B，也不得讓 connection 被迫斷線。',
    )
    ..writeln(
      '- 原有 exact-U mode 證明 `Document A = accepted B + Pending Journal C` 可處理 acceptance/refusal out of order、self-echo、remote-before-local-reply、重連與 accepted insert/refused format；新增 semantic mode 則由 C 重做 Q，不再把 exact U 當成唯一 replay source。',
    )
    ..writeln(
      '- 重要反例：同一個 Yjs document 內，即使兩個 command 語意上作用於不同 Title，後者仍可能因同一 client clock chain 依賴被拒絕或在 A 留下 pending structs。Semantic `dependsOn` 不能單獨取代 Yjs causal dependency。',
    )
    ..writeln(
      '- semantic mode 實測：client 先以 B_client 執行 Q，server 再於較新的 B_server 執行同一 Q，回傳不同的 canonical U；multi-select 是一個 atomic opId，reject 後 surviving Q 可重做且 pending structs 維持 0。',
    )
    ..writeln(
      '- shared-document exact-U route 仍保留重要反例：若產品只能重播 client U，不能承諾拒絕 root 後所有語意獨立的同 client local edit 都保留；此時才需要 per-Title isolation、rebase 或 server-generated update。',
    )
    ..writeln()
    ..writeln('## 架構與資料責任')
    ..writeln()
    ..writeln('| 元件 | 應保存什麼 | 為什麼 |')
    ..writeln('|---|---|---|')
    ..writeln(
      '| A — speculative view | B snapshot 加上仍存活的 C entries replay 結果 | 提供立即的 user-visible state；拒絕時重建，不送 inverse update |',
    )
    ..writeln(
      '| B — accepted document | server canonical Q execution 產生的 Yjs state 與 contiguous `serverSeq` | 是所有 participant 的 canonical base；client optimistic U 不直接成為 B |',
    )
    ..writeln(
      '| C — Pending Journal | semantic Q + opId/targets/anchors/preconditions/baseSeq 或 state vector + optional optimistic U | rebuild 時重做 Q；U 可作 audit/debug/optimistic cache，但不能是 rejected predecessor 的唯一 replay source |',
    )
    ..writeln()
    ..writeln('## Yrs 可行性結論')
    ..writeln()
    ..writeln(
      '- **可以在 Yrs 實作**：Yrs 是 Yjs 的相容 Rust port；Yrs 的 `TransactionMut::apply_update`、`has_missing_updates`、state vector 與 candidate `Doc` 足以承接本次 Yjs probe 的 server-admission 形狀。',
    )
    ..writeln(
      '- 這不是把 Yjs 測試碼直接換成 Rust API：Yrs 不知道產品的 Title command、權限或 Q/U scope，仍需要 application-level envelope、server ledger、candidate validation 與 refusal message。',
    )
    ..writeln(
      '- 最大限制仍是 CRDT causal dependency：exact-U replay 會把 shared Yrs document 的前序 item 一起帶回；本 probe 的 semantic-Q replay 可避開這個來源，但前提是 Q 可在 client/server deterministic execution，且 canonical U 才是 authoritative。',
    )
    ..writeln(
      '- production 還要補上 candidate apply 的資源上限、B/ledger atomic commit、Q schema/version/determinism、multi-select precondition、IME/undo command boundary 與 Yrs FFI error mapping。',
    )
    ..writeln()
    ..writeln('## Scenario evidence 與實際 reject 結果')
    ..writeln();
  for (final result in results) {
    buffer
      ..writeln('### ${result.name}')
      ..writeln()
      ..writeln('- Result: `${result.passed ? 'PASS' : 'FAIL'}`')
      ..writeln('- Evidence: ${result.evidence}')
      ..writeln('- Trace events: ${result.trace.length}')
      ..writeln(
        '- Trace: `${result.trace.map((event) => event['kind']).join(' → ')}`',
      );
    final decisions = _decisionEvents(result);
    if (decisions.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('**Actual server decisions**')
        ..writeln()
        ..writeln(
          '| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |',
        )
        ..writeln('|---|---|---|---|---:|---|---:|---|---:|');
      for (final event in decisions) {
        final envelope = _eventEnvelope(event);
        buffer.writeln(
          '| ${event['kind']} | ${event['opId'] ?? envelope['opId'] ?? ''} | ${envelope['titleId'] ?? ''} | ${event['refusal'] ?? event['outcome'] ?? ''} | ${event['serverSeq'] ?? '—'} | ${event['duplicate'] ?? false} | ${envelope['yrsUpdateBytes'] ?? '—'} | `${(envelope['dependsOn'] as List?)?.join(', ') ?? ''}` | ${envelope['baseSeq'] ?? '—'} |',
        );
      }
      buffer
        ..writeln()
        ..writeln('```json')
        ..writeln(_prettyJson(decisions))
        ..writeln('```');
    }
    buffer
      ..writeln()
      ..writeln('**Final A/B/C state**')
      ..writeln()
      ..writeln('```json')
      ..writeln(_prettyJson(result.finalState))
      ..writeln('```')
      ..writeln();
  }
  buffer
    ..writeln('## Protocol implications')
    ..writeln()
    ..writeln(
      '1. Server checks durable `opId` before any Yjs apply; same identity + same hash returns the original ticket, while a hash conflict refuses without a second sequence.',
    )
    ..writeln(
      '2. Server validates explicit dependencies before candidate apply; it does not queue a missing dependency and does not assign a sequence to a refusal.',
    )
    ..writeln(
      '3. exact-U mode applies client U to a candidate; semantic mode instead executes Q on candidate B_server, validates the complete scope/group, then commits the generated canonical U to B and assigns one sequence. Client U is never blindly applied to live B in semantic mode.',
    )
    ..writeln(
      '4. Client integrates accepted canonical U by contiguous `serverSeq`, removes the accepted Q from C, and re-executes surviving Q entries from B_client. Refusal removes the named entry and its transitive semantic dependants before the same semantic rebuild.',
    )
    ..writeln(
      '5. Reconnect must persist accepted snapshot sequence plus versioned Q/targets/preconditions and optional optimistic U; retries use semantic identity for semantic mode and must tolerate an already-included sequence.',
    )
    ..writeln()
    ..writeln('## Revisit conditions')
    ..writeln()
    ..writeln(
      '- If Q cannot be executed deterministically on client and server, share one command interpreter or make the server canonical result authoritative with cross-runtime golden tests.',
    )
    ..writeln(
      '- If multi-select/group atomicity or resource limits fail, split only the affected feature family into a separate Collaboration Document; do not default to per-object Docs without measuring coordination cost.',
    )
    ..writeln(
      '- If candidate apply cannot be bounded for size/time, add resource limits and a refusal class before accepting U.',
    )
    ..writeln(
      '- If server-side Yjs is unavailable, do not fall back to opaque relay while retaining individual refusal semantics; that would reintroduce causal pending state.',
    );
  return buffer.toString().trimRight();
}

List<Map<String, Object?>> _decisionEvents(_ScenarioResult result) => [
  for (final event in result.trace)
    if (event['kind'] == 'server.refused' ||
        event['kind'] == 'server.identity-conflict' ||
        event['kind'] == 'server.duplicate')
      event,
];

Map<String, Object?> _eventEnvelope(Map<String, Object?> event) {
  final envelope = event['envelope'];
  if (envelope is Map) return Map<String, Object?>.from(envelope);
  return const <String, Object?>{};
}

String _prettyJson(Object? value) =>
    JsonEncoder.withIndent('  ').convert(value);

String _htmlEscape(Object? value) => const HtmlEscape().convert('$value');

String _renderArchitectureHtml(List<_ScenarioResult> results) {
  final decisions = results.expand(_decisionEvents).toList();
  final refusalCount = decisions
      .where((event) => event['kind'] == 'server.refused')
      .length;
  final scenarioCards = StringBuffer();
  for (var i = 0; i < results.length; i++) {
    final result = results[i];
    final resultDecisions = _decisionEvents(result);
    final tableRows = resultDecisions.map((event) {
      final envelope = _eventEnvelope(event);
      return '<tr><td>${_htmlEscape(event['kind'])}</td><td><code>${_htmlEscape(event['opId'] ?? envelope['opId'])}</code></td><td>${_htmlEscape(envelope['titleId'])}</td><td><span class="badge warn">${_htmlEscape(event['refusal'] ?? event['outcome'] ?? '')}</span></td><td>${_htmlEscape(event['serverSeq'] ?? '—')}</td><td>${_htmlEscape(envelope['yrsUpdateBytes'] ?? '—')}</td><td>${_htmlEscape(envelope['baseSeq'] ?? '—')}</td></tr>';
    }).join();
    scenarioCards
      ..writeln('<details class="scenario" ${i < 4 ? 'open' : ''}>')
      ..writeln(
        '<summary><span class="step-num">${(i + 1).toString().padLeft(2, '0')}</span><span><strong>${_htmlEscape(result.name)}</strong><small>${result.trace.length} events · ${resultDecisions.length} decision records</small></span><span class="badge ok">${result.passed ? 'PASS' : 'FAIL'}</span></summary>',
      )
      ..writeln(
        '<div class="scenario-body"><p>${_htmlEscape(result.evidence)}</p>',
      )
      ..writeln(
        '<p><strong>Trace：</strong><code>${_htmlEscape(result.trace.map((event) => event['kind']).join(' → '))}</code></p>',
      );
    if (resultDecisions.isNotEmpty) {
      scenarioCards
        ..writeln(
          '<h4>實際 server decision</h4><div class="table-wrap"><table><thead><tr><th>event</th><th>opId</th><th>Title</th><th>reason</th><th>seq</th><th>U bytes</th><th>baseSeq</th></tr></thead><tbody>$tableRows</tbody></table></div>',
        )
        ..writeln(
          '<details><summary>完整拒絕 envelope / ticket JSON</summary><pre>${_htmlEscape(_prettyJson(resultDecisions))}</pre></details>',
        );
    }
    scenarioCards.writeln(
      '<h4>Final A / B / C</h4><pre>${_htmlEscape(_prettyJson(result.finalState))}</pre></div></details>',
    );
  }

  final html =
      '''<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ticket 05｜Yjs Title admission/refusal 架構導讀</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<style>
:root{--bg:#f7f1e7;--paper:#fffdf8;--paper2:#fff8ee;--ink:#2c2219;--muted:#6e5b47;--line:#dccbb6;--accent:#136f63;--soft:#e3f1ed;--ok:#2d6a4f;--oksoft:#e7f3ea;--warn:#8f4d2d;--warnsoft:#f9eadf;--shadow:0 18px 44px rgba(72,52,30,.10)}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:radial-gradient(circle at 85% 4%,rgba(19,111,99,.09),transparent 28rem),var(--bg);font:16px/1.7 Inter,"Noto Sans TC","Microsoft JhengHei",system-ui,sans-serif}a{color:inherit}code,pre{font-family:"Cascadia Code",Consolas,monospace}code{padding:.12rem .34rem;border-radius:6px;background:#f1e9dc;overflow-wrap:anywhere}pre{padding:1rem;overflow:auto;border:1px solid #3a4a48;border-radius:12px;color:#eaf5f1;background:#1f2b29;font-size:.78rem;line-height:1.5}.layout{display:grid;grid-template-columns:292px minmax(0,1fr);min-height:100vh}.sidebar{position:sticky;top:0;height:100vh;padding:28px 22px;overflow-y:auto;border-right:1px solid var(--line);background:rgba(255,253,248,.88);backdrop-filter:blur(14px)}.brand{margin-bottom:26px;padding:0 10px 20px;border-bottom:1px solid var(--line)}.eyebrow{color:var(--accent);font-size:.74rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase}.brand h1{margin:.45rem 0 .2rem;font-size:1.1rem;line-height:1.35}.brand p,.muted{color:var(--muted);font-size:.84rem}nav a{display:flex;gap:10px;align-items:baseline;margin:5px 0;padding:9px 11px;border-radius:10px;color:var(--muted);text-decoration:none;font-size:.88rem}nav a:hover,nav a.active{color:var(--accent);background:var(--soft)}nav .num{width:1.4rem;color:#9b856d;font:.75rem/1.7 monospace}.sidebar-meta{margin-top:24px;padding:13px;border:1px solid var(--line);border-radius:12px;color:var(--muted);background:#fffaf1;font-size:.78rem}.content{width:min(1200px,100%);margin:0 auto;padding:42px 48px 90px}.hero,.card{border:1px solid var(--line);border-radius:20px;background:var(--paper);box-shadow:var(--shadow)}.hero{padding:clamp(30px,5vw,58px)}.hero h2{max-width:900px;margin:.55rem 0 1rem;font-size:clamp(2rem,4vw,3.35rem);line-height:1.12;letter-spacing:-.035em}.lead{max-width:820px;color:var(--muted)}.status{display:flex;flex-wrap:wrap;gap:9px;margin-top:24px}.badge{display:inline-flex;align-items:center;gap:7px;padding:4px 9px;border:1px solid currentColor;border-radius:999px;font-size:.74rem;font-weight:750}.badge.ok{color:var(--ok);background:var(--oksoft)}.badge.warn{color:var(--warn);background:var(--warnsoft)}.badge.info{color:#315c8a;background:#e8eff7}.grid{display:grid;gap:14px}.hero-grid{grid-template-columns:repeat(3,minmax(0,1fr));margin-top:22px}.stats{grid-template-columns:repeat(4,minmax(0,1fr));margin-top:20px}.panel,.stat{padding:18px;border:1px solid var(--line);border-radius:16px;background:var(--paper2)}.panel h3{margin:0 0 6px;font-size:1rem}.panel p,.stat span{margin:0;color:var(--muted);font-size:.84rem}.stat strong{display:block;color:var(--accent);font-size:1.55rem;line-height:1.1}.section{padding-top:34px;scroll-margin-top:16px}.section h2{margin:0 0 14px;font-size:1.55rem}.card{padding:24px}.callout{padding:17px 18px;border-left:4px solid var(--accent);border-radius:0 12px 12px 0;background:var(--soft)}.callout.warn{border-color:var(--warn);background:var(--warnsoft)}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:.84rem}th,td{padding:11px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{color:var(--accent);background:#f6efe5;font-size:.74rem}tbody tr:last-child td{border-bottom:0}.diagram{padding:22px;border:1px solid var(--line);border-radius:16px;background:var(--paper2);text-align:center}.diagram p{color:var(--muted);font-size:.84rem;text-align:left}.steps{display:grid;gap:12px}.scenario{border:1px solid var(--line);border-radius:15px;background:var(--paper);overflow:hidden}.scenario summary{display:grid;grid-template-columns:46px minmax(0,1fr) auto;gap:14px;align-items:center;padding:16px 18px;cursor:pointer;list-style:none}.scenario summary::-webkit-details-marker{display:none}.scenario summary small{display:block;color:var(--muted);font-size:.78rem}.step-num{display:grid;place-items:center;width:38px;height:38px;border-radius:12px;color:white;background:var(--accent);font:700 .8rem monospace}.scenario-body{padding:0 20px 20px;border-top:1px dashed var(--line)}.scenario-body h4{color:var(--accent);margin-bottom:8px}.controls{display:flex;gap:8px;margin:10px 0}.controls button{padding:7px 11px;border:1px solid var(--line);border-radius:9px;color:var(--accent);background:var(--paper);cursor:pointer}.footer{margin-top:40px;padding-top:22px;border-top:1px solid var(--line);color:var(--muted);font-size:.82rem}@media(max-width:1040px){.layout{grid-template-columns:1fr}.sidebar{position:relative;height:auto;border-right:0;border-bottom:1px solid var(--line)}.sidebar nav{display:flex;gap:5px;overflow-x:auto}.sidebar nav a{min-width:max-content}.sidebar-meta{display:none}.content{padding:28px 22px 70px}.stats{grid-template-columns:repeat(2,1fr)}}@media(max-width:720px){.hero-grid,.stats{grid-template-columns:1fr}.content{padding:20px 14px 60px}.scenario summary{grid-template-columns:40px 1fr}.scenario summary .badge{display:none}}
</style></head><body><div class="layout"><aside class="sidebar"><div class="brand"><div class="eyebrow">Architecture casebook</div><h1>Yjs Title admission/refusal</h1><p>Ticket 05 的真實 Yjs admission probe 與 reject evidence。</p></div><nav aria-label="架構文件章節"><a href="#summary"><span class="num">01</span>TL;DR</a><a href="#scope"><span class="num">02</span>範圍與證據</a><a href="#components"><span class="num">03</span>元件總覽</a><a href="#flow"><span class="num">04</span>主流程</a><a href="#decisions"><span class="num">05</span>設計決策</a><a href="#pitfalls"><span class="num">06</span>風險</a><a href="#debt"><span class="num">07</span>改善方向</a><a href="#scenarios"><span class="num">08</span>Scenario evidence</a></nav><div class="sidebar-meta">分析目的：驗證單一 Title command 的 server admission/refusal<br>日期：2026-09-07<br>依據：${results.length} scenarios、真實 Windows Yjs integration run</div></aside><main class="content">
<header class="hero" id="summary"><div class="eyebrow">TL;DR · Architecture analysis · ticket 05</div><h2>Server reject 一個 command 時，Yjs、A/B/C 如何保持可恢復？</h2><p class="lead">本 spike 將 semantic Title command Q 與精確 Yjs update U 綁在完整 admission envelope，由 server candidate document 先驗證，再決定 accepted 或 refused；client 只以 accepted B 加上存活的 Pending Journal C 重建 A。</p><div class="status"><span class="badge ok">${results.length}/${results.length} scenarios passed</span><span class="badge info">$refusalCount actual refusals</span><span class="badge warn">shared-doc causal coupling confirmed</span></div><div class="grid hero-grid"><div class="panel"><h3>主要責任</h3><p>Server 掌握 canonical B、opId ledger、candidate validation 與 contiguous serverSeq；client 掌握 A/C 的 speculative replay。</p></div><div class="panel"><h3>核心抽象</h3><p>TitleAdmissionEnvelope = opId + Q + U + dependsOn + baseSeq；A = B + replay(C)。</p></div><div class="panel"><h3>依目的快速入口</h3><p>想看 reject：直接跳到 Scenario evidence；想評估 C：看設計決策與最後一節。</p></div></div></header><div class="grid stats"><div class="stat"><strong>${results.length}</strong><span>scenario families</span></div><div class="stat"><strong>$refusalCount</strong><span>server.refused records</span></div><div class="stat"><strong>5</strong><span>refusal classes exercised</span></div><div class="stat"><strong>3</strong><span>A/B/C state owners</span></div></div>
<section class="section" id="scope"><h2>分析範圍與證據</h2><div class="card"><div class="callout"><strong>Evidence boundary</strong><p>所有數字與 reject 結果來自 <code>flutter test integration_test/title_admission_test.dart -d windows</code>；這是 disposable prototype，不是 production collaboration code，也不會因 integration test 而長駐顯示產品視窗。</p></div><div class="callout"><strong>Yrs verdict</strong><p>可以在 Yrs 實作同一個 admission architecture：Yrs 是 Yjs 相容的 Rust port，具備 <code>TransactionMut::apply_update</code>、missing-update 狀態與 state vector；但 Yrs 不知道 Title command、policy 或 Q/U scope，所以仍需要 application-level envelope、candidate Doc、ledger 與 refusal message。最大限制仍是 shared-document causal dependency。</p></div><div class="table-wrap"><table><thead><tr><th>檔案／元件</th><th>角色</th><th>證據狀態</th></tr></thead><tbody><tr><td><code>lib/prototype/title_admission.dart</code></td><td>Admission envelope、server ledger、A/B/C client、restart seam</td><td><span class="badge ok">verified</span></td></tr><tr><td><code>integration_test/title_admission_test.dart</code></td><td>${results.length} 個 scenario 與 report generator</td><td><span class="badge ok">verified</span></td></tr><tr><td><code>runtime/yjs/yjs_runtime.dart</code></td><td>真實 Yjs update apply、projection、pendingStructs</td><td><span class="badge ok">verified</span></td></tr><tr><td>production collaboration implementation</td><td>本 spike 不修改、不宣稱已接線</td><td><span class="badge warn">out of scope</span></td></tr></tbody></table></div></div></section>
<section class="section" id="components"><h2>元件總覽</h2><div class="card"><div class="table-wrap"><table><thead><tr><th>元件</th><th>責任</th><th>觀察點</th></tr></thead><tbody><tr><td>Q semantic command</td><td>描述 Title 操作、scope、依賴與 UX/audit 語意</td><td>server policy / dependency / scope checks</td></tr><tr><td>U Yjs update</td><td>保存實際 CRDT item identities、anchors、client clocks</td><td>candidate apply / pendingStructs / exact replay</td></tr><tr><td>Server B</td><td>只接受 validated U，分配 contiguous serverSeq</td><td>projection 不應被 refusal 改變</td></tr><tr><td>Pending Journal C</td><td>以 opId identity-indexed，保留 envelope 與提交順序</td><td>out-of-order reply / transitive withdrawal / retry</td></tr><tr><td>Client A</td><td>由 B + 存活 C replay 的 user-visible state</td><td>refusal 不送 inverse，改為 rebuild</td></tr></tbody></table></div></div><div class="diagram"><div class="mermaid">graph TD
Q["Q: semantic Title command"] --> E["TitleAdmissionEnvelope"]
U["U: exact Yjs update"] --> E
E --> CAND["Server candidate document"]
CAND --> D["Accepted / Refused ticket"]
D --> B["B: accepted Collaboration Document"]
B --> A["A: speculative view"]
C["C: Pending Journal"] --> A
D --> C</div><p>Q/U 共同形成 server admission boundary；accepted 才能進 B，refused 只移除 C 中對應 opId 及其 semantic dependants，A 再從 B+C 重建。</p></div></section>
<section class="section" id="flow"><h2>主流程</h2><div class="diagram"><div class="mermaid">sequenceDiagram
participant Client as "Client A"
participant C as "Pending Journal C"
participant Server as "Server candidate + B"
Client->>C: append envelope(Q,U,opId,baseSeq)
Client->>Server: submit envelope
Server->>Server: dedup, dependencies, policy, candidate apply
alt accepted
Server-->>Client: ticket(serverSeq)
Client->>Server: integrate U into B by contiguous seq
Client->>Client: remove opId from C; rebuild A
else refused
Server-->>Client: ticket(reason, no serverSeq)
Client->>Client: withdraw opId/dependants; rebuild A from B+C
end</div><p>拒絕是 application-level decision，不是 transport disconnect。server 先在 candidate document 上驗證 U，避免把無法重放的 update 寫入 B。</p></div><div class="card"><div class="table-wrap"><table><thead><tr><th>變體</th><th>處理方式</th><th>已測到的證據</th></tr></thead><tbody><tr><td>reply out of order</td><td>A 先處理 refusal，accepted ticket 仍要等 contiguous serverSeq</td><td>pending C identity 與 B sequence 分離</td></tr><tr><td>lost acknowledgement</td><td>同 opId + 同 hash retry，回傳原 ticket</td><td>duplicate accepted/refused 均可重播</td></tr><tr><td>Yjs causal gap</td><td>candidate pendingStructs 非零則 refuse causalIncomplete</td><td>shared document 的同 client clock coupling 被實際觀察</td></tr></tbody></table></div></div></section>
<section class="section" id="decisions"><h2>設計決策</h2><div class="steps"><details class="scenario" open><summary><span class="step-num">01</span><span><strong>C 保存完整 envelope，而不是只保存 Q 或只保存 U</strong><small>Admission、replay、audit 三者需要不同欄位</small></span><span class="badge info">DECISION</span></summary><div class="scenario-body"><p><strong>決策：</strong> C 保存 Q semantic command、U exact Yjs bytes，以及 opId、Title、dependsOn、baseSeq、causal context／state vector 與 retry status。</p><p><strong>原因：</strong>Q 能回答「為什麼允許／拒絕」與 dependency；U 能保留 CRDT item identities、anchors、undo 所需的精確資料。只存 Q 不能 replay；只存 U 不能安全 admission 或 audit。</p><p><strong>代價：</strong>payload 較大、需要版本化與 durable storage；同時要處理 Q/U mismatch、Yjs causal predecessor 與 resource limits。</p></div></details><details class="scenario"><summary><span class="step-num">02</span><span><strong>Server candidate apply 再 commit B</strong><small>Refusal 不產生 serverSeq，也不污染 canonical B</small></span><span class="badge info">DECISION</span></summary><div class="scenario-body"><p><strong>決策：</strong>先從 B snapshot 建 candidate，apply U、檢查 pendingStructs、Title scope 與 semantic effect；全部通過後才 apply 到 B 並分配 serverSeq。</p><p><strong>原因：</strong>opaque relay 無法做 individual refusal；直接寫 B 會讓 reject 需要 inverse update，容易造成 causal residue。</p><p><strong>代價：</strong>每個 command 都有 candidate apply 成本，production 需要大小／時間／記憶體限制與 atomic durable commit。</p></div></details><details class="scenario"><summary><span class="step-num">03</span><span><strong>A/B/C 是不同責任，不是三份任意副本</strong><small>Canonical、speculative、durable journal 分離</small></span><span class="badge info">DECISION</span></summary><div class="scenario-body"><p><strong>決策：</strong>B 只收 accepted history；C 以 identity-indexed vector 保存 pending；A 永遠由 B + C replay 得出。</p><p><strong>原因：</strong>out-of-order acceptance/refusal、重連與 lost ack 需要把 identity resolution 與 server sequence resolution 分開。</p><p><strong>代價：</strong>rebuild 可能昂貴，且 shared Yjs document 的 causal coupling 會讓「語意獨立」不等於「可單獨保留」。</p></div></details></div></section>
<section class="section" id="pitfalls"><h2>風險與注意事項</h2><div class="grid hero-grid"><div class="panel"><h3>shared-doc causal coupling</h3><p><strong>症狀：</strong>不同 Title 的 local edit 仍被 causalIncomplete 拒絕。<br><strong>根因：</strong>同一 client clock chain。<br><strong>Invariant：</strong>不得讓 C replay 後留下 pendingStructs。</p></div><div class="panel"><h3>Q/U mismatch</h3><p><strong>症狀：</strong>Q 宣稱 Title A，U 實際改 Title B。<br><strong>根因：</strong>raw Yjs bytes 沒有產品 scope。<br><strong>Invariant：</strong>candidate projection 的 changed object ids 必須只落在 envelope.titleId。</p></div><div class="panel"><h3>lost ack / duplicate</h3><p><strong>症狀：</strong>client 重送相同操作。<br><strong>根因：</strong>server accepted/refused 與 reply 不是 atomic。<br><strong>Invariant：</strong>相同 opId + hash 必須回傳原 ticket，不得重分配 serverSeq。</p></div></div></section>
<section class="section" id="debt"><h2>技術債與改善方向</h2><div class="card table-wrap"><table><thead><tr><th>問題</th><th>影響範圍</th><th>建議方向</th><th>優先級</th></tr></thead><tbody><tr><td>prototype ledger 為 memory-only、commandHash 非 cryptographic</td><td>crash recovery、tamper resistance</td><td>durable operation record + cryptographic fingerprint + atomic B/ledger commit</td><td><span class="badge warn">P0 before production</span></td></tr><tr><td>shared Yjs doc 不能保證 semantic independent edit 單獨存活</td><td>拒絕 root 後的同 client local edits</td><td>優先評估 per-Title document isolation；否則實作 rebase/server-generated update</td><td><span class="badge warn">P0 decision</span></td></tr><tr><td>candidate apply 沒有 resource budget</td><td>惡意／超大 U、DoS</td><td>max bytes、max pending structs、CPU/time budget 與明確 refusal class</td><td><span class="badge info">P1</span></td></tr><tr><td>IME composition、format range、multi-command undo 尚未定義正式 command boundary</td><td>UX/audit/undo correctness</td><td>以 command vocabulary spec 和 native Yrs bridge contract 另立 ticket</td><td><span class="badge info">P1</span></td></tr></tbody></table></div></section>
<section class="section" id="scenarios"><h2>Scenario evidence：實際 reject ledger</h2><p class="muted">以下資料由同一次 integration run 產生；每張卡可展開查看 refusal reason、完整 envelope 與 A/B/C final snapshot。</p><div class="controls"><button type="button" id="expand-all">展開全部</button><button type="button" id="collapse-all">收合全部</button></div><div class="steps">$scenarioCards</div></section>
<footer class="footer">Generated by <code>yjs_probe/integration_test/title_admission_test.dart</code> · Ticket 05 · 2026-09-07 · Disposable prototype evidence, not production wiring.</footer>
  </main></div><script>mermaid.initialize({startOnLoad:true,theme:'base',themeVariables:{primaryColor:'#e3f1ed',primaryTextColor:'#2c2219',primaryBorderColor:'#136f63',lineColor:'#136f63',secondaryColor:'#fff8ee',tertiaryColor:'#f7f1e7'}});const cards=[...document.querySelectorAll('details.scenario')];document.querySelector('#expand-all')?.addEventListener('click',()=>cards.forEach(card=>card.open=true));document.querySelector('#collapse-all')?.addEventListener('click',()=>cards.forEach(card=>card.open=false));const links=[...document.querySelectorAll('nav a')];const sections=links.map(link=>document.querySelector(link.getAttribute('href'))).filter(Boolean);const observer=new IntersectionObserver(entries=>{entries.filter(entry=>entry.isIntersecting).forEach(entry=>links.forEach(link=>link.classList.toggle('active',link.getAttribute('href')==='#'+entry.target.id)))},{rootMargin:'-20% 0px -70% 0px'});sections.forEach(section=>observer.observe(section));</script></body></html>''';
  const oldFlow = '''sequenceDiagram
participant Client as "Client A"
participant C as "Pending Journal C"
participant Server as "Server candidate + B"
Client->>C: append envelope(Q,U,opId,baseSeq)
Client->>Server: submit envelope
Server->>Server: dedup, dependencies, policy, candidate apply
alt accepted
Server-->>Client: ticket(serverSeq)
Client->>Server: integrate U into B by contiguous seq
Client->>Client: remove opId from C; rebuild A
else refused
Server-->>Client: ticket(reason, no serverSeq)
Client->>Client: withdraw opId/dependants; rebuild A from B+C
end''';
  const newFlow = '''sequenceDiagram
participant Client as "Client: Q + optimistic A"
participant C as "Semantic Pending Journal C"
participant Server as "Server canonical B"
Client->>Client: execute Q on B_client
Client->>C: append Q, targets, baseSeq, optional optimistic U
Client->>Server: submit Q envelope
Server->>Server: dedup, dependencies, policy
Server->>Server: execute Q on candidate B_server
alt accepted
Server-->>Client: canonical U/result + serverSeq
Client->>Client: integrate canonical U; remove Q from C
Client->>Client: re-execute surviving Q entries
else refused
Server-->>Client: refusal reason, no serverSeq
Client->>Client: remove Q/dependants; re-execute surviving Q entries
end''';
  return html
      .replaceAll(
        'client 只以 accepted B 加上存活的 Pending Journal C 重建 A。',
        'client 先以 B_client 執行 Q 產生 optimistic A；server 再於 canonical B_server 執行 Q，回傳 authoritative U/result；C 保存可重做的 semantic Q。',
      )
      .replaceAll(
        'Server 掌握 canonical B、opId ledger、candidate validation 與 contiguous serverSeq；client 掌握 A/C 的 speculative replay。',
        'Client 先執行 Q；server 掌握 canonical B、policy、candidate Q execution、ledger 與 contiguous serverSeq；client 以 semantic C replay A。',
      )
      .replaceAll(
        'TitleAdmissionEnvelope = opId + Q + U + dependsOn + baseSeq；A = B + replay(C)。',
        'Envelope = opId + versioned Q + targets/preconditions + baseSeq + optional optimistic U；A = B + replay(Q in C)。',
      )
      .replaceAll(
        '<p>可以在 Yrs 實作同一個 admission architecture：Yrs 是 Yjs 相容的 Rust port，具備 <code>TransactionMut::apply_update</code>、missing-update 狀態與 state vector；但 Yrs 不知道 Title command、policy 或 Q/U scope，所以仍需要 application-level envelope、candidate Doc、ledger 與 refusal message。最大限制仍是 shared-document causal dependency。</p>',
        '<p>可以在 Yrs 實作同一個 admission architecture。這次 Yjs probe 已驗證 semantic-Q candidate execution 與 canonical U reconciliation 的形狀；Yrs 仍只負責 CRDT apply/state，不知道 Title command、policy、Q determinism 或 multi-select scope，所以 application layer 必須提供 envelope、ledger、candidate Doc 與 refusal message。exact-U route 的 shared-document causal dependency 仍是主要限制。</p>',
      )
      .replaceAll(
        '<td>只接受 validated U，分配 contiguous serverSeq</td>',
        '<td>在 canonical B_server 的 candidate 上執行 Q，commit canonical U/result 並分配 contiguous serverSeq</td>',
      )
      .replaceAll(
        '<td>candidate apply / pendingStructs / exact replay</td>',
        '<td>candidate Q execution / canonical U / pendingStructs diagnostic</td>',
      )
      .replaceAll(
        '<td>以 opId identity-indexed，保留 envelope 與提交順序</td>',
        '<td>以 opId identity-indexed，保留 versioned Q、targets、preconditions、baseSeq 與 optional optimistic U</td>',
      )
      .replaceAll(
        '<td>out-of-order reply / transitive withdrawal / retry</td>',
        '<td>out-of-order reply / semantic replay / transitive withdrawal / retry</td>',
      )
      .replaceAll(
        '<td>由 B + 存活 C replay 的 user-visible state</td>',
        '<td>由 B + surviving C 的 Q replay 得出的 user-visible state</td>',
      )
      .replaceAll(
        '<p>Q/U 共同形成 server admission boundary；accepted 才能進 B，refused 只移除 C 中對應 opId 及其 semantic dependants，A 再從 B+C 重建。</p>',
        '<p>Q 是 canonical admission unit；client U 只是 optimistic evidence。server 在 candidate B_server 執行 Q，accepted 才提交 canonical U；A 從 B_client 重做 C 中 surviving Q。</p>',
      )
      .replaceAll(oldFlow, newFlow)
      .replaceAll(
        '拒絕是 application-level decision，不是 transport disconnect。server 先在 candidate document 上驗證 U，避免把無法重放的 update 寫入 B。',
        '拒絕是 application-level decision，不是 transport disconnect。semantic mode 不把 client U 直接寫入 live B，而是在 candidate B_server 執行 Q；accept 後 client 接受 canonical result 並重做其餘 Q。',
      )
      .replaceAll(
        'C 保存完整 envelope，而不是只保存 Q 或只保存 U',
        'C 保存 semantic Q 與 optional optimistic U，而不是只保存 exact U',
      )
      .replaceAll(
        'C 保存 Q semantic command、U exact Yjs bytes，以及 opId、Title、dependsOn、baseSeq、causal context／state vector 與 retry status。',
        'C 保存版本化 Q、opId、targets、anchors/preconditions、dependsOn、baseSeq/state vector、retry status，以及可選 optimistic U。',
      )
      .replaceAll(
        'Q 能回答「為什麼允許／拒絕」與 dependency；U 能保留 CRDT item identities、anchors、undo 所需的精確資料。只存其中一個都不足。',
        'Q 是 server/client 都能重做的 semantic source；optimistic U 可供 audit/debug，但 canonical U 由 server 產生。exact U 不再是拒絕後 rebuild 的唯一來源。',
      )
      .replaceAll(
        '先從 B snapshot 建 candidate，apply U、檢查 pendingStructs、Title scope 與 semantic effect；全部通過後才 apply 到 B 並分配 serverSeq。',
        '先從 B_server snapshot 建 candidate，執行 Q、檢查完整 group scope/preconditions 與 effect；全部通過後才 commit canonical U 到 B 並分配 serverSeq。',
      )
      .replaceAll(
        'A 永遠由 B + C replay 得出。',
        'A 永遠由 B + C 中 surviving Q replay 得出；收到 canonical U 後先整合 B，再重做剩餘 Q。',
      )
      .replaceAll(
        '優先評估 per-Title document isolation；否則實作 rebase/server-generated update',
        '優先實作 semantic Q replay + server canonical execution；per-Title/per-object Doc 僅作 feature-family isolation 最佳化',
      )
      .replaceAll(
        'shared Yjs doc 不能保證 semantic independent edit 單獨存活',
        'exact-U replay 不能保證 semantic independent edit 單獨存活',
      )
      .replaceAll(
        '<td>拒絕 root 後的同 client local edits</td>',
        '<td>exact-U route 的 rejected predecessor 與同 client local edits</td>',
      )
      .replaceAll(
        '<td>以 command vocabulary spec 和 native Yrs bridge contract 另立 ticket</td>',
        '<td>以 versioned Q schema、shared executor/golden tests 和 native Yrs bridge contract 另立 ticket</td>',
      );
}
