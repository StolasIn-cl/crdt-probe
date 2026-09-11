// Task 21 on the Yrs side. There is no string-escaping hop here — Dart hands
// yffi a null-terminated UTF-8 buffer directly — so part 1 tests a different
// risk than its Yjs twin (UTF-8 encode/decode across the FFI boundary rather
// than an `eval` payload), while asking the identical questions from
// unicode_bridge_cases.dart so the two runtimes can be compared at all.
//
// Part 2 matters more here: `open` passes `yOffsetUtf16`, and libyrs.h still
// documents `ytext_len` as counting *bytes*. Which of those two the running
// DLL actually does had never been measured.
//
// Part 3 runs LAST on purpose: splitting a surrogate pair inside a Rust FFI
// call could abort the process, which Dart cannot catch — everything before it
// has already printed by then.
//
// What the first run of this file actually printed (2026-08-21, flutter test
// integration_test/unicode_bridge_yrs_test.dart -d windows, 3 tests passed):
//
//  * Part 1: all 20 cases round-tripped byte-for-byte, and nothing was
//    normalised — identical to the Yjs run.
//  * Part 2: seed U+1F642 + "abc". Dart String.length 5, runes.length 4,
//    characters.length 4; `ytext_len` reported 5. erase(2, 1) produced
//    U+1F642 + "bc" and format(2, 1, bold) marked exactly "a". So this API
//    indexes in UTF-16 code units, matching Yjs — and `ytext_len`'s header
//    comment ("in bytes") does NOT describe what the DLL does under
//    `yOffsetUtf16`: bytes would have been 7, not 5.
//  * Part 3: erase(1, 1) — inside the pair — did NOT throw, and did NOT
//    corrupt anything. The text read back as U+1F642 + "bc" with a reported
//    length of 4: the astral character survived whole and the deletion landed
//    on the *next* character instead. That is a different outcome from Yjs
//    (which produced U+FFFD + "abc"), and the divergence is a finding on the
//    same footing as S2.9 — recorded here, not reconciled.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

import 'unicode_bridge_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late YrsRuntime rt;
  const alice = ClientId(1);

  setUp(() async {
    rt = await YrsRuntime.create();
  });

  tearDown(() async {
    await rt.close(alice);
  });

  test('part 1: non-ASCII and escaping-hostile strings survive the bridge', () async {
    final results = await measureRoundTrips(rt, alice);
    // ignore: avoid_print
    print(renderRoundTripReport(rt.name, results));

    expect(
      results.where((r) => !r.ok).map((r) => r.source.label).toList(),
      isEmpty,
      reason: 'these inputs did not come back out of the FFI boundary '
          'unchanged; see the printed report for the exact bytes',
    );
  });

  test('part 2: what unit an integer index counts in', () async {
    final result = await measureIndexMeaning(rt, alice);
    // ignore: avoid_print
    print(renderIndexReport(rt.name, result));

    // Asserts no index and no length; only that the seed being reasoned about
    // is the seed the runtime actually holds.
    expect(result.seedReadBack, indexProbeSeed);
  });

  test('part 3: erasing one unit inside a surrogate pair', () async {
    final result = await measureSurrogateSplit(rt, alice);
    // ignore: avoid_print
    print(renderSurrogateSplitReport(rt.name, result));
    // No assertion by design — see the Yjs twin.
  });
}
