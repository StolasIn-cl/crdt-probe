// Wayfinder ticket 03 (yrs-native-reject-admission-feasibility) validation
// runner — plain Dart, no Flutter engine, no native patch.
//
// Runs the four same-client causal-coupling shapes
// (`lib/prototype/title_admission_native_probe.dart`) for real against the
// vendored, unpatched `native/yffi/v0.27.3/yrs.dll`, via `YrsRuntime.create()`
// unchanged. Chosen for the same reason as ticket 01's
// `pending_updates_probe_dart.dart` and ticket 02's
// `title_admission_native_yrs_probe_dart.dart`: this sandboxed environment
// hangs `flutter test`'s Windows-app-to-VM-service socket (see
// `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
// `integration_test/title_admission_same_client_coupling_test.dart` runs the
// exact same scenario functions and is left in the repo, analyzed clean, as
// the standard harness for whoever can run a Windows Flutter integration
// test in an unrestricted environment; this script's output is this
// session's authoritative evidence.
//
// Run from the yjs_probe/ directory:
//   dart run tool/same_client_coupling_shapes_probe_dart.dart

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

  print('=== Wayfinder ticket 03: same-client causal-coupling shapes beyond '
      'ticket 02\'s first shape, run against native YrsRuntime ===');
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
    'Shape 1: format instead of insert',
    formatInsteadOfInsertCoupling,
  );
  await run(
    'Shape 2: delete instead of insert',
    deleteInsteadOfInsertCoupling,
  );
  await run(
    'Shape 3: insert adjacent to existing content in a non-empty Y.Text',
    adjacentInsertIntoNonEmptyTextCoupling,
  );
  await run(
    'Shape 4: three-command same-client chain',
    threeCommandChainCoupling,
  );

  print('=== OVERALL: ${overallPass ? 'ALL SHAPES RAN' : 'CRASH'} '
      '(${results.length}/4 scenarios completed) ===');

  final report = _renderReport(results, overallPass);
  Directory('reports').createSync(recursive: true);
  File('reports/p8-same-client-coupling-shapes.md')
      .writeAsStringSync('$report\n');
  print('');
  print('Report written to reports/p8-same-client-coupling-shapes.md');

  if (!overallPass) exitCode = 1;
}

String _renderReport(List<NativeProbeResult> results, bool overallPass) {
  final buffer = StringBuffer()
    ..writeln(
      '# Ticket 03 — same-client causal-coupling shapes beyond ticket 02\'s '
      'first shape, on native YrsRuntime',
    )
    ..writeln()
    ..writeln(
      'This is `yjs_probe`\'s disposable evidence for Wayfinder ticket 03 — '
      '[Verify Same-Client Causal Coupling Beyond the First Shape]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/03-verify-same-client-causal-coupling-beyond-the-first-shape.md), '
      'part of the [Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md) map. '
      'It runs four new same-client causal-coupling shapes against the '
      'vendored, unpatched `native/yffi/v0.27.3/yrs.dll`, extending ticket '
      '02\'s `lib/prototype/title_admission_native_probe.dart` — '
      '`YjsAdmissionServer`/`YjsAdmissionClient` from '
      '`lib/prototype/title_admission.dart` stay completely unchanged.',
    )
    ..writeln()
    ..writeln('## How this was run')
    ..writeln()
    ..writeln(
      'Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`, '
      'shared by two harnesses so they cannot drift apart:',
    )
    ..writeln(
      '- `integration_test/title_admission_same_client_coupling_test.dart` — '
      'the standard Flutter `integration_test` harness, matching this '
      'repo\'s convention. Left in the repo, analyzed clean, for whoever can '
      'run a Windows Flutter integration test outside this sandbox.',
    )
    ..writeln(
      '- `tool/same_client_coupling_shapes_probe_dart.dart` (this script) — '
      'a plain `dart run` script with zero Flutter dependency, the same '
      'workaround pattern tickets 01 and 02 established: `flutter test` '
      'hangs this sandboxed environment\'s Windows-app-to-VM-service socket. '
      '**This report\'s numbers come from this script, run for real.**',
    )
    ..writeln()
    ..writeln(
      '## Result: ${overallPass ? 'all four shapes ran to completion' : 'a scenario crashed'} '
      '(${results.length}/4)',
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
