# Ticket 04 — cross-client overlapping multi-select admission safety, on native YrsRuntime

This is `yjs_probe`'s disposable evidence for Wayfinder ticket 04 —
[Verify Cross-Client Overlapping Multi-Select Admission Safety](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/04-verify-cross-client-overlapping-multi-select-admission-safety.md),
part of the [Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md)
map. Unlike tickets 02/03 (one client's own clock chain, shared between a
refused leading command and an independent survivor), this axis is two
*different* clients (A, B) each independently building a self-consistent
`moveObjects` command over a partially-overlapping object set, both from the
same accepted server baseline, before either submission reaches the server.
`YjsAdmissionServer`/`YjsAdmissionClient` and `moveObjects`
(`lib/prototype/title_admission.dart`) stay completely unchanged — reused
exactly as they already existed.

**Headline: `pendingStructCount` is reachable but irrelevant to this axis —
confirmed `0` in every single check, both submissions, both orders (answers
§1). The admission-layer scope check (`_matchesSemanticScope`) behaves
correctly and safely in the order where the CRDT's internal tie-break winner
submits second, but a genuine false acceptance was found in the opposite
order: a command declaring targets `{obj1,obj2,obj3}` was ACCEPTED even
though its actual effect on the server was `{obj1}` only — two of its three
declared targets silently had no effect, with zero signal to the client
(answers §2 and §4). The underlying CRDT merge itself is legitimate and
fully order-independent (both orders converge to byte-identical final field
values) — the divergence is entirely in what the admission layer reports as
"accepted", not in the merge result (answers §3).**

## How this was run

Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`,
extending tickets 02/03's rig, shared by two harnesses so they cannot drift
apart:

- `integration_test/title_admission_cross_client_overlap_test.dart` — the
  standard Flutter `integration_test` harness, matching this repo's
  convention. Left in the repo, analyzed clean (not run — this sandboxed
  environment hangs `flutter test`'s Windows-app-to-VM-service socket, the
  same reason tickets 01-03 each left an equivalent Flutter harness unrun;
  see `p5-zorder-merge.md#how-this-was-run` and `p6-yffi-pending-structs.md`).
- `tool/cross_client_multiselect_overlap_probe_dart.dart` — a plain
  `dart run` script with zero Flutter dependency, the same workaround
  pattern tickets 01-03 established. **This report's numbers come from
  this script, run for real**, from the `yjs_probe/` directory:
  ```
  dart run tool/cross_client_multiselect_overlap_probe_dart.dart
  ```
  Exit code `0`; both scenarios ran to completion (`ALL SCENARIOS RAN`,
  2/2). Full raw output is reproduced in condensed form below; nothing in
  this report is reasoned-only or fabricated.

## Scenario shape

Four Title objects (`obj1..obj4`) are created and accepted as history known
to both A and B before either proposes anything — all start at `x=0, y=0`
(fixed by `createObject`). Both clients then independently build a
`moveObjects` command from that identical baseline, **before either
submission reaches the server**:

- A: `moveObjects({obj1, obj2, obj3}, deltaX: 10, deltaY: 20)`
- B: `moveObjects({obj2, obj3, obj4}, deltaX: -5, deltaY: 100)`

`obj2` and `obj3` are the contested overlap; `obj1` and `obj4` are each
uncontested (touched by exactly one client). Both envelopes are always built
identically regardless of order — only the order they are handed to
`YjsAdmissionServer.submit` (exact-U mode, the mode this whole map's
safety question is about) changes between the two scenario runs:

- `crossClientOverlapMoveAThenB` — A submitted first, B second (against the
  post-A server snapshot).
- `crossClientOverlapMoveBThenA` — B submitted first, A second (against the
  post-B server snapshot).

Each run verifies, with a real state-vector trace (per tickets 02/03's
method, not assumed), that A and B never advance each other's clock in
their own state vectors — confirming this axis genuinely has no shared
client-clock chain at all, unlike tickets 02/03. Both runs confirmed
`crossClientClockShared: false`.

Each run also replays the *second* command's own update bytes alone against
the server's snapshot exactly as it stood right after the *first* command
landed — the identical candidate shape `submit()` builds next internally —
via `manualCandidateReplay`, the same independent double-check method
tickets 02/03 used for `pendingStructCount`.

## Result: both scenarios ran to completion

### Order A-then-B

```
Fields before A: obj1=(0,0)  obj2=(0,0)  obj3=(0,0)  obj4=(0,0)
Fields after A:  obj1=(10,20) obj2=(10,20) obj3=(10,20) obj4=(0,0)
Fields after B:  obj1=(10,20) obj2=(-5,100) obj3=(-5,100) obj4=(-5,100)
```

- A's manual pre-submit replay (against the pristine baseline):
  `pendingStructCount: 0`.
- A's decision: **ACCEPTED**. Actual changed objects:
  `[obj1, obj2, obj3]` — exactly A's declared `targetObjectIds`. Scope
  match: **true**.
- B's manual replay against the post-A server snapshot (the exact candidate
  shape `submit()` builds for B next): `pendingStructCount: 0`.
- B's decision: **ACCEPTED**. Actual changed objects:
  `[obj2, obj3, obj4]` — exactly B's declared `targetObjectIds`. Scope
  match: **true**.
- A/B/server projections converged after both decisions delivered: **true**.
- **False acceptance detected: false.**

### Order B-then-A

```
Fields before B: obj1=(0,0)  obj2=(0,0)  obj3=(0,0)  obj4=(0,0)
Fields after B:  obj1=(0,0)  obj2=(-5,100) obj3=(-5,100) obj4=(-5,100)
Fields after A:  obj1=(10,20) obj2=(-5,100) obj3=(-5,100) obj4=(-5,100)
```

- B's manual pre-submit replay: `pendingStructCount: 0`.
- B's decision: **ACCEPTED**. Actual changed objects:
  `[obj2, obj3, obj4]` — exactly B's declared `targetObjectIds`. Scope
  match: **true**.
- A's manual replay against the post-B server snapshot:
  `pendingStructCount: 0`, all four objects present (no causal gap, no
  crash, no unexpected refusal reason available from this axis).
- A's decision: **ACCEPTED**. Actual changed objects: **`[obj1]` only** —
  despite A's declared `targetObjectIds` being `[obj1, obj2, obj3]`. Scope
  match: **false**.
- A/B/server projections converged after both decisions delivered: **true**
  (both A and B's own speculative views correctly rebuilt to the same
  server-canonical state — the *client-side* bookkeeping is not the problem
  here; the admission decision itself is).
- **False acceptance detected: true.**

Final merged state is **byte-identical** in both orders:
`obj1=(10,20)`, `obj2=(-5,100)`, `obj3=(-5,100)`, `obj4=(-5,100)`. B's values
win the contested keys in both orders.

## What this answers

### 1. Is `pendingStructCount`/causal completeness even reachable or relevant here?

**Reachable, yes; relevant, no — confirmed by direct measurement, not
assumed.** Every manual candidate replay in both orders, for both the first
and second submission, reported `pendingStructCount: 0`. A's and B's state
vectors never advance each other's clock (`crossClientClockShared: false`,
verified via the same `sharesClockChain` trace method tickets 02/03 used).
This matches the ticket's own reframing exactly: two different clients'
`moveObjects` updates are each internally self-consistent field writes
(`setFields`/`FieldWrite` on each object's own `Y.Map`), with no structural
reference to the other client's clock at all — there is no "missing struct"
for native Yrs to ever detect in this shape, regardless of submission order
or how many objects overlap. This axis's actual risk, as the ticket itself
anticipated, is entirely in `_matchesSemanticScope`'s own before/after
scope-diff logic, not in causal completeness.

### 2. Does `_matchesSemanticScope` correctly accept/refuse both commands, with real before/after evidence?

**Partially — it correctly refuses nothing that changed outside its
declared scope in either order (that half of its check held up in every
case tested), but it does not verify that every declared target actually
changed, and that gap is exactly what produced the order-B-then-A false
acceptance.** Concrete per-submission before/after evidence (not merely the
final merged projection) is captured above for both orders: the A-then-B
order shows both commands' actual changed-object sets landing exactly on
their declared scopes; the B-then-A order shows A's second submission
landing on a strict subset (`{obj1}` of `{obj1,obj2,obj3}`) while still
being accepted, because `_matchesSemanticScope`'s own logic
(`title_admission.dart:408-426`) only checks (a) nothing *outside* the
declared scope changed and (b) every declared object still *exists*
afterward — it never checks that every declared object's *value* actually
differs from before. Both of those weaker conditions held for A's losing
submission, so the check passed by its own written definition.

### 3. Does submission order change the outcome — legitimate LWW, or an admission bug?

**The CRDT merge result itself is order-independent and legitimate — this
is not a Yrs merge bug. What order changes is only which side of the
admission layer's scope check gets exercised.** Both orders produced
byte-identical final field values (`obj2=(-5,100)`, `obj3=(-5,100)` in both
runs), confirming the underlying `Y.Map` per-key resolution is deterministic
and does not depend on wall-clock submission order — consistent with the
ticket's own framing that this is "Yrs's own per-key `Y.Map` LWW conflict
resolution, not any admission-layer merge logic." The mechanism, read off
the state vectors: A's and B's *live speculative session* each carry their
own internal Yrs client id (A's session settled at id `11103`, B's at
`11203` — both far larger than their nominal `ClientId`s `1`/`2`, because
`YjsAdmissionClient._rebuildSpeculative` mints a fresh session id on every
`deliver()`, including for the four preceding accepted `createTitle`
tickets both clients received). B's session id (`11203`) is numerically
greater than A's (`11103`), and Yrs's `Y.Map` concurrent-key resolution
consistently favored B's item for the contested keys in *both* orders —
not "whichever arrived at the server later." This is why the *merge* is
order-independent (a real CRDT convergence property) while the *admission
layer's scope-match observation* is order-dependent: whichever client's
write is the structural "loser" on the overlap is scope-matched correctly
only if it happens to submit **before** the winner (its diff is still
visible against the untouched baseline); if the loser submits **after** the
winner, its overlapping writes produce no visible diff at all, and that is
exactly when the false acceptance in §4 appears. This is a genuine
admission-layer finding, not a symptom of an incorrect CRDT merge.

### 4. Any false acceptance?

**Yes — one found, in the B-then-A order, and it is real, not a
double-check artifact (manual replay agrees; A's own state converges
correctly; the server's before/after projections were read directly, not
inferred).** A's `moveObjects` envelope, submitted second against the
post-B server snapshot, declared `targetObjectIds: [obj1, obj2, obj3]` but
its accepted, applied effect changed only `obj1` — `obj2` and `obj3` kept
B's already-landed values with zero observable difference. The command was
still **ACCEPTED** (`outcome: accepted`, no refusal at all), because
`_matchesSemanticScope`'s existence-and-no-out-of-scope-change check is
satisfied by a command that silently no-ops on part of its own declared
target set. Stated plainly, per the ticket's own instruction not to bury
this: **A's client-side view has no way to learn from the ticket alone that
2 of its 3 declared objects never actually moved** — the accepted ticket
looks identical in shape to a fully-effective accept. This is not silent
*data corruption* (no field ever lands in a mixed or invalid state — each
contested object cleanly holds either A's or B's complete `(x, y)` pair,
never a blend), but it is a silent *partial non-effect* of an accepted
command, which is exactly the "accepted with a scope different from what it
declared" case the ticket names as its most important possible output.

## Constraint compliance

`YjsAdmissionServer`/`YjsAdmissionClient` and `title_admission.dart`'s
`moveObjects` command vocabulary were **not modified** — only new scenario
functions and one small independent diff helper
(`changedObjectIds`/`_maybeObjectJson`, a non-private re-derivation of
`title_admission.dart`'s own `_changedObjectIds`, used to double-check the
server's internal bookkeeping rather than trust it, the same
don't-trust-the-implementation posture as `manualCandidateReplay`) were
added to `title_admission_native_probe.dart`. No `TitleCommandKind` or
envelope field was missing for this scenario — `moveObjects` and
`targetObjectIds` already existed and needed no change, confirming the
ticket's own premise that no new capability had to be improvised.

## Scope notes

- The false acceptance found here is a property of `_matchesSemanticScope`'s
  *design* (existence + no-out-of-scope-change, not full-target-changed),
  not of any runtime-specific behavior — nothing about it is native-Yrs
  -specific; the same gap would very likely reproduce on `YjsRuntime` too,
  since `Y.Map`'s per-key concurrent-write resolution is the same CRDT
  primitive in both implementations. Not run against `YjsRuntime` this
  session (out of this ticket's scope, which is about the native-Yrs
  admission path) — flagged here rather than assumed silently.
- This ticket's scenario used exactly one shape (two objects contested out
  of three-and-three declared, one delta command each). Whether a
  different overlap cardinality (e.g. fully-overlapping target sets, or
  more than two concurrent clients) changes the *frequency* of the false
  -acceptance pattern (not its existence, which is already confirmed) is
  not tested here — the ticket's own scope was one representative overlap
  shape, not an exhaustive cardinality sweep.
- Whether ticket 07's synthesis should treat this specific gap as
  disqualifying for exact-U mode, or as an acceptable/expected cost of
  optimistic multi-object moves (arguably any LWW-based concurrent editor
  has *some* version of "your overlapping edit was silently superseded"),
  is a severity judgment left to ticket 07 per the map's own
  failure-classification policy — this report states the finding plainly
  without pre-sorting it.

## Code

- Scenario logic: [`lib/prototype/title_admission_native_probe.dart`](../lib/prototype/title_admission_native_probe.dart)
  (`crossClientOverlapMoveAThenB`, `crossClientOverlapMoveBThenA`,
  `_crossClientOverlapScenario`, `changedObjectIds`).
- Authoritative `dart run` harness: [`tool/cross_client_multiselect_overlap_probe_dart.dart`](../tool/cross_client_multiselect_overlap_probe_dart.dart).
- Flutter harness (left analyzed-clean, not run): [`integration_test/title_admission_cross_client_overlap_test.dart`](../integration_test/title_admission_cross_client_overlap_test.dart).
