import 'dart:typed_data';

import '../core/envelope.dart';
import '../core/ids.dart';
import 'thin_server.dart';
import 'transport.dart';

/// A post office the operator drives by hand. `hold` stops delivery *to* a
/// recipient without stopping the server from sequencing, so the log stays
/// complete and a dropped queue can still be replayed from `since()`.
class InMemoryPostOffice implements Transport {
  InMemoryPostOffice(this.server, {this.onEvent});

  final ThinServer server;
  final void Function(String kind, Map<String, Object?> data)? onEvent;
  final Map<ClientId, List<UpdateEnvelope>> _queues = {};
  final Set<ClientId> _held = {};

  @override
  void register(ClientId c) => _queues.putIfAbsent(c, () => []);

  @override
  void send(ClientId author, Uint8List payload, int baseSeq) {
    final envelope = server.accept(author: author, payload: payload, baseSeq: baseSeq);
    for (final entry in _queues.entries) {
      if (entry.key != author) {
        entry.value.add(envelope);
        onEvent?.call('delivery.enqueue', {
          'recipientId': entry.key.value,
          'envelope': envelope.toJson(),
        });
      }
    }
  }

  @override
  List<UpdateEnvelope> pendingFor(ClientId c) =>
      List.unmodifiable(_queues[c] ?? const <UpdateEnvelope>[]);

  @override
  List<UpdateEnvelope> take(ClientId c) {
    if (_held.contains(c)) return const [];
    final q = _queues[c];
    if (q == null || q.isEmpty) return const [];
    final drained = List<UpdateEnvelope>.unmodifiable(q);
    q.clear();
    onEvent?.call('delivery.take', {
      'recipientId': c.value,
      'seqs': drained.map((e) => e.seq).toList(),
    });
    return drained;
  }

  /// The arrival-order-reversal control. Ignores `hold`, because reversing is
  /// an explicit operator act.
  List<UpdateEnvelope> releaseReversed(ClientId c) {
    final q = _queues[c];
    if (q == null || q.isEmpty) return const [];
    final drained = List<UpdateEnvelope>.unmodifiable(q.reversed);
    q.clear();
    onEvent?.call('delivery.take-reversed', {
      'recipientId': c.value,
      'seqs': drained.map((e) => e.seq).toList(),
    });
    return drained;
  }

  UpdateEnvelope? step(ClientId c) {
    final q = _queues[c];
    if (q == null || q.isEmpty) return null;
    final envelope = q.removeAt(0);
    onEvent?.call('delivery.step', {
      'recipientId': c.value,
      'seq': envelope.seq,
    });
    return envelope;
  }

  void drop(ClientId c) {
    final count = _queues[c]?.length ?? 0;
    _queues[c]?.clear();
    onEvent?.call('delivery.drop', {'recipientId': c.value, 'count': count});
  }

  void hold(ClientId c) {
    _held.add(c);
    onEvent?.call('delivery.hold', {'recipientId': c.value});
  }

  void unhold(ClientId c) {
    _held.remove(c);
    onEvent?.call('delivery.unhold', {'recipientId': c.value});
  }

  bool isHeld(ClientId c) => _held.contains(c);

  Map<String, Object?> toJson() => {
        'held': [for (final c in _held) c.value],
        'pending': {
          for (final entry in _queues.entries)
            '${entry.key.value}': [for (final e in entry.value) e.toJson()],
        },
      };
}
