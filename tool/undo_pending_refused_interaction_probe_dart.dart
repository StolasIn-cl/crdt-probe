// Wayfinder ticket 06 (yrs-native-reject-admission-feasibility) validation
// runner — plain Dart, no Flutter engine, no native patch.
//
// Runs, against the vendored, unpatched `native/yffi/v0.27.3/yrs.dll` via
// `YrsRuntime.create()` unchanged:
//   1. Two scenarios ported from `title_admission_test.dart` (Yjs-only until
//      now): `_transitiveWithdrawal` and `_policyRejectionAcrossCommandKinds`.
//   2. Five new undo-specific scenarios (`lib/prototype/
//      title_admission_native_probe.dart`) probing shape A (undo of a still-
//      pending command) and shape B (undo of an already-refused command).
//
// Chosen for the same reason as tickets 01-05's own `dart run` scripts: this
// sandboxed environment hangs `flutter test`'s Windows-app-to-VM-service
// socket (see `reports/p5-zorder-merge.md#how-this-was-run` and
// `reports/p6-yffi-pending-structs.md`).
// `integration_test/title_admission_native_yrs_undo_test.dart` runs the exact
// same scenario functions and is left in the repo, analyzed clean, as the
// standard harness for whoever can run a Windows Flutter integration test in
// an unrestricted environment; this script's output is this session's
// authoritative evidence.
//
// Run from the yjs_probe/ directory:
//   dart run tool/undo_pending_refused_interaction_probe_dart.dart

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

  print('=== Wayfinder ticket 06: undo interaction with pending and refused '
      'chains, run against native YrsRuntime ===');
  print('DLL search directory: $dllDir');
  print('');

  Future<CrdtRuntime> runtimeFactory() => YrsRuntime.create();

  final results = <NativeProbeResult>[];
  var overallPass = true;

  Future<void> run(
    String label,
    Future<NativeProbeResult> Function(Future<CrdtRuntime> Function())
        scenario,
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
    'Port 1/2: refused CreateTitle withdraws dependent edit/format/delete/'
    'undo chain (_transitiveWithdrawal)',
    transitiveWithdrawalNative,
  );
  await run(
    'Port 2/2: policy rejection across every Title command kind, including '
    'undo (_policyRejectionAcrossCommandKinds)',
    policyRejectionAcrossCommandKindsNative,
  );
  await run(
    'Shape A, order 1: x and pending undo, submitted x-then-undo (both '
    'accepted)',
    pendingUndoXThenUndoBothAccepted,
  );
  await run(
    'Shape A, order 2: x and pending undo, submitted undo-then-x '
    '(undo -> missingDependency)',
    pendingUndoUndoThenXMissingDependency,
  );
  await run(
    'Shape A/B boundary: undo (dependsOn wired) submitted after its own x '
    'was refused by policy',
    pendingUndoXRefusedThenUndoDependencyRefused,
  );
  await run(
    'Shape B (clean): undo() targeting an already-refused, already-'
    'rebuilt-away command',
    refusedUndoAfterRebuildThrows,
  );
  await run(
    'Shape B (racy, no dependsOn): undo of an already-refused-but-not-yet-'
    'delivered command -- the sharpest false-acceptance hunt',
    refusedUndoRacyNoDependsOn,
  );

  print('=== OVERALL: ${overallPass ? 'ALL SCENARIOS RAN' : 'CRASH'} '
      '(${results.length}/7 scenarios completed) ===');

  final report = _renderReport(results, overallPass);
  Directory('reports').createSync(recursive: true);
  File('reports/p11-undo-pending-refused-interaction.md')
      .writeAsStringSync('$report\n');
  print('');
  print(
    'Report written to reports/p11-undo-pending-refused-interaction.md',
  );

  if (!overallPass) exitCode = 1;
}

String _renderReport(List<NativeProbeResult> results, bool overallPass) {
  final buffer = StringBuffer()
    ..writeln(
      '# Ticket 06 — undo interaction with pending and refused chains, on '
      'native YrsRuntime',
    )
    ..writeln()
    ..writeln(
      'This is `yjs_probe`\'s disposable evidence for Wayfinder ticket 06 — '
      '[Verify Undo Interaction With Pending or Refused Chains]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/06-verify-undo-interaction-with-pending-and-refused-chains.md), '
      'the fourth and final axis of the [Verify Server-Centric Reject-'
      'Admission Holds on the Real Yrs (yffi) Runtime]'
      '(../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md) '
      'map\'s exact-U safety test matrix. It ports the two remaining '
      'undo-adjacent scenarios from `title_admission_test.dart` (Yjs-only '
      'until now) to native `YrsRuntime`, then probes two shapes specific to '
      '`undo`: a still-pending target (shape A) and an already-refused '
      'target (shape B). `YjsAdmissionServer`/`YjsAdmissionClient` '
      '(`lib/prototype/title_admission.dart`) stay completely unchanged; '
      '`YjsAdmissionClient.undo`\'s real `UndoManager`-generated inverse is '
      'used throughout, never a symbolic/fake one.',
    )
    ..writeln()
    ..writeln('## How this was run')
    ..writeln()
    ..writeln(
      'Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`, '
      'extending tickets 02-05\'s rig, shared by two harnesses so they '
      'cannot drift apart:',
    )
    ..writeln(
      '- `integration_test/title_admission_native_yrs_undo_test.dart` — the '
      'standard Flutter `integration_test` harness, matching this repo\'s '
      'convention. Left in the repo, analyzed clean, for whoever can run a '
      'Windows Flutter integration test outside this sandbox.',
    )
    ..writeln(
      '- `tool/undo_pending_refused_interaction_probe_dart.dart` (this '
      'script) — a plain `dart run` script with zero Flutter dependency, '
      'the same workaround pattern tickets 01-05 established: `flutter '
      'test` hangs this sandboxed environment\'s Windows-app-to-VM-service '
      'socket (documented in `p5-zorder-merge.md` and '
      '`p6-yffi-pending-structs.md`). **This report\'s numbers come from '
      'this script, run for real.**',
    )
    ..writeln()
    ..writeln(
      '## Result: ${overallPass ? 'all seven scenarios ran to completion' : 'a scenario crashed'} '
      '(${results.length}/7)',
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
