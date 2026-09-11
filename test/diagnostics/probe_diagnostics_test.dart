import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/diagnostics/json_value.dart';
import 'package:yjs_probe/diagnostics/probe_diagnostics.dart';
import '../fakes/fake_runtime.dart';
import 'package:yjs_probe/transport/in_memory_post_office.dart';
import 'package:yjs_probe/transport/thin_server.dart';

void main() {
  test('events are numbered and remain JSON serializable', () {
    final diagnostics = ProbeDiagnostics(
      now: () => DateTime.utc(2026, 8, 21, 1, 2, 3),
    );
    diagnostics.record('operation', {
      'bytes': Uint8List.fromList([1, 2, 3]),
      'nested': {'values': [true, 4]},
    });
    diagnostics.record('projection', {'clientId': 1});

    expect(diagnostics.events[0]['eventNo'], 1);
    expect(diagnostics.events[1]['eventNo'], 2);
    expect(
      diagnostics.events[0]['data'],
      containsPair(
        'bytes',
        {'type': 'Uint8List', 'byteLength': 3, 'base64': 'AQID'},
      ),
    );
    expect(() => jsonEncode(diagnostics.events), returnsNormally);

    diagnostics.clear();
    expect(diagnostics.events, isEmpty);
    diagnostics.record('after-clear', {});
    expect(diagnostics.events.single['eventNo'], 3);
  });

  test('json-safe conversion preserves nested collections and binary values', () {
    expect(
      toJsonSafe({
        'bytes': Uint8List.fromList([0, 255]),
        'list': [1, 'two'],
      }),
      {
        'bytes': {'type': 'Uint8List', 'byteLength': 2, 'base64': 'AP8='},
        'list': [1, 'two'],
      },
    );
  });

  test('export contains event, server envelope, and transport sections', () async {
    final diagnostics = ProbeDiagnostics(
      now: () => DateTime.utc(2026, 8, 21, 1, 2, 3),
    );
    final server = ThinServer();
    final postOffice = InMemoryPostOffice(server);
    server.accept(
      author: const ClientId(1),
      payload: Uint8List.fromList([9, 8]),
      baseSeq: 0,
    );
    diagnostics.record('logical.operation', {'objectId': 'o0', 'field': 'x'});

    final path = await diagnostics.export(
      clients: const [],
      server: server,
      postOffice: postOffice,
      runtime: FakeRuntime(const CapabilitySet.of({})),
    );
    addTearDown(() => File(path).delete());

    final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(json['runtime'], 'fake');
    expect(json['events'], hasLength(1));
    expect(json['events'][0]['kind'], 'logical.operation');
    expect(json['server']['log'][0]['seq'], 1);
    expect(json['server']['log'][0]['payloadB64'], 'CQg=');
    expect(json['postOffice']['pending'], isA<Map<String, dynamic>>());
  });

  test('thin server and post office diagnostics can be wired to recorder', () {
    final diagnostics = ProbeDiagnostics();
    final server = ThinServer(onEvent: diagnostics.record);
    final postOffice = InMemoryPostOffice(server, onEvent: diagnostics.record);
    postOffice.register(const ClientId(1));
    postOffice.register(const ClientId(2));

    postOffice.send(const ClientId(1), Uint8List.fromList([7]), 0);

    expect(diagnostics.events.map((e) => e['kind']), contains('server.accept'));
    expect(diagnostics.events.map((e) => e['kind']), contains('delivery.enqueue'));
  });
}
