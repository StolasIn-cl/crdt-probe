import 'dart:convert';

import '../core/envelope.dart';
import '../core/capability.dart';
import '../core/field_write.dart';
import '../core/ids.dart';
import '../core/projection.dart';
import '../runtime/crdt_runtime.dart';
import '../transport/in_memory_post_office.dart';

/// Seam 3's shared object. The UI and a script drive the same `ProbeClient`, so
/// a behaviour found by hand becomes a scenario without being rewritten.
class ProbeClient {
  ProbeClient({
    required this.clientId,
    required this.runtime,
    required this.postOffice,
    this.onEvent,
  });

  final ClientId clientId;
  final CrdtRuntime runtime;
  final InMemoryPostOffice postOffice;
  final void Function(String kind, Map<String, Object?> data)? onEvent;

  /// The highest server seq this client has integrated. Reconnect is
  /// `since(lastSeq)`, matching ticket 14 §8's log-shaped catch-up.
  int lastSeq = 0;

  Future<void> open({bool undo = false}) async {
    await runtime.open(clientId, undo: undo);
    postOffice.register(clientId);
  }

  /// Moves everything the runtime has produced onto the wire.
  Future<void> flushOutbox() async {
    for (final update in await runtime.drainOutbox(clientId)) {
      DecodedUpdate? decoded;
      String? decodeError;
      if (runtime.capabilities.has(Capability.decodeUpdate)) {
        try {
          decoded = await runtime.decodeUpdate(update);
        } catch (error) {
          decodeError = '$error';
        }
      }
      _record('outgoing.update', {
        'clientId': clientId.value,
        'payloadBytes': update.length,
        'payloadB64': base64Encode(update),
        'decoded': decoded == null
            ? {
                'available': false,
                'error': decodeError,
              }
            : {
                'available': true,
                'structCount': decoded.structCount,
                'summaries': decoded.summaries,
              },
        'baseSeq': lastSeq,
      });
      postOffice.send(clientId, update, lastSeq);
    }
  }

  Future<int> _integrate(List<UpdateEnvelope> envelopes) async {
    var n = 0;
    for (final e in envelopes) {
      // e.seq is threaded through so a runtime whose ordering rule needs the
      // true server total order (PromeoRuntime's Rule A) can see it. Yjs/Yrs
      // ignore the extra argument.
      await runtime.applyUpdate(clientId, e.payload, seq: e.seq);
      if (e.seq > lastSeq) lastSeq = e.seq;
      _record('client.integrate', {
        'clientId': clientId.value,
        'seq': e.seq,
        'authorId': e.authorId.value,
        'baseSeq': e.baseSeq,
        'payloadBytes': e.payload.length,
        'payloadB64': base64Encode(e.payload),
      });
      n++;
    }
    return n;
  }

  Future<int> receiveAll() => _integrate(postOffice.take(clientId));

  /// The arrival-order-reversal experiment, from the client's side.
  Future<int> receiveReversed() => _integrate(postOffice.releaseReversed(clientId));

  /// Reconnect: ask the server for everything after [lastSeq].
  ///
  /// Clears the pending queue afterwards. `since(lastSeq)` is a superset of
  /// every un-integrated envelope in that queue, so nothing is lost — and
  /// leaving them queued would let a following `receiveAll` re-apply envelopes
  /// this call already integrated. Yjs would absorb that idempotently, but the
  /// returned count would report arrivals that never happened, and a probe
  /// whose subject is measurement cannot afford a miscount.
  Future<int> resyncFromServer() async {
    final n = await _integrate(postOffice.server.since(lastSeq));
    postOffice.drop(clientId);
    return n;
  }

  Future<DocProjection> read() => runtime.projection(clientId);

  Future<void> createTitle(
    ObjectId id, {
    required double x,
    required double y,
    required double w,
    required double h,
  }) async {
    await runtime.createObject(clientId, id, ObjectKind.title, x: x, y: y, w: w, h: h);
    _record('logical.operation', {
      'operation': 'createObject',
      'clientId': clientId.value,
      'objectId': id.value,
      'kind': ObjectKind.title.name,
      'x': x,
      'y': y,
      'w': w,
      'h': h,
    });
  }

  Future<void> createImage(
    ObjectId id, {
    required double x,
    required double y,
    required double w,
    required double h,
    required String src,
  }) async {
    await runtime.createObject(clientId, id, ObjectKind.image,
        x: x, y: y, w: w, h: h, src: src);
    _record('logical.operation', {
      'operation': 'createObject',
      'clientId': clientId.value,
      'objectId': id.value,
      'kind': ObjectKind.image.name,
      'x': x,
      'y': y,
      'w': w,
      'h': h,
      'src': src,
    });
  }

  Future<void> type(ObjectId id, int index, String text) =>
      _runTextOperation('insertText', id, () => runtime.insertText(clientId, id, index, text), {
        'index': index,
        'text': text,
      });

  Future<void> erase(ObjectId id, int index, int length) =>
      _runTextOperation('deleteText', id, () => runtime.deleteText(clientId, id, index, length), {
        'index': index,
        'length': length,
      });

  Future<void> format(ObjectId id, int index, int length, Map<String, Object?> attrs) =>
      _runTextOperation('formatText', id,
          () => runtime.formatText(clientId, id, index, length, attrs), {
        'index': index,
        'length': length,
        'attrs': attrs,
      });

  Future<void> move(ObjectId id, String key, num value) async {
    final before = await read();
    await runtime.setField(clientId, id, key, value);
    _record('logical.operation', {
      'operation': 'setField',
      'clientId': clientId.value,
      'writes': [
        {
          'objectId': id.value,
          'field': key,
          'oldValue': _fieldValue(before.objects[id], key),
          'newValue': value,
        },
      ],
    });
  }

  Future<void> setFields(List<FieldWrite> writes) async {
    final before = await read();
    await runtime.setFields(clientId, writes);
    _record('logical.operation', {
      'operation': 'setFields',
      'clientId': clientId.value,
      'writes': [
        for (final write in writes)
          {
            'objectId': write.objectId.value,
            'field': write.key,
            'oldValue': _fieldValue(before.objects[write.objectId], write.key),
            'newValue': write.value,
          },
      ],
    });
  }

  Future<void> moveMany(Map<ObjectId, (double x, double y)> positions) =>
      setFields([
        for (final entry in positions.entries) ...[
          FieldWrite(entry.key, 'x', entry.value.$1),
          FieldWrite(entry.key, 'y', entry.value.$2),
        ],
      ]);

  Future<void> remove(ObjectId id) async {
    await runtime.deleteObject(clientId, id);
    _record('logical.operation', {
      'operation': 'deleteObject',
      'clientId': clientId.value,
      'objectId': id.value,
    });
  }

  Future<void> _runTextOperation(
    String operation,
    ObjectId id,
    Future<void> Function() action,
    Map<String, Object?> details,
  ) async {
    await action();
    _record('logical.operation', {
      'operation': operation,
      'clientId': clientId.value,
      'objectId': id.value,
      ...details,
    });
  }

  Object? _fieldValue(ObjectProjection? object, String key) {
    if (object == null) return null;
    return switch (key) {
      'x' => object.x,
      'y' => object.y,
      'w' => object.w,
      'h' => object.h,
      'rotation' => object.rotation,
      'z' => object.z,
      'src' => object.src,
      'text' => object.text,
      'kind' => object.kind,
      _ => null,
    };
  }

  void _record(String kind, Map<String, Object?> data) => onEvent?.call(kind, data);
}
