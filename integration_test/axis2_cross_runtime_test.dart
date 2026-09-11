import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/harness/report.dart';
import 'package:yjs_probe/harness/scenario.dart';
import 'package:yjs_probe/harness/scenario_runner.dart';
import 'package:yjs_probe/harness/scenarios/axis0_arrival_order.dart';
import 'package:yjs_probe/harness/scenarios/axis2_undo.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';
import 'package:yjs_probe/runtime/undo_runtime.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

// Returns the outcome map (undo/redo booleans, finalX) alongside the raw
// encoded state, kept separate from the map so the map keeps printing
// cleanly and the two comparisons below stay visibly distinct: document
// state (finalX, and this encoded state) versus reported outcome (the
// undo/redo booleans). Task 19 round 2 finding: those are two different
// claims, and printing one combined "parity"/"divergence" verdict over both
// let a reported-outcome difference read as a document merge difference,
// which it was not.
Future<(Map<String, Object?>, Uint8List)> _runSupersededRedo(CrdtRuntime runtime) async {
  final undo = runtime as UndoRuntime;
  final (a, b, _) = await pairOn(runtime, undo: true);
  await seedAxis2Title(a, b);

  await a.move(const ObjectId('s2-title'), 'x', 1);
  await a.flushOutbox();
  await b.receiveAll();
  final didUndo = await undo.undo(a.clientId);
  await a.flushOutbox();
  await b.receiveAll();

  await b.move(const ObjectId('s2-title'), 'x', 2);
  await b.flushOutbox();
  await a.receiveAll();
  final didRedo = await undo.redo(a.clientId);
  final finalValue = (await a.read()).objects[const ObjectId('s2-title')]!.x;
  final stateBytes = await runtime.encodeStateAsUpdate(a.clientId);
  return (
    {
      'undo': didUndo,
      'redo': didRedo,
      'finalX': finalValue,
    },
    stateBytes,
  );
}

// Task 19 round 3, Finding 1: the previous version of this file dismissed a
// cross-runtime byte comparison as "not meaningful" because the two
// runtimes supposedly use different wire encodings. That premise is false --
// verified against source, not assumed. Yjs: yjs.cjs:1861,
// `encodeStateAsUpdate = (doc, sv) => encodeStateAsUpdateV2(doc, sv, new
// UpdateEncoderV1())` -- lib0 v1. Yrs: native/yffi/v0.27.3/libyrs.h documents
// `ytransactionStateDiffV1` as "serialized using lib0 version 1" -- lib0 v1.
// Same format, so the comparison is available and is actually run below,
// not declined.
bool _bytesEqualAcrossRuntimes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Axis 2 compares the same superseded redo sequence on both runtimes', () async {
    final yjs = await YjsRuntime.create();
    final yrs = await YrsRuntime.create();
    final (yjsResult, yjsStateBytes) = await _runSupersededRedo(yjs);
    final (yrsResult, yrsStateBytes) = await _runSupersededRedo(yrs);
    final yjsStateLen = yjsStateBytes.length;
    final yrsStateLen = yrsStateBytes.length;
    final statesEqual = _bytesEqualAcrossRuntimes(yjsStateBytes, yrsStateBytes);

    // S2.7 has consumed client ids 1 and 2 in both runtime instances. Use
    // fresh instances for the full scenario reports so each scenario can
    // deliberately restart its ThinServer/client-id sequence.
    final CrdtRuntime yjsForScenarios = await YjsRuntime.create();
    final CrdtRuntime yrsForScenarios = await YrsRuntime.create();
    final yjsRunner = ScenarioRunner();
    final yrsRunner = ScenarioRunner();
    final yjsScenarios = await yjsRunner.runAll(axis2Scenarios, yjsForScenarios);
    final yrsScenarios = await yrsRunner.runAll(axis2Scenarios, yrsForScenarios);
    final report = [
      '## Scope',
      '',
      'P3 compares a Yjs QuickJS control group with test-only yffi v0.27.3. '
          'This is measurement evidence and does not reopen runtime adoption.',
      '',
      renderReport('P3 Axis 2 — Yjs', yjs, axis2Scenarios, yjsScenarios, yjsRunner.traces),
      '',
      renderReport('P3 Axis 2 — Yrs', yrs, axis2Scenarios, yrsScenarios, yrsRunner.traces),
      '',
      '## S2.7 — superseded redo comparison',
      '',
      'Task 19 round 3, Finding 1: the previous version of this section '
          'declined the one available cross-runtime document comparison on '
          'a false premise (that the two runtimes use different wire '
          'encodings), then still printed a combined verdict. Both parts are '
          'fixed below: the byte comparison is actually run, and the verdict '
          'is narrowed to only what it covers.',
      '',
      '- finalX: `${yjsResult["finalX"]}` on Yjs, `${yrsResult["finalX"]}` on '
          'Yrs — ${yjsResult["finalX"] == yrsResult["finalX"] ? "AGREE" : "DIFFER"}.',
      '- Encoded state: both runtimes encode state in lib0 v1 '
          '(yjs.cjs:1861; libyrs.h documents ytransactionStateDiffV1 as lib0 v1), '
          'so the encoded states are directly comparable, and the comparison was actually '
          'run (byte-for-byte, not just by length): Yjs `$yjsStateLen B`, Yrs '
          '`$yrsStateLen B` — ${statesEqual ? "IDENTICAL" : "DIFFER"}. This '
          'scenario does not explain the difference. It is not evidence of a '
          'merge disagreement, but neither is it evidence of document '
          'agreement beyond finalX.',
      '- Reported outcome (what does redo return?): Yjs `${yjsResult["redo"]}`, '
          'Yrs `${yrsResult["redo"]}` — '
          '${yjsResult["redo"] == yrsResult["redo"] ? "AGREE" : "DIFFER"}. This is '
          'the value that changed after the trackedOrigins fix: Yjs now '
          'genuinely attempts the redo and returns true while declining to '
          'overwrite the remote value; Yrs returns false for the same '
          'situation. Neither this scenario nor the runtime API says why the '
          'two differ.',
      '- Full results: Yjs `$yjsResult`, Yrs `$yrsResult`.',
      '- Verdict: finalX agrees at 2.0 on both runtimes -- the property '
          'ticket 07 §5 cares about. The encoded states '
          '${statesEqual ? "are IDENTICAL" : "DIFFER by size"}, unexplained by '
          'this scenario either way. The REPORTED OUTCOME (the redo return '
          'value) also differs. None of this is evidence that the documents '
          'disagree beyond finalX, and none of it is folded into a single '
          'verdict that could be misread that way.',
    ].join('\n');
    File('reports/p3-axis2.md').writeAsStringSync('$report\n');
    // ignore: avoid_print
    print(report);

    expect(yjsResult['undo'], isTrue);
    expect(yrsResult['undo'], isTrue);
    expect(yjsResult['redo'], isA<bool>());
    expect(yrsResult['redo'], isA<bool>());
    // The only property this comparison asserts: the document state agrees
    // on both runtimes (the remote value survives the redo attempt) -- never
    // the reported undo/redo booleans, which are allowed to and do differ.
    expect(yjsResult['finalX'], 2);
    expect(yrsResult['finalX'], 2);
    expect(yjsResult['finalX'], yrsResult['finalX']);
    // A Failed outcome is a real finding and must not be swallowed.
    for (final entry in yjsScenarios.entries) {
      expect(entry.value, isNot(isA<Failed>()), reason: 'Yjs ${entry.key} failed');
    }
    for (final entry in yrsScenarios.entries) {
      expect(entry.value, isNot(isA<Failed>()), reason: 'Yrs ${entry.key} failed');
    }

    // Task 19 round 3, Finding 7: gate on whether the runtime actually covers
    // the scenario's `requires`, not on whether `requires` is empty. Yjs
    // declares Capability.readUndoStackItems (needed by S2.1-S2.6) AND
    // Capability.decodeUpdate (needed by S2.8 as of this round), so on Yjs
    // every scenario in this list is covered and Unobservable would never be
    // legitimate there. Yrs does not declare decodeUpdate, so Unobservable
    // is the only legitimate outcome for S2.8 on Yrs, and the previous
    // `requires.isEmpty` gate would have let a false Passed slip through
    // silently if S2.8 had ever returned one despite the missing capability.
    for (final s in axis2Scenarios) {
      for (final (label, runtime, results, traces) in [
        (
          'Yjs',
          yjsForScenarios,
          yjsScenarios,
          yjsRunner.traces,
        ),
        (
          'Yrs',
          yrsForScenarios,
          yrsScenarios,
          yrsRunner.traces,
        ),
      ]) {
        final missing = runtime.capabilities.missingFrom(s.requires);
        final outcome = results[s.id];
        if (missing.isEmpty) {
          expect(outcome, isA<Passed>(),
              reason: '$label ${s.id} covers its requires but did not Pass');
          final evidence = (outcome as Passed).evidence;
          expect(evidence, isNotEmpty, reason: '$label ${s.id} evidence was empty');
          final trace = traces[s.id];
          expect(trace, isNotNull, reason: '$label ${s.id} has no trace');
          expect(trace, isNotEmpty, reason: '$label ${s.id} trace was empty');
        } else {
          expect(outcome, isA<Unobservable>(),
              reason:
                  '$label ${s.id} is missing $missing, so only Unobservable is legitimate');
        }
      }
    }
  });
}
