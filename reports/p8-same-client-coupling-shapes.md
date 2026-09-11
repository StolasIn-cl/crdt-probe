# Ticket 03 — same-client causal-coupling shapes beyond ticket 02's first shape, on native YrsRuntime

This is `yjs_probe`'s disposable evidence for Wayfinder ticket 03 —
[Verify Same-Client Causal Coupling Beyond the First Shape](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/03-verify-same-client-causal-coupling-beyond-the-first-shape.md),
part of the [Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md)
map. It extends ticket 02's finding — that native Yrs did not flag one
specific same-client shape (create-then-refused-root followed by an insert
into a separate, empty, already-accepted `Y.Text`) as causally incomplete —
across four more shapes: format instead of insert, delete instead of
insert, insert adjacent to real (non-empty) content, and a three-command
same-client chain. `YjsAdmissionServer`/`YjsAdmissionClient`
(`lib/prototype/title_admission.dart`) stay completely unchanged.

**Headline: all four shapes were ACCEPTED on native Yrs — no causal gap was
ever detected, extending ticket 02's finding across every shape this ticket
tested. No false acceptance was found in any of the four.** Reasoning from
Yjs's documented block-level withholding mechanism (`bridge.js:268-292`,
read for ticket 02), three of the four shapes (format, adjacent-insert, and
the chain's op2/op3) would very likely be *wrongly refused* on Yjs, the same
class of defect ticket 02 found — meaning native Yrs is the more precise,
not merely differently-behaved, runtime across this wider set too. The
fourth shape (delete) turned out to test something structurally different
from the other three — see below, this is itself a real finding, not a
flaw in the scenario.

## How this was run

Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`,
extending ticket 02's rig, shared by two harnesses so they cannot drift
apart:

- `integration_test/title_admission_same_client_coupling_test.dart` — the
  standard Flutter `integration_test` harness, matching this repo's
  convention. Left in the repo, analyzed clean, for whoever can run a
  Windows Flutter integration test outside this sandbox.
- `tool/same_client_coupling_shapes_probe_dart.dart` — a plain `dart run`
  script with zero Flutter dependency, the same workaround pattern tickets
  01 and 02 established: `flutter test` hangs this sandboxed environment's
  Windows-app-to-VM-service socket (documented in `p5-zorder-merge.md` and
  `p6-yffi-pending-structs.md`). **This report's numbers come from that
  script, run for real.**

Each shape follows the same base pattern as ticket 02's negative control: a
leading command (`root`) that the server refuses by policy before it ever
touches server `B`, followed — still on the same speculative document, no
rebuild in between, so still sharing one client's live clock chain — by a
second, semantically independent command with no `dependsOn`. Two new pieces
of shared evidentiary machinery were added for this ticket, both exported
from `title_admission_native_probe.dart`:

- `decodeStateVectorB64` — decodes the lib0-v1 state vector `DocProjection`
  already exposes (`{clientId: clock}`), so the shared-clock-chain
  precondition is *verified from a real trace*, not assumed, for every shape
  (per ticket 02's own method).
- `manualCandidateReplay` — replays the independent command's own update
  bytes alone against a fresh candidate seeded only from the server's
  current snapshot, exactly the shape `YjsAdmissionServer.submit`'s internal
  candidate path builds. An independent double-check of the server's own
  `pendingStructCount` decision, again per ticket 02's method.

## Result: all four shapes ran to completion, all four ACCEPTED

### Shape 1: format instead of insert — ACCEPTED, no gap

Setup: `title-keep-format` is created and seeded with `"seedtext"` as
already-accepted history. On a fresh speculative session, client A proposes
`reject-root-format` (refused by policy) then, without rebuilding,
`local-format-keep` — bolding `"seed"` (index 0, length 4) in
`title-keep-format`.

```
before-root: {11100: 8, 1: 9}
after-root:  {11100: 8, 1: 9, 11101: 9}
after-independent: {11100: 8, 1: 9, 11101: 11}
```

Client `11101` (A's current speculative session) advances `9 -> 11` when the
format command runs — confirming format *does* consume new clock slots
under the same client as the refused root (Yrs represents attribute changes
as real structs, not a side-channel), so this genuinely exercises the same
same-client clock-sharing precondition as ticket 02's insert shape, just
with a different command kind.

- Server decision on `local-format-keep`: **ACCEPTED**, `pendingStructCount: 0`.
- Manual replay of `local-format-keep`'s bytes alone against the server
  snapshot: `pendingStructCount: 0`, `title-keep-format` present — confirms
  the server's own decision, not an artifact of `YjsAdmissionServer`'s
  bookkeeping.

**Reasoned Yjs comparison:** the update is keyed to client `11101` starting
at clock 9 — from a receiver that has never seen any of client `11101`
(root's clock 0-9 never touched server `B`), Yjs's coarse per-client
`missing` bookkeeping would very likely hold this back the same way it held
back ticket 02's insert shape, since the *mechanism* it uses (a `client ->
clock` gap, not per-item structural need) does not distinguish a format
command from an insert. Not run against Yjs directly this session — this is
reasoned from the documented mechanism per the ticket's own allowance — but
if it holds, this shape would be a **second confirmed divergence** in
native Yrs's favor, on a different command kind than ticket 02 tested.

### Shape 2: delete instead of insert — ACCEPTED, but not for the reason the other shapes are

Setup: `title-keep-delete` seeded with `"deleteme"`. Root refused as before;
independent command deletes the first 3 characters (`"del"`) from
`title-keep-delete`.

```
before-root: {11100: 8, 1: 9}
after-root:  {11100: 8, 1: 9, 11101: 9}
after-independent: {11100: 8, 1: 9, 11101: 9}
```

**Client `11101`'s own clock does not move at all between "after-root" and
"after-independent" — `sharesClockChain` genuinely reports `false` here,
verified, not a bug in the check.** This is itself the finding: a pure
delete produces no new item structs owned by the deleting client — Yrs (and
Yjs) records a deletion as a delete-set entry keyed by the *original
owning* client of the deleted range (here, whichever earlier session
authored `"deleteme"`'s seed content, already fully known to the server),
not by the deleting client's own clock. **The premise this ticket's shapes
are built to test — a later same-client command whose own bytes structurally
follow the refused root in that client's clock chain — does not hold for a
delete at all**, because deleting never advances the deleter's own chain.
This is a different, narrower finding than the other three shapes: it says
"same-client causal coupling," as this map has been testing it via
`pendingStructCount`/state-vector clocks, is not even a coherent question
for a pure delete — not that native Yrs is lenient about deletes
specifically.

- Server decision on `local-delete-keep`: **ACCEPTED**, `pendingStructCount: 0`.
- Manual replay: `pendingStructCount: 0`, `title-keep-delete` present with
  the range removed.

**Reasoned Yjs comparison:** since the delete update never mentions client
`11101`'s own clock range at all, Yjs's per-client `missing` bookkeeping has
nothing to key a withholding decision on for *that* client either — the
update only references the already-known deleted range's original owner.
Reasoning suggests Yjs would **also** accept this one, for the same
structural reason, not because of any runtime-precision difference. This
shape does not distinguish the two runtimes; see "Not yet specified" for
what a genuine same-client delete-coupling test would need (two
still-pending deletes from the *same* client, not a create-then-delete
pair).

### Shape 3: insert adjacent to existing (non-empty) content — ACCEPTED, no gap

Setup: `title-adjacent` created and seeded with `"seed"` (4 characters,
authored under an earlier, already-rebuilt speculative session — client
`11100`, distinct from A's current session). On the current session, root
is refused, then `local-adjacent-insert` appends `"more"` at index 4 —
directly following `"seed"`'s last character.

```
before-root: {11100: 4, 1: 9}
after-root:  {11100: 4, 1: 9, 11101: 9}
after-independent: {11100: 4, 1: 9, 11101: 13}
```

Client `11100` (the seed's author) stays fixed at clock 4 throughout — it is
no longer live. Client `11101` (the current session, same as root's author)
advances `9 -> 13` for the 4-character append.

- Server decision on `local-adjacent-insert`: **ACCEPTED**, `pendingStructCount: 0`.
- Manual replay: `pendingStructCount: 0`, `title-adjacent` present with
  `"more"` landed.

**Why, precisely — this is the answer to the ticket's boundary question
(§2):** the new `"more"` item's left origin resolves against `"seed"`'s
last character, which is authored by client `11100` — a client the server's
candidate *already has in full* (it was accepted history before root was
even proposed). The independent command's own bytes therefore reference
**zero** missing structs: nothing about it points at anything client
`11101` (root's author) ever created. Within this scenario pattern — a
leading command refused before touching `B`, followed by a command targeting
a genuinely separate, unrelated object — true structural adjacency to the
*refused* content is not constructible at all, because "independent" is
defined as targeting something else. So this shape's ACCEPT is not evidence
that native Yrs tolerates adjacency to the withheld item specifically (ticket
01's toy scenario already showed the opposite for that exact case — a same-
`Y.Text`, immediately-following insert *does* get flagged); it is evidence
that adjacency to *real but unrelated, already-known* content changes
nothing, which is the sharper and more relevant fact for whether exact-U
mode is safe for Promeo's actual edit patterns (an edit that lands next to
someone else's already-accepted text, while the editor has an unrelated
locally-refused command pending, is exactly what shape 3 models).

**Reasoned Yjs comparison:** like shape 1, the update is keyed to client
`11101` starting at clock 9, with client `11101` never having reached the
receiver — same coarse-withholding shape as ticket 02's original finding.
Reasoning suggests Yjs would **also** wrongly refuse this one. Not run
directly this session.

### Shape 4: three-command same-client chain — op2 and op3 both ACCEPTED, identically

Setup: `title-chain-op2` and `title-chain-op3` created and accepted
up front. On one speculative session, client A proposes, in order and
without submitting any of them yet: `reject-root-chain` (root), then
`local-chain-op2` (insert `"op2"` into `title-chain-op2`), then
`local-chain-op3` (insert `"op3"` into `title-chain-op3`) — `op3` built
*after* `op2` but, per the ticket's own framing, before either `root` or
`op2` reaches the server. Root is submitted first, then `op2`, then `op3`,
each independently.

```
before-root: {11100: 9, 1: 9}
after-root:  {11100: 9, 1: 9, 11101: 9}
after-op2:   {11100: 9, 1: 9, 11101: 12}
after-op3:   {11100: 9, 1: 9, 11101: 15}
```

Client `11101` (shared by root, op2, and op3) advances monotonically
`9 -> 12 -> 15` — confirmed, not assumed, that op2 shares root's clock chain
and op3 shares op2's.

- `op2` decision: **ACCEPTED**, manual replay `pendingStructCount: 0`.
- `op3` decision: **ACCEPTED**, manual replay `pendingStructCount: 0`.
- **op2 and op3's outcomes are identical.** Refusing `root` did not affect
  `op2`, and `op2` never having been submitted before `op3` (each is
  evaluated by the server against its own fresh candidate, independently)
  did not affect `op3` either, even though `op3`'s own update bytes are
  keyed to start at client `11101`'s clock 12 — a *larger* gap from the
  receiving candidate's point of view than op2's (clock 9) or root's
  (clock 0). A bigger apparent gap did not change the outcome.
- After delivering all three decisions back to A, `speculativePendingStructs`
  is `0` — the client's own view is fully clean once the dust settles, with
  no residual accounting artifact from the chain.

This answers the ticket's chain-specific question (§3) directly: no, the
chain's later position did not reveal any new wrongly-affected case beyond
what the two-command shapes already showed. Both `op2` and `op3` are
targeted at objects structurally unrelated to `root`, `op2`, and each other,
so — consistent with the item-level (not per-client-clock) hypothesis —
neither one's evaluation depends on how many other commands from the same
client came before it, only on whether *its own* bytes structurally
reference anything missing. Neither does.

**Reasoned Yjs comparison:** both `op2`'s and `op3`'s updates are keyed to
client `11101` with a clock start (9 and 12 respectively) the receiver has
never seen — the same coarse-withholding shape, just two different gap
sizes. Reasoning suggests Yjs would wrongly refuse **both**, uniformly,
regardless of chain position — i.e. Yjs's own defect would *also* be chain-
position-independent, just wrong in the opposite direction (refusing both
instead of accepting both). Not run directly this session.

## What this answers

1. **Does native Yrs flag any of the four shapes as causally incomplete, or
   accept them — and does that match or diverge from Yjs?** All four were
   accepted; none flagged. Reasoning from Yjs's documented block-level
   mechanism, shapes 1, 3, and 4 (op2/op3) would likely diverge from Yjs
   (which would probably wrongly refuse them) — three more confirmed-by-
   reasoning instances of the same divergence ticket 02 found directly. Shape
   2 (delete) is not expected to diverge, for a structural reason unrelated
   to runtime precision (see below).
2. **What's the actual boundary?** Confirmed, not merely reinforced: native
   Yrs's causal-incompleteness detection is item-level (needs a genuine
   structural reference to a *missing* item), not block-level
   (client-clock-gap-shaped). Shape 3's adjacent insert is the direct test —
   it references only already-known content, so it has nothing to flag,
   regardless of how "close" it sits to real text. True adjacency to the
   *withheld* item specifically (not merely to *some* real item) is what
   ticket 01's toy scenario showed native Yrs actually catches — this
   ticket's "independent-command" scenario shape structurally cannot
   construct that case, because being adjacent to the refused root's own
   content would make the command dependent, not independent.
3. **Does the chain shape reveal anything new?** No wrongly-affected case
   appeared: `op2` and `op3` were accepted identically, independent of chain
   position and of whether the command in between was ever submitted to the
   server first. This is a positive result for semantic mode's
   robustness-adjacent architecture point (ticket 02's conclusion) — even in
   exact-U mode, native Yrs's per-item precision does not degrade as a
   same-client chain gets longer.
4. **Any false acceptance found?** **No — none, in any of the four shapes.**
   Every accepted command targeted an object with zero structural
   relationship to the refused root (a different `Y.Text`/title entirely, in
   every shape), so every acceptance was of a genuinely safe, unrelated
   edit. Stated plainly per the ticket's own instruction: nothing here should
   have been refused by any reasonable domain standard, and nothing was
   wrongly accepted either.

## Scope notes

- **Shape 2's finding narrows, rather than answers, "does same-client delete
  coupling hold."** A pure delete never advances the deleting client's own
  clock, so a create-then-delete pair cannot exercise the same-client
  clock-sharing precondition at all — this was verified (`sharesClockChain`
  correctly reported `false`), not assumed. A genuine test of delete-specific
  coupling would need two still-pending deletes from the *same* client (so
  the deleting client's own delete-set entries chain together), which this
  scenario does not construct. Not sharp enough to ticket on its own yet;
  flagged for the map's "Not yet specified" in case a later ticket needs it.
- Every reasoned (not run) Yjs comparison above is reasoning from
  `bridge.js:268-292`'s documented block-level mechanism, the same source
  ticket 02 read directly — not assumption from nothing, but also not a
  confirmed run. If a future ticket needs certainty here rather than
  reasoned inference, running the four shapes against `YjsRuntime` too (the
  rig already supports either runtime via `runtimeFactory`) would settle it
  directly.
- These four shapes, plus ticket 02's original one, cover same-client
  coupling for `createTitle`+{`insertText`, `formatText`, `deleteText`} pairs
  and a 3-deep chain. Cross-client overlapping edits (ticket 04), IME
  composition churn (ticket 05), and undo interaction (ticket 06) are
  separate axes per the map's test matrix, not this ticket's job.
