import 'dart:typed_data';

import '../core/capability.dart';
import '../core/field_write.dart';
import '../core/ids.dart';
import '../core/projection.dart';

enum ObjectKind { title, image }

class DecodedUpdate {
  const DecodedUpdate({required this.structCount, required this.summaries});
  final int structCount;
  final List<String> summaries;
}

/// Seam 1. Substituting this is how a conclusion about undo gets re-measured on
/// Yrs, whose `UndoManager` is undo-as-a-later-writer where Yjs's `StackItem`
/// is identity-anchored (ticket 17). Every observation that a runtime might not
/// support is gated by [capabilities].
abstract interface class CrdtRuntime {
  String get name;
  CapabilitySet get capabilities;

  /// [undo] requests that this document build its `UndoManager` (or
  /// runtime-equivalent) up front. Task 20: this used to happen
  /// unconditionally for every document, which perturbs `encodeStateAsUpdate`
  /// for scenarios that never touch undo (see S5.2 in task-20-report.md) —
  /// an `UndoManager`'s after-transaction handler keeps tombstoned structs
  /// alive only for transactions whose origin it tracks, which differs
  /// between the peer that authors a change locally and the peer that
  /// receives it remotely. Defaults to `false` on purpose: a caller that
  /// forgets to opt in gets a document with no undo history and a loud,
  /// visible failure the first time it calls undo; a default of `true` would
  /// instead make the opposite mistake silent — a document nobody meant to
  /// give undo to would perturb its own encoded bytes with nothing failing.
  Future<void> open(ClientId clientId, {bool undo = false});
  Future<void> close(ClientId clientId);

  /// [seq] is the server's total-order number for this update, when the
  /// caller has one (every real envelope has one -- see
  /// `UpdateEnvelope.seq`). Yjs/Yrs never need it: their updates are
  /// commutative and converge under any application order. Ticket
  /// yata-core/01's `PromeoRuntime` is the reason this parameter exists --
  /// Rule A ("an insertion lands immediately to the right of its anchor,
  /// applied in server sequence order") requires the actual total order to
  /// place a concurrent insertion correctly, and [ProbeClient] discards
  /// `UpdateEnvelope.seq` before this call unless it is threaded through.
  /// Optional and nullable so every existing caller and implementation
  /// stays source-compatible.
  Future<void> applyUpdate(ClientId c, Uint8List update, {String origin = 'remote', int? seq});
  Future<List<Uint8List>> drainOutbox(ClientId c);
  Future<Uint8List> encodeStateAsUpdate(ClientId c);
  Future<DocProjection> projection(ClientId c);

  Future<void> createObject(
    ClientId c,
    ObjectId id,
    ObjectKind kind, {
    required double x,
    required double y,
    required double w,
    required double h,
    double rotation = 0,
    double z = 0,
    String? src,
  });
  Future<void> setField(ClientId c, ObjectId id, String key, num value);
  Future<void> setFields(ClientId c, List<FieldWrite> writes);
  Future<void> insertText(ClientId c, ObjectId id, int index, String text);
  Future<void> deleteText(ClientId c, ObjectId id, int index, int length);
  Future<void> formatText(
      ClientId c, ObjectId id, int index, int length, Map<String, Object?> attrs);
  Future<void> deleteObject(ClientId c, ObjectId id);

  /// The length the runtime itself reports for a title's text, in whatever
  /// unit that runtime counts in. Task 21 exists because that unit is the
  /// same integer space every [insertText] / [deleteText] / [formatText]
  /// index lives in, and it had never been measured against a string whose
  /// UTF-16 length and grapheme count differ. Deliberately not documented as
  /// "code units": what it returns is the measurement, not a promise.
  Future<int> textLength(ClientId c, ObjectId id);

  /// Requires [Capability.decodeUpdate].
  Future<DecodedUpdate> decodeUpdate(Uint8List update);

  /// Requires [Capability.countPendingStructs].
  Future<int> pendingStructCount(ClientId c);
}
