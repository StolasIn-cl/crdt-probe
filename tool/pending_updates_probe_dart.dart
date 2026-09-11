// Wayfinder ticket 01 validation runner (yrs-native-reject-admission-feasibility)
// — plain Dart, no Flutter engine, no native patch.
//
// `YrsRuntime.pendingStructCount` throws `UnsupportedError('pending struct
// enumeration is not exposed by yffi')`. This script checks that claim
// directly against the vendored, *unpatched*
// `yjs_probe/native/yffi/v0.27.3/yrs.dll` + `libyrs.h`: the C API already
// exports `ytransaction_pending_update` and `ytransaction_pending_ds`
// (confirmed present in the DLL's export table via `objdump -p`, not just
// declared in the header) — Rust's own `Transaction::has_missing_updates`
// (yrs/src/transaction.rs) is defined as exactly
// `store.pending.is_some() || store.pending_ds.is_some()`, which is exactly
// what these two already-exported functions expose as non-null/null. No
// native source change, no rebuild.
//
// This script binds those two functions directly (they are not yet wired
// into `YrsBindings` in `yrs_ffi_bindings.dart` — that wiring is left to
// Ticket 02) and runs the ticket's toy scenario: apply a child update before
// its parent to a fresh doc, confirm "has missing/pending updates" reports
// true; apply the parent, confirm it flips to false.
//
// Run from the yjs_probe/ directory:
//   dart run tool/pending_updates_probe_dart.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:yjs_probe/runtime/yrs/yrs_ffi_bindings.dart';

// ---- New structs/bindings for the two not-yet-wired exports. Mirrors the
// shape of `libyrs.h` exactly (see YStateVector / YPendingUpdate / YIdSet).
// Deliberately kept local to this throwaway script rather than added to
// `YrsBindings` — Ticket 02 owns deciding the permanent binding shape.

final class YStateVector extends Struct {
  @Uint32()
  external int entriesCount;
  external Pointer<Uint64> clientIds;
  external Pointer<Uint32> clocks;
}

final class YPendingUpdate extends Struct {
  external YStateVector missing;
  external Pointer<Uint8> updateV1;
  @Uint32()
  external int updateLen;
}

base class YIdSet extends Opaque {}

typedef _YTransactionPendingUpdateNative = Pointer<YPendingUpdate> Function(
    Pointer<YTransaction> txn);
typedef _YTransactionPendingUpdateDart = Pointer<YPendingUpdate> Function(
    Pointer<YTransaction> txn);
typedef _YPendingUpdateDestroyNative = Void Function(
    Pointer<YPendingUpdate> update);
typedef _YPendingUpdateDestroyDart = void Function(
    Pointer<YPendingUpdate> update);
typedef _YTransactionPendingDsNative = Pointer<YIdSet> Function(
    Pointer<YTransaction> txn);
typedef _YTransactionPendingDsDart = Pointer<YIdSet> Function(
    Pointer<YTransaction> txn);
typedef _YDeleteSetDestroyNative = Void Function(Pointer<YIdSet> ds);
typedef _YDeleteSetDestroyDart = void Function(Pointer<YIdSet> ds);

class PendingProbeBindings {
  PendingProbeBindings(DynamicLibrary library)
      : ytransactionPendingUpdate = library.lookupFunction<
            _YTransactionPendingUpdateNative,
            _YTransactionPendingUpdateDart>('ytransaction_pending_update'),
        ypendingUpdateDestroy = library.lookupFunction<
            _YPendingUpdateDestroyNative,
            _YPendingUpdateDestroyDart>('ypending_update_destroy'),
        ytransactionPendingDs = library.lookupFunction<
            _YTransactionPendingDsNative,
            _YTransactionPendingDsDart>('ytransaction_pending_ds'),
        ydeleteSetDestroy = library.lookupFunction<_YDeleteSetDestroyNative,
            _YDeleteSetDestroyDart>('ydelete_set_destroy');

  final Pointer<YPendingUpdate> Function(Pointer<YTransaction>)
      ytransactionPendingUpdate;
  final void Function(Pointer<YPendingUpdate>) ypendingUpdateDestroy;
  final Pointer<YIdSet> Function(Pointer<YTransaction>) ytransactionPendingDs;
  final void Function(Pointer<YIdSet>) ydeleteSetDestroy;
}

class _Utf8Arena {
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

/// One participant's replica, wrapping a real Yrs `YDoc` directly (same
/// pattern as `zorder_merge.dart`'s `ZOrderDoc`) with a single `Y.Text` root
/// named `content`.
class TextDoc {
  TextDoc._(this._bindings, this._doc, this._text);

  final YrsBindings _bindings;
  final Pointer<YDoc> _doc;
  final Pointer<Branch> _text;

  static const int _flags = yOffsetUtf16;

  static TextDoc open(YrsBindings bindings, int clientId) {
    final options = calloc<YOptions>();
    options.ref
      ..id = clientId
      ..guid = Pointer<Uint8>.fromAddress(0)
      ..collectionId = Pointer<Uint8>.fromAddress(0)
      ..flags = _flags;
    final doc = bindings.ydocNewWithOptions(options.ref);
    calloc.free(options);
    if (doc.address == 0) {
      throw StateError('ydoc_new_with_options returned NULL');
    }
    final arena = _Utf8Arena();
    final Pointer<Branch> text;
    try {
      text = bindings.ytext(doc, arena.add('content'));
    } finally {
      arena.dispose();
    }
    if (text.address == 0) {
      bindings.ydocDestroy(doc);
      throw StateError('Yrs failed to create the content root branch');
    }
    return TextDoc._(bindings, doc, text);
  }

  void dispose() => _bindings.ydocDestroy(_doc);

  void insert(int index, String value, {String origin = 'local'}) {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(
      _doc,
      utf8.encode(origin).length,
      arena.add(origin),
    );
    try {
      _bindings.ytextInsert(
        _text,
        txn,
        index,
        arena.add(value),
        Pointer<YInput>.fromAddress(0),
      );
    } finally {
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }

  String readText() {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(_doc, 4, arena.add('read'));
    try {
      final ptr = _bindings.ytextString(_text, txn);
      if (ptr.address == 0) return '';
      final value = ptr.cast<Utf8>().toDartString();
      _bindings.ystringDestroy(ptr);
      return value;
    } finally {
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }

  Uint8List stateVector() {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(_doc, 4, arena.add('read'));
    final len = calloc<Uint32>();
    try {
      final ptr = _bindings.ytransactionStateVectorV1(txn, len);
      if (ptr.address == 0 || len.value == 0) return Uint8List(0);
      final result = Uint8List.fromList(ptr.asTypedList(len.value));
      _bindings.ybinaryDestroy(ptr, len.value);
      return result;
    } finally {
      _bindings.ytransactionCommit(txn);
      calloc.free(len);
      arena.dispose();
    }
  }

  Uint8List diffFrom(Uint8List sinceStateVector) {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(_doc, 4, arena.add('read'));
    final statePtr = sinceStateVector.isEmpty
        ? Pointer<Uint8>.fromAddress(0)
        : calloc<Uint8>(sinceStateVector.length);
    final len = calloc<Uint32>();
    try {
      if (sinceStateVector.isNotEmpty) {
        statePtr.asTypedList(sinceStateVector.length).setAll(0, sinceStateVector);
      }
      final ptr = _bindings.ytransactionStateDiffV1(
        txn,
        statePtr,
        sinceStateVector.length,
        len,
      );
      if (ptr.address == 0 || len.value == 0) return Uint8List(0);
      final result = Uint8List.fromList(ptr.asTypedList(len.value));
      _bindings.ybinaryDestroy(ptr, len.value);
      return result;
    } finally {
      _bindings.ytransactionCommit(txn);
      if (sinceStateVector.isNotEmpty) calloc.free(statePtr);
      calloc.free(len);
      arena.dispose();
    }
  }

  void applyUpdate(Uint8List update, {String origin = 'remote'}) {
    if (update.isEmpty) return;
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(
      _doc,
      utf8.encode(origin).length,
      arena.add(origin),
    );
    final updatePtr = calloc<Uint8>(update.length);
    updatePtr.asTypedList(update.length).setAll(0, update);
    try {
      final error = _bindings.ytransactionApply(txn, updatePtr, update.length);
      if (error != 0) {
        throw StateError('ytransaction_apply returned error code $error');
      }
    } finally {
      calloc.free(updatePtr);
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }

  /// Reports has_missing_updates()'s own definition
  /// (`store.pending.is_some() || store.pending_ds.is_some()`) via the two
  /// already-exported functions, read-only, in one transaction.
  ({bool hasMissing, int missingEntries, int? missingClientId, int? missingClock})
      pendingStatus(PendingProbeBindings probe) {
    final arena = _Utf8Arena();
    final txn = _bindings.ydocWriteTransaction(_doc, 4, arena.add('read'));
    try {
      final pendingUpdate = probe.ytransactionPendingUpdate(txn);
      final pendingDs = probe.ytransactionPendingDs(txn);
      try {
        final hasMissing = pendingUpdate.address != 0 || pendingDs.address != 0;
        int missingEntries = 0;
        int? missingClientId;
        int? missingClock;
        if (pendingUpdate.address != 0) {
          final missing = pendingUpdate.ref.missing;
          missingEntries = missing.entriesCount;
          if (missingEntries > 0) {
            missingClientId = missing.clientIds[0];
            missingClock = missing.clocks[0];
          }
        }
        return (
          hasMissing: hasMissing,
          missingEntries: missingEntries,
          missingClientId: missingClientId,
          missingClock: missingClock,
        );
      } finally {
        if (pendingUpdate.address != 0) probe.ypendingUpdateDestroy(pendingUpdate);
        if (pendingDs.address != 0) probe.ydeleteSetDestroy(pendingDs);
      }
    } finally {
      _bindings.ytransactionCommit(txn);
      arena.dispose();
    }
  }
}

void main() {
  final dllPath = File('native/yffi/v0.27.3/yrs.dll').absolute.path;
  final library = DynamicLibrary.open(dllPath);
  final bindings = YrsBindings(library);
  final probe = PendingProbeBindings(library);

  print('=== Wayfinder ticket 01: pending-struct detection via already-exposed '
      'yffi C API (no native patch) ===');
  print('DLL: $dllPath');
  print('');

  // --- Producer: builds two causally-dependent Yjs updates from one client.
  final producer = TextDoc.open(bindings, 500);
  final target = TextDoc.open(bindings, 501);
  try {
    final sv0 = producer.stateVector();
    producer.insert(0, 'A', origin: 'op1-parent');
    final sv1 = producer.stateVector();
    final u1Parent = producer.diffFrom(sv0);

    producer.insert(1, 'B', origin: 'op2-child');
    final u2Child = producer.diffFrom(sv1);

    print('--- producer state ---');
    print('producer text after both ops: "${producer.readText()}"');
    print('U1 (parent, op1) bytes: ${u1Parent.length}');
    print('U2 (child, op2, causally depends on op1) bytes: ${u2Child.length}');
    print('');

    print('--- step 1: apply child (U2) before parent (U1) to a fresh doc ---');
    target.applyUpdate(u2Child, origin: 'remote');
    var status = target.pendingStatus(probe);
    print('target text after child-only apply: "${target.readText()}"');
    print('ytransaction_pending_update/ds -> hasMissing=${status.hasMissing} '
        '(missingEntries=${status.missingEntries}, '
        'missingClientId=${status.missingClientId}, '
        'missingClock=${status.missingClock})');
    final step1Pass = status.hasMissing == true;
    print('EXPECTATION hasMissing == true: ${step1Pass ? 'PASS' : 'FAIL'}');
    print('');

    print('--- step 2: apply parent (U1) so the dependency is satisfied ---');
    target.applyUpdate(u1Parent, origin: 'remote');
    status = target.pendingStatus(probe);
    print('target text after both applied: "${target.readText()}"');
    print('ytransaction_pending_update/ds -> hasMissing=${status.hasMissing} '
        '(missingEntries=${status.missingEntries})');
    final step2Pass = status.hasMissing == false;
    final convergedPass = target.readText() == producer.readText();
    print('EXPECTATION hasMissing == false: ${step2Pass ? 'PASS' : 'FAIL'}');
    print('EXPECTATION target text == producer text ("${producer.readText()}"): '
        '${convergedPass ? 'PASS' : 'FAIL'}');
    print('');

    final overall = step1Pass && step2Pass && convergedPass;
    print('=== OVERALL: ${overall ? 'PASS' : 'FAIL'} ===');
    if (!overall) {
      exitCode = 1;
    }
  } finally {
    producer.dispose();
    target.dispose();
  }
}
