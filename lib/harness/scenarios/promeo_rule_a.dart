import '../../core/ids.dart';
import '../../driver/probe_client.dart';
import '../../driver/script_driver.dart';
import '../../runtime/crdt_runtime.dart';
import '../../transport/in_memory_post_office.dart';
import 'axis0_arrival_order.dart';

/// yata-core ticket 01: the contiguity scenario and the reflow scenario,
/// runnable against any [CrdtRuntime] (used here for both `PromeoRuntime`
/// and `YjsRuntime`, per item 4 of the ticket).
///
/// ## What a "shredded" result looks like -- declared before any result is
/// read, per the ticket's own instruction
///
/// Two writers each type a 3-character burst -- writer 1 types "P","Q","R"
/// in that order, writer 2 types "X","Y","Z" in that order -- at the same
/// anchor. A **contiguous** result has "PQR" appearing as one unbroken,
/// in-order substring of the final text, and likewise "XYZ" -- the two
/// runs may interleave with each other as *blocks*, in either order
/// ("...PQRXYZ..." or "...XYZPQR..."), and that is still contiguous. A
/// **shredded** result is anything else: one writer's characters broken up
/// by the other's, e.g. "...PXQYRZ..." (fully interleaved) or
/// "...PQXYRZ..." (partially interleaved) -- neither "PQR" nor "XYZ"
/// would appear as a substring of a shredded result. [ContiguityRunResult]
/// checks exactly this (`text.contains('PQR')` / `text.contains('XYZ')`),
/// so a pass here is "the run was never broken open", not merely "the
/// characters are all present somewhere".

/// The ack this prototype's own scenarios need and the ordinary
/// `receiveAll`/`receiveReversed`/`resyncFromServer` path cannot give them.
///
/// `InMemoryPostOffice.send` never delivers an envelope to its own author
/// (see that class's doc comment), and `ThinServer.since(lastSeq)` is a
/// strict suffix by `seq` -- once a client's `lastSeq` has advanced past a
/// gap, `since` can never go back and fill it, which is exactly what
/// happens here: a client's own operation can be *earlier*-sequenced than
/// an operation it already received remotely, at which point its own
/// `lastSeq` has already passed the seq its own operation was assigned.
/// Real acknowledgment is a message the server sends straight back to an
/// operation's author at accept time; nothing in this harness's transport
/// models that message, so this reads the same information -- envelopes
/// this client authored, exactly as `ThinServer` recorded them -- directly
/// off `ThinServer.log`, which is already public and already
/// author-inclusive.
Future<void> deliverOwnEnvelopes(ProbeClient client, InMemoryPostOffice po) async {
  final own = po.server.log.where((e) => e.authorId == client.clientId).toList();
  for (final e in own) {
    await client.runtime.applyUpdate(client.clientId, e.payload, seq: e.seq);
  }
  if (own.isEmpty) return;
  final maxSeq = own.map((e) => e.seq).reduce((a, b) => a > b ? a : b);
  if (maxSeq > client.lastSeq) client.lastSeq = maxSeq;
}

const reflowTitle = ObjectId('reflow-title');

/// Ticket 01's own worked example: seed "Hello", both carets at the end,
/// "you" type "A", "peer" types "B", peer's operation is sequenced first.
Future<Map<String, String>> runReflowSingleChar(
  CrdtRuntime runtime,
  ScriptDriver driver,
) async {
  final (you, peer, po) = await pairOn(runtime);

  await driver.step('seed "Hello"; both start from the same base', () async {
    await you.createTitle(reflowTitle, x: 0, y: 0, w: 100, h: 30);
    await you.type(reflowTitle, 0, 'Hello');
    await you.flushOutbox();
    await peer.receiveAll();
  });

  await driver.step(
    'you type "A" at the end (index 5) -- your own optimistic echo, not sent yet',
    () async => you.type(reflowTitle, 5, 'A'),
  );
  driver.note('you see "${(await you.read()).objects[reflowTitle]!.text}"');

  await driver.step(
    'peer types "B" at the end (index 5) -- their own optimistic echo, not sent yet',
    () async => peer.type(reflowTitle, 5, 'B'),
  );
  driver.note('peer sees "${(await peer.read()).objects[reflowTitle]!.text}"');

  await driver.step(
    'peer flushes first, so the server sequences "B" before "A"',
    () => peer.flushOutbox(),
  );
  await driver.step('you flush "A" second', () => you.flushOutbox());

  await driver.step(
    'you receive peer\'s "B" as a remote, already-sequenced operation',
    () => you.receiveAll(),
  );
  driver.note(
    'you now see "${(await you.read()).objects[reflowTitle]!.text}" -- '
    'your own pending "A" is still unacknowledged, and (correctly, since it '
    'really is the later-sequenced one) already sits nearest the anchor',
  );

  await driver.step(
    'peer receives your "A" as a remote, already-sequenced operation',
    () => peer.receiveAll(),
  );
  driver.note(
    'peer now sees "${(await peer.read()).objects[reflowTitle]!.text}" -- '
    'peer\'s own pending "B" is STILL treated as the latest thing, but it '
    'is not -- this is a provisional, not-yet-corrected view',
  );

  await driver.step(
    'peer\'s own envelope comes back to them -- this prototype\'s stand-in '
    'for the moment the server\'s acceptance of "B" becomes known to its own '
    'author (see promeo_runtime.dart\'s class doc comment on why the '
    'ordinary receive path never delivers this)',
    () => deliverOwnEnvelopes(peer, po),
  );
  driver.note(
    'peer now sees "${(await peer.read()).objects[reflowTitle]!.text}" -- '
    'their "B" has shifted one position right',
  );

  await driver.step(
    'your own envelope comes back to you too, for symmetry',
    () => deliverOwnEnvelopes(you, po),
  );
  driver.note(
    'you still see "${(await you.read()).objects[reflowTitle]!.text}" -- '
    'confirms nothing of yours moved',
  );

  return {
    'you': (await you.read()).objects[reflowTitle]!.text!,
    'peer': (await peer.read()).objects[reflowTitle]!.text!,
  };
}

/// The burst variant item 3 asks for: this time "peer" types a whole
/// 3-character run, and "you" — deliberately sequenced *first* this time,
/// the opposite role from the single-character case — end up shifting by
/// the *length of peer's whole run* rather than by one character.
Future<Map<String, String>> runReflowBurst(
  CrdtRuntime runtime,
  ScriptDriver driver,
) async {
  final (you, peer, po) = await pairOn(runtime);

  await driver.step('seed "Hello"; both start from the same base', () async {
    await you.createTitle(reflowTitle, x: 0, y: 0, w: 100, h: 30);
    await you.type(reflowTitle, 0, 'Hello');
    await you.flushOutbox();
    await peer.receiveAll();
  });

  await driver.step(
    'you type a single "A" at the end -- your own optimistic echo',
    () => you.type(reflowTitle, 5, 'A'),
  );
  driver.note('you see "${(await you.read()).objects[reflowTitle]!.text}"');

  await driver.step(
    'peer types a 3-character burst "X","Y","Z" at the end, one keystroke '
    'at a time -- their own optimistic echo, each chained to the last',
    () async {
      await peer.type(reflowTitle, 5, 'X');
      await peer.type(reflowTitle, 6, 'Y');
      await peer.type(reflowTitle, 7, 'Z');
    },
  );
  driver.note('peer sees "${(await peer.read()).objects[reflowTitle]!.text}"');

  await driver.step(
    'this time YOU flush first, so the server sequences your single "A" '
    'BEFORE peer\'s whole burst -- the opposite role from the single-'
    'character case, chosen so the shift below is the length of a run '
    'rather than one character',
    () => you.flushOutbox(),
  );
  await driver.step(
    'peer flushes their burst second (as one flush, three envelopes in '
    'typed order)',
    () => peer.flushOutbox(),
  );

  await driver.step(
    'you receive peer\'s burst as three remote, already-sequenced operations',
    () => you.receiveAll(),
  );
  driver.note(
    'you now see "${(await you.read()).objects[reflowTitle]!.text}" -- your '
    'own pending "A" is STILL treated as the latest thing, but it is not -- '
    'a provisional, not-yet-corrected view',
  );

  await driver.step(
    'peer receives your "A" as a remote, already-sequenced operation',
    () => peer.receiveAll(),
  );
  driver.note(
    'peer now sees "${(await peer.read()).objects[reflowTitle]!.text}" -- '
    'peer\'s burst really is the later-sequenced side, so this is already '
    'the final answer for peer',
  );

  await driver.step(
    'your own envelope comes back to you',
    () => deliverOwnEnvelopes(you, po),
  );
  driver.note(
    'you now see "${(await you.read()).objects[reflowTitle]!.text}" -- your '
    '"A" has shifted right by 3, the length of peer\'s whole run',
  );

  await driver.step(
    'peer\'s own envelopes come back too, for symmetry',
    () => deliverOwnEnvelopes(peer, po),
  );
  driver.note(
    'peer still sees "${(await peer.read()).objects[reflowTitle]!.text}" -- '
    'confirms nothing of peer\'s moved',
  );

  return {
    'you': (await you.read()).objects[reflowTitle]!.text!,
    'peer': (await peer.read()).objects[reflowTitle]!.text!,
  };
}

/// Every merge of two ordered sequences of length [n] and [m] that keeps
/// each sequence's own internal order -- every server interleaving of two
/// writers' envelopes, per item 2 of the ticket. `C(n+m, n)` results.
List<List<bool>> interleavings(int n, int m) {
  final total = n + m;
  final results = <List<bool>>[];
  void rec(List<bool> acc, int usedTrue, int usedFalse) {
    if (acc.length == total) {
      results.add(List.of(acc));
      return;
    }
    if (usedTrue < n) {
      acc.add(true);
      rec(acc, usedTrue + 1, usedFalse);
      acc.removeLast();
    }
    if (usedFalse < m) {
      acc.add(false);
      rec(acc, usedTrue, usedFalse + 1);
      acc.removeLast();
    }
  }

  rec(<bool>[], 0, 0);
  return results;
}

class ContiguityRunResult {
  ContiguityRunResult({
    required this.pattern,
    required this.text,
    required this.w1Contiguous,
    required this.w2Contiguous,
  });

  /// `1` = writer 1's turn, `2` = writer 2's turn, at each of the six
  /// server-accept steps in this interleaving.
  final String pattern;
  final String text;
  final bool w1Contiguous;
  final bool w2Contiguous;

  bool get shredded => !(w1Contiguous && w2Contiguous);
}

const contiguityTitle = ObjectId('contiguity-title');

Future<ContiguityRunResult> _runOneInterleaving(
  CrdtRuntime runtime,
  List<bool> pattern,
) async {
  final (clients, po) = await clientsOn(runtime, 3);
  final [w1, w2, observer] = clients;
  await w1.createTitle(contiguityTitle, x: 0, y: 0, w: 100, h: 30);
  await w1.type(contiguityTitle, 0, 'abc');
  await w1.flushOutbox();
  await w2.receiveAll();
  await observer.receiveAll();

  const w1Chars = ['P', 'Q', 'R'];
  const w2Chars = ['X', 'Y', 'Z'];
  var i1 = 0, i2 = 0;
  for (final isW1 in pattern) {
    if (isW1) {
      await w1.type(contiguityTitle, 1 + i1, w1Chars[i1]);
      await w1.flushOutbox();
      i1++;
    } else {
      await w2.type(contiguityTitle, 1 + i2, w2Chars[i2]);
      await w2.flushOutbox();
      i2++;
    }
  }

  await observer.receiveAll();
  final text = (await observer.read()).objects[contiguityTitle]!.text!;
  return ContiguityRunResult(
    pattern: pattern.map((b) => b ? '1' : '2').join(),
    text: text,
    w1Contiguous: text.contains('PQR'),
    w2Contiguous: text.contains('XYZ'),
  );
}

/// Runs every interleaving of two 3-character bursts ("P","Q","R" and
/// "X","Y","Z") at the same anchor against [runtime], and reports the
/// resulting string for each one.
Future<List<ContiguityRunResult>> runContiguityScenario(CrdtRuntime runtime) async {
  final results = <ContiguityRunResult>[];
  for (final pattern in interleavings(3, 3)) {
    results.add(await _runOneInterleaving(runtime, pattern));
  }
  return results;
}
