import 'dart:convert';
import 'dart:typed_data';

import '../../core/capability.dart';
import '../../core/field_write.dart';
import '../../core/ids.dart';
import '../../core/projection.dart';
import '../crdt_runtime.dart';

/// yata-core ticket 01: a prototype of **Rule A** — "an insertion lands
/// immediately to the right of its anchor", applied in server sequence
/// order, with no YATA integration loop and no `clientID` tie-break,
/// because the server never ties. Predecessor ticket 15 §3/§4's decided
/// scheme is reused: a character identity is `(session, counter)`, one
/// UTF-16 code unit; deletion tombstones rather than removes; an insertion
/// carries only its anchor, its first identity and the string, and later
/// identities are computed by offset.
///
/// Text insert/delete only. `formatText` and undo are deliberately
/// unimplemented — ticket 05 and ticket 06's territory — and no scenario in
/// this file's sibling scenarios calls them.
///
/// ## The canonical/pending split this runtime actually needs
///
/// Ticket 15 §2's model is "Local Projected View = Canonical Store
/// (advanced only by *sequenced* operations, applied in sequence order)
/// with the Pending Journal (this participant's own not-yet-sequenced
/// operations) replayed over it." This runtime implements exactly that,
/// per character:
///
/// - A character's `seq` is `null` while it is *this client's own* not-yet
///   -acknowledged insertion — it is in the Pending Journal.
/// - A character's `seq` is the server's envelope `seq` once it is known to
///   be durable — either because it arrived as a genuinely remote envelope
///   (which always carries a real `seq`), or because this client's own
///   pending character was *promoted*: the same envelope came back to its
///   own author (see below) and told it the truth.
/// - Rendering a text object is: sort every character by `(seq ?? +∞,
///   seq == null ? counter : 0)` ascending, then splice each one
///   immediately to the right of its anchor, in that order. Because every
///   already-sequenced character sorts before every still-pending one, this
///   single pass *is* "canonical, then pending replayed over it" — there is
///   no second data structure to keep in sync.
///
/// **Why [applyUpdate] needs [seq] at all**, unlike Yjs/Yrs: their updates
/// are commutative, so no external order ever has to reach the runtime.
/// Rule A is not commutative in that sense — "immediately right of its
/// anchor" only has one meaning once you know which of two anchor-sharing
/// insertions was *later*-sequenced — so the true total order has to be
/// visible to `applyUpdate`. `CrdtRuntime.applyUpdate`'s `seq` parameter
/// exists for exactly this runtime; see its doc comment.
///
/// **Why a character's own author needs its envelope back.**
/// `InMemoryPostOffice.send` never delivers an envelope to its own author,
/// so the ordinary `receiveAll`/`receiveReversed` path never tells a client
/// what its own operation's `seq` turned out to be. Nothing about that
/// operation's *content* needs telling — the author already applied it —
/// but its *position relative to a concurrent peer* does, whenever the
/// peer's insertion turned out to be earlier-sequenced. This runtime
/// resolves that the same way a real client would resync after being
/// offline: `ProbeClient.resyncFromServer` calls `ThinServer.since(0..)`,
/// which is not author-filtered, so it hands every client — including an
/// operation's own author — every envelope in the log, itself included.
/// Calling `resyncFromServer` is therefore how this prototype's own
/// scenarios model "the moment authorization is judged" and an
/// unacknowledged character's provisional position is corrected. This is a
/// property of how the *scenario* drives the existing harness, not a new
/// wire mechanism — see the reflow scenario for where it matters.
///
/// ## Wire encoding
///
/// This prototype's own business (ticket 01's own words) — JSON, UTF-8
/// encoded, one object per operation. Nothing downstream decodes it except
/// this runtime's own [decodeUpdate] and [applyUpdate].
class PromeoRuntime implements CrdtRuntime {
  PromeoRuntime._();

  static Future<PromeoRuntime> create() async => PromeoRuntime._();

  final Map<int, _PromeoDoc> _docs = {};

  @override
  String get name => 'promeo-rule-a';

  @override
  CapabilitySet get capabilities => const CapabilitySet.of({
        Capability.decodeUpdate,
      });

  @override
  Future<void> open(ClientId c, {bool undo = false}) async {
    if (undo) {
      throw UnsupportedError(
        'PromeoRuntime has no undo -- ticket 06\'s territory, not built here',
      );
    }
    _docs[c.value] = _PromeoDoc(session: c.value);
  }

  @override
  Future<void> close(ClientId c) async {
    _docs.remove(c.value);
  }

  _PromeoDoc _require(ClientId c) =>
      _docs[c.value] ?? (throw StateError('no Promeo document for client ${c.value}'));

  @override
  Future<void> applyUpdate(
    ClientId c,
    Uint8List update, {
    String origin = 'remote',
    int? seq,
  }) async {
    if (update.isEmpty) return;
    if (seq == null) {
      throw ArgumentError(
        'PromeoRuntime.applyUpdate requires seq -- Rule A has no meaning '
        'without the server total order (see the class doc comment)',
      );
    }
    final op = jsonDecode(utf8.decode(update)) as Map<String, dynamic>;
    _require(c).apply(op, seq);
  }

  @override
  Future<List<Uint8List>> drainOutbox(ClientId c) async {
    final doc = _require(c);
    final out = List<Uint8List>.from(doc.outbox);
    doc.outbox.clear();
    return out;
  }

  @override
  Future<Uint8List> encodeStateAsUpdate(ClientId c) async =>
      utf8.encode(jsonEncode(_require(c).canonicalSnapshot()));

  @override
  Future<DocProjection> projection(ClientId c) async {
    final doc = _require(c);
    return DocProjection(
      clientId: ClientId(doc.session),
      objects: doc.projectAll(),
      stateVectorB64:
          base64Encode(utf8.encode(jsonEncode({'lastKnownSeq': doc.highestSeqSeen}))),
    );
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
    _require(c).createObjectLocal(id, kind, x: x, y: y, w: w, h: h, rotation: rotation, z: z, src: src);
  }

  @override
  Future<void> setField(ClientId c, ObjectId id, String key, num value) async {
    _require(c).setFieldLocal(id, key, value);
  }

  @override
  Future<void> setFields(ClientId c, List<FieldWrite> writes) async {
    final doc = _require(c);
    for (final w in writes) {
      doc.setFieldLocal(w.objectId, w.key, w.value);
    }
  }

  @override
  Future<void> insertText(ClientId c, ObjectId id, int index, String text) async {
    _require(c).insertTextLocal(id, index, text);
  }

  @override
  Future<void> deleteText(ClientId c, ObjectId id, int index, int length) async {
    _require(c).deleteTextLocal(id, index, length);
  }

  @override
  Future<void> formatText(
    ClientId c,
    ObjectId id,
    int index,
    int length,
    Map<String, Object?> attrs,
  ) async {
    throw UnsupportedError(
      'PromeoRuntime has no formatting -- ticket 05\'s territory, not built here',
    );
  }

  @override
  Future<void> deleteObject(ClientId c, ObjectId id) async {
    _require(c).deleteObjectLocal(id);
  }

  @override
  Future<int> textLength(ClientId c, ObjectId id) async => _require(c).visibleText(id).length;

  @override
  Future<DecodedUpdate> decodeUpdate(Uint8List update) async {
    final op = jsonDecode(utf8.decode(update)) as Map<String, dynamic>;
    final kind = op['op'] as String;
    final summary = switch (kind) {
      'ins' => 'insert ${(op['units'] as List).length} unit(s), session '
          '${op['session']} starting at counter ${op['start']}, anchor '
          '${op['anchor']}',
      'del' => 'delete ${(op['ids'] as List).length} identity(ies): '
          '${(op['ids'] as List).join(', ')}',
      'setField' =>
        'setField ${op['objectId']}.${op['key']} = ${op['value']} (session '
            '${op['session']}, counter ${op['counter']})',
      'createObject' => 'createObject ${op['objectId']} (${op['kind']})',
      'deleteObject' => 'deleteObject ${op['objectId']}',
      _ => 'unrecognized op "$kind"',
    };
    return DecodedUpdate(structCount: 1, summaries: [summary]);
  }

  @override
  Future<int> pendingStructCount(ClientId c) async => throw UnsupportedError(
        'PromeoRuntime does not enumerate pending structs -- '
        'Capability.countPendingStructs is not claimed',
      );
}

/// One canonical character. Immutable identity per predecessor ticket 15
/// §3: `(session, counter)`, one UTF-16 code unit. [seq] is `null` exactly
/// while this is the character's own author's Pending Journal entry.
class _Char {
  _Char({
    required this.session,
    required this.counter,
    required this.unit,
    required this.anchor,
  });

  final int session;
  final int counter;
  final int unit;

  /// Identity of the character this one was inserted immediately right of,
  /// or [_start] for "beginning of the text".
  final String anchor;

  int? seq;
  bool tombstone = false;

  String get id => '$session:$counter';
}

/// Sentinel anchor meaning "beginning of the text" -- never a real
/// `session:counter` pair, so it can never collide with one.
const _start = '^';

class _TextDoc {
  final Map<String, _Char> byId = {};
  int _nextCounter = 1;

  int _allocCounter() => _nextCounter++;

  /// Ascending: every sequenced character before every still-pending one;
  /// among two sequenced characters, by `seq`; among two pending characters
  /// (always the same author -- see the class doc comment on why a client
  /// is never pending on anyone else's behalf), by authoring order
  /// (`counter`). This ordering, replayed as "splice right of anchor" in
  /// one pass, is "canonical folded, then pending folded over it" in a
  /// single sort -- see PromeoRuntime's class doc comment.
  int _compare(_Char a, _Char b) {
    final aSeq = a.seq, bSeq = b.seq;
    if (aSeq != null && bSeq != null) {
      if (aSeq != bSeq) return aSeq.compareTo(bSeq);
      // Same seq means the same envelope -- a multi-character insert stamps
      // every character it created with one seq. Tie-break by counter so
      // each character's anchor (the previous character of that same
      // insert) is guaranteed already placed: `sort` is not guaranteed
      // stable, and without this a same-seq group could be visited in an
      // order that puts a character before its own anchor.
      return a.counter.compareTo(b.counter);
    }
    if (aSeq == null && bSeq == null) return a.counter.compareTo(b.counter);
    return aSeq == null ? 1 : -1;
  }

  /// Rebuilds the full order (tombstones included) from scratch every call.
  /// Deliberately not incremental: a prototype whose subject is "is the
  /// order right", not "is the order fast" (ticket 08 owns performance),
  /// and a from-scratch replay can't accumulate a stale invariant.
  ///
  /// **Not a single sorted pass.** A first version sorted every character
  /// once by `(seq ?? +∞, counter)` and spliced in that order -- correct
  /// whenever a character's anchor is either already-canonical or an
  /// earlier pending character of the same author, which is the case ticket
  /// 15 §2's own two-party worked example assumes (it starts from an
  /// already-settled base). It is not the general case: a participant's
  /// *own* not-yet-acknowledged character (still `seq == null` in their own
  /// view) can be the anchor a **remote, already-sequenced** operation
  /// names -- this happens the first time this prototype's reflow scenario
  /// runs it, when a peer's reply anchors onto the seed text before its own
  /// author has been told the seed itself is durable. Sorting pending
  /// characters to "after everything canonical" then visits the remote
  /// operation before its own anchor is placed, and the splice has nowhere
  /// to go.
  ///
  /// This instead builds the order by repeatedly placing whichever
  /// not-yet-placed character has the smallest `(seq ?? +∞, counter)` key
  /// **among those whose anchor is already placed** -- a priority-respecting
  /// topological build. It still prefers a lower `seq` over a pending
  /// character (Rule A: later-sequenced lands nearer the anchor), and still
  /// resolves same-seq or same-pending-author ties by `counter`; it simply
  /// no longer assumes anchors become available in that same order.
  List<_Char> _orderedAll() {
    final placed = <String>[_start];
    final position = <String, int>{_start: 0};
    final remaining = byId.values.toList();
    while (remaining.isNotEmpty) {
      _Char? best;
      for (final ch in remaining) {
        if (!position.containsKey(ch.anchor)) continue;
        if (best == null || _compare(ch, best) < 0) best = ch;
      }
      if (best == null) {
        throw StateError(
          'PromeoRuntime: ${remaining.length} character(s) never became '
          'placeable -- every one of them anchors to something not yet '
          'placed. Under a gapless server order this should be impossible; '
          'this means an anchor was referenced before it was ever created.',
        );
      }
      final at = position[best.anchor]! + 1;
      placed.insert(at, best.id);
      position.updateAll((id, pos) => pos >= at ? pos + 1 : pos);
      position[best.id] = at;
      remaining.remove(best);
    }
    return [for (final id in placed.skip(1)) byId[id]!];
  }

  List<_Char> visibleOrder() => _orderedAll().where((c) => !c.tombstone).toList();

  String visibleText() => String.fromCharCodes(visibleOrder().map((c) => c.unit));

  /// The identity to anchor a new insertion at local visible [index] to.
  String anchorForIndex(int index) {
    if (index <= 0) return _start;
    final visible = visibleOrder();
    if (index - 1 >= visible.length) {
      throw RangeError('index $index beyond visible length ${visible.length}');
    }
    return visible[index - 1].id;
  }

  Map<String, Object?> toSnapshotJson() => {
        'chars': [
          for (final c in byId.values.toList()
            ..sort((a, b) {
              final s = a.session.compareTo(b.session);
              return s != 0 ? s : a.counter.compareTo(b.counter);
            }))
          {
            'id': c.id,
            'unit': c.unit,
            'anchor': c.anchor,
            'seq': c.seq,
            'tombstone': c.tombstone,
          },
      ],
      };
}

class _FieldSlot {
  num value;
  int? authoritySeq;
  int? _pendingSession;
  int? _pendingCounter;

  _FieldSlot(this.value);

  /// Local, optimistic write: always visible immediately, and always wins
  /// until either an equal-or-later remote write arrives or this write's
  /// own envelope comes back with its seq (see [applyRemote]).
  void applyLocal(num v, int session, int counter) {
    value = v;
    authoritySeq = null;
    _pendingSession = session;
    _pendingCounter = counter;
  }

  /// A write learned through an envelope, sequenced. If it is this slot's
  /// own still-pending write being confirmed, it always takes the seq
  /// (idempotent, value already showing). Otherwise last-write-wins by
  /// `seq`, so field convergence does not depend on arrival order --
  /// mirrors the character comparator's rule, at field granularity.
  void applyRemote(num v, int session, int counter, int seq) {
    final isOwnPendingConfirm = _pendingSession == session &&
        _pendingCounter == counter &&
        authoritySeq == null;
    if (isOwnPendingConfirm) {
      authoritySeq = seq;
      return;
    }
    if (authoritySeq == null || seq >= authoritySeq!) {
      value = v;
      authoritySeq = seq;
      _pendingSession = null;
      _pendingCounter = null;
    }
  }
}

class _PromeoObject {
  _PromeoObject({required this.kind, this.textDoc});

  final ObjectKind kind;
  final _TextDoc? textDoc;
  final Map<String, _FieldSlot> fields = {};
  bool deleted = false;
  String? src;

  num field(String key, num fallback) => fields[key]?.value ?? fallback;
}

class _PromeoDoc {
  _PromeoDoc({required this.session});

  final int session;
  final Map<String, _PromeoObject> objects = {};
  final List<Uint8List> outbox = [];
  int _nextFieldCounter = 1;
  int highestSeqSeen = 0;

  Uint8List _encode(Map<String, Object?> op) => utf8.encode(jsonEncode(op));

  _TextDoc _textDocOf(ObjectId id) {
    final obj = objects[id.value];
    if (obj == null) throw StateError('no object ${id.value}');
    final t = obj.textDoc;
    if (t == null) throw StateError('object ${id.value} has no text');
    return t;
  }

  String visibleText(ObjectId id) => _textDocOf(id).visibleText();

  void createObjectLocal(
    ObjectId id,
    ObjectKind kind, {
    required double x,
    required double y,
    required double w,
    required double h,
    double rotation = 0,
    double z = 0,
    String? src,
  }) {
    final obj = _PromeoObject(
      kind: kind,
      textDoc: kind == ObjectKind.title ? _TextDoc() : null,
    )..src = src;
    obj.fields['x'] = _FieldSlot(x);
    obj.fields['y'] = _FieldSlot(y);
    obj.fields['w'] = _FieldSlot(w);
    obj.fields['h'] = _FieldSlot(h);
    obj.fields['rotation'] = _FieldSlot(rotation);
    obj.fields['z'] = _FieldSlot(z);
    objects[id.value] = obj;
    outbox.add(_encode({
      'op': 'createObject',
      'objectId': id.value,
      'kind': kind.name,
      'x': x,
      'y': y,
      'w': w,
      'h': h,
      'rotation': rotation,
      'z': z,
      'src': src,
    }));
  }

  void setFieldLocal(ObjectId id, String key, num value) {
    final obj = objects[id.value] ?? (throw StateError('no object ${id.value}'));
    final counter = _nextFieldCounter++;
    (obj.fields[key] ??= _FieldSlot(value)).applyLocal(value, session, counter);
    outbox.add(_encode({
      'op': 'setField',
      'objectId': id.value,
      'key': key,
      'value': value,
      'session': session,
      'counter': counter,
    }));
  }

  void deleteObjectLocal(ObjectId id) {
    final obj = objects[id.value];
    if (obj != null) obj.deleted = true;
    outbox.add(_encode({'op': 'deleteObject', 'objectId': id.value}));
  }

  void insertTextLocal(ObjectId id, int index, String text) {
    if (text.isEmpty) return;
    final textDoc = _textDocOf(id);
    final externalAnchor = textDoc.anchorForIndex(index);
    final units = text.codeUnits;
    final startCounter = textDoc._allocCounter();
    for (var i = 1; i < units.length; i++) {
      textDoc._allocCounter();
    }
    var anchor = externalAnchor;
    for (var i = 0; i < units.length; i++) {
      final counter = startCounter + i;
      final ch = _Char(session: session, counter: counter, unit: units[i], anchor: anchor);
      textDoc.byId[ch.id] = ch;
      anchor = ch.id;
    }
    outbox.add(_encode({
      'op': 'ins',
      'objectId': id.value,
      'session': session,
      'start': startCounter,
      'units': units,
      'anchor': externalAnchor,
    }));
  }

  void deleteTextLocal(ObjectId id, int index, int length) {
    if (length <= 0) return;
    final textDoc = _textDocOf(id);
    final visible = textDoc.visibleOrder();
    final removed = visible.sublist(index, index + length);
    for (final ch in removed) {
      ch.tombstone = true;
    }
    outbox.add(_encode({
      'op': 'del',
      'objectId': id.value,
      'ids': [for (final ch in removed) ch.id],
    }));
  }

  void apply(Map<String, dynamic> op, int seq) {
    if (seq > highestSeqSeen) highestSeqSeen = seq;
    switch (op['op'] as String) {
      case 'createObject':
        final id = op['objectId'] as String;
        if (objects.containsKey(id)) return; // already known, incl. self-echo
        final kind = ObjectKind.values.byName(op['kind'] as String);
        final obj = _PromeoObject(kind: kind, textDoc: kind == ObjectKind.title ? _TextDoc() : null)
          ..src = op['src'] as String?;
        for (final key in const ['x', 'y', 'w', 'h', 'rotation', 'z']) {
          obj.fields[key] = _FieldSlot((op[key] as num).toDouble());
        }
        objects[id] = obj;
        return;
      case 'deleteObject':
        objects[op['objectId'] as String]?.deleted = true;
        return;
      case 'setField':
        final obj = objects[op['objectId'] as String];
        if (obj == null) return;
        final key = op['key'] as String;
        final slot = obj.fields[key] ??= _FieldSlot((op['value'] as num).toDouble());
        slot.applyRemote(
          op['value'] as num,
          op['session'] as int,
          op['counter'] as int,
          seq,
        );
        return;
      case 'ins':
        final textDoc = _textDocOf(ObjectId(op['objectId'] as String));
        final opSession = op['session'] as int;
        final start = op['start'] as int;
        final units = (op['units'] as List).cast<int>();
        var anchor = op['anchor'] as String;
        for (var i = 0; i < units.length; i++) {
          final counter = start + i;
          final id = '$opSession:$counter';
          final existing = textDoc.byId[id];
          if (existing != null) {
            existing.seq ??= seq;
          } else {
            textDoc.byId[id] = _Char(
              session: opSession,
              counter: counter,
              unit: units[i],
              anchor: anchor,
            )..seq = seq;
          }
          anchor = id;
        }
        return;
      case 'del':
        final textDoc = _textDocOf(ObjectId(op['objectId'] as String));
        for (final id in (op['ids'] as List).cast<String>()) {
          final ch = textDoc.byId[id];
          if (ch != null) ch.tombstone = true;
        }
        return;
      default:
        throw StateError('PromeoRuntime cannot decode op "${op['op']}"');
    }
  }

  Map<ObjectId, ObjectProjection> projectAll() => {
        for (final entry in objects.entries)
          if (!entry.value.deleted)
            ObjectId(entry.key): ObjectProjection(
              kind: entry.value.kind.name,
              x: entry.value.field('x', 0).toDouble(),
              y: entry.value.field('y', 0).toDouble(),
              w: entry.value.field('w', 0).toDouble(),
              h: entry.value.field('h', 0).toDouble(),
              rotation: entry.value.field('rotation', 0).toDouble(),
              z: entry.value.field('z', 0).toDouble(),
              text: entry.value.textDoc?.visibleText(),
              delta: null,
              src: entry.value.src,
            ),
      };

  /// Deterministic regardless of arrival/insertion order -- sorted by
  /// identity, not by iteration order -- so two logically-equal documents
  /// that received the same operations in different orders encode to
  /// byte-identical snapshots. See axis0 S0.3's forward/reversed byte
  /// comparison, which this exists to support.
  Map<String, Object?> canonicalSnapshot() => {
        'objects': {
          for (final key in objects.keys.toList()..sort())
            key: {
              'kind': objects[key]!.kind.name,
              'deleted': objects[key]!.deleted,
              'src': objects[key]!.src,
              'fields': {
                for (final fk in objects[key]!.fields.keys.toList()..sort())
                  fk: objects[key]!.fields[fk]!.value,
              },
              'text': objects[key]!.textDoc?.toSnapshotJson(),
            },
        },
      };
}
