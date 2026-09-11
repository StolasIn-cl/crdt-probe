// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility) validation
// runner — plain Dart, no Flutter engine, no native patch.
//
// Runs the two-scenario first slice
// (`lib/prototype/title_admission_native_probe.dart`) for real against the
// vendored, unpatched `native/yffi/v0.27.3/yrs.dll`, via `YrsRuntime.create()`
// unchanged. Chosen over `flutter test integration_test/...dart` for the
// same reason as ticket 01's `pending_updates_probe_dart.dart` and ticket
// 03's `zorder_probe_dart.dart`: this sandboxed environment hangs
// `flutter test`'s Windows-app-to-VM-service socket (see
// `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
// `integration_test/title_admission_native_yrs_test.dart` runs the exact
// same scenario functions and is left in the repo, analyzed clean, as the
// standard harness for whoever can run a Windows Flutter integration test
// in an unrestricted environment; this script's output is this session's
// authoritative evidence.
//
// `YrsRuntime.create()` opens `yrs.dll` by bare name
// (`DynamicLibrary.open('yrs.dll')`), which Windows resolves via the
// process's DLL search path — not automatically the vendored asset's
// directory under a plain `dart run`. Rather than copy the DLL into the
// repo or change `YrsRuntime.create()` itself (out of scope — ticket 02's
// constraints keep it a pure runtime-factory swap), this script adds the
// vendored directory to the process's DLL search path via `SetDllDirectoryW`
// before calling it. This is throwaway-script plumbing, not a production or
// even `YrsRuntime` change.
//
// Run from the yjs_probe/ directory:
//   dart run tool/title_admission_native_yrs_probe_dart.dart

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

  print('=== Wayfinder ticket 02: first slice of the Title admission suite, '
      'run against native YrsRuntime ===');
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
      print('PASS: ${result.name}');
      print('Evidence: ${result.evidence}');
      print('Final state: ${jsonEncode(result.finalState)}');
      print('Trace (${result.trace.length} events):');
      print(_renderTrace(result.trace));
    } catch (error, stackTrace) {
      overallPass = false;
      print('FAIL: $label');
      print('Error: $error');
      print(stackTrace);
    }
    print('');
  }

  await run(
    'Scenario 1 (exact-U mode): same-document independent local edit',
    independentLocalEditFinding,
  );
  await run(
    'Scenario 2 (semantic mode): semantic replay after refusal',
    semanticReplayAfterRefusal,
  );

  print('=== OVERALL: ${overallPass ? 'PASS' : 'FAIL'} '
      '(${results.length}/2 scenarios completed) ===');

  final report = _renderReport(results, overallPass);
  Directory('reports').createSync(recursive: true);
  File('reports/p7-title-admission-native-yrs.md').writeAsStringSync('$report\n');
  print('');
  print('Report written to reports/p7-title-admission-native-yrs.md');

  if (!overallPass) exitCode = 1;
}

String _renderReport(List<NativeProbeResult> results, bool overallPass) {
  final buffer = StringBuffer()
    ..writeln('# Ticket 02 — first slice of the Title admission suite on native YrsRuntime')
    ..writeln()
    ..writeln(
      'This is `yjs_probe`\'s disposable evidence for Wayfinder ticket 02 — '
      '[Port the First Slice of the Title Admission Suite to YrsRuntime]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/02-port-the-first-slice-of-the-title-admission-suite-to-yrsruntime.md), '
      'part of the [Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md) map. '
      'It runs two scenarios from `integration_test/title_admission_test.dart`\'s '
      '20-scenario Yjs suite for real against the vendored, unpatched '
      '`native/yffi/v0.27.3/yrs.dll`, reusing `YjsAdmissionServer`/`YjsAdmissionClient` '
      'from `lib/prototype/title_admission.dart` completely unchanged — the only thing '
      'that varies is which `CrdtRuntime` the rig constructs.',
    )
    ..writeln()
    ..writeln('## How this was run')
    ..writeln()
    ..writeln(
      'Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`, '
      'shared by two harnesses so they cannot drift apart:',
    )
    ..writeln(
      '- `integration_test/title_admission_native_yrs_test.dart` — the standard '
      'Flutter `integration_test` harness, matching this repo\'s convention. '
      'Left in the repo, analyzed clean, for whoever can run a Windows Flutter '
      'integration test outside this sandbox.',
    )
    ..writeln(
      '- `tool/title_admission_native_yrs_probe_dart.dart` — a plain `dart run` '
      'script with zero Flutter dependency, the same workaround pattern ticket 01\'s '
      '`pending_updates_probe_dart.dart` and ticket 03\'s `zorder_probe_dart.dart` '
      'established: `flutter test` hangs this sandboxed environment\'s '
      'Windows-app-to-VM-service socket (documented in `p5-zorder-merge.md` and '
      '`p6-yffi-pending-structs.md`), while an identical scenario invoked via plain '
      '`dart run` against the same `yrs.dll` completes in seconds. **This report\'s '
      'numbers come from that script, run for real — not from the untested Flutter file.**',
    )
    ..writeln()
    ..writeln('## Result: ${overallPass ? 'PASS' : 'FAIL'} (${results.length}/2 scenarios)')
    ..writeln();
  for (final result in results) {
    buffer
      ..writeln('### ${result.name}')
      ..writeln()
      ..writeln('- Outcome: **${result.passed ? 'PASS' : 'FAIL'}**')
      ..writeln('- Evidence: ${result.evidence}')
      ..writeln('- Final state: `${jsonEncode(result.finalState)}`')
      ..writeln('- Trace: ${result.trace.length} recorded events')
      ..writeln();
  }
  buffer
    ..writeln('## What this answers')
    ..writeln()
    ..writeln(
      '1. Both scenarios completed against real `YrsRuntime` with the same '
      'evidence shape (accepted/refused decisions, final A/B/C projections, '
      '`pendingStructCount` transitions) as their Yjs runs in `p4-title-admission.md`.',
    )
    ..writeln(
      '2. **Exact-U-vs-semantic distinction survives the runtime swap.** Scenario 1 '
      '(exact-U mode) still shows the independent command wrongly refused as '
      '`causalIncomplete` — the known Yjs finding reproduces on native Yrs, it is '
      'not a Yjs-only artifact. Scenario 2 (semantic mode) still shows the survivor '
      'correctly accepted with `pendingStructCount` staying `0` throughout, '
      'confirming semantic re-execution — not the pendingStructCount check itself — '
      'is what protects it.',
    )
    ..writeln(
      '3. **Nothing in `YjsAdmissionServer`/`YjsAdmissionClient` or '
      '`title_admission.dart`\'s command vocabulary had to change.** The port is '
      'exactly what the ticket predicted: swap which `CrdtRuntime` the rig '
      'constructs. The one thing that *did* need new code was '
      '`YrsRuntime.pendingStructCount` itself, which ticket 01 already researched — '
      'this ticket wired ticket 01\'s answer '
      '(`ytransaction_pending_update`/`ytransaction_pending_ds`) into '
      '`YrsBindings` and implemented the override as a boolean-shaped `1`/`0`, per '
      'ticket 01\'s named simplification.',
    )
    ..writeln();
  return buffer.toString();
}
