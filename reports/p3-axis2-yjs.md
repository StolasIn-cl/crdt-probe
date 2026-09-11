# P3 Axis 2 — Yjs control group measurement report

- Runtime: `yjs-quickjs`
- Capabilities: decodeUpdate, readStateVector, enumerateFormatMarkers, countPendingStructs, readUndoStackItems

| Scenario | Targets | Outcome | Evidence |
|---|---|---|---|
| S2.1 `stackitem-boundary-capture-timeout` | ticket 25 §1 and ticket 16 §7 — measure the default capture timeout against Promeo's 1,000 ms typing group | pass | two edits within 100 ms grouped; edit after 650 ms was a separate stack item (first undo="ab", second undo="") |
| S2.2 `remote-update-closes-stackitem-or-not` | ticket 25 §1 — whether a remote update closes the local capture group | pass | remote B arrived between local A and C; one undo left "B". The remote update did not close it: A and C were undone together. |
| S2.3 `trackedOrigins-separates-mine-from-yours` | ticket 25 §2 — tracked origins separate local and untracked contributions | pass | tracked origin mine removed C then A while untracked origin other remained as B |
| S2.4 `undo-my-insert-inside-your-range` | ticket 23 §6 — undo a local insert while preserving another participant's edit | pass | local X was removed; remote Y remained: "abYcd" |
| S2.5 `redo-of-a-superseded-write-preserves-the-remote-value` | ticket 07 §5 — a redo of a locally superseded write must not overwrite a remote value; ticket 17 §3 is about what redoItem returns internally, not about the UndoManager.redo return value; ticket 07 §10 asks whether the skip is named anywhere the redo return value does not answer | pass | the property this scenario asserts held: the remote value survived the redo attempt, final x=2.0 on yjs-quickjs, unchanged from what B wrote. Reported but NOT asserted: redo() itself returned true on this runtime. That boolean is a separate claim from whether the write was skipped: measured across both runtimes in this project own test run, Yjs redo() returns true while skipping the superseded write, and Yrs redo() returns false for the identical scenario, yet both leave x=2 unchanged. Neither boolean names what was skipped or why, which is the gap ticket 07 §10 asked about and this scenario cannot close by itself. |
| S2.6 `undo-a-formatting-only-change` | ticket 23 — a style-only change must be independently undoable | pass | format-only edit was captured and undo removed the bold mark |
| S2.8 `undo-a-deletion-revives-or-rewrites` | ticket 17 §127 — whether undo of a deletion reuses the deleted item's own identity or mints a fresh one, settled directly via decodeUpdate rather than inferred from byte size (task 19 round 3, Finding 2); byte size is reported only as supporting detail | pass | text round-tripped to "abcde" after undo. decodeUpdate on the update the undo itself produced introduced a clock ({14}) above every clock seen before the undo (ceiling 9) — a fresh item, not a reuse of the deleted item's own identity. This settles mint vs reuse directly; it is not inferred from size. Supporting size detail: baseline=124 B, after delete=136 B (delta=12 B), after undo=143 B (delta=7 B) — the undo grew by 7 B, which a same-size-or-smaller flag flip could not produce. No length is asserted; the decodeUpdate identity check above is what this conclusion rests on. |
| S2.9 `concurrent-delete-then-undo` | ticket 07 §5 and ticket 17 §127 — whether undoing a deletion that a concurrent peer also performed reintroduces a character over a delete that peer never withdrew | pass | both clients converged on "abde" after concurrent deletes at index 2. A undo=true -> a="abcde", and after delivery b="abcde". the character came back ("abcde"). B's delete still stands -- B never withdrew it -- yet B's own document now shows the character again, which is exactly what ticket 07 §5 rejected. |
| S2.10 `undo-redo-cycles-do-not-grow-the-document` | ticket 17 §127 — byte growth across repeated undo/redo cycles, sampled every cycle (task 19 round 3, Finding 4) so a linear trend can be told apart from a one-off jump plus a plateau, which two endpoints cannot do | pass | text round-tripped to "abcde" through 10 undo/redo cycles. The document grew by 94 B (9.4 B/cycle) over 10 cycles (size before=124 B, after=218 B). Sampled every cycle rather than only at the endpoints: the 10 per-cycle deltas were not all equal ([13, 9, 9, 9, 9, 9, 9, 9, 9, 9]); growth is not simply linear across cycles. Per redoItem, only the redo half of each cycle can mint a fresh item; the undo half only deletes — this run attributes growth no further than "at least one of the two operations per cycle wrote new content." No length is asserted; this is the measurement. |

## Traces

### S2.1

-   -> stack before=2; undo1=true -> "ab"; undo2=true -> ""

### S2.2

-   -> before="ABC"; undo=true; after="B"

### S2.3

-   -> undo1=true -> "AB"; undo2=true -> "B"

### S2.4

-   -> before="abXYcd"; undo=true; after="abYcd"

### S2.5

-   -> undo=true; remote superseding x=2; redo=true; final x=2.0

### S2.6

-   -> undo=true; bold before=true; bold after=false

### S2.8

-   -> baseline=124 B; after erase(2,1)="abde" (136 B, delete delta=12 B); after undo="abcde" (143 B, undo delta=7 B); clock ceiling before undo=9; clocks in the undo update={14}; minted a new clock=true

### S2.9

-   -> both clients seeded: a="abcde" b="abcde"
-   -> after both deleted index 2 independently and exchanged updates: a="abde" b="abde"
-   -> A undoes its own deletion: undo=true -> a="abcde"; after delivering A's update to B -> b="abcde"

### S2.10

-   -> before=124 B; size after each of 10 cycles=[137, 146, 155, 164, 173, 182, 191, 200, 209, 218]; per-cycle deltas=[13, 9, 9, 9, 9, 9, 9, 9, 9, 9]; total delta=94 B over 10 cycles; text="abcde"


