# P1 axis 0 measurement report

- Runtime: `yjs-quickjs`
- Capabilities: decodeUpdate, readStateVector, enumerateFormatMarkers, countPendingStructs, readUndoStackItems

| Scenario | Targets | Outcome | Evidence |
|---|---|---|---|
| S0.1 `same-key-different-values-both-arrival-orders` | ticket 15 §1 — "Yjs updates are commutative, so an external total order is semantically inert" | pass | forward=200.0, reversed=200.0 over 2 envelopes, full-state byte comparison also identical — identical, so the total order is inert |
| S0.2 `winner-is-clientid-not-seq` | ticket 17 §4 — the only knob is `clientID`, which expresses "Alice always beats Bob", never "this one is later" | pass | w1-first=222.0, w2-first=222.0 — winner is independent of seq. Disambiguation: w1(lower clientID) wrote 999, w2(higher clientID) wrote 111, observer sees x=111.0 — the higher clientID (w2) won despite writing the smaller value, matching yjs.cjs:9993's client-id compare (values are never compared). |
| S0.3 `insert-at-same-anchor-both-orders` | ticket 15 §2 — "an insertion lands immediately to the right of its anchor", with the later-sequenced insertion appearing to the left | pass | forward="aABbc", reversed="aABbc" over 2 envelopes, full-state byte comparison also identical — identical, so arrival order did not change the interleaving. Seed was "abc", both inserted at index 1, w1 sequenced first. Ticket 15 §2 predicts "aBAbc" for this input, because its rule puts the LATER-sequenced insertion nearer the anchor. Yjs produced "aABbc" — CONTRADICTING that half of ticket 15 §2: the earlier-sequenced insertion landed nearer the anchor. w1 is both earlier-sequenced and lower-clientID here, so this run cannot say which field Yjs used; yjs.cjs:9993 is where that lives. |

## Traces

### S0.1

- hold both observers
- w1 sets x=100, w2 sets x=200, both flush
-   -> each observer holds 2 envelopes before draining
- obsFwd drains forward, obsRev drains reversed
-   -> forward observer sees x=200.0, reversed observer sees x=200.0
-   -> full-state byte comparison: forward 140B, reversed 140B — identical

### S0.2

- w1 is sequenced first
-   -> w1 sequenced first; observer sees x=222.0 (w1 wrote 111 as clientID 1, w2 wrote 222 as clientID 2)
- w2 is sequenced first
-   -> w2 sequenced first; observer sees x=222.0 (w1 wrote 111 as clientID 1, w2 wrote 222 as clientID 2)
- disambiguation: w1 (lower clientID) sequenced first writing the LARGER value 999; w2 (higher clientID) writes the smaller value 111
-   -> value/clientID disambiguation: w1 (clientID 1) wrote 999, w2 (clientID 2) wrote 111; observer sees x=111.0

### S0.3

- hold both observers
- both writers insert after index 1
- obsFwd drains forward, obsRev drains reversed
-   -> seeded "abc"; forward gives "aABbc", reversed gives "aABbc"
-   -> full-state byte comparison: forward 143B, reversed 143B — identical

