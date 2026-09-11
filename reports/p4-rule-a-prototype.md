# P4 Rule A prototype (yata-core ticket 01)

Prototypes `PromeoRuntime` (Rule A: an insertion lands immediately right of its anchor, applied in server sequence order -- no YATA integration loop, no clientID tie-break) and measures the contiguity claim and the pre-acknowledgement reflow ticket 15 §2 only reasoned about, plus a re-run of S0.3 against an actual Rule A implementation.

## 1. Contiguity scenario

### Contiguity -- `promeo-rule-a`

Two writers each type a 3-character burst ("P","Q","R" and "X","Y","Z") at the same anchor. Contiguous: "PQR" and "XYZ" each appear as one unbroken, in-order substring (the two runs may interleave as whole blocks in either order). Shredded: anything else -- one writer's characters broken open by the other's, e.g. "PXQYRZ" or "PQXYRZ".

| # | server interleaving (1=P/Q/R writer, 2=X/Y/Z writer) | resulting string | PQR contiguous | XYZ contiguous |
|---|---|---|---|---|
| 1 | 111222 | `aXYZPQRbc` | true | true |
| 2 | 112122 | `aXYZPQRbc` | true | true |
| 3 | 112212 | `aXYZPQRbc` | true | true |
| 4 | 112221 | `aXYZPQRbc` | true | true |
| 5 | 121122 | `aXYZPQRbc` | true | true |
| 6 | 121212 | `aXYZPQRbc` | true | true |
| 7 | 121221 | `aXYZPQRbc` | true | true |
| 8 | 122112 | `aXYZPQRbc` | true | true |
| 9 | 122121 | `aXYZPQRbc` | true | true |
| 10 | 122211 | `aXYZPQRbc` | true | true |
| 11 | 211122 | `aPQRXYZbc` | true | true |
| 12 | 211212 | `aPQRXYZbc` | true | true |
| 13 | 211221 | `aPQRXYZbc` | true | true |
| 14 | 212112 | `aPQRXYZbc` | true | true |
| 15 | 212121 | `aPQRXYZbc` | true | true |
| 16 | 212211 | `aPQRXYZbc` | true | true |
| 17 | 221112 | `aPQRXYZbc` | true | true |
| 18 | 221121 | `aPQRXYZbc` | true | true |
| 19 | 221211 | `aPQRXYZbc` | true | true |
| 20 | 222111 | `aPQRXYZbc` | true | true |

**Verdict:** 20 interleavings run; all stayed contiguous.


### Contiguity -- `yjs-quickjs`

Two writers each type a 3-character burst ("P","Q","R" and "X","Y","Z") at the same anchor. Contiguous: "PQR" and "XYZ" each appear as one unbroken, in-order substring (the two runs may interleave as whole blocks in either order). Shredded: anything else -- one writer's characters broken open by the other's, e.g. "PXQYRZ" or "PQXYRZ".

| # | server interleaving (1=P/Q/R writer, 2=X/Y/Z writer) | resulting string | PQR contiguous | XYZ contiguous |
|---|---|---|---|---|
| 1 | 111222 | `aPQRXYZbc` | true | true |
| 2 | 112122 | `aPQRXYZbc` | true | true |
| 3 | 112212 | `aPQRXYZbc` | true | true |
| 4 | 112221 | `aPQRXYZbc` | true | true |
| 5 | 121122 | `aPQRXYZbc` | true | true |
| 6 | 121212 | `aPQRXYZbc` | true | true |
| 7 | 121221 | `aPQRXYZbc` | true | true |
| 8 | 122112 | `aPQRXYZbc` | true | true |
| 9 | 122121 | `aPQRXYZbc` | true | true |
| 10 | 122211 | `aPQRXYZbc` | true | true |
| 11 | 211122 | `aPQRXYZbc` | true | true |
| 12 | 211212 | `aPQRXYZbc` | true | true |
| 13 | 211221 | `aPQRXYZbc` | true | true |
| 14 | 212112 | `aPQRXYZbc` | true | true |
| 15 | 212121 | `aPQRXYZbc` | true | true |
| 16 | 212211 | `aPQRXYZbc` | true | true |
| 17 | 221112 | `aPQRXYZbc` | true | true |
| 18 | 221121 | `aPQRXYZbc` | true | true |
| 19 | 221211 | `aPQRXYZbc` | true | true |
| 20 | 222111 | `aPQRXYZbc` | true | true |

**Verdict:** 20 interleavings run; all stayed contiguous.


## 2. Reflow scenario

### Reflow (single-character) -- `promeo-rule-a`

Final: you="HelloAB", peer="HelloAB" -- CONVERGED

- seed "Hello"; both start from the same base
- you type "A" at the end (index 5) -- your own optimistic echo, not sent yet
-   -> you see "HelloA"
- peer types "B" at the end (index 5) -- their own optimistic echo, not sent yet
-   -> peer sees "HelloB"
- peer flushes first, so the server sequences "B" before "A"
- you flush "A" second
- you receive peer's "B" as a remote, already-sequenced operation
-   -> you now see "HelloAB" -- your own pending "A" is still unacknowledged, and (correctly, since it really is the later-sequenced one) already sits nearest the anchor
- peer receives your "A" as a remote, already-sequenced operation
-   -> peer now sees "HelloBA" -- peer's own pending "B" is STILL treated as the latest thing, but it is not -- this is a provisional, not-yet-corrected view
- peer's own envelope comes back to them -- this prototype's stand-in for the moment the server's acceptance of "B" becomes known to its own author (see promeo_runtime.dart's class doc comment on why the ordinary receive path never delivers this)
-   -> peer now sees "HelloAB" -- their "B" has shifted one position right
- your own envelope comes back to you too, for symmetry
-   -> you still see "HelloAB" -- confirms nothing of yours moved


### Reflow (burst) -- `promeo-rule-a`

Final: you="HelloXYZA", peer="HelloXYZA" -- CONVERGED

- seed "Hello"; both start from the same base
- you type a single "A" at the end -- your own optimistic echo
-   -> you see "HelloA"
- peer types a 3-character burst "X","Y","Z" at the end, one keystroke at a time -- their own optimistic echo, each chained to the last
-   -> peer sees "HelloXYZ"
- this time YOU flush first, so the server sequences your single "A" BEFORE peer's whole burst -- the opposite role from the single-character case, chosen so the shift below is the length of a run rather than one character
- peer flushes their burst second (as one flush, three envelopes in typed order)
- you receive peer's burst as three remote, already-sequenced operations
-   -> you now see "HelloAXYZ" -- your own pending "A" is STILL treated as the latest thing, but it is not -- a provisional, not-yet-corrected view
- peer receives your "A" as a remote, already-sequenced operation
-   -> peer now sees "HelloXYZA" -- peer's burst really is the later-sequenced side, so this is already the final answer for peer
- your own envelope comes back to you
-   -> you now see "HelloXYZA" -- your "A" has shifted right by 3, the length of peer's whole run
- peer's own envelopes come back too, for symmetry
-   -> peer still sees "HelloXYZA" -- confirms nothing of peer's moved


### Reflow (single-character) -- `yjs-quickjs`

Final: you="HelloAB", peer="HelloAB" -- CONVERGED

- seed "Hello"; both start from the same base
- you type "A" at the end (index 5) -- your own optimistic echo, not sent yet
-   -> you see "HelloA"
- peer types "B" at the end (index 5) -- their own optimistic echo, not sent yet
-   -> peer sees "HelloB"
- peer flushes first, so the server sequences "B" before "A"
- you flush "A" second
- you receive peer's "B" as a remote, already-sequenced operation
-   -> you now see "HelloAB" -- your own pending "A" is still unacknowledged, and (correctly, since it really is the later-sequenced one) already sits nearest the anchor
- peer receives your "A" as a remote, already-sequenced operation
-   -> peer now sees "HelloAB" -- peer's own pending "B" is STILL treated as the latest thing, but it is not -- this is a provisional, not-yet-corrected view
- peer's own envelope comes back to them -- this prototype's stand-in for the moment the server's acceptance of "B" becomes known to its own author (see promeo_runtime.dart's class doc comment on why the ordinary receive path never delivers this)
-   -> peer now sees "HelloAB" -- their "B" has shifted one position right
- your own envelope comes back to you too, for symmetry
-   -> you still see "HelloAB" -- confirms nothing of yours moved


### Reflow (burst) -- `yjs-quickjs`

Final: you="HelloAXYZ", peer="HelloAXYZ" -- CONVERGED

- seed "Hello"; both start from the same base
- you type a single "A" at the end -- your own optimistic echo
-   -> you see "HelloA"
- peer types a 3-character burst "X","Y","Z" at the end, one keystroke at a time -- their own optimistic echo, each chained to the last
-   -> peer sees "HelloXYZ"
- this time YOU flush first, so the server sequences your single "A" BEFORE peer's whole burst -- the opposite role from the single-character case, chosen so the shift below is the length of a run rather than one character
- peer flushes their burst second (as one flush, three envelopes in typed order)
- you receive peer's burst as three remote, already-sequenced operations
-   -> you now see "HelloAXYZ" -- your own pending "A" is STILL treated as the latest thing, but it is not -- a provisional, not-yet-corrected view
- peer receives your "A" as a remote, already-sequenced operation
-   -> peer now sees "HelloAXYZ" -- peer's burst really is the later-sequenced side, so this is already the final answer for peer
- your own envelope comes back to you
-   -> you now see "HelloAXYZ" -- your "A" has shifted right by 3, the length of peer's whole run
- peer's own envelopes come back too, for symmetry
-   -> peer still sees "HelloAXYZ" -- confirms nothing of peer's moved


## 3. S0.3 re-run against PromeoRuntime

Ticket 15 §2 predicts "aBAbc" for seed "abc", both writers inserting at index 1, w1 sequenced first. `reports/p1-axis0.md` already measured that Yjs instead produces "aABbc" (CONTRADICTING that half of ticket 15 §2). This re-runs the same S0.3 scenario, unmodified, against `PromeoRuntime`.

- Outcome: `Passed`
- Evidence: forward="aBAbc", reversed="aBAbc" over 2 envelopes, full-state byte comparison also identical — identical, so arrival order did not change the interleaving. Seed was "abc", both inserted at index 1, w1 sequenced first. Ticket 15 §2 predicts "aBAbc" for this input, because its rule puts the LATER-sequenced insertion nearer the anchor. promeo-rule-a produced "aBAbc" — see above. This is promeo-rule-a's measured ordering for the same input; it must not be attributed to Yjs.
- Matches ticket 15 §2's "aBAbc" prediction: true

### S0.3 trace

- hold both observers
- both writers insert after index 1
- obsFwd drains forward, obsRev drains reversed
-   -> seeded "abc"; forward gives "aBAbc", reversed gives "aBAbc"
-   -> full-state byte comparison: forward 474B, reversed 474B — identical
