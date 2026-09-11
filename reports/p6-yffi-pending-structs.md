# Ticket 01 — Can yffi detect causal incompleteness, cheaply or by patching?

This is `yjs_probe`'s disposable research note for Wayfinder ticket 01 —
[Research Whether yffi Can Detect Causal Incompleteness, Cheaply or by Patching](../../promeo_trunk/docs/realtime-collaboration/yrs-native-reject-admission-feasibility/issues/01-research-whether-yffi-can-detect-causal-incompleteness.md),
part of the `yrs-native-reject-admission-feasibility` map. It answers whether
`YrsRuntime.pendingStructCount` (currently `throw UnsupportedError('pending
struct enumeration is not exposed by yffi')`) can be made to work against the
real native Yrs runtime. No production collaboration code is touched, and the
existing vendored `yjs_probe/native/yffi/v0.27.3/` asset is untouched.

**Headline: yes, a no-native-change alternative exists, it was verified to
work against the real vendored DLL, and it was used instead of patching.**
`yffi`'s C API (`libyrs.h`) already exports `ytransaction_pending_update` and
`ytransaction_pending_ds` — the DLL's own export table was checked, not just
the header — and together they are the *exact* logic Rust's own
`Transaction::has_missing_updates` uses. No Rust source change, no rebuild,
no new `.dll`.

## 1. The cheap-alternative check — concrete, not inferred

The ticket asked to check the *already-exposed* yffi C surface concretely
from real function signatures, not guess. Two facts were checked directly:

### 1a. What `has_missing_updates` actually is, in the vendored Rust core

```
$ grep -n "has_missing_updates" -r yrs/src/transaction.rs
285:    fn has_missing_updates(&self) -> bool {
```

(inside
`promeo_trunk/lib/packages/yrs_ffi/windows/third_party/y-crdt/yrs/src/transaction.rs`,
read-only — never modified)

```rust
    /// Returns `true` if current document has any pending updates that are not yet
    /// integrated into the document.
    fn has_missing_updates(&self) -> bool {
        let store = self.store();
        store.pending.is_some() || store.pending_ds.is_some()
    }
```

So the fact the ticket needs is exactly: *is `store.pending` set, or is
`store.pending_ds` set*.

### 1b. What yffi's own C API already exposes for exactly those two fields

`yffi/src/lib.rs` (same vendored tree, same crate the ticket named as the
patch target) already has:

```rust
#[no_mangle]
pub unsafe extern "C" fn ytransaction_pending_ds(txn: *const Transaction) -> *mut YIdSet {
    let txn = txn.as_ref().unwrap();
    match txn.store().pending_ds() {
        None => null_mut(),
        Some(ds) => Box::into_raw(Box::new(YIdSet::new(ds))),
    }
}
```

```rust
#[no_mangle]
pub unsafe extern "C" fn ytransaction_pending_update(
    txn: *const Transaction,
) -> *mut YPendingUpdate {
    let txn = txn.as_ref().unwrap();
    match txn.store().pending_update() {
        None => null_mut(),
        Some(u) => { /* ... boxes a YPendingUpdate carrying the missing YStateVector ... */ }
    }
}
```

`txn.store().pending_ds()` and `txn.store().pending_update()` read exactly
`store.pending_ds` and `store.pending` — the same two fields
`has_missing_updates` ORs together. **`ytransaction_pending_update(txn) !=
NULL || ytransaction_pending_ds(txn) != NULL` is not an approximation of
`has_missing_updates()`, it is the same boolean, computed from the same two
fields, just not pre-OR'd into a single exported bool.**

Both are declared in the vendored `libyrs.h` this probe already ships
(`yjs_probe/native/yffi/v0.27.3/libyrs.h:1456` and `:1470`):

```
struct YIdSet *ytransaction_pending_ds(const YTransaction *txn);
...
struct YPendingUpdate *ytransaction_pending_update(const YTransaction *txn);
```

### 1c. Confirmed present in the actual shipped `.dll`, not just the header

A header declaration alone would not prove the symbol is linked into the
binary this probe actually loads. Checked with `objdump` against the
existing, unmodified `yjs_probe/native/yffi/v0.27.3/yrs.dll`:

```
$ objdump -p yrs.dll | grep -i "pending\|has_missing"
	[  97] ypending_update_destroy
	[ 129] ytransaction_pending_ds
	[ 130] ytransaction_pending_update
```

All three symbols the header promises (the two accessors plus the
destructor for the update struct; `ydelete_set_destroy` is also present,
confirmed separately) are really exported by the `.dll` already vendored in
this repo. **Conclusion for §1: yes — a no-native-change alternative exists.
It was used instead of patching, per the ticket's own instruction.**

## 2. Verifying it actually works — toy scenario, real Yrs document

Per the ticket's evidentiary bar ("this is fact-finding *and* an attempt to
build, not reasoning-only"), the alternative was not just reasoned about —
it was bound and run.

`yjs_probe/tool/pending_updates_probe_dart.dart` (new, plain `dart run`, no
Flutter engine — same pattern `tool/zorder_probe_dart.dart` established for
ticket 03's p5 report, chosen for the same reason: this sandboxed
environment hangs `flutter test`'s Windows-app-to-VM-service socket, as
already documented in
[`p5-zorder-merge.md`](p5-zorder-merge.md#how-this-was-run)) does the
following against the *unpatched* `native/yffi/v0.27.3/yrs.dll`:

- Locally declares Dart FFI bindings for `ytransaction_pending_update`,
  `ytransaction_pending_ds`, and their two destructors — these are not yet
  wired into `YrsBindings` in `lib/runtime/yrs/yrs_ffi_bindings.dart`
  (deliberately: that permanent-binding decision belongs to Ticket 02, not
  this research ticket).
- Builds a producer `Y.Text` document (client id 500), inserts `"A"` (op1,
  parent) and then `"B"` (op2, child — causally depends on op1 via its
  left-origin), and extracts each op's own Yjs update bytes via
  `ytransaction_state_diff_v1` against the state vector captured right
  before/after op1.
- Applies the **child update first** to a fresh target document (client id
  501) and reads pending status.
- Applies the **parent update second** and re-reads pending status.

Run:

```
$ cd yjs_probe
$ dart run tool/pending_updates_probe_dart.dart
=== Wayfinder ticket 01: pending-struct detection via already-exposed yffi C API (no native patch) ===
DLL: C:\Users\stolas_in\Desktop\promeo-pc-promeo-memory-profiler\yjs_probe\native/yffi/v0.27.3/yrs.dll

--- producer state ---
producer text after both ops: "AB"
U1 (parent, op1) bytes: 18
U2 (child, op2, causally depends on op1) bytes: 12

--- step 1: apply child (U2) before parent (U1) to a fresh doc ---
target text after child-only apply: ""
ytransaction_pending_update/ds -> hasMissing=true (missingEntries=1, missingClientId=500, missingClock=0)
EXPECTATION hasMissing == true: PASS

--- step 2: apply parent (U1) so the dependency is satisfied ---
target text after both applied: "AB"
ytransaction_pending_update/ds -> hasMissing=false (missingEntries=0)
EXPECTATION hasMissing == false: PASS
EXPECTATION target text == producer text ("AB"): PASS

=== OVERALL: PASS ===
```

- **Result: PASS.**
- Evidence: with only the child update applied, `ytransaction_pending_update`
  returned a non-null `YPendingUpdate` whose `missing` state vector named
  exactly the withheld dependency (`clientId=500, clock=0` — the parent
  insert's own clock position) and the target document's visible text stayed
  empty (the child struct is held back, not silently applied out of causal
  order). After the parent update arrived, `ytransaction_pending_update`
  returned `NULL`, `ytransaction_pending_ds` stayed `NULL` throughout (no
  delete-set dependency in this scenario, as expected for a pure insert
  case), and the target's text converged to the producer's `"AB"`. This is
  exactly the shape of the ticket's required toy scenario and exactly the
  shape of `p4-title-admission.md`'s "same-document independent local edit
  exposes Yjs causal coupling" finding (`pendingStructs: 1` there, `hasMissing:
  true` here — same underlying condition, observed through two different
  runtimes).

## 3. Cost

- **No native patch was attempted** — §1/§2 made one unnecessary. The
  Rust/cargo toolchain the ticket named was nonetheless checked for the
  record, in case a future ticket needs it for something else:
  ```
  $ cargo --version
  cargo 1.98.0 (797e8a9bc 2026-08-05)
  $ rustc --version
  rustc 1.98.0 (88d9e12ae 2026-08-18)
  ```
  Matches the ticket's stated `cargo 1.98.0`/`rustc 1.98.0` exactly, so
  patching remains available as a fallback if Ticket 02 or a later ticket
  ever needs a Yrs C export this vendored yffi build genuinely lacks — this
  is not one of those cases.
- **No new native asset was produced.** `yjs_probe/native/yffi/v0.27.3/` is
  unchanged (still the vendored, unpatched asset); there is no
  `v0.27.3-patched-pending-structs/` directory, because nothing needed
  patching.
- **Diff size against vendored source: zero.**
  `promeo_trunk/lib/packages/yrs_ffi/windows/third_party/y-crdt` was read
  only, never written.
- **New files added, entirely inside `yjs_probe`:**
  - `yjs_probe/tool/pending_updates_probe_dart.dart` (throwaway verification
    harness, ~300 lines, mirrors `tool/zorder_probe_dart.dart`'s shape)
  - `yjs_probe/reports/p6-yffi-pending-structs.md` (this file)
- **Existing sanity tests
  (`integration_test/yrs_runtime_test.dart`/`integration_test/yrs_asset_test.dart`):**
  not re-run. Reasoning, not evasion: both are Flutter `integration_test`
  files that exercise `YrsRuntime` against the same, unmodified
  `native/yffi/v0.27.3/yrs.dll` this ticket also left unmodified — neither
  the `.dll` nor `lib/runtime/yrs/yrs_ffi_bindings.dart` nor
  `lib/runtime/yrs/yrs_runtime.dart` was touched by this ticket, so there is
  no code path this change could have regressed for them to catch. Running
  them would additionally hit the same sandboxed-environment
  Windows-app-to-VM-service hang already documented for the identical
  harness shape in
  [`p5-zorder-merge.md`](p5-zorder-merge.md#how-this-was-run) (`flutter test
  integration_test/zorder_merge_test.dart` built successfully but then hung
  indefinitely with no output). If a future session can run a Windows
  Flutter integration test outside this sandbox, re-running those two files
  unmodified is still the right regression check for *this* finding's
  eventual production wiring (Ticket 02) — not for this ticket, which changed
  no runtime code.

## The answer must decide

1. **Whether a no-native-change alternative exists.** Yes. `libyrs.h`
   already declares, and the vendored `yrs.dll` already exports,
   `ytransaction_pending_update` and `ytransaction_pending_ds` — the exact
   two fields (`store.pending`, `store.pending_ds`) Rust's own
   `has_missing_updates()` ORs together (`yrs/src/transaction.rs:285`).
   `ytransaction_pending_update(txn) != NULL || ytransaction_pending_ds(txn)
   != NULL` **is** `has_missing_updates()`, not an inference from unrelated
   signals like state-vector diffing. It was used instead of patching, per
   §1–§2 above, and verified against the real DLL with the ticket's own toy
   scenario (child-before-parent → true, then-parent-arrives → false), both
   PASS.
2. **Patching.** Not attempted — unnecessary once §1 held up under the DLL
   export-table check. No diff, no build, no new asset. (Toolchain
   confirmed available regardless: `cargo`/`rustc` 1.98.0, matching the
   ticket's expectation, in case a genuinely-missing export turns up later.)
3. **What Ticket 02 should call.** Bind `ytransaction_pending_update` and
   `ytransaction_pending_ds` (plus their destructors,
   `ypending_update_destroy` and `ydelete_set_destroy`) into `YrsBindings`
   in `lib/runtime/yrs/yrs_ffi_bindings.dart`, and implement
   `YrsRuntime.pendingStructCount` (or a same-shaped boolean, since neither
   exported function actually enumerates a *count* of pending structs — see
   caveat below) as: open a read transaction, call both, treat "either
   returned non-null" as "has pending/incomplete structs", free whatever was
   returned via the matching destructor, commit the read transaction. The
   exact binding shapes (`YStateVector`, `YPendingUpdate`, opaque `YIdSet`)
   and the read-transaction-then-both-calls-then-free sequence are already
   working code in `yjs_probe/tool/pending_updates_probe_dart.dart` —
   Ticket 02 can lift the struct/typedef declarations and the
   `pendingStatus` method directly rather than re-deriving them.

   **Deliberate simplification to name explicitly, since this is a
   boolean/state-vector fact, not literally a "count":** `CrdtRuntime`'s
   interface method is named `pendingStructCount` and returns `int` (see
   `lib/prototype/title_admission.dart`'s
   `if (pendingStructs != 0) { refuse causalIncomplete }` and
   `lib/runtime/crdt_runtime.dart`). Neither `ytransaction_pending_update`
   nor `ytransaction_pending_ds` reports *how many* individual structs are
   withheld — `YPendingUpdate.missing` is a `YStateVector` (one entry per
   *client*, not per struct) and `YIdSet` is a delete-set, not a struct
   tally. `YjsRuntime`'s existing `pendingStructCount` (the Yjs-side
   implementation this probe already exercises in `p4`) can report a true
   per-struct count because `Y.Doc.store.pendingStructs` is a JS-side array
   yjs itself maintains; yrs/yffi does not expose an equivalent enumerable
   collection. The honest simplification for `YrsRuntime` is: return `1` for
   "yes, causally incomplete" and `0` for "no", not a real count — every
   existing call site in `title_admission.dart` and the p4 scenarios only
   ever tests `!= 0`/`== 0`, never a specific magnitude, so this changes
   nothing observable at any call site today. This should be named plainly
   in `YrsRuntime`'s implementation (a doc comment on the override, not a
   silent behavior difference from `YjsRuntime`) so a future reader who does
   start relying on the numeric value is warned rather than surprised.

## Files touched by this ticket

- Added: [`yjs_probe/tool/pending_updates_probe_dart.dart`](../tool/pending_updates_probe_dart.dart)
- Added: this report, `yjs_probe/reports/p6-yffi-pending-structs.md`
- Unchanged: `yjs_probe/native/yffi/v0.27.3/` (vendored asset — read-only,
  no new `v0.27.3-patched-*` sibling was needed)
- Unchanged: `promeo_trunk/lib/packages/yrs_ffi` and everything else under
  `promeo_trunk/lib/packages/` (never touched, per the ticket's constraint)
