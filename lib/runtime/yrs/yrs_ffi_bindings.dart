import 'dart:ffi';

base class YDoc extends Opaque {}

base class Branch extends Opaque {}

base class YTransaction extends Opaque {}

base class YUndoManager extends Opaque {}

// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility): opaque
// delete-set handle returned by `ytransaction_pending_ds`. Its fields are
// never read directly by this probe (only null-ness matters — see
// `YrsRuntime.pendingStructCount`), so it stays opaque rather than a full
// struct mirror, unlike `YPendingUpdate` below.
base class YIdSet extends Opaque {}

final class YMapInputData extends Struct {
  external Pointer<Pointer<Uint8>> keys;
  external Pointer<YInput> values;
}

final class YInputContent extends Union {
  @Uint8()
  external int flag;

  @Double()
  external double num;

  @Int64()
  external int integer;

  external Pointer<Uint8> str;
  external Pointer<Int8> buf;
  external Pointer<YInput> values;
  external YMapInputData map;
  external Pointer<YDoc> doc;
  external Pointer<Void> weak;
}

final class YInput extends Struct {
  @Int8()
  external int tag;

  @Uint32()
  external int len;

  external YInputContent value;
}

final class YOutputContent extends Union {
  @Uint8()
  external int flag;

  @Double()
  external double num;

  @Int64()
  external int integer;

  external Pointer<Uint8> str;
  external Pointer<Int8> buf;
  external Pointer<YOutput> array;
  external Pointer<YMapEntry> map;
  external Pointer<Branch> yType;
  external Pointer<YDoc> yDoc;
}

final class YOutput extends Struct {
  @Int8()
  external int tag;

  @Uint32()
  external int len;

  external YOutputContent value;
}

final class YMapEntry extends Struct {
  external Pointer<Uint8> key;
  external Pointer<YOutput> value;
}

final class YChunk extends Struct {
  external YOutput data;

  @Uint32()
  external int fmtLen;

  external Pointer<YMapEntry> fmt;
}

final class YOptions extends Struct {
  @Uint64()
  external int id;

  external Pointer<Uint8> guid;
  external Pointer<Uint8> collectionId;

  @Uint8()
  external int flags;
}

final class YUndoManagerOptions extends Struct {
  @Int32()
  external int captureTimeoutMillis;
}

// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility): mirrors
// `libyrs.h`'s `YStateVector`/`YPendingUpdate` exactly (same shape already
// verified against the real DLL by ticket 01's
// `tool/pending_updates_probe_dart.dart`). `entriesCount` is the number of
// (clientId, clock) pairs in `clientIds`/`clocks` — a per-*client* state
// vector, not a per-*struct* enumeration; see `YrsRuntime.pendingStructCount`
// for why that distinction matters here.
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

typedef _YDocNewWithOptionsNative = Pointer<YDoc> Function(YOptions options);
typedef _YDocNewWithOptionsDart = Pointer<YDoc> Function(YOptions options);
typedef _YDocDestroyNative = Void Function(Pointer<YDoc> value);
typedef _YDocDestroyDart = void Function(Pointer<YDoc> value);
typedef _YDocIdNative = Uint64 Function(Pointer<YDoc> doc);
typedef _YDocIdDart = int Function(Pointer<YDoc> doc);
typedef _YDocWriteTransactionNative = Pointer<YTransaction> Function(
    Pointer<YDoc> doc, Uint32 originLen, Pointer<Uint8> origin);
typedef _YDocWriteTransactionDart = Pointer<YTransaction> Function(
    Pointer<YDoc> doc, int originLen, Pointer<Uint8> origin);
typedef _YTransactionCommitNative = Void Function(Pointer<YTransaction> txn);
typedef _YTransactionCommitDart = void Function(Pointer<YTransaction> txn);
typedef _YTransactionStateVectorNative = Pointer<Uint8> Function(
    Pointer<YTransaction> txn, Pointer<Uint32> len);
typedef _YTransactionStateVectorDart = Pointer<Uint8> Function(
    Pointer<YTransaction> txn, Pointer<Uint32> len);
typedef _YTransactionStateDiffNative = Pointer<Uint8> Function(
    Pointer<YTransaction> txn,
    Pointer<Uint8> stateVector,
    Uint32 stateVectorLen,
    Pointer<Uint32> len,
  );
typedef _YTransactionStateDiffDart = Pointer<Uint8> Function(
    Pointer<YTransaction> txn,
    Pointer<Uint8> stateVector,
    int stateVectorLen,
    Pointer<Uint32> len,
  );
typedef _YTransactionApplyNative = Uint8 Function(
    Pointer<YTransaction> txn, Pointer<Uint8> update, Uint32 updateLen);
typedef _YTransactionApplyDart = int Function(
    Pointer<YTransaction> txn, Pointer<Uint8> update, int updateLen);
typedef _YBinaryDestroyNative = Void Function(Pointer<Uint8> ptr, Uint32 len);
typedef _YBinaryDestroyDart = void Function(Pointer<Uint8> ptr, int len);
typedef _YStringDestroyNative = Void Function(Pointer<Uint8> ptr);
typedef _YStringDestroyDart = void Function(Pointer<Uint8> ptr);
typedef _YMapNative = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YMapDart = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YTextNative = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YTextDart = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YBranchJsonNative = Pointer<Uint8> Function(
    Pointer<Branch> branch, Pointer<YTransaction> txn);
typedef _YBranchJsonDart = Pointer<Uint8> Function(
    Pointer<Branch> branch, Pointer<YTransaction> txn);
typedef _YMapGetNative = Pointer<YOutput> Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YMapGetDart = Pointer<YOutput> Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YMapGetJsonNative = Pointer<Uint8> Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YMapGetJsonDart = Pointer<Uint8> Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YMapInsertNative = Void Function(
    Pointer<Branch> map,
    Pointer<YTransaction> txn,
    Pointer<Uint8> key,
    Pointer<YInput> value);
typedef _YMapInsertDart = void Function(
    Pointer<Branch> map,
    Pointer<YTransaction> txn,
    Pointer<Uint8> key,
    Pointer<YInput> value);
typedef _YMapRemoveNative = Uint8 Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YMapRemoveDart = int Function(
    Pointer<Branch> map, Pointer<YTransaction> txn, Pointer<Uint8> key);
typedef _YOutputReadYMapNative = Pointer<Branch> Function(Pointer<YOutput> value);
typedef _YOutputReadYMapDart = Pointer<Branch> Function(Pointer<YOutput> value);
typedef _YOutputReadYTextNative = Pointer<Branch> Function(Pointer<YOutput> value);
typedef _YOutputReadYTextDart = Pointer<Branch> Function(Pointer<YOutput> value);
typedef _YOutputDestroyNative = Void Function(Pointer<YOutput> value);
typedef _YOutputDestroyDart = void Function(Pointer<YOutput> value);
typedef _YInputJsonNative = YInput Function(Pointer<Uint8> json);
typedef _YInputJsonDart = YInput Function(Pointer<Uint8> json);
typedef _YInputFloatNative = YInput Function(Double value);
typedef _YInputFloatDart = YInput Function(double value);
typedef _YInputStringNative = YInput Function(Pointer<Uint8> value);
typedef _YInputStringDart = YInput Function(Pointer<Uint8> value);
typedef _YInputYTextNative = YInput Function(Pointer<Uint8> value);
typedef _YInputYTextDart = YInput Function(Pointer<Uint8> value);
typedef _YInputYMapNative = YInput Function(
    Pointer<Pointer<Uint8>> keys, Pointer<YInput> values, Uint32 len);
typedef _YInputYMapDart = YInput Function(
    Pointer<Pointer<Uint8>> keys, Pointer<YInput> values, int len);
typedef _YTextStringNative = Pointer<Uint8> Function(
    Pointer<Branch> text, Pointer<YTransaction> txn);
typedef _YTextStringDart = Pointer<Uint8> Function(
    Pointer<Branch> text, Pointer<YTransaction> txn);
typedef _YTextInsertNative = Void Function(
    Pointer<Branch> text,
    Pointer<YTransaction> txn,
    Uint32 index,
    Pointer<Uint8> value,
    Pointer<YInput> attrs);
typedef _YTextInsertDart = void Function(
    Pointer<Branch> text,
    Pointer<YTransaction> txn,
    int index,
    Pointer<Uint8> value,
    Pointer<YInput> attrs);
typedef _YTextFormatNative = Void Function(
    Pointer<Branch> text,
    Pointer<YTransaction> txn,
    Uint32 index,
    Uint32 len,
    Pointer<YInput> attrs);
typedef _YTextFormatDart = void Function(
    Pointer<Branch> text,
    Pointer<YTransaction> txn,
    int index,
    int len,
    Pointer<YInput> attrs);
// Task 21: libyrs.h documents `ytext_len` as "the length of the `YText` string
// content in bytes". That comment predates the per-document offset flag this
// probe passes (`yOffsetUtf16`), so what it actually returns is a measurement,
// not a documented fact — which is precisely why the test prints it rather
// than asserting it.
typedef _YTextLenNative = Uint32 Function(
    Pointer<Branch> text, Pointer<YTransaction> txn);
typedef _YTextLenDart = int Function(
    Pointer<Branch> text, Pointer<YTransaction> txn);
typedef _YTextRemoveNative = Void Function(
    Pointer<Branch> text, Pointer<YTransaction> txn, Uint32 index, Uint32 len);
typedef _YTextRemoveDart = void Function(
    Pointer<Branch> text, Pointer<YTransaction> txn, int index, int len);
typedef _YTextChunksNative = Pointer<YChunk> Function(
    Pointer<Branch> text, Pointer<YTransaction> txn, Pointer<Uint32> len);
typedef _YTextChunksDart = Pointer<YChunk> Function(
    Pointer<Branch> text, Pointer<YTransaction> txn, Pointer<Uint32> len);
typedef _YChunksDestroyNative = Void Function(Pointer<YChunk> chunks, Uint32 len);
typedef _YChunksDestroyDart = void Function(Pointer<YChunk> chunks, int len);
typedef _YUndoManagerNative = Pointer<YUndoManager> Function(
    Pointer<YUndoManagerOptions> options);
typedef _YUndoManagerDart = Pointer<YUndoManager> Function(
    Pointer<YUndoManagerOptions> options);
typedef _YUndoManagerDestroyNative = Void Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerDestroyDart = void Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerAddScopeNative = Void Function(
    Pointer<YUndoManager> manager, Pointer<YDoc> doc, Pointer<Branch> scope);
typedef _YUndoManagerAddScopeDart = void Function(
    Pointer<YUndoManager> manager, Pointer<YDoc> doc, Pointer<Branch> scope);
typedef _YUndoManagerAddOriginNative = Void Function(
    Pointer<YUndoManager> manager, Uint32 len, Pointer<Uint8> origin);
typedef _YUndoManagerAddOriginDart = void Function(
    Pointer<YUndoManager> manager, int len, Pointer<Uint8> origin);
typedef _YUndoManagerRemoveOriginNative = Void Function(
    Pointer<YUndoManager> manager, Uint32 len, Pointer<Uint8> origin);
typedef _YUndoManagerRemoveOriginDart = void Function(
    Pointer<YUndoManager> manager, int len, Pointer<Uint8> origin);
typedef _YUndoManagerStopNative = Void Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerStopDart = void Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerUndoNative = Uint8 Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerUndoDart = int Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerRedoNative = Uint8 Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerRedoDart = int Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerStackLenNative = Uint32 Function(Pointer<YUndoManager> manager);
typedef _YUndoManagerStackLenDart = int Function(Pointer<YUndoManager> manager);

// Wayfinder ticket 02 (yrs-native-reject-admission-feasibility): binds
// `ytransaction_pending_update`/`ytransaction_pending_ds` — together exactly
// `Transaction::has_missing_updates()` (`yrs/src/transaction.rs:285`,
// `store.pending.is_some() || store.pending_ds.is_some()`), confirmed
// present in the shipped `.dll`'s export table by ticket 01's research (see
// `yjs_probe/reports/p6-yffi-pending-structs.md`). No native patch, no
// rebuild — this only wires up C exports the vendored `yrs.dll` already
// ships.
typedef _YTransactionPendingUpdateNative = Pointer<YPendingUpdate> Function(
    Pointer<YTransaction> txn);
typedef _YTransactionPendingUpdateDart = Pointer<YPendingUpdate> Function(
    Pointer<YTransaction> txn);
typedef _YPendingUpdateDestroyNative = Void Function(Pointer<YPendingUpdate> update);
typedef _YPendingUpdateDestroyDart = void Function(Pointer<YPendingUpdate> update);
typedef _YTransactionPendingDsNative = Pointer<YIdSet> Function(Pointer<YTransaction> txn);
typedef _YTransactionPendingDsDart = Pointer<YIdSet> Function(Pointer<YTransaction> txn);
typedef _YDeleteSetDestroyNative = Void Function(Pointer<YIdSet> ds);
typedef _YDeleteSetDestroyDart = void Function(Pointer<YIdSet> ds);

// Wayfinder ticket 03 (yrs-zorder-merge-feasibility): Y.Array bindings.
// Not needed by any production-facing runtime path yet — added purely to
// exercise the `Y.Array` clip-id delete+reinsert representation ticket 01
// found yffi-reachable (libyrs.h:1642-1698) so the prototype can run it for
// real rather than reason about it on paper.
typedef _YArrayNative = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YArrayDart = Pointer<Branch> Function(Pointer<YDoc> doc, Pointer<Uint8> name);
typedef _YArrayLenNative = Uint32 Function(Pointer<Branch> array);
typedef _YArrayLenDart = int Function(Pointer<Branch> array);
typedef _YArrayGetJsonNative = Pointer<Uint8> Function(
    Pointer<Branch> array, Pointer<YTransaction> txn, Uint32 index);
typedef _YArrayGetJsonDart = Pointer<Uint8> Function(
    Pointer<Branch> array, Pointer<YTransaction> txn, int index);
typedef _YArrayInsertRangeNative = Void Function(
    Pointer<Branch> array,
    Pointer<YTransaction> txn,
    Uint32 index,
    Pointer<YInput> items,
    Uint32 itemsLen);
typedef _YArrayInsertRangeDart = void Function(
    Pointer<Branch> array,
    Pointer<YTransaction> txn,
    int index,
    Pointer<YInput> items,
    int itemsLen);
typedef _YArrayRemoveRangeNative = Void Function(
    Pointer<Branch> array, Pointer<YTransaction> txn, Uint32 index, Uint32 len);
typedef _YArrayRemoveRangeDart = void Function(
    Pointer<Branch> array, Pointer<YTransaction> txn, int index, int len);

class YrsBindings {
  YrsBindings(this.library)
      : ydocNewWithOptions = library.lookupFunction<
            _YDocNewWithOptionsNative, _YDocNewWithOptionsDart>('ydoc_new_with_options'),
        ydocDestroy = library.lookupFunction<_YDocDestroyNative, _YDocDestroyDart>('ydoc_destroy'),
        ydocId = library.lookupFunction<_YDocIdNative, _YDocIdDart>('ydoc_id'),
        ydocWriteTransaction = library.lookupFunction<_YDocWriteTransactionNative,
            _YDocWriteTransactionDart>('ydoc_write_transaction'),
        ytransactionCommit = library.lookupFunction<_YTransactionCommitNative,
            _YTransactionCommitDart>('ytransaction_commit'),
        ytransactionStateVectorV1 = library.lookupFunction<
            _YTransactionStateVectorNative, _YTransactionStateVectorDart>('ytransaction_state_vector_v1'),
        ytransactionStateDiffV1 = library.lookupFunction<_YTransactionStateDiffNative,
            _YTransactionStateDiffDart>('ytransaction_state_diff_v1'),
        ytransactionApply = library.lookupFunction<_YTransactionApplyNative,
            _YTransactionApplyDart>('ytransaction_apply'),
        ybinaryDestroy = library.lookupFunction<_YBinaryDestroyNative, _YBinaryDestroyDart>('ybinary_destroy'),
        ystringDestroy = library.lookupFunction<_YStringDestroyNative, _YStringDestroyDart>('ystring_destroy'),
        ymap = library.lookupFunction<_YMapNative, _YMapDart>('ymap'),
        ytext = library.lookupFunction<_YTextNative, _YTextDart>('ytext'),
        ybranchJson = library.lookupFunction<_YBranchJsonNative, _YBranchJsonDart>('ybranch_json'),
        ymapGet = library.lookupFunction<_YMapGetNative, _YMapGetDart>('ymap_get'),
        ymapGetJson = library.lookupFunction<_YMapGetJsonNative, _YMapGetJsonDart>('ymap_get_json'),
        ymapInsert = library.lookupFunction<_YMapInsertNative, _YMapInsertDart>('ymap_insert'),
        ymapRemove = library.lookupFunction<_YMapRemoveNative, _YMapRemoveDart>('ymap_remove'),
        youtputReadYMap = library.lookupFunction<_YOutputReadYMapNative, _YOutputReadYMapDart>('youtput_read_ymap'),
        youtputReadYText = library.lookupFunction<_YOutputReadYTextNative, _YOutputReadYTextDart>('youtput_read_ytext'),
        youtputDestroy = library.lookupFunction<_YOutputDestroyNative, _YOutputDestroyDart>('youtput_destroy'),
        yinputJson = library.lookupFunction<_YInputJsonNative, _YInputJsonDart>('yinput_json'),
        yinputFloat = library.lookupFunction<_YInputFloatNative, _YInputFloatDart>('yinput_float'),
        yinputString = library.lookupFunction<_YInputStringNative, _YInputStringDart>('yinput_string'),
        yinputYText = library.lookupFunction<_YInputYTextNative, _YInputYTextDart>('yinput_ytext'),
        yinputYMap = library.lookupFunction<_YInputYMapNative, _YInputYMapDart>('yinput_ymap'),
        ytextString = library.lookupFunction<_YTextStringNative, _YTextStringDart>('ytext_string'),
        ytextLen = library.lookupFunction<_YTextLenNative, _YTextLenDart>('ytext_len'),
        ytextInsert = library.lookupFunction<_YTextInsertNative, _YTextInsertDart>('ytext_insert'),
        ytextFormat = library.lookupFunction<_YTextFormatNative, _YTextFormatDart>('ytext_format'),
        ytextRemoveRange = library.lookupFunction<_YTextRemoveNative, _YTextRemoveDart>('ytext_remove_range'),
        ytextChunks = library.lookupFunction<_YTextChunksNative, _YTextChunksDart>('ytext_chunks'),
        ychunksDestroy = library.lookupFunction<_YChunksDestroyNative, _YChunksDestroyDart>('ychunks_destroy'),
        yundoManager = library.lookupFunction<_YUndoManagerNative, _YUndoManagerDart>('yundo_manager'),
        yundoManagerDestroy = library.lookupFunction<_YUndoManagerDestroyNative, _YUndoManagerDestroyDart>('yundo_manager_destroy'),
        yundoManagerAddScope = library.lookupFunction<_YUndoManagerAddScopeNative, _YUndoManagerAddScopeDart>('yundo_manager_add_scope'),
        yundoManagerAddOrigin = library.lookupFunction<_YUndoManagerAddOriginNative, _YUndoManagerAddOriginDart>('yundo_manager_add_origin'),
        yundoManagerRemoveOrigin = library.lookupFunction<_YUndoManagerRemoveOriginNative, _YUndoManagerRemoveOriginDart>('yundo_manager_remove_origin'),
        yundoManagerStop = library.lookupFunction<_YUndoManagerStopNative, _YUndoManagerStopDart>('yundo_manager_stop'),
        yundoManagerUndo = library.lookupFunction<_YUndoManagerUndoNative, _YUndoManagerUndoDart>('yundo_manager_undo'),
        yundoManagerRedo = library.lookupFunction<_YUndoManagerRedoNative, _YUndoManagerRedoDart>('yundo_manager_redo'),
        yundoManagerUndoStackLen = library.lookupFunction<_YUndoManagerStackLenNative, _YUndoManagerStackLenDart>('yundo_manager_undo_stack_len'),
        yundoManagerRedoStackLen = library.lookupFunction<_YUndoManagerStackLenNative, _YUndoManagerStackLenDart>('yundo_manager_redo_stack_len'),
        ytransactionPendingUpdate = library.lookupFunction<_YTransactionPendingUpdateNative, _YTransactionPendingUpdateDart>('ytransaction_pending_update'),
        ypendingUpdateDestroy = library.lookupFunction<_YPendingUpdateDestroyNative, _YPendingUpdateDestroyDart>('ypending_update_destroy'),
        ytransactionPendingDs = library.lookupFunction<_YTransactionPendingDsNative, _YTransactionPendingDsDart>('ytransaction_pending_ds'),
        ydeleteSetDestroy = library.lookupFunction<_YDeleteSetDestroyNative, _YDeleteSetDestroyDart>('ydelete_set_destroy'),
        yarray = library.lookupFunction<_YArrayNative, _YArrayDart>('yarray'),
        yarrayLen = library.lookupFunction<_YArrayLenNative, _YArrayLenDart>('yarray_len'),
        yarrayGetJson = library.lookupFunction<_YArrayGetJsonNative, _YArrayGetJsonDart>('yarray_get_json'),
        yarrayInsertRange = library.lookupFunction<_YArrayInsertRangeNative, _YArrayInsertRangeDart>('yarray_insert_range'),
        yarrayRemoveRange = library.lookupFunction<_YArrayRemoveRangeNative, _YArrayRemoveRangeDart>('yarray_remove_range');

  final DynamicLibrary library;
  final Pointer<YDoc> Function(YOptions options) ydocNewWithOptions;
  final void Function(Pointer<YDoc>) ydocDestroy;
  final int Function(Pointer<YDoc>) ydocId;
  final Pointer<YTransaction> Function(Pointer<YDoc>, int, Pointer<Uint8>) ydocWriteTransaction;
  final void Function(Pointer<YTransaction>) ytransactionCommit;
  final Pointer<Uint8> Function(Pointer<YTransaction>, Pointer<Uint32>) ytransactionStateVectorV1;
  final Pointer<Uint8> Function(Pointer<YTransaction>, Pointer<Uint8>, int, Pointer<Uint32>) ytransactionStateDiffV1;
  final int Function(Pointer<YTransaction>, Pointer<Uint8>, int) ytransactionApply;
  final void Function(Pointer<Uint8>, int) ybinaryDestroy;
  final void Function(Pointer<Uint8>) ystringDestroy;
  final Pointer<Branch> Function(Pointer<YDoc>, Pointer<Uint8>) ymap;
  final Pointer<Branch> Function(Pointer<YDoc>, Pointer<Uint8>) ytext;
  final Pointer<Uint8> Function(Pointer<Branch>, Pointer<YTransaction>) ybranchJson;
  final Pointer<YOutput> Function(Pointer<Branch>, Pointer<YTransaction>, Pointer<Uint8>) ymapGet;
  final Pointer<Uint8> Function(Pointer<Branch>, Pointer<YTransaction>, Pointer<Uint8>) ymapGetJson;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, Pointer<Uint8>, Pointer<YInput>) ymapInsert;
  final int Function(Pointer<Branch>, Pointer<YTransaction>, Pointer<Uint8>) ymapRemove;
  final Pointer<Branch> Function(Pointer<YOutput>) youtputReadYMap;
  final Pointer<Branch> Function(Pointer<YOutput>) youtputReadYText;
  final void Function(Pointer<YOutput>) youtputDestroy;
  final YInput Function(Pointer<Uint8>) yinputJson;
  final YInput Function(double) yinputFloat;
  final YInput Function(Pointer<Uint8>) yinputString;
  final YInput Function(Pointer<Uint8>) yinputYText;
  final YInput Function(Pointer<Pointer<Uint8>>, Pointer<YInput>, int) yinputYMap;
  final Pointer<Uint8> Function(Pointer<Branch>, Pointer<YTransaction>) ytextString;
  final int Function(Pointer<Branch>, Pointer<YTransaction>) ytextLen;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, int, Pointer<Uint8>, Pointer<YInput>) ytextInsert;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, int, int, Pointer<YInput>) ytextFormat;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, int, int) ytextRemoveRange;
  final Pointer<YChunk> Function(Pointer<Branch>, Pointer<YTransaction>, Pointer<Uint32>) ytextChunks;
  final void Function(Pointer<YChunk>, int) ychunksDestroy;
  final Pointer<YUndoManager> Function(Pointer<YUndoManagerOptions>) yundoManager;
  final void Function(Pointer<YUndoManager>) yundoManagerDestroy;
  final void Function(Pointer<YUndoManager>, Pointer<YDoc>, Pointer<Branch>) yundoManagerAddScope;
  final void Function(Pointer<YUndoManager>, int, Pointer<Uint8>) yundoManagerAddOrigin;
  final void Function(Pointer<YUndoManager>, int, Pointer<Uint8>) yundoManagerRemoveOrigin;
  final void Function(Pointer<YUndoManager>) yundoManagerStop;
  final int Function(Pointer<YUndoManager>) yundoManagerUndo;
  final int Function(Pointer<YUndoManager>) yundoManagerRedo;
  final int Function(Pointer<YUndoManager>) yundoManagerUndoStackLen;
  final int Function(Pointer<YUndoManager>) yundoManagerRedoStackLen;
  final Pointer<YPendingUpdate> Function(Pointer<YTransaction>) ytransactionPendingUpdate;
  final void Function(Pointer<YPendingUpdate>) ypendingUpdateDestroy;
  final Pointer<YIdSet> Function(Pointer<YTransaction>) ytransactionPendingDs;
  final void Function(Pointer<YIdSet>) ydeleteSetDestroy;
  final Pointer<Branch> Function(Pointer<YDoc>, Pointer<Uint8>) yarray;
  final int Function(Pointer<Branch>) yarrayLen;
  final Pointer<Uint8> Function(Pointer<Branch>, Pointer<YTransaction>, int) yarrayGetJson;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, int, Pointer<YInput>, int) yarrayInsertRange;
  final void Function(Pointer<Branch>, Pointer<YTransaction>, int, int) yarrayRemoveRange;
}

const int yOffsetUtf16 = 1;
const int yCleanupFmt = 1 << 4;
const int yJsonBool = -8;
const int yJsonNum = -7;
const int yJsonInt = -6;
const int yJsonString = -5;
