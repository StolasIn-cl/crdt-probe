import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/transport/thin_server.dart';

Uint8List bytes(int b) => Uint8List.fromList([b]);

void main() {
  test('client ids are assigned in connection order', () {
    final s = ThinServer();
    expect(s.assignClientId(), const ClientId(1));
    expect(s.assignClientId(), const ClientId(2));
    expect(s.assignClientId(), const ClientId(3));
  });

  test('sequence numbers start at 1 and increase by one', () {
    final s = ThinServer();
    final a = s.accept(author: const ClientId(1), payload: bytes(1), baseSeq: 0);
    final b = s.accept(author: const ClientId(2), payload: bytes(2), baseSeq: 0);
    expect(a.seq, 1);
    expect(b.seq, 2);
    expect(s.headSeq, 2);
  });

  test('since returns only envelopes after the given seq, in order', () {
    final s = ThinServer();
    for (var i = 0; i < 3; i++) {
      s.accept(author: const ClientId(1), payload: bytes(i), baseSeq: 0);
    }
    expect(s.since(1).map((e) => e.seq), [2, 3]);
    expect(s.since(0).map((e) => e.seq), [1, 2, 3]);
    expect(s.since(3), isEmpty);
  });

  test('the server never inspects a payload', () {
    final s = ThinServer();
    final e = s.accept(author: const ClientId(9), payload: bytes(0xAB), baseSeq: 4);
    expect(e.payload, bytes(0xAB));
    expect(e.authorId, const ClientId(9));
    expect(e.baseSeq, 4);
  });
}
