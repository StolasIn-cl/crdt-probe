import 'dart:convert';
import 'dart:typed_data';

import 'ids.dart';

/// The transport envelope. `seq`, `authorId` and `baseSeq` ride here and never
/// enter the `Y.Doc`, so the server log can be inspected independently of the
/// CRDT.
class UpdateEnvelope {
  const UpdateEnvelope({
    required this.seq,
    required this.authorId,
    required this.baseSeq,
    required this.payload,
  });

  final int seq;
  final ClientId authorId;
  final int baseSeq;
  final Uint8List payload;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'authorId': authorId.value,
        'baseSeq': baseSeq,
        'payloadBytes': payload.length,
        'payloadB64': base64Encode(payload),
      };

  @override
  String toString() =>
      'UpdateEnvelope(seq: $seq, author: ${authorId.value}, baseSeq: $baseSeq, ${payload.length}B)';
}
