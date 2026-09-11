import '../../core/ids.dart';
import '../../driver/probe_client.dart';
import '../../runtime/crdt_runtime.dart';
import '../../transport/in_memory_post_office.dart';
import '../../transport/thin_server.dart';
import '../scenario.dart';

/// Two fresh clients on one server, with ids assigned in connection order.
///
/// [undo] is forwarded to [ProbeClient.open] — see [CrdtRuntime.open]'s doc
/// comment (task 20). Only axis 2 needs `undo: true`; every other axis
/// defaults to `false` so its documents never carry an UndoManager they don't
/// use, and so `encodeStateAsUpdate` measures Yjs/Yrs rather than the probe's
/// own instrumentation.
Future<(ProbeClient, ProbeClient, InMemoryPostOffice)> pairOn(
  CrdtRuntime runtime, {
  bool undo = false,
}) async {
  final server = ThinServer();
  final po = InMemoryPostOffice(server);
  final a = ProbeClient(clientId: server.assignClientId(), runtime: runtime, postOffice: po);
  final b = ProbeClient(clientId: server.assignClientId(), runtime: runtime, postOffice: po);
  await a.open(undo: undo);
  await b.open(undo: undo);
  return (a, b, po);
}

/// N fresh clients on one server, ids assigned in connection order.
///
/// **CORRECTED 2026-08-20 during Task 6. Read this before changing any axis-0
/// scenario back to two clients.**
///
/// `InMemoryPostOffice.send` never delivers an envelope back to its author. So
/// in a strict two-peer exchange where each side writes once, each side's inbox
/// holds **exactly one** envelope — and `releaseReversed` on a one-element queue
/// is bit-for-bit identical to `take`. A "forward versus reversed" comparison
/// built on two mutual peers therefore compares two identical operations and
/// reports "identical" **whether or not arrival order actually matters**: a
/// confident-looking confirmation of ticket 15 §1 that is a pure artifact of the
/// setup. That is the exact clean false pass this project exists to avoid, and
/// the original plan had it at the heart of its central experiment.
///
/// The shape that works: writers who author the conflict, and a separate
/// **observer** who authors nothing and therefore receives every writer's
/// envelope. Only an observer's queue reaches two elements, so only an observer
/// can have its arrival order reversed. Comparing forward against reversed on
/// two observers holding an identical pair — rather than reversing twice on one
/// observer — also keeps the two orders from contaminating each other's state.
///
/// Each call here builds a fresh [ThinServer], so clientIDs restart at 1 on
/// every call — but the JS bridge's `docs` map (`yjs_bridge.js`) is keyed by
/// clientId alone, and `createDoc` unconditionally overwrites that key with a
/// brand-new `Y.Doc`. That is *only* safe because `createDoc` never reuses an
/// existing entry. If `open`/`createDoc` ever became reuse-if-present (e.g. an
/// optimisation that skips recreating a doc for a clientId already seen this
/// process), a later `clientsOn` call in the same test run — S0.2's second and
/// third iterations reuse clientId 1 and 2 — would silently inherit the prior
/// iteration's document state instead of starting fresh, and S0.2's
/// seq-independence and clientID-attribution results would become false
/// passes with nothing in this file able to catch it. Keep `createDoc`
/// unconditional, or give this function a way to detect reuse, before
/// touching that code path.
Future<(List<ProbeClient>, InMemoryPostOffice)> clientsOn(
  CrdtRuntime runtime,
  int n, {
  bool undo = false,
}) async {
  final server = ThinServer();
  final po = InMemoryPostOffice(server);
  final clients = <ProbeClient>[];
  for (var i = 0; i < n; i++) {
    final c = ProbeClient(
      clientId: server.assignClientId(),
      runtime: runtime,
      postOffice: po,
    );
    await c.open(undo: undo);
    clients.add(c);
  }
  return (clients, po);
}

const _t = ObjectId('s0-title');

/// Every participant starts from the same base before the concurrent writes.
Future<void> _seedAll(List<ProbeClient> clients) async {
  final author = clients.first;
  await author.createTitle(_t, x: 0, y: 0, w: 100, h: 30);
  await author.type(_t, 0, 'abc');
  await author.flushOutbox();
  for (final c in clients.skip(1)) {
    await c.receiveAll();
  }
}

/// A single field can agree between two documents while their underlying
/// item/tombstone structure still diverges. `encodeStateAsUpdate` needs no
/// extra capability and is the strongest comparison available, so the
/// convergence claims below rest on this rather than on one projected field.
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final List<Scenario> axis0Scenarios = [
  Scenario(
    id: 'S0.1',
    title: 'same-key-different-values-both-arrival-orders',
    targets:
        'ticket 15 §1 — "Yjs updates are commutative, so an external total order is semantically inert"',
    requires: const {},
    body: (ctx) async {
      // Two writers author the conflict; two observers author nothing, so each
      // observer's inbox reaches two envelopes and can actually be reversed.
      // See clientsOn's doc comment for why two mutual peers cannot express
      // this experiment at all.
      final (clients, po) = await clientsOn(ctx.runtime, 4);
      final [w1, w2, obsFwd, obsRev] = clients;
      await _seedAll(clients);

      await ctx.driver.step('hold both observers', () async {
        po.hold(obsFwd.clientId);
        po.hold(obsRev.clientId);
      });

      await ctx.driver.step('w1 sets x=100, w2 sets x=200, both flush', () async {
        await w1.move(_t, 'x', 100);
        await w2.move(_t, 'x', 200);
        await w1.flushOutbox();
        await w2.flushOutbox();
      });

      // Check the queue that is actually reversed below (obsRev), not just
      // obsFwd — send()'s symmetric fan-out makes the two counts equal today,
      // but the guard exists to protect whichever queue gets reversed, so it
      // must look there too rather than assuming symmetry holds forever.
      final queuedFwd = po.pendingFor(obsFwd.clientId).length;
      final queuedRev = po.pendingFor(obsRev.clientId).length;
      if (queuedFwd < 2 || queuedRev < 2) {
        return Failed(
          reason: 'observers queued $queuedFwd (forward) / $queuedRev (reversed) '
              'envelopes, not 2 each — with fewer than two there is no arrival '
              'order to reverse and this scenario would report a false '
              '"identical"',
        );
      }
      final queued = queuedFwd;
      ctx.driver.note('each observer holds $queued envelopes before draining');

      await ctx.driver.step('obsFwd drains forward, obsRev drains reversed', () async {
        po.unhold(obsFwd.clientId);
        po.unhold(obsRev.clientId);
        await obsFwd.receiveAll();
        await obsRev.receiveReversed();
      });

      final fwd = (await obsFwd.read()).objects[_t]!.x;
      final rev = (await obsRev.read()).objects[_t]!.x;
      ctx.driver.note('forward observer sees x=$fwd, reversed observer sees x=$rev');

      // The convergence claim rests on the full document, not on one field —
      // see _bytesEqual's doc comment.
      final fwdState = await ctx.runtime.encodeStateAsUpdate(obsFwd.clientId);
      final revState = await ctx.runtime.encodeStateAsUpdate(obsRev.clientId);
      final statesConverged = _bytesEqual(fwdState, revState);
      ctx.driver.note(
          'full-state byte comparison: forward ${fwdState.length}B, reversed '
          '${revState.length}B — ${statesConverged ? 'identical' : 'DIFFERENT'}');

      if (fwd == rev && !statesConverged) {
        return Failed(
          reason: 'field x agreed ($fwd) on both observers but the full '
              'document state diverged: forward state ${fwdState.length} '
              'bytes vs reversed state ${revState.length} bytes — agreement '
              'on one field does not establish document convergence',
        );
      }

      final inert = fwd == rev && statesConverged;
      return Passed(
        evidence: 'forward=$fwd, reversed=$rev over $queued envelopes, '
            'full-state byte comparison ${statesConverged ? 'also identical' : 'DIFFERENT'} — '
            '${inert ? 'identical, so the total order is inert' : 'DIFFERENT, so arrival order changed the merge'}',
      );
    },
  ),

  Scenario(
    id: 'S0.2',
    title: 'winner-is-clientid-not-seq',
    targets:
        'ticket 17 §4 — the only knob is `clientID`, which expresses "Alice always beats Bob", never "this one is later"',
    requires: const {},
    body: (ctx) async {
      // The server assigns 1 then 2, so B always holds the higher clientID.
      // If the winner tracks the higher clientID regardless of who was
      // sequenced first, a server-ordered id is a deterministic, server-decided
      // tie-break needing no patch to Yjs.
      // Read the winner on an observer that authored neither write, so the
      // result cannot be an artifact of local-versus-remote asymmetry inside
      // one writer's own document.
      //
      // `clientsOn` builds a fresh server each run and assigns ids in
      // connection order, so w1 is always clientID 1 and w2 always clientID 2.
      // The ONLY thing that varies between the first two runs is which write
      // the server sequences first. That isolation is the experiment.
      final winners = <String, double>{};

      for (final firstWriter in ['w1', 'w2']) {
        final (clients, po) = await clientsOn(ctx.runtime, 3);
        final [w1, w2, obs] = clients;
        await _seedAll(clients);
        po.hold(obs.clientId);

        await ctx.driver.step('$firstWriter is sequenced first', () async {
          if (firstWriter == 'w1') {
            await w1.move(_t, 'x', 111);
            await w1.flushOutbox();
            await w2.move(_t, 'x', 222);
            await w2.flushOutbox();
          } else {
            await w2.move(_t, 'x', 222);
            await w2.flushOutbox();
            await w1.move(_t, 'x', 111);
            await w1.flushOutbox();
          }
        });

        po.unhold(obs.clientId);
        await obs.receiveAll();

        final x = (await obs.read()).objects[_t]!.x;
        winners[firstWriter] = x;
        ctx.driver.note(
            '$firstWriter sequenced first; observer sees x=$x '
            '(w1 wrote 111 as clientID ${w1.clientId.value}, '
            'w2 wrote 222 as clientID ${w2.clientId.value})');
      }

      // The two runs above cannot separate "higher clientID wins" from
      // "larger value wins": w2 holds both the higher clientID AND the
      // larger value (222 > 111) in both of them, so a clientID attribution
      // drawn from just those two runs would be borrowed from reading
      // yjs.cjs rather than measured. This third run keeps sequencing fixed
      // (w1 first, as in the first run above) but swaps which writer holds
      // the larger value: w1 (lower clientID) writes 999, w2 (higher
      // clientID) writes 111. If the higher clientID still wins here despite
      // writing the smaller value, the attribution is earned by measurement.
      final (clients3, po3) = await clientsOn(ctx.runtime, 3);
      final [w1c, w2c, obs3] = clients3;
      await _seedAll(clients3);
      po3.hold(obs3.clientId);

      await ctx.driver.step(
          'disambiguation: w1 (lower clientID) sequenced first writing the '
          'LARGER value 999; w2 (higher clientID) writes the smaller value 111',
          () async {
        await w1c.move(_t, 'x', 999);
        await w1c.flushOutbox();
        await w2c.move(_t, 'x', 111);
        await w2c.flushOutbox();
      });

      po3.unhold(obs3.clientId);
      await obs3.receiveAll();
      final xSwapped = (await obs3.read()).objects[_t]!.x;
      ctx.driver.note(
          'value/clientID disambiguation: w1 (clientID ${w1c.clientId.value}) '
          'wrote 999, w2 (clientID ${w2c.clientId.value}) wrote 111; observer '
          'sees x=$xSwapped');

      final seqIndependent = winners['w1'] == winners['w2'];
      final higherClientIdWon = xSwapped == 111;
      return Passed(
        evidence: 'w1-first=${winners['w1']}, w2-first=${winners['w2']} — '
            '${seqIndependent ? 'winner is independent of seq' : 'winner tracked seq, contradicting ticket 17 §4'}. '
            'Disambiguation: w1(lower clientID) wrote 999, w2(higher clientID) '
            'wrote 111, observer sees x=$xSwapped — '
            '${higherClientIdWon ? "the higher clientID (w2) won despite writing the smaller value, matching yjs.cjs:9993's client-id compare (values are never compared)" : 'the LARGER VALUE won despite the lower clientID, contradicting the yjs.cjs:9993 client-id rule as read'}.',
      );
    },
  ),

  Scenario(
    id: 'S0.3',
    title: 'insert-at-same-anchor-both-orders',
    targets:
        'ticket 15 §2 — "an insertion lands immediately to the right of its anchor", with the later-sequenced insertion appearing to the left',
    requires: const {},
    body: (ctx) async {
      // Same observer shape as S0.1, for the same reason: only a client that
      // authored nothing receives both insertions, and only a two-element queue
      // has an arrival order to reverse.
      final (clients, po) = await clientsOn(ctx.runtime, 4);
      final [w1, w2, obsFwd, obsRev] = clients;
      await _seedAll(clients);

      await ctx.driver.step('hold both observers', () async {
        po.hold(obsFwd.clientId);
        po.hold(obsRev.clientId);
      });

      await ctx.driver.step('both writers insert after index 1', () async {
        await w1.type(_t, 1, 'A');
        await w2.type(_t, 1, 'B');
        await w1.flushOutbox();
        await w2.flushOutbox();
      });

      // Check the queue that is actually reversed below (obsRev), not just
      // obsFwd — see S0.1's identical guard for why.
      final queuedFwd = po.pendingFor(obsFwd.clientId).length;
      final queuedRev = po.pendingFor(obsRev.clientId).length;
      if (queuedFwd < 2 || queuedRev < 2) {
        return Failed(
          reason: 'observers queued $queuedFwd (forward) / $queuedRev '
              '(reversed) envelopes, not 2 each — nothing to reverse',
        );
      }
      final queued = queuedFwd;

      await ctx.driver.step('obsFwd drains forward, obsRev drains reversed', () async {
        po.unhold(obsFwd.clientId);
        po.unhold(obsRev.clientId);
        await obsFwd.receiveAll();
        await obsRev.receiveReversed();
      });

      final fwd = (await obsFwd.read()).objects[_t]!.text!;
      final rev = (await obsRev.read()).objects[_t]!.text!;
      ctx.driver.note('seeded "abc"; forward gives "$fwd", reversed gives "$rev"');

      // The convergence claim rests on the full document, not on one field —
      // see _bytesEqual's doc comment.
      final fwdState = await ctx.runtime.encodeStateAsUpdate(obsFwd.clientId);
      final revState = await ctx.runtime.encodeStateAsUpdate(obsRev.clientId);
      final statesConverged = _bytesEqual(fwdState, revState);
      ctx.driver.note(
          'full-state byte comparison: forward ${fwdState.length}B, reversed '
          '${revState.length}B — ${statesConverged ? 'identical' : 'DIFFERENT'}');

      if (fwd == rev && !statesConverged) {
        return Failed(
          reason: 'field text agreed ("$fwd") on both observers but the full '
              'document state diverged: forward state ${fwdState.length} '
              'bytes vs reversed state ${revState.length} bytes — agreement '
              'on one field does not establish document convergence',
        );
      }

      // Ticket 15 §2 is not only "lands immediately right of its anchor" —
      // its directional consequence (quoted in `targets` above) predicts
      // EXACTLY ONE string for this input: "aBAbc", because it puts the
      // LATER-sequenced insertion (w2's "B", sequenced second) nearer the
      // anchor "a". Reporting "predicts one of X/Y" would let a reader miss
      // a contradiction, so this states plainly whether "$fwd" matches or
      // contradicts that prediction rather than listing both possibilities.
      final converged = fwd == rev && statesConverged;
      final runtimeOrderingNote = ctx.runtime.name == 'yjs'
          ? 'w1 is both earlier-sequenced and lower-clientID here, so this '
              'run cannot say which field Yjs used; yjs.cjs:9993 is where that lives.'
          : 'This is ${ctx.runtime.name}\'s measured ordering for the same input; '
              'it must not be attributed to Yjs.';
      return Passed(
        evidence: 'forward="$fwd", reversed="$rev" over $queued envelopes, '
            'full-state byte comparison ${statesConverged ? 'also identical' : 'DIFFERENT'} — '
            '${converged ? 'identical, so arrival order did not change the interleaving' : 'DIFFERENT, so arrival order changed the interleaving'}. '
            'Seed was "abc", both inserted at index 1, w1 sequenced first. '
            'Ticket 15 §2 predicts "aBAbc" for this input, because its rule '
            'puts the LATER-sequenced insertion nearer the anchor. ${ctx.runtime.name} '
            'produced "$fwd" — '
            '${fwd == 'aABbc' ? "CONTRADICTING that half of ticket 15 §2: the earlier-sequenced insertion landed nearer the anchor" : 'see above'}. '
            '$runtimeOrderingNote',
      );
    },
  ),
];
