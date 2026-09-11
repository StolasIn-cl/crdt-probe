import 'dart:convert';

import '../../core/capability.dart';
import '../../core/ids.dart';
import '../../driver/probe_client.dart';
import '../../runtime/crdt_runtime.dart';
import '../../transport/in_memory_post_office.dart';
import '../scenario.dart';
import 'axis0_arrival_order.dart';

const _t = ObjectId('s6-title');

Future<void> _seedAll(
  List<ProbeClient> clients, {
  String text = 'abcdefgh',
}) async {
  final writer = clients.first;
  await writer.createTitle(_t, x: 0, y: 0, w: 100, h: 30);
  await writer.type(_t, 0, text);
  await writer.flushOutbox();
  for (final client in clients.skip(1)) {
    await client.receiveAll();
  }
}

Future<List<Map<String, Object?>>> _readDelta(ProbeClient client) async {
  final projection = await client.read();
  final object = projection.objects[_t];
  if (object == null || object.delta == null) {
    throw StateError('title delta is unavailable');
  }
  return object.delta!;
}

String _deltaText(List<Map<String, Object?>> delta) => jsonEncode(delta);

Future<(ProbeClient, ProbeClient, ProbeClient, ProbeClient, InMemoryPostOffice)>
_prepareFour(CrdtRuntime runtime, {String text = 'abcdefgh'}) async {
  final (clients, po) = await clientsOn(runtime, 4);
  await _seedAll(clients, text: text);
  final [a, b, forward, reversed] = clients;
  return (a, b, forward, reversed, po);
}

Future<(List<Map<String, Object?>>, List<Map<String, Object?>>)> _drainPair(
  InMemoryPostOffice po,
  ProbeClient forward,
  ProbeClient reversed,
) async {
  final forwardQueued = po.pendingFor(forward.clientId).length;
  final reversedQueued = po.pendingFor(reversed.clientId).length;
  if (forwardQueued < 2 || reversedQueued < 2) {
    throw StateError(
      'observers queued $forwardQueued/$reversedQueued envelopes; '
      'at least two are required to compare arrival orders',
    );
  }

  po.unhold(forward.clientId);
  po.unhold(reversed.clientId);
  await forward.receiveAll();
  await reversed.receiveReversed();
  return (await _readDelta(forward), await _readDelta(reversed));
}

Future<List<Map<String, Object?>>> _boundaryExperiment(
  CrdtRuntime runtime,
  int index,
  String inserted,
) async {
  final (a, b, po) = await pairOn(runtime);
  await _seedAll([a, b]);
  await a.format(_t, 1, 3, {'bold': true});
  await a.flushOutbox();
  await b.receiveAll();

  await b.type(_t, index, inserted);
  await b.flushOutbox();
  await a.receiveAll();
  po.drop(b.clientId);
  return _readDelta(a);
}

final List<Scenario> axis6Scenarios = [
  Scenario(
    id: 'S6.1',
    title: 'same-attribute-different-values-same-range',
    targets:
        'ticket 25 formatting half — same attribute, different values, same range; compare both arrival orders and record whether the winner is source-only',
    requires: const {},
    body: (ctx) async {
      final (a, b, forward, reversed, po) = await _prepareFour(ctx.runtime);
      po.hold(forward.clientId);
      po.hold(reversed.clientId);

      await ctx.driver.step(
        'both writers format the same range differently',
        () async {
          await a.format(_t, 0, 5, {'bold': true});
          await b.format(_t, 0, 5, {'bold': false});
          await a.flushOutbox();
          await b.flushOutbox();
        },
      );

      final (forwardDelta, reversedDelta) = await _drainPair(
        po,
        forward,
        reversed,
      );
      ctx.driver.note(
        'forward=${_deltaText(forwardDelta)}, '
        'reversed=${_deltaText(reversedDelta)}',
      );
      return Passed(
        evidence:
            'forward=${_deltaText(forwardDelta)}, '
            'reversed=${_deltaText(reversedDelta)}; the observed winner is a '
            'Yjs control-group result, not a server-order guarantee',
      );
    },
  ),
  Scenario(
    id: 'S6.2',
    title: 'overlapping-but-not-identical-ranges',
    targets:
        'ticket 25 formatting half — A formats [0,5), B formats [3,8); observe the overlap [3,5) and both arrival orders',
    requires: const {},
    body: (ctx) async {
      final (a, b, forward, reversed, po) = await _prepareFour(ctx.runtime);
      po.hold(forward.clientId);
      po.hold(reversed.clientId);

      await ctx.driver.step('writers format overlapping ranges', () async {
        await a.format(_t, 0, 5, {'bold': true});
        await b.format(_t, 3, 5, {'bold': false});
        await a.flushOutbox();
        await b.flushOutbox();
      });

      final (forwardDelta, reversedDelta) = await _drainPair(
        po,
        forward,
        reversed,
      );
      ctx.driver.note(
        'forward=${_deltaText(forwardDelta)}, '
        'reversed=${_deltaText(reversedDelta)}',
      );
      return Passed(
        evidence:
            'forward=${_deltaText(forwardDelta)}, '
            'reversed=${_deltaText(reversedDelta)}; overlap is represented '
            'by Y.Text delta chunks',
      );
    },
  ),
  Scenario(
    id: 'S6.3',
    title: 'insert-inside-formatted-range',
    targets:
        'ticket 25 formatting half — determine whether a character inserted inside a formatted range inherits the surrounding mark',
    requires: const {},
    body: (ctx) async {
      final (a, b, _) = await pairOn(ctx.runtime);
      await _seedAll([a, b]);

      await ctx.driver.step(
        'format a range and deliver it to the inserter',
        () async {
          await a.format(_t, 1, 3, {'bold': true});
          await a.flushOutbox();
          await b.receiveAll();
        },
      );
      await ctx.driver.step('insert inside the formatted range', () async {
        await b.type(_t, 2, 'X');
        await b.flushOutbox();
        await a.receiveAll();
      });

      final delta = await _readDelta(a);
      var insertedIsBold = false;
      var offset = 0;
      for (final chunk in delta) {
        final inserted = chunk['insert'];
        if (inserted is! String) continue;
        final containsX = offset <= 2 && 2 < offset + inserted.length;
        offset += inserted.length;
        if (!containsX) continue;
        final attributes = chunk['attributes'];
        insertedIsBold = attributes is Map && attributes['bold'] == true;
      }
      ctx.driver.note(
        'delta=${_deltaText(delta)}, '
        'inserted X inherits bold=$insertedIsBold',
      );
      return Passed(
        evidence:
            'delta=${_deltaText(delta)}; '
            'inserted X inherits bold=$insertedIsBold',
      );
    },
  ),
  Scenario(
    id: 'S6.4',
    title: 'insert-at-boundary-of-formatted-range',
    targets:
        'ticket 25 formatting half — compare insertion at the left and right boundaries of a formatted range against Promeo Sticky Run anchors',
    requires: const {},
    body: (ctx) async {
      final left = await _boundaryExperiment(ctx.runtime, 1, 'L');
      final right = await _boundaryExperiment(ctx.runtime, 4, 'R');
      ctx.driver.note(
        'left boundary=${_deltaText(left)}, '
        'right boundary=${_deltaText(right)}',
      );
      return Passed(
        evidence:
            'left boundary=${_deltaText(left)}, '
            'right boundary=${_deltaText(right)}',
      );
    },
  ),
  Scenario(
    id: 'S6.5',
    title: 'format-a-range-the-other-deleted',
    targets:
        'ticket 25 formatting half — formatting applied to a range another participant deletes concurrently',
    requires: const {},
    body: (ctx) async {
      final (a, b, forward, reversed, po) = await _prepareFour(ctx.runtime);
      po.hold(forward.clientId);
      po.hold(reversed.clientId);

      await ctx.driver.step(
        'format and delete overlapping text concurrently',
        () async {
          await a.format(_t, 1, 3, {'bold': true});
          await b.erase(_t, 2, 2);
          await a.flushOutbox();
          await b.flushOutbox();
        },
      );

      final (forwardDelta, reversedDelta) = await _drainPair(
        po,
        forward,
        reversed,
      );
      ctx.driver.note(
        'forward=${_deltaText(forwardDelta)}, '
        'reversed=${_deltaText(reversedDelta)}',
      );
      return Passed(
        evidence:
            'forward=${_deltaText(forwardDelta)}, '
            'reversed=${_deltaText(reversedDelta)}',
      );
    },
  ),
  Scenario(
    id: 'S6.6',
    title: 'concurrent-format-and-text-edit-same-range',
    targets:
        'ticket 23 formatting differential paths — format and text edit overlap on the same range',
    requires: const {},
    body: (ctx) async {
      final (a, b, forward, reversed, po) = await _prepareFour(ctx.runtime);
      po.hold(forward.clientId);
      po.hold(reversed.clientId);

      await ctx.driver.step(
        'format and delete in the same area concurrently',
        () async {
          await a.format(_t, 1, 5, {'bold': true});
          await b.erase(_t, 3, 1);
          await a.flushOutbox();
          await b.flushOutbox();
        },
      );

      final (forwardDelta, reversedDelta) = await _drainPair(
        po,
        forward,
        reversed,
      );
      ctx.driver.note(
        'forward=${_deltaText(forwardDelta)}, '
        'reversed=${_deltaText(reversedDelta)}',
      );
      return Passed(
        evidence:
            'forward=${_deltaText(forwardDelta)}, '
            'reversed=${_deltaText(reversedDelta)}',
      );
    },
  ),
  Scenario(
    id: 'S6.7',
    title: 'format-marker-growth-under-repeated-toggle',
    targets:
        'ticket 25 formatting half — repeated format toggles; measure encoded size and ContentFormat structs separately from adoption',
    requires: const {Capability.decodeUpdate},
    body: (ctx) async {
      final (writer, observer, _) = await pairOn(ctx.runtime);
      await _seedAll([writer, observer]);

      final sizes = <int>[];
      final markerCounts = <int>[];
      await ctx.driver.step(
        'toggle bold twenty times and decode each full state',
        () async {
          for (var i = 0; i < 20; i++) {
            await writer.format(_t, 0, 5, {'bold': i.isEven});
            await writer.flushOutbox();
            await observer.receiveAll();

            final encoded = await ctx.runtime.encodeStateAsUpdate(
              writer.clientId,
            );
            final decoded = await ctx.runtime.decodeUpdate(encoded);
            sizes.add(encoded.length);
            markerCounts.add(
              decoded.summaries
                  .where((summary) => summary.contains('ContentFormat'))
                  .length,
            );
          }
        },
      );

      ctx.driver.note(
        'sizes=${sizes.join(',')}; '
        'ContentFormat counts=${markerCounts.join(',')}',
      );
      return Passed(
        evidence:
            '20 toggles: first=${sizes.first}B/${markerCounts.first} '
            'ContentFormat, last=${sizes.last}B/${markerCounts.last} '
            'ContentFormat; growth is reported as a measurement',
      );
    },
  ),
];
