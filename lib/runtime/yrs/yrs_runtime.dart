import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/capability.dart';
import '../../core/field_write.dart';
import '../../core/ids.dart';
import '../../core/projection.dart';
import '../crdt_runtime.dart';
import '../undo_runtime.dart';
import 'yrs_ffi_bindings.dart';

class YrsRuntime implements CrdtRuntime, UndoRuntime {
  YrsRuntime._(this._bindings);

  final YrsBindings _bindings;
  final Map<int, _YrsDoc> _docs = {};

  static Future<YrsRuntime> create() async {
    final library = DynamicLibrary.open('yrs.dll');
    return YrsRuntime._(YrsBindings(library));
  }

  @override
  String get name => 'yrs-ffi-0.27.3';

  @override
  CapabilitySet get capabilities => const CapabilitySet.of({
        Capability.readStateVector,
        Capability.enumerateFormatMarkers,
        Capability.readUndoStackItems,
        // Wayfinder ticket 02: pendingStructCount is now real (see its
        // override below), so this capability is no longer a lie.
        Capability.countPendingStructs,
      });

  @override
  Future<void> open(ClientId c, {bool undo = false}) async {
    if (_docs.containsKey(c.value)) {
      // The probe's Yjs bridge recreates a document whenever createDoc sees a
      // reused client id. Scenario helpers deliberately restart their
      // ThinServer/client-id sequence, so mirror that lifecycle here.
      await close(c);
    }
    final options = calloc<YOptions>();
    options.ref
      ..id = c.value
      ..guid = Pointer<Uint8>.fromAddress(0)
      ..collectionId = Pointer<Uint8>.fromAddress(0)
      ..flags = yOffsetUtf16 | yCleanupFmt;
    final doc = _bindings.ydocNewWithOptions(options.ref);
    calloc.free(options);
    if (doc.address == 0) throw StateError('ydoc_new_with_options returned NULL');

    final arena = _Utf8Arena();
    final objects = _bindings.ymap(doc, arena.add('objects'));
    if (objects.address == 0) {
      _bindings.ydocDestroy(doc);
      arena.dispose();
      throw StateError('Yrs failed to create root objects map');
    }

    // Task 20: build the undo manager only when requested, and build it here
    // — eagerly, before any content exists — rather than on first undo-call,
    // for the same reason as the Yjs bridge (see CrdtRuntime.open's doc
    // comment and yjs_probe/js/src/bridge.js's createDoc). A null pointer
    // (address 0) marks "no undo manager for this document" and every
    // undo-related method below fails loudly against it via `_requireUndo`
    // rather than silently doing nothing.
    var undoManager = Pointer<YUndoManager>.fromAddress(0);
    if (undo) {
      final undoOptions = calloc<YUndoManagerOptions>();
      undoOptions.ref.captureTimeoutMillis = 500;
      undoManager = _bindings.yundoManager(undoOptions);
      calloc.free(undoOptions);
      if (undoManager.address == 0) {
        _bindings.ydocDestroy(doc);
        arena.dispose();
        throw StateError('Yrs failed to create undo manager');
      }
      _bindings.yundoManagerAddScope(undoManager, doc, objects);
      _withOrigin('local', (ptr, len) {
        _bindings.yundoManagerAddOrigin(undoManager, len, ptr);
      });
    }
    arena.dispose();
    _docs[c.value] = _YrsDoc(
      clientId: c,
      doc: doc,
      objects: objects,
      undoManager: undoManager,
    );
  }

  @override
  Future<void> close(ClientId c) async {
    final value = _docs.remove(c.value);
    if (value == null) return;
    if (value.undoManager.address != 0) {
      _bindings.yundoManagerDestroy(value.undoManager);
    }
    _bindings.ydocDestroy(value.doc);
  }

  @override
  Future<void> applyUpdate(
    ClientId c,
    Uint8List update, {
    String origin = 'remote',
    int? seq,
  }) async {
    if (update.isEmpty) return;
    final value = _require(c);
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(
      value.doc,
      utf8.encode(origin).length,
      arena.add(origin),
    );
    if (txn.address == 0) {
      arena.dispose();
      throw StateError('ydoc_write_transaction returned NULL while applying update');
    }
    final updatePtr = calloc<Uint8>(update.length);
    updatePtr.asTypedList(update.length).setAll(0, update);
    try {
      final error = _bindings.ytransactionApply(txn, updatePtr, update.length);
      if (error != 0) throw StateError('ytransaction_apply returned error code $error');
    } finally {
      calloc.free(updatePtr);
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }

  @override
  Future<List<Uint8List>> drainOutbox(ClientId c) async {
    final value = _require(c);
    final result = List<Uint8List>.from(value.outbox);
    value.outbox.clear();
    return result;
  }

  @override
  Future<Uint8List> encodeStateAsUpdate(ClientId c) async {
    final value = _require(c);
    return _read(value, (txn, _) => _stateDiff(txn, Uint8List(0)));
  }

  @override
  Future<DocProjection> projection(ClientId c) async {
    final value = _require(c);
    return _read(value, (txn, doc) {
      final objectsJson = _takeString(
        _bindings.ybranchJson(doc.objects, txn),
        label: 'objects JSON',
      );
      final decoded = jsonDecode(objectsJson);
      final source = decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
      final objects = <ObjectId, ObjectProjection>{};
      for (final entry in source.entries) {
        final raw = entry.value as Map<String, dynamic>;
        final kind = raw['kind'] as String;
        final textBranch = kind == ObjectKind.title.name
            ? _textBranch(doc, txn, entry.key)
            : null;
        objects[ObjectId(entry.key)] = ObjectProjection(
          kind: kind,
          x: _number(raw['x']),
          y: _number(raw['y']),
          w: _number(raw['w']),
          h: _number(raw['h']),
          rotation: _number(raw['rotation']),
          z: _number(raw['z']),
          text: textBranch == null ? null : _takeString(
              _bindings.ytextString(textBranch, txn),
              label: 'text',
            ),
          delta: textBranch == null ? null : _delta(textBranch, txn),
          src: kind == ObjectKind.image.name ? raw['src'] as String? : null,
        );
      }
      return DocProjection(
        clientId: doc.clientId,
        objects: objects,
        stateVectorB64: base64Encode(_stateVector(txn)),
      );
    });
  }

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
  }) async {
    final value = _require(c);
    _mutate(value, (txn, doc) {
      final arena = _Utf8Arena();
      final keys = calloc<Pointer<Uint8>>(kind == ObjectKind.title ? 8 : 8);
      final inputs = calloc<YInput>(8);
      final objectInput = calloc<YInput>();
      try {
        final names = <String>[
          'kind',
          'x',
          'y',
          'w',
          'h',
          'rotation',
          'z',
          kind == ObjectKind.title ? 'text' : 'src',
        ];
        final values = <YInput>[
          _bindings.yinputString(arena.add(kind.name)),
          _bindings.yinputFloat(x),
          _bindings.yinputFloat(y),
          _bindings.yinputFloat(w),
          _bindings.yinputFloat(h),
          _bindings.yinputFloat(rotation),
          _bindings.yinputFloat(z),
          kind == ObjectKind.title
              ? _bindings.yinputYText(arena.add(''))
              : _bindings.yinputString(arena.add(src ?? '')),
        ];
        for (var i = 0; i < names.length; i++) {
          keys[i] = arena.add(names[i]);
          inputs[i] = values[i];
        }
        objectInput.ref = _bindings.yinputYMap(keys, inputs, names.length);
        _withUtf8(id.value, (key) {
          _bindings.ymapInsert(doc.objects, txn, key, objectInput);
        });
      } finally {
        calloc.free(objectInput);
        calloc.free(inputs);
        calloc.free(keys);
        arena.dispose();
      }
    });
  }

  @override
  Future<void> setField(ClientId c, ObjectId id, String key, num value) async {
    final doc = _require(c);
    _mutate(doc, (txn, docValue) {
      final object = _objectMap(docValue, txn, id.value);
      final input = calloc<YInput>();
      try {
        input.ref = _bindings.yinputFloat(value.toDouble());
        _withUtf8(key, (keyPtr) {
          _bindings.ymapInsert(object, txn, keyPtr, input);
        });
      } finally {
        calloc.free(input);
      }
    });
  }

  @override
  Future<void> setFields(ClientId c, List<FieldWrite> writes) async {
    final doc = _require(c);
    _mutate(doc, (txn, docValue) {
      for (final write in writes) {
        final object = _objectMap(docValue, txn, write.objectId.value);
        final input = calloc<YInput>();
        try {
          input.ref = _bindings.yinputFloat(write.value.toDouble());
          _withUtf8(write.key, (keyPtr) {
            _bindings.ymapInsert(object, txn, keyPtr, input);
          });
        } finally {
          calloc.free(input);
        }
      }
    });
  }

  @override
  Future<void> insertText(ClientId c, ObjectId id, int index, String text) async {
    final doc = _require(c);
    _mutate(doc, (txn, value) {
      final textBranch = _textBranch(value, txn, id.value);
      _withUtf8(text, (textPtr) {
        _bindings.ytextInsert(
          textBranch,
          txn,
          index,
          textPtr,
          Pointer<YInput>.fromAddress(0),
        );
      });
    });
  }

  @override
  Future<void> deleteText(ClientId c, ObjectId id, int index, int length) async {
    final doc = _require(c);
    _mutate(doc, (txn, value) {
      _bindings.ytextRemoveRange(_textBranch(value, txn, id.value), txn, index, length);
    });
  }

  @override
  Future<void> formatText(
    ClientId c,
    ObjectId id,
    int index,
    int length,
    Map<String, Object?> attrs,
  ) async {
    final doc = _require(c);
    _mutate(doc, (txn, value) {
      final input = calloc<YInput>();
      final arena = _Utf8Arena();
      try {
        input.ref = _bindings.yinputJson(arena.add(jsonEncode(attrs)));
        _bindings.ytextFormat(
          _textBranch(value, txn, id.value),
          txn,
          index,
          length,
          input,
        );
      } finally {
        calloc.free(input);
        arena.dispose();
      }
    });
  }

  @override
  Future<void> deleteObject(ClientId c, ObjectId id) async {
    final doc = _require(c);
    _mutate(doc, (txn, value) {
      _withUtf8(id.value, (key) {
        _bindings.ymapRemove(value.objects, txn, key);
      });
    });
  }

  @override
  Future<int> textLength(ClientId c, ObjectId id) async {
    final doc = _require(c);
    return _read(doc, (txn, value) =>
        _bindings.ytextLen(_textBranch(value, txn, id.value), txn));
  }

  @override
  Future<DecodedUpdate> decodeUpdate(Uint8List update) async =>
      throw UnsupportedError('yffi v0.27.3 has no update decoder capability');

  /// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility). yffi has
  /// no enumerable pending-structs collection the way Yjs's JS-side
  /// `store.pendingStructs` array does — `ytransaction_pending_update`'s
  /// `missing` field is a *state vector* (one entry per client whose causal
  /// chain has a gap), not a per-struct count. Ticket 01 confirmed both
  /// `ytransaction_pending_update` and `ytransaction_pending_ds` are already
  /// exported by the vendored `yrs.dll` and together are exactly Rust's own
  /// `Transaction::has_missing_updates()` (`store.pending.is_some() ||
  /// store.pending_ds.is_some()`, yrs/src/transaction.rs:285) — see
  /// `yjs_probe/reports/p6-yffi-pending-structs.md`.
  ///
  /// Named simplification: this returns `1` for "causally incomplete", `0`
  /// for "not" — a boolean-shaped count, not a real per-struct enumeration.
  /// Every current call site (`title_admission.dart`, the p4 scenarios) only
  /// ever tests `!= 0`/`== 0`, so this changes nothing observable today; a
  /// caller that starts relying on the actual magnitude would be relying on
  /// something this override does not provide.
  @override
  Future<int> pendingStructCount(ClientId c) async {
    final doc = _require(c);
    return _read(doc, (txn, _) {
      final pendingUpdate = _bindings.ytransactionPendingUpdate(txn);
      final pendingDs = _bindings.ytransactionPendingDs(txn);
      try {
        return (pendingUpdate.address != 0 || pendingDs.address != 0) ? 1 : 0;
      } finally {
        if (pendingUpdate.address != 0) {
          _bindings.ypendingUpdateDestroy(pendingUpdate);
        }
        if (pendingDs.address != 0) _bindings.ydeleteSetDestroy(pendingDs);
      }
    });
  }

  @override
  Future<void> setOperationOrigin(ClientId c, String origin) async {
    _require(c).operationOrigin = origin;
  }

  @override
  Future<void> setTrackedOrigins(ClientId c, Set<String> origins) async {
    final doc = _require(c);
    final undoManager = _requireUndo(c, doc);
    final removed = doc.trackedOrigins.difference(origins);
    final added = origins.difference(doc.trackedOrigins);
    for (final origin in removed) {
      _withOrigin(origin, (ptr, len) {
        _bindings.yundoManagerRemoveOrigin(undoManager, len, ptr);
      });
    }
    for (final origin in added) {
      _withOrigin(origin, (ptr, len) {
        _bindings.yundoManagerAddOrigin(undoManager, len, ptr);
      });
    }
    doc.trackedOrigins
      ..clear()
      ..addAll(origins);
  }

  @override
  Future<void> stopCapturing(ClientId c) async {
    final doc = _require(c);
    _bindings.yundoManagerStop(_requireUndo(c, doc));
  }

  @override
  Future<bool> undo(ClientId c) async => _undoLike(c, _bindings.yundoManagerUndo);

  @override
  Future<bool> redo(ClientId c) async => _undoLike(c, _bindings.yundoManagerRedo);

  @override
  Future<int> undoStackLength(ClientId c) async {
    final doc = _require(c);
    return _bindings.yundoManagerUndoStackLen(_requireUndo(c, doc));
  }

  @override
  Future<int> redoStackLength(ClientId c) async {
    final doc = _require(c);
    return _bindings.yundoManagerRedoStackLen(_requireUndo(c, doc));
  }

  _YrsDoc _require(ClientId c) =>
      _docs[c.value] ?? (throw StateError('no Yrs document for client ${c.value}'));

  // Task 20: mirrors the Yjs bridge's `needUndo` — a document opened without
  // `undo: true` has no undo manager (a null/zero pointer), and calling an
  // undo-related op on it must fail loudly rather than dereference that
  // pointer into the FFI boundary.
  Pointer<YUndoManager> _requireUndo(ClientId c, _YrsDoc doc) {
    if (doc.undoManager.address == 0) {
      throw StateError(
        'no undo manager for client ${c.value} — open this document with undo: true',
      );
    }
    return doc.undoManager;
  }

  T _read<T>(_YrsDoc doc, T Function(Pointer<YTransaction>, _YrsDoc) action) {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(
      doc.doc,
      4,
      arena.add('read'),
    );
    if (txn.address == 0) {
      arena.dispose();
      throw StateError('ydoc_write_transaction returned NULL for read');
    }
    try {
      return action(txn, doc);
    } finally {
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }

  void _mutate(
    _YrsDoc doc,
    void Function(Pointer<YTransaction>, _YrsDoc) action,
  ) {
    final arena = _Utf8Arena();
    final origin = doc.operationOrigin;
    final txn = _bindings.ydocWriteTransaction(
      doc.doc,
      utf8.encode(origin).length,
      arena.add(origin),
    );
    if (txn.address == 0) {
      arena.dispose();
      throw StateError('ydoc_write_transaction returned NULL for local edit');
    }
    Uint8List? update;
    var completed = false;
    try {
      final before = _stateVector(txn);
      action(txn, doc);
      update = _stateDiff(txn, before);
      completed = true;
    } finally {
      _bindings.ytransactionCommit(txn);
      arena.dispose();
      final generated = update;
      if (completed && generated != null && generated.isNotEmpty) {
        doc.outbox.add(generated);
      }
    }
  }

  Future<bool> _undoLike(
    ClientId clientId,
    int Function(Pointer<YUndoManager>) operation,
  ) async {
    final doc = _require(clientId);
    final undoManager = _requireUndo(clientId, doc);
    final before = _read(doc, (txn, _) => _stateVector(txn));
    final changed = operation(undoManager) != 0;
    final update = _read(doc, (txn, _) => _stateDiff(txn, before));
    if (update.isNotEmpty) doc.outbox.add(update);
    return changed;
  }

  Uint8List _stateVector(Pointer<YTransaction> txn) {
    final len = calloc<Uint32>();
    try {
      final ptr = _bindings.ytransactionStateVectorV1(txn, len);
      return _copyBinary(ptr, len.value);
    } finally {
      calloc.free(len);
    }
  }

  Uint8List _stateDiff(Pointer<YTransaction> txn, Uint8List before) {
    final statePtr = before.isEmpty
        ? Pointer<Uint8>.fromAddress(0)
        : calloc<Uint8>(before.length);
    final len = calloc<Uint32>();
    try {
      if (before.isNotEmpty) statePtr.asTypedList(before.length).setAll(0, before);
      final ptr = _bindings.ytransactionStateDiffV1(
        txn,
        statePtr,
        before.length,
        len,
      );
      return _copyBinary(ptr, len.value);
    } finally {
      if (before.isNotEmpty) calloc.free(statePtr);
      calloc.free(len);
    }
  }

  Uint8List _copyBinary(Pointer<Uint8> ptr, int length) {
    if (ptr.address == 0 || length == 0) return Uint8List(0);
    final result = Uint8List.fromList(ptr.asTypedList(length));
    _bindings.ybinaryDestroy(ptr, length);
    return result;
  }

  Pointer<Branch> _objectMap(_YrsDoc doc, Pointer<YTransaction> txn, String id) {
    return _withUtf8Result(id, (key) {
      final output = _bindings.ymapGet(doc.objects, txn, key);
      if (output.address == 0) throw StateError('no object $id');
      final result = _bindings.youtputReadYMap(output);
      _bindings.youtputDestroy(output);
      if (result.address == 0) throw StateError('object $id is not a YMap');
      return result;
    });
  }

  Pointer<Branch> _textBranch(_YrsDoc doc, Pointer<YTransaction> txn, String id) {
    final object = _objectMap(doc, txn, id);
    return _withUtf8Result('text', (key) {
      final output = _bindings.ymapGet(object, txn, key);
      if (output.address == 0) throw StateError('object $id has no text');
      final result = _bindings.youtputReadYText(output);
      _bindings.youtputDestroy(output);
      if (result.address == 0) throw StateError('object $id text is not YText');
      return result;
    });
  }

  List<Map<String, Object?>> _delta(Pointer<Branch> text, Pointer<YTransaction> txn) {
    final len = calloc<Uint32>();
    final chunks = _bindings.ytextChunks(text, txn, len);
    try {
      final result = <Map<String, Object?>>[];
      for (var i = 0; i < len.value; i++) {
        final chunk = (chunks + i).ref;
        final item = <String, Object?>{
          'insert': _outputString(chunk.data),
        };
        if (chunk.fmtLen > 0 && chunk.fmt.address != 0) {
          final attrs = <String, Object?>{};
          for (var j = 0; j < chunk.fmtLen; j++) {
            final entry = (chunk.fmt + j).ref;
            attrs[entry.key.cast<Utf8>().toDartString()] = _outputValue(entry.value.ref);
          }
          item['attributes'] = attrs;
        }
        result.add(item);
      }
      return result;
    } finally {
      if (chunks.address != 0) _bindings.ychunksDestroy(chunks, len.value);
      calloc.free(len);
    }
  }

  String _outputString(YOutput output) {
    if (output.tag != yJsonString || output.value.str.address == 0) {
      throw StateError('Yrs text chunk was not a string (tag ${output.tag})');
    }
    return output.value.str.cast<Utf8>().toDartString();
  }

  Object? _outputValue(YOutput output) {
    switch (output.tag) {
      case yJsonBool:
        return output.value.flag != 0;
      case yJsonNum:
        return output.value.num;
      case yJsonInt:
        return output.value.integer;
      case yJsonString:
        return output.value.str.cast<Utf8>().toDartString();
      default:
        return null;
    }
  }

  String _takeString(Pointer<Uint8> ptr, {required String label}) {
    if (ptr.address == 0) throw StateError('Yrs returned NULL for $label');
    try {
      return ptr.cast<Utf8>().toDartString();
    } finally {
      _bindings.ystringDestroy(ptr);
    }
  }

  double _number(Object? value) => (value as num?)?.toDouble() ?? 0;

  void _withOrigin(String value, void Function(Pointer<Uint8>, int) action) {
    _withUtf8(value, (ptr) => action(ptr, utf8.encode(value).length));
  }

  T _withUtf8Result<T>(String value, T Function(Pointer<Uint8>) action) {
    final arena = _Utf8Arena();
    try {
      return action(arena.add(value));
    } finally {
      arena.dispose();
    }
  }

  void _withUtf8(String value, void Function(Pointer<Uint8>) action) {
    final arena = _Utf8Arena();
    try {
      action(arena.add(value));
    } finally {
      arena.dispose();
    }
  }
}

final class _YrsDoc {
  _YrsDoc({
    required this.clientId,
    required this.doc,
    required this.objects,
    required this.undoManager,
  });

  final ClientId clientId;
  final Pointer<YDoc> doc;
  final Pointer<Branch> objects;
  final Pointer<YUndoManager> undoManager;
  final List<Uint8List> outbox = [];
  final Set<String> trackedOrigins = {'local'};
  String operationOrigin = 'local';
}

final class _Utf8Arena {
  final List<Pointer<Utf8>> _pointers = [];

  Pointer<Uint8> add(String value) {
    final pointer = value.toNativeUtf8();
    _pointers.add(pointer);
    return pointer.cast<Uint8>();
  }

  void dispose() {
    for (final pointer in _pointers) {
      calloc.free(pointer);
    }
    _pointers.clear();
  }
}
