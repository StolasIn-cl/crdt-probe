# Ticket 07 — Deciding Exact-U Admission Mode's Fate for Promeo Title Editing

This is `yjs_probe`'s disposable evidence for Wayfinder ticket 07 —
[Decide Whether Exact-U Admission Mode Is Safe to Adopt for Promeo Title Editing](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/07-decide-whether-exact-u-admission-mode-is-safe-to-adopt.md),
the synthesis/decision ticket closing the
[Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md)
map. This report synthesizes tickets 02–06's evidence into an adopt/reject/
hybrid decision; it does not run any new scenario.

## Decision

**Adopt exact-U admission mode as the default for Promeo's Title editing
surface. Keep semantic-Q re-execution as a documented, supported alternative
execution path in the architecture — not removed, not actively used unless
exact-U is later shown to have a real problem.** No hybrid triggered by
`pendingStructCount` is adopted, for the reason given in Options below.

## Options and trade-offs

1. **Adopt exact-U outright, drop semantic-Q from the architecture.**
   Simplest going forward; removes the Q-executor-drift risk entirely (no
   server-side `Q` executor to keep in parity with the client's Dart
   implementation — a pitfall `yrs-server-centric-reject-admission.html`
   names explicitly). Cost: forecloses semantic-Q as an escape hatch for a
   future command kind that cannot be safely represented as a direct,
   client-computed update.
2. **Keep semantic-Q as the default, treat exact-U as unproven.** Costs the
   Q-executor-drift risk unconditionally, for no safety benefit this map's
   evidence supports — every axis tested (tickets 02–06) found exact-U's own
   distinguishing mechanism (`pendingStructCount` causal-completeness
   detection) produced zero false acceptances and zero false refusals
   against native `YrsRuntime`.
3. **Adopt exact-U as the default; retain semantic-Q in the architecture as a
   documented, not-actively-used alternative** — chosen here. Gets the
   Q-executor-drift-avoidance benefit now, without permanently closing the
   door on semantic-Q if a future Title command kind, or a real production
   incident, ever needs re-execution semantics exact-U cannot express.

A `pendingStructCount`-triggered hybrid (exact-U by default, fall back to
semantic-Q specifically when `pendingStructCount` signals a gap) was
considered and rejected: the one confirmed danger this map found (below) is
invisible to `pendingStructCount` entirely, so such a hybrid would carry
semantic-Q's Q-executor-drift cost without addressing the actual risk found.

## Is there a confirmed false acceptance?

**Yes, one — found in Ticket 04, in `_matchesSemanticScope`
(`title_admission.dart:408-426`), not in `pendingStructCount`.** A
`moveObjects` command declaring targets `{obj1,obj2,obj3}` was ACCEPTED in
one submission order even though its actual effect on the server was
`{obj1}` only — `obj2`/`obj3` were silently overwritten by a concurrent
client's higher-tie-break write before this command's own candidate replay
ran, and `_matchesSemanticScope` only checks (a) nothing outside the
declared scope changed and (b) every declared object still exists — never
that every declared object's *value* actually changed. This is a real,
reproduced defect (re-run independently, confirmed byte-for-byte).

**This finding does not move the exact-U-vs-semantic-Q needle, for a reason
none of tickets 02–06 stated explicitly: `_matchesSemanticScope` runs
unconditionally after the mode branch in `submit()`
(`title_admission.dart:325-353`), identically in both `exactUpdate` and
`semanticCommand` mode.** Confirmed by reading the source directly, not
inferred. Semantic-Q's own candidate execution would produce the exact same
`before`/`after` projections for this scenario shape and pass through the
same `_matchesSemanticScope` call — the defect is orthogonal to which mode
computes `U`, not a cost specific to exact-U. Per this ticket's own
constraint ("any single confirmed false acceptance... is normally decisive
against adopting exact-U"), that constraint's premise — that the acceptance
is a cost *of exact-U specifically* — does not hold here, so it is not
treated as decisive against exact-U. It is treated as a known, common
admission-layer limitation instead (see Known limitation below).

The underlying CRDT merge itself is legitimate and order-independent (both
submission orders converge to byte-identical final field values — Ticket
04's own finding); the defect is entirely in what the admission layer
*reports*, not in the merge result. Concretely for Promeo: the practical
failure mode is a silent, single-operation partial no-op (some of the
objects a user multi-selected and moved don't visibly move, with no error),
discoverable on the client's next resync via `deliver()`'s rebuild from the
server's canonical projection — not data corruption, not a persistent
divergence between client and canonical state.

## False-refusal landscape

**Zero false refusals were found against native `YrsRuntime` across every
shape in tickets 02–06.** Every refusal actually observed in these tickets'
runs was either a deliberate policy refusal used as scenario scaffolding, or
a legitimate `missingDependency`/`dependencyRefused` reflecting a real,
not-yet-resolved dependency (e.g. Ticket 06's undo-before-its-target-lands
race) — never a wrongful refusal of a command that should have succeeded.
The "wrongly refuse" language appearing in Ticket 03's report (`p8`)
describes *reasoned, not run* predictions of what Yjs would do, not
anything native Yrs actually did.

**The coherent boundary rule, confirmed (not merely hypothesized) by Ticket
03 shape 3:** native Yrs's causal-completeness detection (`pendingStructCount`
/ `ytransaction_pending_update`+`ytransaction_pending_ds`) is item-level —
it fires only when a candidate structurally references a genuinely missing
item — never merely because a command shares a client's clock chain with a
refused predecessor. Adjacency to real-but-unrelated content (shape 3)
changes nothing; true structural dependence on a withheld item (Ticket 01's
toy scenario) is the only thing that trips it. This is a strictly narrower,
more precise trigger than Yjs's documented block-level bookkeeping — the
divergence this whole map's extension was chasing runs entirely in the safe
direction (native Yrs accepts more of what's actually safe, never accepts
something Yjs would have correctly caught).

## Known limitation (not a blocker, not opened as a tracked ticket)

`_matchesSemanticScope`'s missing "declared target actually changed" check
is a known, accepted-risk limitation of `yjs_probe`'s prototype admission
layer, common to both execution modes. Per explicit user decision
(2026-09-10 grilling session): **not opened as a Wayfinder ticket** — the
team does not currently intend to schedule the fix, and an open, unclaimed
ticket that nobody plans to pick up is worse bookkeeping than a plainly
documented limitation. It is recorded here and in
`yrs-server-centric-reject-admission.html`'s technical-debt table. If it is
ever fixed, the direction agreed during grilling was a generic check (every
object in `declaredScope` must show some field-level difference between
`before` and `after`, regardless of `TitleCommandKind`) rather than a
per-command-kind semantic-diff rule — the scope of commands tested here
(insert/delete/format/clear-format/whole-replace/moveObjects) didn't surface
a case the generic rule couldn't catch.

## Assumptions and evidence

**Confirmed facts:**
- `pendingStructCount`: 0/0 false acceptances, 0/0 false refusals, across
  tickets 02–06's full test matrix (same-client coupling ×4 shapes,
  cross-client overlap ×2 orders, IME churn ×2 burst sizes + cancel, undo ×5
  scenarios).
- `_matchesSemanticScope` false acceptance (Ticket 04) is mode-independent —
  confirmed via direct source read of `title_admission.dart:325-353`, not
  assumed.
- Exact-U's structural advantage over semantic-Q (no server-side Q executor,
  hence no Q-executor-drift risk) is real and unconditional — it does not
  depend on any of tickets 02–06's specific findings.

**Assumptions:**
- Ticket 03 shapes 1/3/4's Yjs comparisons are reasoned from `bridge.js`'s
  documented mechanism, not run directly. Judged sufficient to rely on for
  this decision — the reasoning is corroborated by Ticket 01's independently
  *run* toy-scenario result and by the coherent, mechanistically-explained
  item-level boundary Ticket 03 shape 3 confirmed empirically. Not re-run.

**Unknowns, left as residual fog (see map's Not yet specified — unchanged
by this ticket):**
- Same-client delete-coupling with two still-pending deletes (not a
  create-then-delete pair) remains untested; tickets 04–06 did not surface a
  delete-shaped gap that makes it urgent.

## Revisit when

- A new Title command kind is added that `_matchesSemanticScope`'s generic
  scope check, or exact-U's client-computed-`U` model, cannot safely
  represent.
- A future Yrs version change alters `pendingStructCount`'s item-level
  precision (the boundary this decision leans on).
- Real production traffic, once a server-side admission gate is ever built
  (see map's Out of scope re: `yrs-server-seam`), surfaces a false
  acceptance or false refusal pattern this probe's scenarios didn't cover.
- The `_matchesSemanticScope` known limitation is ever scheduled for a fix —
  at that point, open a proper ticket rather than relying on this report's
  note.

## Constraint compliance

This ticket produced no new scenario code and modified no source file — it
is a synthesis of tickets 02–06's existing, already-verified evidence plus
one direct source read (`title_admission.dart:325-353`, `:408-426`) to
establish the mode-independence finding above. `title_admission.dart` and
`title_admission_native_probe.dart` were read, not modified, by this ticket.
