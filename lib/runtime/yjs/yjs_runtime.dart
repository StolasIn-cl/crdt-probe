import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

import '../../core/capability.dart';
import '../../core/field_write.dart';
import '../../core/ids.dart';
import '../../core/projection.dart';
import '../crdt_runtime.dart';
import '../undo_runtime.dart';

/// Yjs behind `flutter_js` (QuickJS on Windows). Every crossing is a string:
/// `flutter_js` transfers no binary, so updates travel as base64 and state
/// travels as JSON.
class YjsRuntime implements CrdtRuntime, UndoRuntime {
  YjsRuntime._(this._js);

  final JavascriptRuntime _js;

  static Future<YjsRuntime> create() async {
    final js = getJavascriptRuntime();
    final bundle = await rootBundle.loadString('assets/js/yjs_bridge.js');
    final loaded = js.evaluate(bundle);
    if (loaded.isError) {
      throw StateError('yjs_bridge.js failed to load: ${loaded.stringResult}');
    }
    return YjsRuntime._(js);
  }

  @override
  String get name => 'yjs-quickjs';

  /// What Yjs can actually show. `enumerateTombstones`,
  /// `enumeratePerCharacterIdentity` and `readUndoStackItems` are left out of
  /// P0 because no bridge op reads them yet — a capability is claimed only when
  /// something implements it.
  @override
  CapabilitySet get capabilities => const CapabilitySet.of({
        Capability.decodeUpdate,
        Capability.readStateVector,
        Capability.enumerateFormatMarkers,
        Capability.countPendingStructs,
        Capability.readUndoStackItems,
      });

  Map<String, dynamic> _call(Map<String, Object?> request) {
    // Single-quote the JSON literal, so only backslashes and single quotes
    // need escaping. JSON itself never emits a raw newline.
    final payload = jsonEncode(request)
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    final r = _js.evaluate("__probe.call('$payload')");
    if (r.isError) throw StateError('evaluate threw: ${r.stringResult}');
    final decoded = jsonDecode(r.stringResult) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw StateError('bridge error for ${request['op']}: ${decoded['error']}');
    }
    return decoded['result'] as Map<String, dynamic>;
  }

  @override
  Future<void> open(ClientId c, {bool undo = false}) async =>
      _call({'op': 'createDoc', 'clientId': c.value, 'undo': undo});

  @override
  Future<void> close(ClientId c) async {}

  @override
  Future<void> applyUpdate(ClientId c, Uint8List update, {String origin = 'remote', int? seq}) async =>
      _call({
        'op': 'applyUpdate',
        'clientId': c.value,
        'updateB64': base64Encode(update),
        'origin': origin,
      });

  @override
  Future<List<Uint8List>> drainOutbox(ClientId c) async {
    final r = _call({'op': 'drainOutbox', 'clientId': c.value});
    return (r['updates'] as List).cast<String>().map(base64Decode).toList();
  }

  @override
  Future<Uint8List> encodeStateAsUpdate(ClientId c) async {
    final r = _call({'op': 'encodeStateAsUpdate', 'clientId': c.value});
    return base64Decode(r['updateB64'] as String);
  }

  @override
  Future<DocProjection> projection(ClientId c) async =>
      DocProjection.fromJson(_call({'op': 'projection', 'clientId': c.value}));

  @override
  Future<void> createObject(
    ClientId c,
    ObjectId id,
    ObjectKind kind, {
    required double x,
    required double y,
    required double w,
    required double h,
    double rotation = 0,
    double z = 0,
    String? src,
  }) async =>
      _call({
        'op': 'createObject',
        'clientId': c.value,
        'objectId': id.value,
        'kind': kind.name,
        'box': {'x': x, 'y': y, 'w': w, 'h': h, 'rotation': rotation, 'z': z},
        'src': src,
      });

  @override
  Future<void> setField(ClientId c, ObjectId id, String key, num value) async => _call({
        'op': 'setField',
        'clientId': c.value,
        'objectId': id.value,
        'key': key,
        'value': value,
      });

  @override
  Future<void> setFields(ClientId c, List<FieldWrite> writes) async => _call({
        'op': 'setFields',
        'clientId': c.value,
        'writes': writes.map((write) => write.toJson()).toList(),
      });

  @override
  Future<void> insertText(ClientId c, ObjectId id, int index, String text) async => _call({
        'op': 'insertText',
        'clientId': c.value,
        'objectId': id.value,
        'index': index,
        'text': text,
      });

  @override
  Future<void> deleteText(ClientId c, ObjectId id, int index, int length) async => _call({
        'op': 'deleteText',
        'clientId': c.value,
        'objectId': id.value,
        'index': index,
        'length': length,
      });

  @override
  Future<void> formatText(
    ClientId c,
    ObjectId id,
    int index,
    int length,
    Map<String, Object?> attrs,
  ) async =>
      _call({
        'op': 'formatText',
        'clientId': c.value,
        'objectId': id.value,
        'index': index,
        'length': length,
        'attrs': attrs,
      });

  @override
  Future<void> deleteObject(ClientId c, ObjectId id) async =>
      _call({'op': 'deleteObject', 'clientId': c.value, 'objectId': id.value});

  @override
  Future<int> textLength(ClientId c, ObjectId id) async => _call({
        'op': 'textLength',
        'clientId': c.value,
        'objectId': id.value,
      })['length'] as int;

  @override
  Future<DecodedUpdate> decodeUpdate(Uint8List update) async {
    final r = _call({'op': 'decodeUpdate', 'updateB64': base64Encode(update)});
    return DecodedUpdate(
      structCount: r['structCount'] as int,
      summaries: (r['summaries'] as List).cast<String>(),
    );
  }

  @override
  Future<int> pendingStructCount(ClientId c) async =>
      _call({'op': 'pendingStructCount', 'clientId': c.value})['count'] as int;

  @override
  Future<void> setOperationOrigin(ClientId c, String origin) async =>
      _call({'op': 'setOperationOrigin', 'clientId': c.value, 'origin': origin});

  @override
  Future<void> setTrackedOrigins(ClientId c, Set<String> origins) async =>
      _call({'op': 'setTrackedOrigins', 'clientId': c.value, 'origins': origins.toList()});

  @override
  Future<void> stopCapturing(ClientId c) async =>
      _call({'op': 'stopCapturing', 'clientId': c.value});

  @override
  Future<bool> undo(ClientId c) async =>
      _call({'op': 'undo', 'clientId': c.value})['changed'] as bool;

  @override
  Future<bool> redo(ClientId c) async =>
      _call({'op': 'redo', 'clientId': c.value})['changed'] as bool;

  @override
  Future<int> undoStackLength(ClientId c) async =>
      _call({'op': 'undoStackLength', 'clientId': c.value})['length'] as int;

  @override
  Future<int> redoStackLength(ClientId c) async =>
      _call({'op': 'redoStackLength', 'clientId': c.value})['length'] as int;

  void dispose() => _js.dispose();
}
