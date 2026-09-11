// Task 21 on the Yjs side: Dart -> jsonEncode -> `YjsRuntime._call`'s
// single-quote/backslash escaping -> QuickJS `eval` -> Y.Text, and back out
// through `projection`. Every scenario in this probe before now used ASCII
// (`abcde`, `ABC`, `L`, `R`, `X`), so this path had never carried a character
// outside the Basic Latin block.
//
// The three parts run in brief order, and part 3 runs LAST on purpose: it
// deliberately splits a surrogate pair, and if that ever takes the engine down
// with it, everything before it has already printed.
//
// What the first run of this file actually printed (2026-08-21, flutter test
// integration_test/unicode_bridge_yjs_test.dart -d windows, 3 tests passed):
//
//  * Part 1: all 20 cases round-tripped byte-for-byte. Nothing was
//    normalised — `e` + U+0301 came back decomposed and U+00E9 came back
//    precomposed, as two distinct strings. Raw U+2028 / U+2029 survived the
//    `eval`, so this QuickJS build accepts them inside a string literal.
//    `你` (six ASCII characters) came back as six ASCII characters, so
//    nothing on the path unescapes twice.
//  * Part 2: seed U+1F642 + "abc". Dart String.length 5, runes.length 4,
//    characters.length 4; Y.Text reported 5. erase(2, 1) produced
//    U+1F642 + "bc" and format(2, 1, bold) marked exactly "a". Index 2 is
//    therefore the third UTF-16 code unit: this API indexes in UTF-16 code
//    units.
//  * Part 3: erase(1, 1) — inside the pair — did NOT throw. It silently
//    corrupted the string: the text read back as U+FFFD + "abc" with a
//    reported length of 4.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/yjs/yjs_runtime.dart';

import 'unicode_bridge_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late YjsRuntime rt;
  const alice = ClientId(1);

  setUp(() async {
    rt = await YjsRuntime.create();
  });

  test('part 1: non-ASCII and escaping-hostile strings survive the bridge', () async {
    final results = await measureRoundTrips(rt, alice);
    // ignore: avoid_print
    print(renderRoundTripReport(rt.name, results));

    // Round-trip equality is the one thing this task expects, so it is the one
    // thing it asserts. A failure here is a defect to report, not to patch.
    expect(
      results.where((r) => !r.ok).map((r) => r.source.label).toList(),
      isEmpty,
      reason: 'these inputs did not come back out of the string-only bridge '
          'unchanged; see the printed report for the exact bytes',
    );
  });

  test('part 2: what unit an integer index counts in', () async {
    final result = await measureIndexMeaning(rt, alice);
    // ignore: avoid_print
    print(renderIndexReport(rt.name, result));

    // Deliberately asserts no index and no length — those are the measurement.
    // The only assertion is that the seed we are reasoning about is the seed
    // the runtime actually holds; without it every number above is unmoored.
    expect(result.seedReadBack, indexProbeSeed);
  });

  test('part 3: erasing one unit inside a surrogate pair', () async {
    final result = await measureSurrogateSplit(rt, alice);
    // ignore: avoid_print
    print(renderSurrogateSplitReport(rt.name, result));
    // No assertion by design. An exception, a replacement character, a
    // corrupted string and a refused no-op are all legitimate outcomes for
    // this call; the task is to put on record which one this runtime picks.
  });
}
