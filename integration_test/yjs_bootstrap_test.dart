import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late JavascriptRuntime js;

  setUp(() async {
    js = getJavascriptRuntime();
    final bundle = await rootBundle.loadString('assets/js/yjs_bridge.js');
    final load = js.evaluate(bundle);
    expect(load.isError, isFalse, reason: 'bundle failed to evaluate: ${load.stringResult}');
  });

  tearDown(() => js.dispose());

  Map<String, dynamic> call(Map<String, Object?> request) {
    final json = jsonEncode(request).replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final r = js.evaluate("__probe.call('$json')");
    expect(r.isError, isFalse, reason: 'evaluate threw: ${r.stringResult}');
    final decoded = jsonDecode(r.stringResult) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue, reason: 'bridge error: ${decoded['error']}');
    return decoded['result'] as Map<String, dynamic>;
  }

  test('yjs loads and exposes YText and YMap under QuickJS', () {
    final result = call({'op': 'yjsVersion'});
    expect(result['hasYText'], isTrue);
    expect(result['hasYMap'], isTrue);
  });

  test('a pinned clientID is honoured rather than randomised', () {
    final result = call({'op': 'createDoc', 'clientId': 7});
    expect(result['clientId'], 7);
  });

  test('text inserted on one doc converges onto another through base64 updates', () {
    call({'op': 'createDoc', 'clientId': 1});
    call({'op': 'createDoc', 'clientId': 2});

    // Task 3 replaced insertText: it now requires the object to already
    // exist (Task 1's auto-creation was scaffolding for this bootstrap test)
    // and throws otherwise, so the object is created explicitly first.
    call({
      'op': 'createObject',
      'clientId': 1,
      'objectId': 'o1',
      'kind': 'title',
      'box': {'x': 0, 'y': 0, 'w': 0, 'h': 0, 'rotation': 0, 'z': 0},
    });
    call({'op': 'insertText', 'objectId': 'o1', 'clientId': 1, 'index': 0, 'text': 'Hello'});

    final drained = call({'op': 'drainOutbox', 'clientId': 1});
    final updates = (drained['updates'] as List).cast<String>();
    expect(updates, isNotEmpty, reason: 'no update was emitted');

    for (final u in updates) {
      call({'op': 'applyUpdate', 'clientId': 2, 'updateB64': u});
    }

    expect(call({'op': 'readText', 'clientId': 2, 'objectId': 'o1'})['text'], 'Hello');
  });
}
