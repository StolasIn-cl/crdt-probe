import 'dart:typed_data';

import '../core/envelope.dart';
import '../core/ids.dart';

/// The thin server: assigns a sequence number, appends to a log, and serves a
/// slice. It never applies a Yjs update and never looks inside a payload — the
/// shape ticket 08 §8 preserves, and the shape this probe measures against.
class ThinServer {
  ThinServer({this.onEvent});

  final void Function(String kind, Map<String, Object?> data)? onEvent;
  final List<UpdateEnvelope> _log = [];
  int _nextSeq = 1;
  int _nextClientId = 1;

  /// Assigning ids in connection order is scenario S0.2's whole experiment:
  /// Yjs breaks a tie by comparing `clientID`, so a server-ordered id makes
  /// that tie-break deterministic and server-decided with no patch to Yjs.
  ClientId assignClientId() => ClientId(_nextClientId++);

  int get headSeq => _nextSeq - 1;

  List<UpdateEnvelope> get log => List.unmodifiable(_log);

  UpdateEnvelope accept({
    required ClientId author,
    required Uint8List payload,
    required int baseSeq,
  }) {
    final e = UpdateEnvelope(
      seq: _nextSeq++,
      authorId: author,
      baseSeq: baseSeq,
      payload: payload,
    );
    _log.add(e);
    onEvent?.call('server.accept', {
      'seq': e.seq,
      'authorId': e.authorId.value,
      'baseSeq': e.baseSeq,
      'payloadBytes': e.payload.length,
      'payloadB64': e.payload,
    });
    return e;
  }

  List<UpdateEnvelope> since(int lastSeq) =>
      _log.where((e) => e.seq > lastSeq).toList(growable: false);

  Map<String, Object?> toJson() => {
        'headSeq': headSeq,
        'log': [for (final envelope in _log) envelope.toJson()],
      };
}
