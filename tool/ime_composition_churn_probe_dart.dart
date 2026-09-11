// Wayfinder ticket 05 (yrs-native-reject-admission-feasibility) validation
// runner — plain Dart, no Flutter engine, no native patch.
//
// Runs the IME composition-churn scenarios
// (`lib/prototype/title_admission_native_probe.dart`) for real against the
// vendored, unpatched `native/yffi/v0.27.3/yrs.dll`, via `YrsRuntime.create()`
// unchanged. Chosen for the same reason as tickets 01-04's own `dart run`
// scripts: this sandboxed environment hangs `flutter test`'s
// Windows-app-to-VM-service socket (see `reports/p5-zorder-merge.md` and
// `reports/p6-yffi-pending-structs.md`).
// `integration_test/title_admission_ime_composition_test.dart` runs the exact
// same scenario functions and is left in the repo, analyzed clean, as the
// standard harness for whoever can run a Windows Flutter integration test in
// an unrestricted environment; this script's output is this session's
// authoritative evidence.
//
// Run from the yjs_probe/ directory:
//   dart run tool/ime_composition_churn_probe_dart.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:yjs_probe/prototype/title_admission_native_probe.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void _addDllSearchDirectory(String dir) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDirectory = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final dirPtr = dir.toNativeUtf16();
  try {
    final result = setDllDirectory(dirPtr);
    if (result == 0) {
      throw StateError('SetDllDirectoryW failed for $dir');
    }
  } finally {
    calloc.free(dirPtr);
  }
}

String _renderTrace(List<Map<String, Object?>> trace) => trace
    .map((event) => '  - ${event['kind']}: ${_compactJson(event)}')
    .join('\n');

String _compactJson(Map<String, Object?> value) {
  const maxLen = 400;
  final encoded = jsonEncode(value);
  return encoded.length > maxLen
      ? '${encoded.substring(0, maxLen)}… (${encoded.length} chars total)'
      : encoded;
}

Future<void> main() async {
  final dllDir = File('native/yffi/v0.27.3').absolute.path;
  _addDllSearchDirectory(dllDir);

  print('=== Wayfinder ticket 05: IME composition churn causal coupling, run '
      'against native YrsRuntime ===');
  print('DLL search directory: $dllDir');
  print('');

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  final results = <NativeProbeResult>[];
  var overallPass = true;

  Future<void> run(
    String label,
    Future<NativeProbeResult> Function(Future<CrdtRuntime> Function()) scenario,
  ) async {
    print('--- $label ---');
    try {
      final result = await scenario(runtimeFactory);
      results.add(result);
      print('DONE: ${result.name}');
      print('Evidence: ${result.evidence}');
      print('Final state: ${jsonEncode(result.finalState)}');
      print('Trace (${result.trace.length} events):');
      print(_renderTrace(result.trace));
    } catch (error, stackTrace) {
      overallPass = false;
      print('CRASH: $label');
      print('Error: $error');
      print(stackTrace);
    }
    print('');
  }

  await run(
    'Small burst: 2 same-client transactions (1 composition-update step)',
    imeCompositionSmallBurstCoupling,
  );
  await run(
    'Large burst: 20 same-client transactions (10 composition-update steps)',
    imeCompositionLargeBurstCoupling,
  );
  await run(
    'cancelComposition compensating delete after a burst',
    imeCancelCompositionCoupling,
  );

  print('=== OVERALL: ${overallPass ? 'ALL SCENARIOS RAN' : 'CRASH'} '
      '(${results.length}/3 scenarios completed) ===');

  final report = _renderReport(results, overallPass);
  Directory('reports').createSync(recursive: true);
  File('reports/p10-ime-composition-churn.md').writeAsStringSync('$report\n');
  print('');
  print('Raw run log also folded into reports/p10-ime-composition-churn.md');

  if (!overallPass) exitCode = 1;
}

String _renderReport(List<NativeProbeResult> results, bool overallPass) {
  final buffer = StringBuffer()
    ..writeln(
      '# Ticket 05 raw run log — IME composition churn causal coupling, on '
      'native YrsRuntime',
    )
    ..writeln()
    ..writeln(
      'This is the raw per-scenario evidence this script actually produced. '
      'See `reports/p10-ime-composition-churn.md`\'s own prose sections '
      '(written after this run) for the narrative answer — this block is '
      'appended here only as a durable, regenerable record tied to this '
      'exact script.',
    )
    ..writeln()
    ..writeln(
      '## Result: ${overallPass ? 'all scenarios ran to completion' : 'a scenario crashed'} '
      '(${results.length}/3)',
    )
    ..writeln();
  for (final result in results) {
    buffer
      ..writeln('### ${result.name}')
      ..writeln()
      ..writeln('- Evidence: ${result.evidence}')
      ..writeln('- Final state: `${jsonEncode(result.finalState)}`')
      ..writeln('- Trace: ${result.trace.length} recorded events')
      ..writeln();
  }
  return buffer.toString();
}
