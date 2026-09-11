import 'dart:typed_data';

import 'package:yjs_probe/core/capability.dart';
import 'package:yjs_probe/core/field_write.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/core/projection.dart';
import 'package:yjs_probe/runtime/crdt_runtime.dart';

class FakeRuntime implements CrdtRuntime {
  FakeRuntime(this.capabilities);

  @override
  final CapabilitySet capabilities;

  @override
  String get name => 'fake';

  Never _no() => throw UnsupportedError('FakeRuntime must not be driven');

  @override
  Future<void> open(ClientId c, {bool undo = false}) => _no();
  @override
  Future<void> close(ClientId c) => _no();
  @override
  Future<void> applyUpdate(ClientId c, Uint8List u, {String origin = 'remote', int? seq}) => _no();
  @override
  Future<List<Uint8List>> drainOutbox(ClientId c) => _no();
  @override
  Future<Uint8List> encodeStateAsUpdate(ClientId c) => _no();
  @override
  Future<DocProjection> projection(ClientId c) => _no();
  @override
  Future<void> createObject(ClientId c, ObjectId id, ObjectKind k,
          {required double x,
          required double y,
          required double w,
          required double h,
          double rotation = 0,
          double z = 0,
          String? src}) =>
      _no();
  @override
  Future<void> setField(ClientId c, ObjectId id, String key, num value) => _no();
  @override
  Future<void> setFields(ClientId c, List<FieldWrite> writes) => _no();
  @override
  Future<void> insertText(ClientId c, ObjectId id, int i, String t) => _no();
  @override
  Future<void> deleteText(ClientId c, ObjectId id, int i, int l) => _no();
  @override
  Future<void> formatText(
          ClientId c, ObjectId id, int i, int l, Map<String, Object?> a) =>
      _no();
  @override
  Future<void> deleteObject(ClientId c, ObjectId id) => _no();
  @override
  Future<int> textLength(ClientId c, ObjectId id) => _no();
  @override
  Future<DecodedUpdate> decodeUpdate(Uint8List u) => _no();
  @override
  Future<int> pendingStructCount(ClientId c) => _no();
}
