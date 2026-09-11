// Task 21's measurement code, shared by unicode_bridge_yjs_test.dart and
// unicode_bridge_yrs_test.dart so the two runtimes are asked *literally the
// same questions* rather than two hand-copied approximations of them.
//
// Nothing in here asserts an index or a length. Part 1 asserts round-trip
// equality (the one thing we do expect); parts 2 and 3 only observe, because
// what an integer index counts in — and what a split surrogate pair does — are
// facts about the runtime to be recorded, not requirements to be enforced.

import 'package:characters/characters.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';

/// One string pushed through the bridge, with a label for the report.
class RoundTripCase {
  const RoundTripCase(this.label, this.input);
  final String label;
  final String input;
}

/// Every case is pushed through `insertText` and read back via `projection`.
///
/// Ordered so the escaping-hostile cases sit together: those are the point of
/// part 1, since every existing scenario in this probe used `abcde`-class
/// ASCII and therefore never touched `YjsRuntime._call`'s single-quote /
/// backslash escaping or QuickJS's own source-text parsing.
const roundTripCases = <RoundTripCase>[
  // --- scripts ---
  RoundTripCase('traditional chinese', '你好世界'),
  RoundTripCase('mixed script and ascii', 'Promeo 影片產生器 v2'),
  RoundTripCase('japanese hiragana and katakana', 'ひらがな カタカナ'),
  RoundTripCase('korean syllable block', '한글'),

  // --- characters the escaping itself is most likely to break ---
  RoundTripCase('double quote', 'a"b'),
  RoundTripCase('single quote', "a'b"),
  RoundTripCase('backslash', r'a\b'),
  RoundTripCase('newline', 'a\nb'),
  RoundTripCase('tab', 'a\tb'),
  RoundTripCase('script close tag', 'x</script>y'),
  RoundTripCase('dollar-brace template', r'${payload}'),
  // Six ASCII characters -- backslash, u, 4, f, 6, 0 -- and NOT the character
  // U+4F60 itself. If anything on the path does a second round of unescaping,
  // this comes back as that one character, and that is the finding.
  RoundTripCase('literal backslash-u4f60 as six ascii chars', r'\u4f60'),
  // U+2028 / U+2029 are legal raw inside a JSON string but were line
  // terminators inside a JS string literal before ES2019. The Yjs path builds
  // JS *source text* around the payload, so if this engine predates that
  // change these two break the eval rather than the JSON. Spelled as escapes
  // on purpose: an invisible character in a source file is unreviewable.
  RoundTripCase('line separator U+2028', 'a\u2028b'),
  RoundTripCase('paragraph separator U+2029', 'a\u2029b'),

  // --- normalisation: a difference here is a finding, not a bug to fix ---
  RoundTripCase('combining mark: e + U+0301', 'e\u0301'),
  RoundTripCase('precomposed U+00E9', '\u00e9'),
  RoundTripCase(
      'zwj sequence: woman + ZWJ + laptop', '\u{1F469}\u200D\u{1F4BB}'),

  // --- astral plane: two UTF-16 code units each, and part 2's input ---
  RoundTripCase('emoji U+1F642', '\u{1F642}'),
  RoundTripCase('cjk extension b U+2000B', '\u{2000B}'),
];

/// Part 2 and 3's seed: one astral character then ASCII, so UTF-16 length and
/// grapheme count differ and an integer index can be told apart by what it
/// lands on.
const indexProbeSeed = '\u{1F642}abc';

/// The UTF-16 index of the first ASCII character in [indexProbeSeed], from
/// Dart's point of view. Not a claim about the runtime — that is the question.
const dartUtf16IndexOfFirstAscii = 2;

/// An index that lands *inside* [indexProbeSeed]'s surrogate pair.
const insideSurrogatePairIndex = 1;

class RoundTripResult {
  RoundTripResult(this.source, {this.readBack, this.error});
  final RoundTripCase source;
  final String? readBack;
  final Object? error;

  bool get ok => error == null && readBack == source.input;
}

class IndexProbeResult {
  IndexProbeResult({
    required this.seedReadBack,
    required this.runtimeLength,
    required this.afterEraseOneUnit,
    required this.eraseError,
    required this.markedRuns,
    required this.formatError,
    required this.deltaAfterFormat,
  });

  final String seedReadBack;
  final int runtimeLength;
  final String? afterEraseOneUnit;
  final Object? eraseError;

  /// The `insert` payload of every delta run that carries `bold: true`.
  final List<String> markedRuns;
  final Object? formatError;
  final List<Map<String, Object?>> deltaAfterFormat;
}

class SurrogateSplitResult {
  SurrogateSplitResult({
    required this.eraseThrew,
    required this.eraseError,
    required this.readThrew,
    required this.readError,
    required this.textAfter,
    required this.runtimeLengthAfter,
  });

  final bool eraseThrew;
  final Object? eraseError;
  final bool readThrew;
  final Object? readError;
  final String? textAfter;
  final int? runtimeLengthAfter;
}

/// Renders a string as its UTF-16 code units, with printable ASCII left alone.
/// The console this runs in is not guaranteed to be able to *display* CJK or
/// astral characters, so every reported string goes through here: a report
/// nobody can read is not evidence.
String showCodeUnits(String value) {
  final out = StringBuffer();
  for (final unit in value.codeUnits) {
    if (unit >= 0x20 && unit <= 0x7e) {
      out.write(String.fromCharCode(unit));
    } else {
      out.write('<U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}>');
    }
  }
  return out.toString();
}

/// A fresh title on a freshly-opened document, so no case can be contaminated
/// by the one before it. `undo: false` is the default and stays that way —
/// nothing here exercises undo (task 20).
Future<ObjectId> _freshTitle(CrdtRuntime rt, ClientId c) async {
  await rt.open(c);
  const id = ObjectId('u21');
  await rt.createObject(c, id, ObjectKind.title, x: 0, y: 0, w: 1, h: 1);
  return id;
}

Future<List<RoundTripResult>> measureRoundTrips(CrdtRuntime rt, ClientId c) async {
  final results = <RoundTripResult>[];
  for (final testCase in roundTripCases) {
    try {
      final id = await _freshTitle(rt, c);
      await rt.insertText(c, id, 0, testCase.input);
      final text = (await rt.projection(c)).objects[id]?.text;
      results.add(RoundTripResult(testCase, readBack: text ?? ''));
    } catch (error) {
      // A throw here is a result, not a reason to abandon the remaining cases.
      results.add(RoundTripResult(testCase, error: error));
    }
  }
  return results;
}

Future<IndexProbeResult> measureIndexMeaning(CrdtRuntime rt, ClientId c) async {
  final seedId = await _freshTitle(rt, c);
  await rt.insertText(c, seedId, 0, indexProbeSeed);
  final seedReadBack = (await rt.projection(c)).objects[seedId]!.text!;
  final runtimeLength = await rt.textLength(c, seedId);

  String? afterErase;
  Object? eraseError;
  try {
    await rt.deleteText(c, seedId, dartUtf16IndexOfFirstAscii, 1);
    afterErase = (await rt.projection(c)).objects[seedId]!.text;
  } catch (error) {
    eraseError = error;
  }

  // A second, untouched seed: formatting must be measured against the whole
  // seed, not against whatever the erase above left behind.
  final formatId = await _freshTitle(rt, c);
  await rt.insertText(c, formatId, 0, indexProbeSeed);
  final marked = <String>[];
  var delta = <Map<String, Object?>>[];
  Object? formatError;
  try {
    await rt.formatText(
      c,
      formatId,
      dartUtf16IndexOfFirstAscii,
      1,
      {'bold': true},
    );
    delta = (await rt.projection(c)).objects[formatId]!.delta!;
    for (final run in delta) {
      final attrs = run['attributes'] as Map?;
      if (attrs != null && attrs['bold'] == true) {
        marked.add('${run['insert']}');
      }
    }
  } catch (error) {
    formatError = error;
  }

  return IndexProbeResult(
    seedReadBack: seedReadBack,
    runtimeLength: runtimeLength,
    afterEraseOneUnit: afterErase,
    eraseError: eraseError,
    markedRuns: marked,
    formatError: formatError,
    deltaAfterFormat: delta,
  );
}

/// Part 3. Guarded at every step: a Dart exception, a corrupted read, or a
/// refused no-op are all acceptable outcomes to *record*. (A native abort
/// inside yrs.dll cannot be caught from Dart at all, which is why the callers
/// run this last in their file — everything before it has already printed.)
Future<SurrogateSplitResult> measureSurrogateSplit(CrdtRuntime rt, ClientId c) async {
  final id = await _freshTitle(rt, c);
  await rt.insertText(c, id, 0, indexProbeSeed);

  var eraseThrew = false;
  Object? eraseError;
  try {
    await rt.deleteText(c, id, insideSurrogatePairIndex, 1);
  } catch (error) {
    eraseThrew = true;
    eraseError = error;
  }

  var readThrew = false;
  Object? readError;
  String? textAfter;
  int? lengthAfter;
  try {
    textAfter = (await rt.projection(c)).objects[id]?.text;
    lengthAfter = await rt.textLength(c, id);
  } catch (error) {
    readThrew = true;
    readError = error;
  }

  return SurrogateSplitResult(
    eraseThrew: eraseThrew,
    eraseError: eraseError,
    readThrew: readThrew,
    readError: readError,
    textAfter: textAfter,
    runtimeLengthAfter: lengthAfter,
  );
}

String renderRoundTripReport(String runtimeName, List<RoundTripResult> results) {
  final out = StringBuffer('== $runtimeName: round-trip through the bridge ==\n');
  for (final result in results) {
    final verdict = result.error != null
        ? 'THREW'
        : result.ok
            ? 'ok'
            : 'MISMATCH';
    out.writeln('[$verdict] ${result.source.label}');
    out.writeln('   in : ${showCodeUnits(result.source.input)}');
    if (result.error != null) {
      out.writeln('   err: ${result.error}');
    } else if (!result.ok) {
      out.writeln('   out: ${showCodeUnits(result.readBack!)}');
    }
  }
  final failed = results.where((r) => !r.ok).map((r) => r.source.label).toList();
  out.writeln('failing cases: ${failed.isEmpty ? '(none)' : failed.join(', ')}');
  return out.toString();
}

String renderIndexReport(String runtimeName, IndexProbeResult result) {
  final out = StringBuffer('== $runtimeName: what does an integer index mean? ==\n');
  out.writeln('seed                     : ${showCodeUnits(indexProbeSeed)}');
  out.writeln('seed read back           : ${showCodeUnits(result.seedReadBack)}');
  out.writeln('Dart String.length       : ${indexProbeSeed.length}');
  out.writeln('Dart runes.length        : ${indexProbeSeed.runes.length}');
  out.writeln('Dart characters.length   : ${indexProbeSeed.characters.length}');
  out.writeln('$runtimeName reported len : ${result.runtimeLength}');
  out.writeln('erase(index=$dartUtf16IndexOfFirstAscii, len=1) ->');
  if (result.eraseError != null) {
    out.writeln('   THREW: ${result.eraseError}');
  } else {
    out.writeln('   ${showCodeUnits(result.afterEraseOneUnit ?? '')}');
  }
  out.writeln('format(index=$dartUtf16IndexOfFirstAscii, len=1, bold) ->');
  if (result.formatError != null) {
    out.writeln('   THREW: ${result.formatError}');
  } else {
    out.writeln('   marked runs: '
        '${result.markedRuns.map(showCodeUnits).toList()}');
    out.writeln('   full delta : '
        '${result.deltaAfterFormat.map((run) => {
              'insert': showCodeUnits('${run['insert']}'),
              if (run['attributes'] != null) 'attributes': run['attributes'],
            }).toList()}');
  }
  return out.toString();
}

String renderSurrogateSplitReport(String runtimeName, SurrogateSplitResult result) {
  final out = StringBuffer('== $runtimeName: erase one unit INSIDE a surrogate pair ==\n');
  out.writeln('seed                : ${showCodeUnits(indexProbeSeed)}');
  out.writeln('erase(index=$insideSurrogatePairIndex, len=1) threw: ${result.eraseThrew}');
  if (result.eraseError != null) out.writeln('   err: ${result.eraseError}');
  out.writeln('read-back threw     : ${result.readThrew}');
  if (result.readError != null) out.writeln('   err: ${result.readError}');
  if (!result.readThrew) {
    out.writeln('text after          : ${showCodeUnits(result.textAfter ?? '')}');
    out.writeln('reported len after  : ${result.runtimeLengthAfter}');
  }
  return out.toString();
}
