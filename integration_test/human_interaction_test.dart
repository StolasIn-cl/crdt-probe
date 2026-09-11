import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/ui/probe_app.dart';

bool _hasBoldSpan(RichText richText) {
  final root = richText.text;
  if (root is! TextSpan) return false;
  final spans = <TextSpan>[];
  void collect(InlineSpan span) {
    if (span is TextSpan) {
      spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        collect(child);
      }
    }
  }

  collect(root);
  return spans.any((span) => span.style?.fontWeight == FontWeight.bold);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a human can edit a selected title before releasing it to the peer',
      (tester) async {
    await tester.pumpWidget(const ProbeApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pane-1-add-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pane-1-object-o0')));
    await tester.pumpAndSettle();

    final editor = find.byKey(const Key('inspector-title-editor'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'Edited title');
    await tester.ensureVisible(find.byKey(const Key('inspector-title-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-title-apply')));
    await tester.pumpAndSettle();

    final editorWidget = tester.widget<TextField>(editor);
    expect(editorWidget.controller!.text, 'Edited title');

    await tester.drag(find.byKey(const Key('inspector-list')), const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-switch')));
    await tester.pumpAndSettle();
    final peerBeforeRelease = tester.widget<TextField>(editor);
    expect(peerBeforeRelease.controller!.text, 'Title o0');

    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();
    final peerAfterRelease = tester.widget<TextField>(editor);
    expect(peerAfterRelease.controller!.text, 'Edited title');

    await tester.drag(find.byKey(const Key('inspector-list')), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('inspector-format-start')), '0');
    await tester.enterText(find.byKey(const Key('inspector-format-end')), '5');
    await tester.tap(find.byKey(const Key('inspector-format-bold')));
    await tester.pumpAndSettle();

    final formattedPeer = tester.widget<RichText>(
      find.byKey(const Key('pane-2-title-text-o0')),
    );
    expect(_hasBoldSpan(formattedPeer), isTrue);

    await tester.tap(find.byKey(const Key('inspector-undo')));
    await tester.pumpAndSettle();
    final undonePeer = tester.widget<RichText>(
      find.byKey(const Key('pane-2-title-text-o0')),
    );
    expect(_hasBoldSpan(undonePeer), isFalse);

    await tester.tap(find.byKey(const Key('inspector-redo')));
    await tester.pumpAndSettle();
    final redonePeer = tester.widget<RichText>(
      find.byKey(const Key('pane-2-title-text-o0')),
    );
    expect(_hasBoldSpan(redonePeer), isTrue);

    await tester.drag(find.byKey(const Key('inspector-list')), const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-1-release')));
    await tester.pumpAndSettle();
    final formattedLeft = tester.widget<RichText>(
      find.byKey(const Key('pane-1-title-text-o0')),
    );
    expect(_hasBoldSpan(formattedLeft), isTrue);
  });

  testWidgets('a human can multi-select and move objects as one group',
      (tester) async {
    await tester.pumpWidget(const ProbeApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pane-1-add-image')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pane-1-add-image')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();

    final firstBefore = tester.widget<Positioned>(
      find.byKey(const Key('pane-1-object-o0')),
    );
    final secondBefore = tester.widget<Positioned>(
      find.byKey(const Key('pane-1-object-o1')),
    );

    await tester.tap(find.byKey(const Key('pane-1-object-o0')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const Key('pane-1-object-o1')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inspector-selected-o0')), findsOneWidget);
    expect(find.byKey(const Key('inspector-selected-o1')), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('pane-1-object-o0')),
      const Offset(40, 30),
    );
    await tester.pumpAndSettle();

    final firstAfter = tester.widget<Positioned>(
      find.byKey(const Key('pane-1-object-o0')),
    );
    final secondAfter = tester.widget<Positioned>(
      find.byKey(const Key('pane-1-object-o1')),
    );
    final dx = firstAfter.left! - firstBefore.left!;
    final dy = firstAfter.top! - firstBefore.top!;
    expect(dx, isNot(0));
    expect(dy, isNot(0));
    expect(secondAfter.left, secondBefore.left! + dx);
    expect(secondAfter.top, secondBefore.top! + dy);

    final peerBeforeRelease = tester.widget<Positioned>(
      find.byKey(const Key('pane-2-object-o0')),
    );
    expect(peerBeforeRelease.left, firstBefore.left);
    expect(peerBeforeRelease.top, firstBefore.top);

    await tester.tap(find.byKey(const Key('inbox-2-release')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('inspector-switch')));
    await tester.pumpAndSettle();
    final peerFirstAfter = tester.widget<Positioned>(
      find.byKey(const Key('pane-2-object-o0')),
    );
    final peerSecondAfter = tester.widget<Positioned>(
      find.byKey(const Key('pane-2-object-o1')),
    );
    expect(peerFirstAfter.left, firstAfter.left);
    expect(peerFirstAfter.top, firstAfter.top);
    expect(peerSecondAfter.left, secondAfter.left);
    expect(peerSecondAfter.top, secondAfter.top);

    await tester.tap(find.byKey(const Key('diagnostics-export')));
    await tester.pumpAndSettle();
    final status = tester.widget<Text>(find.descendant(
      of: find.byKey(const Key('diagnostics-path')),
      matching: find.byType(Text),
    ));
    final path = status.data!.substring('JSON exported: '.length);
    final artifact = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    addTearDown(() => File(path).delete());
    expect(artifact['events'], isNotEmpty);
    expect(
      (artifact['events'] as List).any((event) => event['kind'] == 'logical.operation'),
      isTrue,
    );
    expect(
      (artifact['events'] as List).any((event) => event['kind'] == 'projection.snapshot'),
      isTrue,
    );
    expect(artifact['clients'][0]['stateVectorB64'], isA<String>());
    expect(
      (artifact['events'] as List).any(
        (event) =>
            event['kind'] == 'outgoing.update' &&
            event['data']['payloadB64'] is String &&
            event['data']['decoded']['available'] == true &&
            event['data']['decoded']['structCount'] is int,
      ),
      isTrue,
    );
    expect(artifact['server']['log'], isNotEmpty);
    expect(artifact['server']['log'][0]['payloadB64'], isA<String>());
  });
}
