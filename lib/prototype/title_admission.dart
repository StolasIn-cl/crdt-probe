// THROWAWAY PROTOTYPE — Wayfinder ticket 05.
//
// This file deliberately lives outside the production collaboration packages.
// It exercises the proposed application-level admission boundary against a
// real CrdtRuntime (the integration test supplies YjsRuntime) without
// pretending that a raw Yjs update is itself a safe acceptance unit.

import 'dart:convert';
import 'dart:typed_data';

import '../core/field_write.dart';
import '../core/ids.dart';
import '../core/projection.dart';
import '../runtime/crdt_runtime.dart';
import '../runtime/undo_runtime.dart';

enum TitleCommandKind {
  createTitle,
  insertText,
  deleteText,
  formatText,
  moveObjects,
  undo,
}

class TitleCommand {
  const TitleCommand({
    required this.kind,
    required this.titleId,
    this.index,
    this.length,
    this.text,
    this.attributes = const <String, Object?>{},
    this.targetOpId,
    this.targetObjectIds = const <String>[],
    this.deltaX = 0,
    this.deltaY = 0,
  });

  final TitleCommandKind kind;
  final String titleId;
  final int? index;
  final int? length;
  final String? text;
  final Map<String, Object?> attributes;
  final String? targetOpId;
  final List<String> targetObjectIds;
  final double deltaX;
  final double deltaY;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'titleId': titleId,
    'index': index,
    'length': length,
    'text': text,
    'attributes': attributes,
    'targetOpId': targetOpId,
    'targetObjectIds': targetObjectIds,
    'deltaX': deltaX,
    'deltaY': deltaY,
  };
}

enum AdmissionExecutionMode { exactUpdate, semanticCommand }

class TitleAdmissionEnvelope {
  TitleAdmissionEnvelope({
    required this.opId,
    required this.titleId,
    required this.command,
    required Uint8List yrsUpdate,
    required this.dependsOn,
    required this.baseSeq,
    this.baseStateVectorB64,
  }) : yrsUpdate = Uint8List.fromList(yrsUpdate);

  final String opId;
  final String titleId;
  final TitleCommand command;
  final Uint8List yrsUpdate;
  final List<String> dependsOn;
  final int baseSeq;
  final String? baseStateVectorB64;

  /// A deterministic identity fingerprint for the prototype's ledger.
  /// Production should replace this with a cryptographic command hash.
  String get commandHash => jsonEncode({
    'titleId': titleId,
    'command': command.toJson(),
    'yrsUpdateB64': base64Encode(yrsUpdate),
    'dependsOn': dependsOn,
    'baseSeq': baseSeq,
  });

  /// Semantic identity deliberately excludes the optimistic U and baseSeq.
  /// A replay can produce a different client-clock update, and a retry may be
  /// sent after the accepted server head has advanced; neither changes Q's
  /// operation identity.
  String get semanticCommandHash => jsonEncode({
    'titleId': titleId,
    'command': command.toJson(),
    'dependsOn': dependsOn,
  });

  Map<String, Object?> toJson() => {
    'opId': opId,
    'titleId': titleId,
    'command': command.toJson(),
    'yrsUpdateBytes': yrsUpdate.length,
    'yrsUpdateB64': base64Encode(yrsUpdate),
    'dependsOn': dependsOn,
    'baseSeq': baseSeq,
    'baseStateVectorB64': baseStateVectorB64,
    'commandHash': commandHash,
  };
}

enum AdmissionOutcome { accepted, refused }

enum AdmissionRefusal {
  malformed,
  futureBase,
  missingDependency,
  dependencyRefused,
  causalIncomplete,
  policy,
  semanticMismatch,
  noEffect,
  applyFailed,
  identityConflict,
}

class AdmissionTicket {
  const AdmissionTicket._({
    required this.opId,
    required this.envelope,
    required this.outcome,
    this.serverSeq,
    this.refusal,
    this.duplicate = false,
    this.canonicalUpdate,
  });

  factory AdmissionTicket.accepted({
    required TitleAdmissionEnvelope envelope,
    required int serverSeq,
    bool duplicate = false,
    Uint8List? canonicalUpdate,
  }) => AdmissionTicket._(
    opId: envelope.opId,
    envelope: envelope,
    outcome: AdmissionOutcome.accepted,
    serverSeq: serverSeq,
    duplicate: duplicate,
    canonicalUpdate: canonicalUpdate,
  );

  factory AdmissionTicket.refused({
    required TitleAdmissionEnvelope envelope,
    required AdmissionRefusal refusal,
    bool duplicate = false,
  }) => AdmissionTicket._(
    opId: envelope.opId,
    envelope: envelope,
    outcome: AdmissionOutcome.refused,
    refusal: refusal,
    duplicate: duplicate,
  );

  final String opId;
  final TitleAdmissionEnvelope envelope;
  final AdmissionOutcome outcome;
  final int? serverSeq;
  final AdmissionRefusal? refusal;
  final bool duplicate;
  final Uint8List? canonicalUpdate;

  bool get accepted => outcome == AdmissionOutcome.accepted;

  Map<String, Object?> toJson() => {
    'opId': opId,
    'outcome': outcome.name,
    'serverSeq': serverSeq,
    'refusal': refusal?.name,
    'duplicate': duplicate,
    'canonicalUpdateBytes': canonicalUpdate?.length,
    'canonicalUpdateB64': canonicalUpdate == null
        ? null
        : base64Encode(canonicalUpdate!),
    // Keep the full admission identity beside the decision in the
    // disposable trace. A refusal is only useful to the architecture
    // review if we can inspect the exact Q/U envelope that was rejected.
    'envelope': envelope.toJson(),
  };
}

typedef AdmissionPolicy = AdmissionRefusal? Function(TitleAdmissionEnvelope);

class YjsAdmissionServer {
  YjsAdmissionServer({
    required this.runtime,
    this.serverId = const ClientId(9000),
    this.policy,
    this.mode = AdmissionExecutionMode.exactUpdate,
    this.onEvent,
  });

  final CrdtRuntime runtime;
  final ClientId serverId;
  final AdmissionPolicy? policy;
  final AdmissionExecutionMode mode;
  final void Function(String kind, Map<String, Object?> data)? onEvent;

  final Map<String, AdmissionTicket> _decisions = {};
  final List<AdmissionTicket> _acceptedHistory = [];
  int _headSeq = 0;
  int _candidateCounter = 0;

  int get headSeq => _headSeq;
  List<AdmissionTicket> get acceptedHistory =>
      List<AdmissionTicket>.unmodifiable(_acceptedHistory);
  Map<String, AdmissionTicket> get decisions =>
      Map<String, AdmissionTicket>.unmodifiable(_decisions);

  Future<void> open() => runtime.open(serverId);

  /// Restores the accepted state and idempotency ledger after a simulated
  /// server restart. Production durability is intentionally out of scope for
  /// this probe; this seam makes the required recovery contract explicit.
  Future<void> restoreAcceptedState({
    required Uint8List snapshot,
    required Iterable<AdmissionTicket> acceptedHistory,
    required int headSeq,
  }) async {
    if (snapshot.isNotEmpty) {
      await runtime.applyUpdate(serverId, snapshot, origin: 'recovery');
    }
    _acceptedHistory
      ..clear()
      ..addAll(acceptedHistory);
    _decisions
      ..clear()
      ..addEntries(
        _acceptedHistory.map((ticket) => MapEntry(ticket.opId, ticket)),
      );
    _headSeq = headSeq;
    _record('server.recovered', {
      'serverSeq': _headSeq,
      'acceptedHistory': _acceptedHistory
          .map((ticket) => ticket.toJson())
          .toList(),
    });
  }

  Future<AdmissionTicket> submit(TitleAdmissionEnvelope envelope) async {
    final existing = _decisions[envelope.opId];
    if (existing != null) {
      final sameIdentity = mode == AdmissionExecutionMode.semanticCommand
          ? existing.envelope.semanticCommandHash ==
                envelope.semanticCommandHash
          : existing.envelope.commandHash == envelope.commandHash;
      if (sameIdentity) {
        final duplicate = existing.accepted
            ? AdmissionTicket.accepted(
                envelope: existing.envelope,
                serverSeq: existing.serverSeq!,
                duplicate: true,
                canonicalUpdate: existing.canonicalUpdate,
              )
            : AdmissionTicket.refused(
                envelope: existing.envelope,
                refusal: existing.refusal!,
                duplicate: true,
              );
        _record('server.duplicate', duplicate.toJson());
        return duplicate;
      }
      final conflict = AdmissionTicket.refused(
        envelope: envelope,
        refusal: AdmissionRefusal.identityConflict,
      );
      _record('server.identity-conflict', conflict.toJson());
      return conflict;
    }

    if (envelope.yrsUpdate.isEmpty ||
        envelope.opId.isEmpty ||
        envelope.titleId.isEmpty ||
        envelope.command.titleId.isEmpty ||
        envelope.titleId != envelope.command.titleId) {
      return _rememberRefusal(envelope, AdmissionRefusal.malformed);
    }
    if (envelope.baseSeq > _headSeq) {
      return _rememberRefusal(envelope, AdmissionRefusal.futureBase);
    }

    for (final dependency in envelope.dependsOn) {
      final decision = _decisions[dependency];
      if (decision == null) {
        return _rememberRefusal(envelope, AdmissionRefusal.missingDependency);
      }
      if (!decision.accepted) {
        return _rememberRefusal(envelope, AdmissionRefusal.dependencyRefused);
      }
    }

    final policyRefusal = policy?.call(envelope);
    if (policyRefusal != null) {
      return _rememberRefusal(envelope, policyRefusal);
    }

    final candidateId = ClientId(9500 + _candidateCounter++);
    Uint8List canonicalUpdate = envelope.yrsUpdate;
    try {
      await runtime.open(candidateId);
      final snapshot = await runtime.encodeStateAsUpdate(serverId);
      if (snapshot.isNotEmpty) {
        await runtime.applyUpdate(candidateId, snapshot, origin: 'remote');
      }
      // The snapshot is remote state. Drain defensively so the canonical
      // update below contains only the candidate's execution of Q.
      await runtime.drainOutbox(candidateId);
      final before = await runtime.projection(candidateId);
      if (mode == AdmissionExecutionMode.semanticCommand) {
        canonicalUpdate = await _executeSemanticCommand(
          candidateId,
          envelope.command,
        );
      } else {
        await runtime.applyUpdate(
          candidateId,
          canonicalUpdate,
          origin: 'remote',
        );
      }
      final pendingStructs = await runtime.pendingStructCount(candidateId);
      if (pendingStructs != 0) {
        return _rememberRefusal(
          envelope,
          AdmissionRefusal.causalIncomplete,
          extra: {'pendingStructs': pendingStructs},
        );
      }
      final after = await runtime.projection(candidateId);
      final changedTitles = _changedObjectIds(before, after);
      if (!_matchesSemanticScope(envelope, before, after, changedTitles)) {
        return _rememberRefusal(
          envelope,
          AdmissionRefusal.semanticMismatch,
          extra: {'changedTitles': changedTitles.toList()..sort()},
        );
      }
    } catch (error) {
      return _rememberRefusal(
        envelope,
        AdmissionRefusal.applyFailed,
        extra: {'error': '$error'},
      );
    } finally {
      await runtime.close(candidateId);
    }

    if (canonicalUpdate.isEmpty) {
      return _rememberRefusal(envelope, AdmissionRefusal.noEffect);
    }

    try {
      await runtime.applyUpdate(serverId, canonicalUpdate, origin: 'remote');
    } catch (error) {
      return _rememberRefusal(
        envelope,
        AdmissionRefusal.applyFailed,
        extra: {'error': '$error'},
      );
    }

    final ticket = AdmissionTicket.accepted(
      envelope: envelope,
      serverSeq: ++_headSeq,
      canonicalUpdate: canonicalUpdate,
    );
    _decisions[envelope.opId] = ticket;
    _acceptedHistory.add(ticket);
    _record('server.accepted', ticket.toJson());
    return ticket;
  }

  Future<Uint8List> _executeSemanticCommand(
    ClientId candidateId,
    TitleCommand command,
  ) async {
    await _applyCommand(runtime, candidateId, command);
    final updates = await runtime.drainOutbox(candidateId);
    if (updates.length != 1) {
      throw StateError(
        'semantic Q must produce one canonical U for ${command.kind.name}; '
        'got ${updates.length}',
      );
    }
    return updates.single;
  }

  Future<Uint8List> snapshot() => runtime.encodeStateAsUpdate(serverId);

  Future<DocProjection> projection() => runtime.projection(serverId);

  bool _matchesSemanticScope(
    TitleAdmissionEnvelope envelope,
    DocProjection before,
    DocProjection after,
    Set<String> changedTitles,
  ) {
    final declaredScope = envelope.command.kind == TitleCommandKind.moveObjects
        ? envelope.command.targetObjectIds.toSet()
        : {envelope.titleId};
    if (declaredScope.isEmpty ||
        changedTitles.any((id) => !declaredScope.contains(id))) {
      return false;
    }
    if (envelope.command.kind == TitleCommandKind.createTitle) {
      return !before.objects.containsKey(ObjectId(envelope.titleId)) &&
          after.objects.containsKey(ObjectId(envelope.titleId));
    }
    return declaredScope.every((id) => after.objects.containsKey(ObjectId(id)));
  }

  Future<AdmissionTicket> _rememberRefusal(
    TitleAdmissionEnvelope envelope,
    AdmissionRefusal refusal, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    final ticket = AdmissionTicket.refused(
      envelope: envelope,
      refusal: refusal,
    );
    _decisions[envelope.opId] = ticket;
    _record('server.refused', {...ticket.toJson(), ...extra});
    return ticket;
  }

  void _record(String kind, Map<String, Object?> data) =>
      onEvent?.call(kind, data);
}

/// Executes the semantic command vocabulary against a document. The same
/// function is used by client optimistic replay and the server candidate. A
/// production version should move this into a shared, versioned command
/// interpreter or make the server result authoritative with cross-runtime
/// golden tests.
Future<void> _applyCommand(
  CrdtRuntime runtime,
  ClientId clientId,
  TitleCommand command,
) async {
  switch (command.kind) {
    case TitleCommandKind.createTitle:
      await runtime.createObject(
        clientId,
        ObjectId(command.titleId),
        ObjectKind.title,
        x: 0,
        y: 0,
        w: 100,
        h: 40,
      );
    case TitleCommandKind.insertText:
      await runtime.insertText(
        clientId,
        ObjectId(command.titleId),
        command.index!,
        command.text!,
      );
    case TitleCommandKind.deleteText:
      await runtime.deleteText(
        clientId,
        ObjectId(command.titleId),
        command.index!,
        command.length!,
      );
    case TitleCommandKind.formatText:
      await runtime.formatText(
        clientId,
        ObjectId(command.titleId),
        command.index!,
        command.length!,
        command.attributes,
      );
    case TitleCommandKind.moveObjects:
      final projection = await runtime.projection(clientId);
      final writes = <FieldWrite>[];
      for (final objectId in command.targetObjectIds) {
        final object = projection.objects[ObjectId(objectId)];
        if (object == null) {
          throw StateError('moveObjects target does not exist: $objectId');
        }
        writes
          ..add(FieldWrite(ObjectId(objectId), 'x', object.x + command.deltaX))
          ..add(FieldWrite(ObjectId(objectId), 'y', object.y + command.deltaY));
      }
      if (writes.isNotEmpty) {
        await runtime.setFields(clientId, writes);
      }
    case TitleCommandKind.undo:
      throw StateError(
        'semantic Q replay does not support identity-bound undo; encode an '
        'explicit inverse command instead',
      );
  }
}

class PendingTitleCommand {
  const PendingTitleCommand(this.envelope);

  final TitleAdmissionEnvelope envelope;
}

class YjsAdmissionClient {
  YjsAdmissionClient({
    required this.runtime,
    required this.clientId,
    this.mode = AdmissionExecutionMode.exactUpdate,
    this.onEvent,
  }) : acceptedId = ClientId(10000 + clientId.value),
       _speculativeId = clientId;

  final CrdtRuntime runtime;
  final ClientId clientId;
  final AdmissionExecutionMode mode;
  final ClientId acceptedId;
  final void Function(String kind, Map<String, Object?> data)? onEvent;
  ClientId _speculativeId;
  int _rebuildCounter = 0;

  final List<PendingTitleCommand> _pending = [];
  final Map<int, AdmissionTicket> _acceptedBuffer = {};
  int lastAcceptedSeq = 0;
  bool connectionAlive = true;

  List<TitleAdmissionEnvelope> get pending => [
    for (final entry in _pending) entry.envelope,
  ];

  List<String> get pendingOpIds => [
    for (final entry in _pending) entry.envelope.opId,
  ];

  Future<void> open() async {
    await runtime.open(acceptedId);
    await runtime.open(_speculativeId, undo: true);
  }

  Future<void> close() async {
    await runtime.close(_speculativeId);
    await runtime.close(acceptedId);
  }

  Future<TitleAdmissionEnvelope> propose({
    required String opId,
    required TitleCommand command,
    required Future<void> Function() mutate,
    List<String> dependsOn = const <String>[],
  }) async {
    final baseProjection = await runtime.projection(acceptedId);
    await mutate();
    if (runtime is UndoRuntime) {
      await (runtime as UndoRuntime).stopCapturing(_speculativeId);
    }
    final updates = await runtime.drainOutbox(_speculativeId);
    if (updates.length != 1) {
      throw StateError(
        'prototype expects one Yjs update per command for $opId, got ${updates.length}',
      );
    }
    final envelope = TitleAdmissionEnvelope(
      opId: opId,
      titleId: command.titleId,
      command: command,
      yrsUpdate: updates.single,
      dependsOn: List<String>.unmodifiable(dependsOn),
      baseSeq: lastAcceptedSeq,
      baseStateVectorB64: baseProjection.stateVectorB64,
    );
    _pending.add(PendingTitleCommand(envelope));
    _record('client.proposed', {
      'clientId': clientId.value,
      'opId': opId,
      'dependsOn': dependsOn,
      'baseSeq': lastAcceptedSeq,
      'yrsUpdateBytes': updates.single.length,
    });
    return envelope;
  }

  Future<TitleAdmissionEnvelope> createTitle(
    String opId,
    String titleId, {
    List<String> dependsOn = const <String>[],
  }) => propose(
    opId: opId,
    command: TitleCommand(kind: TitleCommandKind.createTitle, titleId: titleId),
    dependsOn: dependsOn,
    mutate: () => runtime.createObject(
      _speculativeId,
      ObjectId(titleId),
      ObjectKind.title,
      x: 0,
      y: 0,
      w: 100,
      h: 40,
    ),
  );

  Future<TitleAdmissionEnvelope> insert(
    String opId,
    String titleId,
    int index,
    String text, {
    List<String> dependsOn = const <String>[],
  }) => propose(
    opId: opId,
    command: TitleCommand(
      kind: TitleCommandKind.insertText,
      titleId: titleId,
      index: index,
      text: text,
    ),
    dependsOn: dependsOn,
    mutate: () =>
        runtime.insertText(_speculativeId, ObjectId(titleId), index, text),
  );

  Future<TitleAdmissionEnvelope> erase(
    String opId,
    String titleId,
    int index,
    int length, {
    List<String> dependsOn = const <String>[],
    TitleCommandKind kind = TitleCommandKind.deleteText,
    String? targetOpId,
  }) => propose(
    opId: opId,
    command: TitleCommand(
      kind: kind,
      titleId: titleId,
      index: index,
      length: length,
      targetOpId: targetOpId,
    ),
    dependsOn: dependsOn,
    mutate: () =>
        runtime.deleteText(_speculativeId, ObjectId(titleId), index, length),
  );

  Future<TitleAdmissionEnvelope> format(
    String opId,
    String titleId,
    int index,
    int length,
    Map<String, Object?> attributes, {
    List<String> dependsOn = const <String>[],
  }) => propose(
    opId: opId,
    command: TitleCommand(
      kind: TitleCommandKind.formatText,
      titleId: titleId,
      index: index,
      length: length,
      attributes: attributes,
    ),
    dependsOn: dependsOn,
    mutate: () => runtime.formatText(
      _speculativeId,
      ObjectId(titleId),
      index,
      length,
      attributes,
    ),
  );

  Future<TitleAdmissionEnvelope> moveObjects(
    String opId,
    List<String> objectIds, {
    required double deltaX,
    required double deltaY,
    List<String> dependsOn = const <String>[],
  }) {
    if (objectIds.isEmpty) {
      throw ArgumentError.value(objectIds, 'objectIds', 'must not be empty');
    }
    final command = TitleCommand(
      kind: TitleCommandKind.moveObjects,
      // The envelope retains one primary scope for compatibility with the
      // original Title probe; the command's targetObjectIds is authoritative
      // for a group operation.
      titleId: objectIds.first,
      targetObjectIds: List<String>.unmodifiable(objectIds),
      deltaX: deltaX,
      deltaY: deltaY,
    );
    return propose(
      opId: opId,
      command: command,
      dependsOn: dependsOn,
      mutate: () => _applyCommand(runtime, _speculativeId, command),
    );
  }

  /// Produces a real Yjs UndoManager inverse and wraps it as a semantic
  /// `undo` command. The inverse is still a normal client-generated U, so it
  /// must pass the same admission and dependency rules as every other command.
  Future<TitleAdmissionEnvelope> undo(
    String opId,
    String titleId, {
    required String targetOpId,
    List<String> dependsOn = const <String>[],
  }) async {
    final undoRuntime = runtime as UndoRuntime?;
    if (undoRuntime == null) {
      throw StateError('Yjs admission prototype requires UndoRuntime for undo');
    }
    return propose(
      opId: opId,
      command: TitleCommand(
        kind: TitleCommandKind.undo,
        titleId: titleId,
        targetOpId: targetOpId,
      ),
      dependsOn: dependsOn,
      mutate: () async {
        if (!await undoRuntime.undo(_speculativeId)) {
          throw StateError('no local Yjs undo item for $opId');
        }
      },
    );
  }

  Future<void> deliver(AdmissionTicket ticket) async {
    if (ticket.accepted) {
      final seq = ticket.serverSeq!;
      if (seq <= lastAcceptedSeq) {
        _removePending(ticket.opId);
        await _rebuildSpeculative();
        return;
      }
      _acceptedBuffer[seq] = ticket;
      while (_acceptedBuffer.containsKey(lastAcceptedSeq + 1)) {
        final next = _acceptedBuffer.remove(lastAcceptedSeq + 1)!;
        await runtime.applyUpdate(
          acceptedId,
          next.canonicalUpdate ?? next.envelope.yrsUpdate,
          origin: 'remote',
        );
        lastAcceptedSeq = next.serverSeq!;
        _removePending(next.opId);
        _record('client.accepted-integrated', next.toJson());
      }
    } else {
      _withdrawTransitively(ticket.opId);
      _record('client.refused-withdrawn', {
        ...ticket.toJson(),
        'remainingPending': pendingOpIds,
      });
    }
    await _rebuildSpeculative();
  }

  Future<void> deliverRemote(AdmissionTicket ticket) => deliver(ticket);

  Future<DocProjection> acceptedProjection() => runtime.projection(acceptedId);

  Future<DocProjection> speculativeProjection() =>
      runtime.projection(_speculativeId);

  Future<int> speculativePendingStructs() =>
      runtime.pendingStructCount(_speculativeId);

  Future<Uint8List> acceptedSnapshot() =>
      runtime.encodeStateAsUpdate(acceptedId);

  Future<void> restoreAcceptedSnapshot(
    Uint8List snapshot, {
    required int serverSeq,
  }) async {
    await runtime.applyUpdate(acceptedId, snapshot, origin: 'remote');
    lastAcceptedSeq = serverSeq;
    await _rebuildSpeculative();
  }

  Future<void> reconnectFromSnapshot(
    Uint8List snapshot, {
    required int serverSeq,
    required Iterable<TitleAdmissionEnvelope> outstanding,
  }) async {
    _pending
      ..clear()
      ..addAll(outstanding.map(PendingTitleCommand.new));
    await restoreAcceptedSnapshot(snapshot, serverSeq: serverSeq);
    _record('client.reconnected', {
      'clientId': clientId.value,
      'serverSeq': serverSeq,
      'pending': pendingOpIds,
    });
  }

  Future<void> _rebuildSpeculative() async {
    final snapshot = await runtime.encodeStateAsUpdate(acceptedId);
    await runtime.close(_speculativeId);
    // Applying an accepted snapshot can contain this participant's old Yjs
    // clientID. Reusing that ID for freshly-derived A makes Yjs rotate it
    // implicitly, which breaks the probe's one-update-per-command boundary.
    // A fresh session-local ID is safe: pending envelopes retain their old
    // item identities, while new local edits use the new ID.
    _speculativeId = ClientId(11000 + clientId.value * 100 + _rebuildCounter++);
    await runtime.open(_speculativeId, undo: true);
    if (snapshot.isNotEmpty) {
      await runtime.applyUpdate(_speculativeId, snapshot, origin: 'remote');
    }
    for (final entry in _pending) {
      if (mode == AdmissionExecutionMode.semanticCommand) {
        await _applyCommand(runtime, _speculativeId, entry.envelope.command);
        final replayed = await runtime.drainOutbox(_speculativeId);
        if (replayed.length != 1) {
          throw StateError(
            'semantic Q replay must produce one local U for '
            '${entry.envelope.opId}; got ${replayed.length}',
          );
        }
        _record('client.semantic-replayed', {
          'opId': entry.envelope.opId,
          'optimisticUpdateBytes': replayed.single.length,
        });
      } else {
        await runtime.applyUpdate(
          _speculativeId,
          entry.envelope.yrsUpdate,
          origin: 'remote',
        );
      }
    }
  }

  void _removePending(String opId) {
    _pending.removeWhere((entry) => entry.envelope.opId == opId);
  }

  void _withdrawTransitively(String rootOpId) {
    final removed = <String>{rootOpId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in _pending) {
        if (entry.envelope.dependsOn.any(removed.contains) &&
            removed.add(entry.envelope.opId)) {
          changed = true;
        }
      }
    }
    _pending.removeWhere((entry) => removed.contains(entry.envelope.opId));
  }

  void _record(String kind, Map<String, Object?> data) =>
      onEvent?.call(kind, data);
}

Set<String> _changedObjectIds(DocProjection before, DocProjection after) {
  final ids = <String>{
    ...before.objects.keys.map((id) => id.value),
    ...after.objects.keys.map((id) => id.value),
  };
  return {
    for (final id in ids)
      if (_objectJson(before.objects[ObjectId(id)]) !=
          _objectJson(after.objects[ObjectId(id)]))
        id,
  };
}

String _objectJson(ObjectProjection? value) => jsonEncode(value?.toJson());
