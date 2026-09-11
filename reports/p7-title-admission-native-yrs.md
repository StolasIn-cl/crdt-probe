# Ticket 02 — first slice of the Title admission suite on native YrsRuntime

This is `yjs_probe`'s disposable evidence for Wayfinder ticket 02 —
[Port the First Slice of the Title Admission Suite to YrsRuntime](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/02-port-the-first-slice-of-the-title-admission-suite-to-yrsruntime.md),
part of the [Verify Server-Centric Reject-Admission Holds on the Real Yrs (yffi) Runtime](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/map.md)
map. It runs two scenarios from `integration_test/title_admission_test.dart`'s
20-scenario Yjs suite for real against the vendored, unpatched
`native/yffi/v0.27.3/yrs.dll`, reusing `YjsAdmissionServer`/`YjsAdmissionClient`
from `lib/prototype/title_admission.dart` completely unchanged — the only
thing that varies is which `CrdtRuntime` the rig constructs.

**Headline: the exact-U-vs-semantic distinction does *not* survive the
runtime swap unchanged — and the way it differs is itself the finding.**
Semantic mode ports cleanly (scenario 2: PASS, `pendingStructCount` stays 0
throughout, exactly as on Yjs). Exact-U mode does **not** reproduce the known
Yjs defect (scenario 1: the independent, unrelated command is *correctly
accepted* on native Yrs, not wrongly refused as `causalIncomplete`) — real,
confirmed evidence that native Yrs's causal-incompleteness detection is more
precise than Yjs's for this scenario shape, not merely "the same bug ported."

## How this was run

Scenario logic lives once in `lib/prototype/title_admission_native_probe.dart`,
shared by two harnesses so they cannot drift apart:

- `integration_test/title_admission_native_yrs_test.dart` — the standard
  Flutter `integration_test` harness, matching this repo's convention. Left
  in the repo, analyzed clean, for whoever can run a Windows Flutter
  integration test outside this sandbox.
- `tool/title_admission_native_yrs_probe_dart.dart` — a plain `dart run`
  script with zero Flutter dependency, the same workaround pattern ticket
  01's `pending_updates_probe_dart.dart` and ticket 03's
  `zorder_probe_dart.dart` established: `flutter test` hangs this sandboxed
  environment's Windows-app-to-VM-service socket (documented in
  `p5-zorder-merge.md` and `p6-yffi-pending-structs.md`), while an identical
  scenario invoked via plain `dart run` against the same `yrs.dll` completes
  in seconds. **This report's numbers come from that script, run for real —
  not from the untested Flutter file.**

`YrsRuntime.create()` opens `yrs.dll` by bare name
(`DynamicLibrary.open('yrs.dll')`), resolved by Windows via the process's DLL
search path. Under a plain `dart run` that path doesn't include the vendored
asset directory by default, so the tool script adds it with
`SetDllDirectoryW` (a Win32 call via `dart:ffi`) before calling
`YrsRuntime.create()` — throwaway-script plumbing, not a change to
`YrsRuntime.create()` itself, which stays exactly what the ticket asked for:
a pure runtime-factory swap.

## Result: 1/2 scenarios PASS as originally asserted — and that is the real answer

### Scenario 2 (semantic mode): semantic replay removes rejected root without causal residue — **PASS, ported cleanly**

Real run output:

```
--- Scenario 2 (semantic mode): semantic replay after refusal ---
PASS: semantic replay removes rejected root without causal residue (native Yrs)
Evidence: after a policy refusal, the surviving independent Q was re-executed
from accepted B on native Yrs; no exact rejected U was replayed and
pendingStructCount stayed 0 throughout (0 final).
```

Final projections (both A and B participants converged with the server):

- `title-a` (the rejected root's target): `text: ""` — the rejected insert
  never landed, exactly as on Yjs.
- `title-b` (the surviving format's target): `delta: [{"insert":"s","attributes":{"bold":true}},{"insert":"eed"}]`
  — the surviving `format` command was re-executed fresh against accepted `B`
  (semantic mode never touches the rejected root's bytes at all) and landed
  correctly.
- `pendingStructs: 0` throughout — semantic re-execution never leaves a
  causally-incomplete document, on native Yrs exactly as it does on Yjs.

This confirms semantic mode's actual protection mechanism — re-executing the
survivor's own `Q` fresh against current canonical `B`, never touching the
rejected root's stale update bytes — is a property of the *architecture*, not
of Yjs specifically. It holds unchanged on the real native runtime Promeo
ships.

### Scenario 1 (exact-U mode): same-document independent local edit — **the assertion FAILS; native Yrs does not reproduce the Yjs defect**

Real run output:

```
--- Scenario 1 (exact-U mode): same-document independent local edit ---
FAIL: Scenario 1 (exact-U mode): same-document independent local edit
Error: Bad state: independent command should have been refused, was accepted
```

The scenario reproduces `p4-title-admission.md`'s exact setup: client A
creates `title-root` (`reject-root`, refused by server policy before any `B`
mutation — its bytes never touch server `B`), then, still on the *same*
speculative document (no rebuild in between, so the same client-clock
chain), inserts `"survives?"` into an unrelated, already-accepted, empty
`title-keep` (`local-edit-keep`, no semantic `dependsOn` — deliberately, per
the scenario's own point). On Yjs, this second, semantically-independent
command is wrongly refused as `causalIncomplete`, because its Yjs update
bytes share client A's clock chain with the refused root and applying them
alone to a candidate leaves the candidate causally incomplete. **On native
Yrs, the second command was accepted — no gap was detected.**

#### Why: verified with a state-vector trace, not assumed

Instrumenting the same production `YjsAdmissionServer`/`YjsAdmissionClient`
code path (not a simplified stand-in) confirms the two commands genuinely do
share one client's contiguous clock chain, so this isn't a case of them
landing on different clients by accident:

```
speculative SV before root: {1: 9}
speculative SV after root:  {11100: 9, 1: 9}
speculative SV after independent: {11100: 18, 1: 9}
```

Client `11100` (A's rebuilt speculative document identity) goes `absent →
[0,9) → [9,18)` — `root`'s creation consumes clock `[0,9)`, and
`independent`'s insert consumes the immediately-following `[9,18)` on the
*same* client, exactly the shared-clock-chain shape the scenario is built to
exercise. Manually replaying `independent`'s own envelope bytes alone (never
applying `root`'s bytes at all) against a fresh candidate that has the
server's real snapshot but has never seen client `11100` — precisely what
`YjsAdmissionServer.submit`'s candidate-execution path does internally —
gives:

```
MANUAL candidate pendingStructCount after applying independent.yrsUpdate alone: 0
MANUAL candidate objects: [title-keep]
  title-keep: text=survives?
```

No gap. The update integrates cleanly and `title-keep` shows the inserted
text immediately. By contrast, a structurally-adjacent case — inserting a
second character *right after* a first character in the *same* `Y.Text`,
exactly ticket 01's own toy scenario shape — **does** get flagged as pending
by the same `YrsRuntime.pendingStructCount` implementation:

```
u2 (independent insert) updates: 1, bytes: [21]
pendingStructCount after applying u2 alone (no u1): 1
```

So `YrsRuntime.pendingStructCount` (this ticket's own new code) is not
silently broken — the same override correctly flags a genuine positional gap
in one case and correctly reports none in the other. The difference is in
what each case actually needs: ticket 01's toy insertion is *structurally
adjacent* to the withheld item (same `Y.Text`, immediately following
position — the new character's left origin literally is the missing item),
while scenario 1's `independent` edit targets a *different, already-complete*
branch (`title-keep`'s separate, empty `Y.Text`) that never references
anything `root` created. The two commands share a client's clock numbering
but have no structural dependency between their items.

Yjs's own bridge code, read for this investigation
(`yjs_probe/js/src/bridge.js:268-292`), documents that its
`pendingStructCount` reads `doc.store.pendingStructs — { missing: Map<client,
clock>, update } | null` — the *entire received update* is held back as one
unit keyed by which clients' clocks are missing, not decomposed by whether
any individual item inside it actually needs the missing range. That is
consistent with what was observed here: Yjs's integration algorithm appears
to require a client's structs to be integrated in strict, unbroken clock
order regardless of whether a later item structurally depends on the gap,
while native Yrs's `has_missing_updates` (`ytransaction_pending_update`/
`ytransaction_pending_ds`, the same mechanism ticket 01 verified) did not
flag this specific structurally-independent case as pending. This is an
observed behavioral difference between the two runtimes' integration
algorithms, not a difference in wire format (both are lib0 v1, already
confirmed identical in `axis2_cross_runtime_test.dart`) — the *scope* of that
difference (whether it generalizes beyond "new key + insert into an empty,
unrelated `Y.Text`") was not explored further; scoping it precisely is fog
for a later ticket, not this one.

## What this answers

1. **Do both scenarios pass against `YrsRuntime` with the same evidence shape
   as their Yjs runs?** No — and that divergence is itself scenario 1's
   value as a *negative control*. Scenario 2 passes with the same evidence
   shape. Scenario 1 does not: the assertion "the independent command is
   wrongly refused" does not hold on native Yrs. This was verified with a
   concrete run and a state-vector trace, not assumed or smoothed over — see
   above.
2. **What differs from the Yjs run, and is it expected or a real gap?** The
   difference is real and unexpected relative to the ticket's own working
   assumption (that this specific defect would reproduce unchanged) — see the
   headline above. It is not an artifact of different update bytes or
   different client-clock representation; the state-vector trace confirms
   the same shared-clock-chain shape existed on Yrs as on Yjs, and the two
   runtimes still disagreed on whether the second command was safe to
   accept.
3. **Did `YjsAdmissionServer`/`YjsAdmissionClient` or the command vocabulary
   have to change?** No. Both scenarios ran with `title_admission.dart`
   completely unchanged, exactly as the ticket's constraint required — the
   only thing that varied was which `CrdtRuntime` the rig constructed. The
   one piece of new code this ticket added was `YrsRuntime.pendingStructCount`
   itself (`lib/runtime/yrs/yrs_runtime.dart`, wiring
   `lib/runtime/yrs/yrs_ffi_bindings.dart`'s new
   `ytransaction_pending_update`/`ytransaction_pending_ds` bindings, per
   ticket 01's answer) — and that override was independently confirmed
   correct on both a case that should flag pending (adjacent same-`Y.Text`
   insert) and a case that should not (this scenario), so the divergence is
   in the two runtimes' actual behavior, not in this ticket's binding code.
4. **Does the exact-U-vs-semantic distinction survive the runtime swap?**
   Partially, and asymmetrically. Semantic mode's protection (re-executing
   `Q` fresh, never touching rejected bytes) survives unchanged — scenario 2
   is identical to its Yjs run. Exact-U mode's *specific known defect*
   (wrongly refusing a semantically-unrelated command that merely shares a
   client's clock chain with an already-refused command) does **not**
   reproduce on native Yrs for this scenario's shape — native Yrs's causal
   detection appears more precise than Yjs's here, accepting a case Yjs
   would refuse. This is the headline finding this ticket exists to
   surface, and it argues *for* the map's semantic-mode conclusion for a
   different reason than expected: not "exact-U is equally broken on both
   runtimes, so prefer semantic mode everywhere," but "exact-U's behavior is
   *runtime-dependent* in a way that would make its safety margin
   unpredictable and non-portable if Promeo ever changed CRDT engines or
   ran mixed client/server engine versions — semantic mode's correctness
   argument does not depend on which runtime is underneath, and this
   ticket's evidence is the first controlled comparison showing that
   dependency is real, not hypothetical."

## Scope notes

- A no-native-change, `YjsAdmissionServer`/`YjsAdmissionClient`-unchanged
  port of a first slice was completed, run for real, and both a pass and a
  fail were captured with concrete evidence per the ticket's own evidentiary
  bar — a converging-but-different outcome was not smoothed into a single
  "it works" verdict.
- Scenario 1's finding is scoped narrowly to the specific shape exercised
  here (a new-key object creation followed by an insert into a separate,
  empty, already-accepted `Y.Text`, sharing one client's clock chain, no
  semantic `dependsOn`). Whether native Yrs also declines to flag other
  causal-coupling shapes (e.g. two edits to the *same* already-non-empty
  `Y.Text`, or a format command instead of an insert) was not tested and is
  not claimed here — see the map's "Not yet specified" for what remains
  fog.
- Expanding beyond these two scenarios to the remaining ~18 in
  `p4-title-admission.md` is later fog per the map, not this ticket's job.
