import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/core/field_write.dart';
import 'package:yjs_probe/driver/probe_client.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';
import 'package:yjs_probe/transport/in_memory_post_office.dart';
import 'package:yjs_probe/transport/thin_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('two clients converge through the post office', () async {
    final rt = await YjsRuntime.create();
    final server = ThinServer();
    final po = InMemoryPostOffice(server);

    final a = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final b = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    await a.open();
    await b.open();

    const t = ObjectId('t1');
    await a.createTitle(t, x: 0, y: 0, w: 100, h: 30);
    await a.type(t, 0, 'Hello');
    await a.flushOutbox();

    expect(await b.receiveAll(), greaterThan(0));
    expect((await b.read()).objects[t]!.text, 'Hello');
  });

  test('resyncFromServer catches a client up from its lastSeq', () async {
    final rt = await YjsRuntime.create();
    final server = ThinServer();
    final po = InMemoryPostOffice(server);

    final a = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final b = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    await a.open();
    await b.open();

    const t = ObjectId('t2');
    po.hold(b.clientId);
    await a.createTitle(t, x: 0, y: 0, w: 10, h: 10);
    await a.type(t, 0, 'offline');
    await a.flushOutbox();

    expect(await b.receiveAll(), 0, reason: 'held clients receive nothing');

    po.unhold(b.clientId);
    po.drop(b.clientId);
    expect(await b.resyncFromServer(), greaterThan(0));
    expect((await b.read()).objects[t]!.text, 'offline');
  });

  test('receiveReversed converges to the same result as receiveAll', () async {
    final rt = await YjsRuntime.create();
    final server = ThinServer();
    final po = InMemoryPostOffice(server);

    // Two writers author a genuine field conflict; two pure receivers hold
    // the identical pair of resulting envelopes and drain them in opposite
    // orders — the exact [2,1] vs [1,2] shape the review confirmed by
    // reasoning, now pinned by a test.
    final writer1 = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final writer2 = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final receiverA = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final receiverB = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    await writer1.open();
    await writer2.open();
    await receiverA.open();
    await receiverB.open();

    const t = ObjectId('t3');
    await writer1.createTitle(t, x: 0, y: 0, w: 10, h: 10);
    await writer1.flushOutbox();
    await writer2.receiveAll();
    await receiverA.receiveAll();
    await receiverB.receiveAll();

    po.hold(receiverA.clientId);
    po.hold(receiverB.clientId);

    await writer1.move(t, 'x', 11);
    await writer2.move(t, 'x', 22);
    await writer1.flushOutbox();
    await writer2.flushOutbox();

    po.unhold(receiverA.clientId);
    po.unhold(receiverB.clientId);

    final forwardCount = await receiverA.receiveAll();
    final reversedCount = await receiverB.receiveReversed();

    expect(reversedCount, forwardCount);
    expect(receiverA.lastSeq, receiverB.lastSeq);

    // Which value wins is a later task's measurement, not a fact to pin here.
    final valueViaForward = (await receiverA.read()).objects[t]!.x;
    final valueViaReversed = (await receiverB.read()).objects[t]!.x;
    expect(valueViaReversed, valueViaForward);
  });

  test('resyncFromServer clears the pending queue so a later receiveAll does not double count', () async {
    final rt = await YjsRuntime.create();
    final server = ThinServer();
    final po = InMemoryPostOffice(server);

    final a = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final b = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    await a.open();
    await b.open();

    const t = ObjectId('t4');
    po.hold(b.clientId);
    await a.createTitle(t, x: 0, y: 0, w: 10, h: 10);
    await a.type(t, 0, 'resync');
    await a.flushOutbox();

    expect(await b.resyncFromServer(), greaterThan(0));
    expect(po.pendingFor(b.clientId), isEmpty);

    po.unhold(b.clientId);
    expect(await b.receiveAll(), 0,
        reason: 'resync already integrated everything; the queue must not double-count');
  });

  test('a batch field write updates multiple objects in one outgoing update', () async {
    final rt = await YjsRuntime.create();
    final server = ThinServer();
    final po = InMemoryPostOffice(server);

    final a = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    final b = ProbeClient(clientId: server.assignClientId(), runtime: rt, postOffice: po);
    await a.open();
    await b.open();

    const first = ObjectId('batch-1');
    const second = ObjectId('batch-2');
    await a.createImage(first, x: 0, y: 0, w: 10, h: 10, src: 'a');
    await a.createImage(second, x: 20, y: 20, w: 10, h: 10, src: 'b');
    await a.flushOutbox();
    await b.receiveAll();

    final beforeSeq = server.headSeq;
    await a.setFields([
      const FieldWrite(first, 'x', 100),
      const FieldWrite(first, 'y', 110),
      const FieldWrite(second, 'x', 120),
      const FieldWrite(second, 'y', 130),
    ]);
    await a.flushOutbox();

    expect(server.headSeq, beforeSeq + 1,
        reason: 'one batch transaction should create one server envelope');
    expect((await a.read()).objects[first]!.x, 100);
    expect((await a.read()).objects[second]!.y, 130);
    expect((await b.read()).objects[first]!.x, 0,
        reason: 'the peer must not change before delivery');

    expect(await b.receiveAll(), 1);
    expect((await b.read()).objects[first]!.x, 100);
    expect((await b.read()).objects[second]!.y, 130);
  });
}
