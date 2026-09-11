import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/transport/in_memory_post_office.dart';
import 'package:yjs_probe/transport/thin_server.dart';

Uint8List bytes(int b) => Uint8List.fromList([b]);
const alice = ClientId(1);
const bob = ClientId(2);

InMemoryPostOffice fresh() {
  final po = InMemoryPostOffice(ThinServer());
  po.register(alice);
  po.register(bob);
  return po;
}

void main() {
  test('an update reaches every client except its author', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    expect(po.pendingFor(bob).map((e) => e.seq), [1]);
    expect(po.pendingFor(alice), isEmpty);
  });

  test('take drains in send order and empties the queue', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.take(bob).map((e) => e.seq), [1, 2]);
    expect(po.pendingFor(bob), isEmpty);
  });

  test('releaseReversed drains in the opposite order', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.releaseReversed(bob).map((e) => e.seq), [2, 1]);
    expect(po.pendingFor(bob), isEmpty);
  });

  test('a held client accumulates and delivers nothing until unheld', () {
    final po = fresh();
    po.hold(bob);
    po.send(alice, bytes(1), 0);
    expect(po.isHeld(bob), isTrue);
    expect(po.take(bob), isEmpty, reason: 'a held client must deliver nothing');
    po.unhold(bob);
    expect(po.take(bob).map((e) => e.seq), [1]);
  });

  test('step delivers exactly one envelope', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.step(bob)!.seq, 1);
    expect(po.pendingFor(bob).map((e) => e.seq), [2]);
  });

  test('drop discards a queue without delivering it', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    po.drop(bob);
    expect(po.pendingFor(bob), isEmpty);
    expect(po.take(bob), isEmpty);
  });

  test('the server log still holds a dropped envelope, so it can be replayed', () {
    final po = fresh();
    po.send(alice, bytes(1), 0);
    po.drop(bob);
    expect(po.server.since(0).map((e) => e.seq), [1]);
  });

  test('releaseReversed ignores hold', () {
    final po = fresh();
    po.hold(bob);
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.isHeld(bob), isTrue);
    expect(po.releaseReversed(bob).map((e) => e.seq), [2, 1],
        reason: 'releaseReversed must work even when bob is held');
    expect(po.isHeld(bob), isTrue, reason: 'releaseReversed must not clear hold');
    expect(po.pendingFor(bob), isEmpty);
  });

  test('step ignores hold', () {
    final po = fresh();
    po.hold(bob);
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.isHeld(bob), isTrue);
    expect(po.step(bob)!.seq, 1,
        reason: 'step must return oldest envelope even when bob is held');
    expect(po.pendingFor(bob).map((e) => e.seq), [2]);
    expect(po.isHeld(bob), isTrue, reason: 'step must not clear hold');
  });

  test('drop ignores hold', () {
    final po = fresh();
    po.hold(bob);
    po.send(alice, bytes(1), 0);
    po.send(alice, bytes(2), 0);
    expect(po.isHeld(bob), isTrue);
    po.drop(bob);
    expect(po.pendingFor(bob), isEmpty,
        reason: 'drop must clear queue even when bob is held');
    expect(po.isHeld(bob), isTrue, reason: 'drop must not clear hold');
    expect(po.server.since(0).map((e) => e.seq), [1, 2],
        reason: 'server log must preserve dropped envelopes even for held clients');
  });
}
