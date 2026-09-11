import './shims.js';
import * as Y from 'yjs';
import { u8ToB64, b64ToU8 } from './base64.js';

const docs = new Map();   // clientId -> { doc, outbox: string[] }

function need(clientId) {
  const entry = docs.get(clientId);
  if (!entry) throw new Error('no doc for clientId ' + clientId);
  return entry;
}

// Task 20: undo-related handlers require the caller to have opened this
// document with `undo: true` (see createDoc). A lazily-built UndoManager was
// tried first and measured against yjs_runtime_test.dart's self-registration
// regression test — that test creates content BEFORE calling any
// undo-related op, so a manager built on first undo-call missed that
// content's transactions and undo() silently found an empty stack. An
// explicit opt-in, resolved at open time, is what makes a forgotten opt-in
// fail loudly (calling an undo op on a null manager throws) rather than
// silently costing undo history or perturbing bytes on documents that never
// asked for undo at all.
function needUndo(clientId) {
  const entry = need(clientId);
  if (!entry.undoManager) {
    throw new Error(
      'no UndoManager for clientId ' + clientId + ' — open this document with undo: true',
    );
  }
  return entry.undoManager;
}

const handlers = {
  createDoc({ clientId, undo = false }) {
    // `Doc` takes no clientID option (verified against yjs 13.6.32 source,
    // dist/yjs.cjs:459). Assigning the property immediately after construction,
    // before any content exists, is what pins it: clientID is read when an Item
    // is created.
    const doc = new Y.Doc();
    doc.clientID = clientId;
    const objects = doc.getMap('objects');
    // Task 20: the UndoManager is now built only when the caller opts in via
    // `undo`, and built eagerly (right here, before any content exists) when
    // it does. Commit 0d61a38270 started building one for every document,
    // unconditionally, so axis 2 could exercise undo — but an UndoManager's
    // after-transaction handler keeps a tombstoned struct alive only for
    // transactions whose origin it tracks (yjs.cjs:3662-3670's guard, with
    // the keepItem call at :3704-3706), and a document's own local writes are
    // tracked while the same content arriving as someone else's remote
    // update is not. That asymmetry perturbs `encodeStateAsUpdate` for any
    // document carrying an UndoManager it never needed — see S5.2 in
    // task-20-report.md, where it cost two peers their byte-identical
    // result. A lazily-built manager (construct on first undo-related call)
    // was tried and rejected: yjs_runtime_test.dart's self-registration
    // regression test creates content before ever calling an undo op, so a
    // manager built that late has an empty stack and silently loses undo
    // history — worse than the perturbation it would have fixed.
    const undoManager = undo
      ? (() => {
          const um = new Y.UndoManager(objects, { captureTimeout: 500 });
          um.trackedOrigins.add('local');
          return um;
        })()
      : null;
    const entry = {
      doc,
      objects,
      undoManager,
      operationOrigin: 'local',
      outbox: [],
    };
    doc.on('update', (update, origin) => {
      // Yjs emits 'update' for remote applications too (dist/yjs.cjs:3385-3390
      // gates only on hasContent, not on transaction.local or origin). Without
      // this filter a client re-broadcasts content it merely received, which
      // inflates server sequence numbers and corrupts the arrival-order
      // measurements this project exists to make.
      // UndoManager-originated updates and custom tracked origins are local
      // writes too. Only updates explicitly applied with the remote marker
      // must stay out of the outbox.
      if (origin !== 'remote') entry.outbox.push(u8ToB64(update));
    });
    docs.set(clientId, entry);
    return { clientId: doc.clientID };
  },

  drainOutbox({ clientId }) {
    const entry = need(clientId);
    const drained = entry.outbox;
    entry.outbox = [];
    return { updates: drained };
  },

  applyUpdate({ clientId, updateB64, origin }) {
    const entry = need(clientId);
    Y.applyUpdate(entry.doc, b64ToU8(updateB64), origin ?? 'remote');
    return {};
  },

  setOperationOrigin({ clientId, origin }) {
    need(clientId).operationOrigin = origin;
    return {};
  },

  setTrackedOrigins({ clientId, origins }) {
    const um = needUndo(clientId);
    um.trackedOrigins.clear();
    // Yjs's UndoManager registers ITSELF in trackedOrigins in its constructor
    // (dist/yjs.cjs:3632), and its capture guard (:3667) tests
    // trackedOrigins.has(transaction.origin). It sets transaction.origin to
    // itself when applying an undo, so without re-adding it here the manager
    // cannot recognise its own undo transaction and never pushes it onto the
    // redo stack — redo silently stops working for the rest of this doc's life,
    // and any scenario reading a false `didRedo` would mistake that for a
    // finding about supersession.
    um.trackedOrigins.add(um);
    for (const origin of origins) um.trackedOrigins.add(origin);
    return {};
  },

  stopCapturing({ clientId }) {
    needUndo(clientId).stopCapturing();
    return {};
  },

  undo({ clientId }) {
    const manager = needUndo(clientId);
    const changed = manager.undoStack.length > 0;
    manager.undo();
    return { changed };
  },

  redo({ clientId }) {
    const manager = needUndo(clientId);
    const changed = manager.redoStack.length > 0;
    manager.redo();
    return { changed };
  },

  undoStackLength({ clientId }) {
    return { length: needUndo(clientId).undoStack.length };
  },

  redoStackLength({ clientId }) {
    return { length: needUndo(clientId).redoStack.length };
  },

  createObject({ clientId, objectId, kind, box, src }) {
    const entry = need(clientId);
    const objects = entry.doc.getMap('objects');
    entry.doc.transact(() => {
      const obj = new Y.Map();
      objects.set(objectId, obj);
      obj.set('kind', kind);
      for (const k of ['x', 'y', 'w', 'h', 'rotation', 'z']) obj.set(k, box[k]);
      if (kind === 'title') obj.set('text', new Y.Text());
      if (kind === 'image') obj.set('src', src ?? '');
    }, entry.operationOrigin);
    return {};
  },

  setField({ clientId, objectId, key, value }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    if (obj === undefined) throw new Error('no object ' + objectId);
    entry.doc.transact(() => { obj.set(key, value); }, entry.operationOrigin);
    return {};
  },

  setFields({ clientId, writes }) {
    const entry = need(clientId);
    const objects = entry.doc.getMap('objects');
    entry.doc.transact(() => {
      for (const write of writes) {
        const obj = objects.get(write.objectId);
        if (obj === undefined) throw new Error('no object ' + write.objectId);
        obj.set(write.key, write.value);
      }
    }, entry.operationOrigin);
    return {};
  },

  insertText({ clientId, objectId, index, text }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    if (obj === undefined) throw new Error('no object ' + objectId);
    entry.doc.transact(() => { obj.get('text').insert(index, text); }, entry.operationOrigin);
    return {};
  },

  deleteText({ clientId, objectId, index, length }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    entry.doc.transact(() => { obj.get('text').delete(index, length); }, entry.operationOrigin);
    return {};
  },

  formatText({ clientId, objectId, index, length, attrs }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    entry.doc.transact(() => { obj.get('text').format(index, length, attrs); }, entry.operationOrigin);
    return {};
  },

  deleteObject({ clientId, objectId }) {
    const entry = need(clientId);
    entry.doc.transact(() => { entry.doc.getMap('objects').delete(objectId); }, entry.operationOrigin);
    return {};
  },

  // Task 21: the length Y.Text itself reports, in whatever unit it counts in.
  // Y.Text.length is the sum of its items' `length`, and a ContentString's
  // length is `str.length` — a JS string's UTF-16 code-unit count. Reported,
  // not asserted: the test prints it beside Dart's String.length and
  // characters.length and lets the numbers say what an index means.
  textLength({ clientId, objectId }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    if (obj === undefined) throw new Error('no object ' + objectId);
    return { length: obj.get('text').length };
  },

  projection({ clientId }) {
    const entry = need(clientId);
    const out = {};
    entry.doc.getMap('objects').forEach((obj, objectId) => {
      const kind = obj.get('kind');
      const text = kind === 'title' ? obj.get('text') : null;
      out[objectId] = {
        kind,
        x: obj.get('x') ?? 0,
        y: obj.get('y') ?? 0,
        w: obj.get('w') ?? 0,
        h: obj.get('h') ?? 0,
        rotation: obj.get('rotation') ?? 0,
        z: obj.get('z') ?? 0,
        text: text === null ? null : text.toString(),
        delta: text === null ? null : text.toDelta(),
        src: kind === 'image' ? (obj.get('src') ?? '') : null,
      };
    });
    return {
      clientId: entry.doc.clientID,
      objects: out,
      stateVectorB64: u8ToB64(Y.encodeStateVector(entry.doc)),
    };
  },

  encodeStateAsUpdate({ clientId }) {
    return { updateB64: u8ToB64(Y.encodeStateAsUpdate(need(clientId).doc)) };
  },

  // Capability.decodeUpdate — Yjs can do this; `yffi` exposes no equivalent,
  // which is why this is gated rather than assumed (ticket 17 §9).
  decodeUpdate({ updateB64 }) {
    const decoded = Y.decodeUpdate(b64ToU8(updateB64));
    const summaries = decoded.structs.map(
      (s) => {
        const contentName = s.content && s.content.constructor
          ? s.content.constructor.name
          : '';
        return `${s.constructor.name} content=${contentName} id=${s.id.client}:${s.id.clock} len=${s.length}`;
      },
    );
    return { structCount: decoded.structs.length, summaries };
  },

  // Capability.countPendingStructs — S5.1's observation point.
  //
  // DEVIATION from the brief, in two parts, both confirmed empirically against
  // yjs 13.6.32 by withholding a causal dependency and inspecting the live
  // store (see task-3-report.md):
  //
  // 1. `doc.store.pendingStructs` is not `{ clients: Map<clientId, struct[]> }`
  //    (dist/yjs.cjs:2828 and the assignment sites around readUpdateV2). It is
  //    `{ missing: Map<client, clock>, update: Uint8Array } | null` — `update`
  //    holds the structs that arrived but could not be integrated because a
  //    causal dependency is missing; `missing` counts distinct blocked clients,
  //    not structs.
  // 2. `pending.update` is written with `new UpdateEncoderV2()`
  //    (dist/yjs.cjs:1657), i.e. V2 wire format — but `Y.decodeUpdate` is
  //    `decodeUpdateV2(update, UpdateDecoderV1)` (dist/yjs.cjs:3952), a V1
  //    *decoder*. Feeding it V2 bytes does not throw; it silently produces zero
  //    structs, which is what the first version of this handler returned even
  //    while `pending.update.length` was demonstrably non-zero. `Y.decodeUpdateV2`
  //    (no second argument, defaulting to `UpdateDecoderV2`) is the matching
  //    decoder for this buffer.
  pendingStructCount({ clientId }) {
    const pending = need(clientId).doc.store.pendingStructs;
    if (!pending) return { count: 0 };
    const decoded = Y.decodeUpdateV2(pending.update);
    return { count: decoded.structs.length };
  },

  // Kept from Task 1 unchanged — still relied on by yjs_bootstrap_test.dart's
  // convergence assertion; superseded for new code by `projection`, which
  // reads the same field but never auto-creates the object.
  readText({ clientId, objectId }) {
    const entry = need(clientId);
    const obj = entry.doc.getMap('objects').get(objectId);
    return { text: obj === undefined ? null : obj.get('text').toString() };
  },

  yjsVersion() {
    return { hasYText: typeof Y.Text === 'function', hasYMap: typeof Y.Map === 'function' };
  },
};

globalThis.__probe = {
  call(requestJson) {
    try {
      const req = JSON.parse(requestJson);
      const fn = handlers[req.op];
      if (!fn) return JSON.stringify({ ok: false, error: 'unknown op: ' + req.op });
      return JSON.stringify({ ok: true, result: fn(req) });
    } catch (e) {
      // Carry-forward fix from Task 1: this QuickJS build's Error.prototype.stack
      // does not prepend a "Name: message" header the way V8 does, so a thrown
      // error surfaced via `e.stack` alone can arrive with its message missing.
      // Verified against this engine: a `new Error('no object x')` here yields
      // `e.stack === '    at ...'` with no leading "Error: no object x" line, and
      // a plain `throw new Error(...)` with no name override yields `e.name ===
      // 'Error'`. Building the label from name+message explicitly, with the
      // stack appended only as extra context, keeps the message present.
      const name = (e && e.name) || 'Error';
      const msg = (e && e.message) || String(e);
      const stack = (e && e.stack) ? '\n' + e.stack : '';
      return JSON.stringify({ ok: false, error: name + ': ' + msg + stack });
    }
  },
};
