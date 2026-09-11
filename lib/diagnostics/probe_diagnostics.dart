import 'dart:convert';
import 'dart:io';

import '../driver/probe_client.dart';
import '../runtime/crdt_runtime.dart';
import '../transport/in_memory_post_office.dart';
import '../transport/thin_server.dart';
import 'json_value.dart';

class ProbeDiagnostics {
  ProbeDiagnostics({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<_ProbeEvent> _events = [];
  var _nextEventNo = 1;

  List<Map<String, Object?>> get events => [
        for (final event in _events) event.toJson(),
      ];

  void record(String kind, Map<String, Object?> data) {
    _events.add(
      _ProbeEvent(
        eventNo: _nextEventNo++,
        timestamp: _now().toUtc(),
        kind: kind,
        data: toJsonSafe(data) as Map<String, Object?>,
      ),
    );
  }

  void clear() => _events.clear();

  Future<String> export({
    required Iterable<ProbeClient> clients,
    required ThinServer server,
    required InMemoryPostOffice postOffice,
    required CrdtRuntime runtime,
  }) async {
    final clientSnapshots = <Map<String, Object?>>[];
    for (final client in clients) {
      final projection = await client.read();
      clientSnapshots.add({
        'clientId': client.clientId.value,
        'lastSeq': client.lastSeq,
        'projection': projection.toJson(),
        'stateVectorB64': projection.stateVectorB64,
        'stateAsUpdateB64': base64Encode(await runtime.encodeStateAsUpdate(client.clientId)),
      });
    }

    final payload = <String, Object?>{
      'runtime': runtime.name,
      'exportedAt': _now().toUtc().toIso8601String(),
      'events': events,
      'clients': clientSnapshots,
      'server': server.toJson(),
      'postOffice': postOffice.toJson(),
    };
    final directory = Directory(
      '${Directory.current.path}${Platform.pathSeparator}reports',
    );
    await directory.create(recursive: true);
    final stamp = _now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}human-session-$stamp.json',
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJsonSafe(payload)),
      flush: true,
    );
    return file.absolute.path;
  }
}

class _ProbeEvent {
  const _ProbeEvent({
    required this.eventNo,
    required this.timestamp,
    required this.kind,
    required this.data,
  });

  final int eventNo;
  final DateTime timestamp;
  final String kind;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'eventNo': eventNo,
        'timestamp': timestamp.toIso8601String(),
        'kind': kind,
        'data': data,
      };
}
