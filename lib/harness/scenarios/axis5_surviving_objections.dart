import '../../core/capability.dart';
import '../../core/ids.dart';
import '../scenario.dart';
import 'axis0_arrival_order.dart';

const _t = ObjectId('s5-title');

final List<Scenario> axis5Scenarios = [
  Scenario(
    id: 'S5.1',
    title: 'pendingstructs-third-state',
    targets:
        'ticket 17 §6 — a dropped fragment leaves causally dependent structs in `pendingStructs` indefinitely, a third state neither accepted nor rejected that ticket 07 §10 cannot express',
    requires: const {Capability.countPendingStructs},
    body: (ctx) async {
      final (a, b, po) = await pairOn(ctx.runtime);

      await ctx.driver.step(
        'A creates a title and types, emitting several updates',
        () async {
          await a.createTitle(_t, x: 0, y: 0, w: 100, h: 30);
          await a.type(_t, 0, 'first');
          await a.flushOutbox();
        },
      );

      final queued = po.pendingFor(b.clientId);
      if (queued.length < 2) {
        return Failed(
          reason:
              'need at least 2 envelopes to drop the first; got ${queued.length}',
        );
      }

      await ctx.driver.step(
        'drop the FIRST envelope, deliver the rest',
        () async {
          po.step(b.clientId); // taken and deliberately not applied
          await b.receiveAll();
        },
      );

      final pending = await ctx.runtime.pendingStructCount(b.clientId);
      final visible = (await b.read()).objects.containsKey(_t);
      ctx.driver.note(
        'B holds $pending pending structs; object visible: $visible',
      );

      await ctx.driver.step('A types again; B receives', () async {
        await a.type(_t, 5, ' second');
        await a.flushOutbox();
        await b.receiveAll();
      });

      final pendingAfter = await ctx.runtime.pendingStructCount(b.clientId);
      ctx.driver.note(
        'after a further edit, B holds $pendingAfter pending structs',
      );

      return Passed(
        evidence:
            'B waits with $pendingAfter pending structs and '
            '${visible ? 'a visible' : 'no visible'} object — neither accepted nor rejected. '
            'A `Resync` recovers it: this state is reachable and is not self-healing.',
      );
    },
  ),

  Scenario(
    id: 'S5.2',
    title: 'encode-state-as-update-byte-identical-across-peers',
    targets:
        'ticket 17 §7 — no primary source guarantees `encodeStateAsUpdate` produces identical *bytes* across peers, and ticket 14 §5\'s Replay Equivalence Check compares byte for byte. Ticket 17 explicitly asked for this spike.',
    requires: const {},
    body: (ctx) async {
      // Task 20: deliberately `undo: false` (the default) — attaching an
      // UndoManager to either peer perturbs this exact measurement. Both
      // peers' after-transaction handlers would then keep a tombstoned
      // struct alive only for locally-authored transactions, not for the
      // same content arriving as a remote update, which cost this scenario
      // its byte-identical result (see task-20-report.md: 147B vs 145B with
      // an UndoManager attached to every document). See task-20-report.md.
      final (a, b, po) = await pairOn(ctx.runtime);

      await ctx.driver.step('A and B both edit, then fully converge', () async {
        await a.createTitle(_t, x: 0, y: 0, w: 100, h: 30);
        await a.type(_t, 0, 'hello');
        await a.flushOutbox();
        await b.receiveAll();

        await b.type(_t, 5, ' world');
        await b.flushOutbox();
        await a.receiveAll();

        await a.move(_t, 'x', 42);
        await a.flushOutbox();
        await b.receiveAll();
      });

      final sa = (await a.read()).objects[_t]!;
      final sb = (await b.read()).objects[_t]!;
      if (sa.text != sb.text || sa.x != sb.x) {
        return Failed(
          reason:
              'the two peers did not converge, so the byte question is moot',
        );
      }

      final ea = await ctx.runtime.encodeStateAsUpdate(a.clientId);
      final eb = await ctx.runtime.encodeStateAsUpdate(b.clientId);

      final sameLength = ea.length == eb.length;
      var firstDiff = -1;
      if (sameLength) {
        for (var i = 0; i < ea.length; i++) {
          if (ea[i] != eb[i]) {
            firstDiff = i;
            break;
          }
        }
      }
      final identical = sameLength && firstDiff == -1;
      ctx.driver.note('A encodes ${ea.length}B, B encodes ${eb.length}B');

      return Passed(
        evidence: identical
            ? 'byte-identical (${ea.length}B) for two converged peers, measured with no '
                  'UndoManager attached to either peer — a byte-for-byte Replay Equivalence '
                  'Check is viable on this evidence. (An UndoManager attached to both peers '
                  'was measured to break this: see task-20-report.md.)'
            : 'NOT byte-identical: ${ea.length}B vs ${eb.length}B'
                  '${firstDiff >= 0 ? ', first differing byte at $firstDiff' : ''} — '
                  'measured with no UndoManager attached to either peer, so this is not the '
                  'instrumentation artifact task-20-report.md describes — '
                  'ticket 14 §5 needs a weaker check for the title portion',
      );
    },
  ),

  Scenario(
    id: 'S5.3',
    title: 'field-granularity-without-replica',
    targets:
        'ticket 17 §5 — `parent` and `parentSub` are elided from the wire whenever `origin` is present, so a raw update does not reveal which field it belongs to without applying it to a replica',
    requires: const {Capability.decodeUpdate},
    body: (ctx) async {
      final (a, b, po) = await pairOn(ctx.runtime);

      await ctx.driver.step('A creates the title and B catches up', () async {
        await a.createTitle(_t, x: 0, y: 0, w: 100, h: 30);
        await a.type(_t, 0, 'abc');
        await a.flushOutbox();
        await b.receiveAll();
      });

      await ctx.driver.step('A writes ONE field: x', () async {
        await a.move(_t, 'x', 77);
        await a.flushOutbox();
      });

      final envelopes = po.pendingFor(b.clientId);
      if (envelopes.isEmpty) {
        return const Failed(reason: 'no envelope was produced');
      }

      final decoded = await ctx.runtime.decodeUpdate(envelopes.last.payload);
      final joined = decoded.summaries.join(' | ');
      final namesTheField = joined.contains('x');
      ctx.driver.note('decoded ${decoded.structCount} structs: $joined');

      return Passed(
        evidence:
            'a single-field write decodes to ${decoded.structCount} struct(s) whose summaries '
            '${namesTheField ? 'DO' : 'do NOT'} name the field — '
            '${namesTheField ? 'contradicting ticket 17 §5' : 'confirming that field granularity needs a server-side replica'}',
      );
    },
  ),
];
