import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

const _sampleCount = 5;
const _client = ClientId(1);
const _title = ObjectId('benchmark-title');

class _Stats {
  const _Stats(this.minMs, this.medianMs, this.maxMs);

  final double minMs;
  final double medianMs;
  final double maxMs;
}

Future<double> _time(Future<void> Function() operation) async {
  final stopwatch = Stopwatch()..start();
  await operation();
  stopwatch.stop();
  return stopwatch.elapsedMicroseconds / 1000.0;
}

_Stats _stats(List<double> values) {
  final sorted = [...values]..sort();
  return _Stats(
    sorted.first,
    sorted[sorted.length ~/ 2],
    sorted.last,
  );
}

String _formatStats(_Stats stats) =>
    '${stats.minMs.toStringAsFixed(3)} | '
    '${stats.medianMs.toStringAsFixed(3)} | '
    '${stats.maxMs.toStringAsFixed(3)}';

Future<Map<String, List<double>>> _measureRuntime(
  String name,
  Future<CrdtRuntime> Function() create,
) async {
  final samples = <String, List<double>>{
    'local inserts (50)': [],
    'format ranges (10)': [],
    'projection': [],
    'encodeStateAsUpdate': [],
  };

  for (var sample = 0; sample < _sampleCount; sample++) {
    final runtime = await create();
    await runtime.open(_client);
    try {
      await runtime.createObject(
        _client,
        _title,
        ObjectKind.title,
        x: 0,
        y: 0,
        w: 160,
        h: 36,
      );
      await runtime.insertText(_client, _title, 0, 'seed');
      await runtime.formatText(_client, _title, 0, 2, {'bold': true});
      await runtime.projection(_client);
      await runtime.encodeStateAsUpdate(_client);

      await runtime.close(_client);
      await runtime.open(_client);
      await runtime.createObject(
        _client,
        _title,
        ObjectKind.title,
        x: 0,
        y: 0,
        w: 160,
        h: 36,
      );
      await runtime.insertText(_client, _title, 0, 'seed');

      samples['local inserts (50)']!.add(await _time(() async {
        for (var i = 0; i < 50; i++) {
          await runtime.insertText(_client, _title, 4 + i, 'x');
        }
      }));
      samples['format ranges (10)']!.add(await _time(() async {
        for (var i = 0; i < 10; i++) {
          await runtime.formatText(
            _client,
            _title,
            (i * 3) % 45,
            3,
            {'bold': true},
          );
        }
      }));
      samples['projection']!.add(
        await _time(() async {
          final projection = await runtime.projection(_client);
          final object = projection.objects[_title]!;
          expect(object.text, hasLength(54));
          expect(
            object.delta!.any(
              (chunk) => (chunk['attributes'] as Map?)?['bold'] == true,
            ),
            isTrue,
            reason: '$name projection lost the bold delta',
          );
        }),
      );
      samples['encodeStateAsUpdate']!.add(
        await _time(() async {
          final update = await runtime.encodeStateAsUpdate(_client);
          expect(update, isNotEmpty, reason: '$name produced an empty update');
        }),
      );
    } finally {
      await runtime.close(_client);
      if (runtime is YjsRuntime) runtime.dispose();
    }
  }
  return samples;
}

String _renderReport(Map<String, Map<String, List<double>>> results) {
  final lines = <String>[
    '# P3 Yjs/Yrs performance benchmark',
    '',
    'Single-machine Windows measurement from the standalone `yjs_probe`. '
        'Runtime bootstrap and DLL load are excluded; each row measures the '
        'same workload after a warmup document. Values are milliseconds.',
    '',
    '| Runtime | Workload | Min | Median | Max |',
    '|---|---|---:|---:|---:|',
  ];
  for (final entry in results.entries) {
    for (final workload in entry.value.entries) {
      lines.add('| ${entry.key} | ${workload.key} | ${_formatStats(_stats(workload.value))} |');
    }
  }
  lines.addAll([
    '',
    'This is directional evidence for the exact versions and workload, not '
        'an adoption threshold. Repeat on representative Promeo hardware and '
        'with production-sized documents before making a performance decision.',
  ]);
  return '${lines.join('\n')}\n';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Yjs and Yrs benchmark reports are generated for the shared workload', () async {
    final results = <String, Map<String, List<double>>>{
      'Yjs': await _measureRuntime('Yjs', () async => YjsRuntime.create()),
      'Yrs': await _measureRuntime('Yrs', () async => YrsRuntime.create()),
    };
    for (final runtime in results.entries) {
      expect(runtime.value, hasLength(4));
      for (final workload in runtime.value.entries) {
        expect(workload.value, hasLength(_sampleCount));
        expect(workload.value.every((value) => value.isFinite && value >= 0), isTrue);
      }
    }

    final report = _renderReport(results);
    File('reports/p3-performance.md').writeAsStringSync(report);
    // ignore: avoid_print
    print(report);
  });
}
