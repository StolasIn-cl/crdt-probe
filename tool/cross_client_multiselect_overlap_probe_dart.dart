// Wayfinder ticket 04 (yrs-native-reject-admission-feasibility) validation
// runner — plain Dart, no Flutter engine, no native patch.
//
// Runs the two cross-client overlapping multi-select move scenarios
// (`lib/prototype/title_admission_native_probe.dart`) for real against the
// vendored, unpatched `native/yffi/v0.27.3/yrs.dll`, via `YrsRuntime.create()`
// unchanged. Same rationale as tickets 01-03's `dart run` scripts: this
// sandboxed environment hangs `flutter test`'s Windows-app-to-VM-service
// socket (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
// `integration_test/title_admission_cross_client_overlap_test.dart` runs the
// exact same scenario functions and is left in the repo, analyzed clean, as
// the standard harness for whoever can run a Windows Flutter integration
// test in an unrestricted environment; this script's output is this
// session's authoritative evidence.
//
// Run from the yjs_probe/ directory:
//   dart run tool/cross_client_multiselect_overlap_probe_dart.dart

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

  print('=== Wayfinder ticket 04: cross-client overlapping multi-select '
      'admission safety, run against native YrsRuntime ===');
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
    'Order A-then-B: A moves {obj1,obj2,obj3}, then B moves {obj2,obj3,obj4}',
    crossClientOverlapMoveAThenB,
  );
  await run(
    'Order B-then-A: B moves {obj2,obj3,obj4}, then A moves {obj1,obj2,obj3}',
    crossClientOverlapMoveBThenA,
  );

  print('=== OVERALL: ${overallPass ? 'ALL SCENARIOS RAN' : 'CRASH'} '
      '(${results.length}/2 scenarios completed) ===');

  if (!overallPass) exitCode = 1;
}
