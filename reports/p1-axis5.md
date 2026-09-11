# P1 axis 5 measurement report

- Runtime: `yjs-quickjs`
- Capabilities: decodeUpdate, readStateVector, enumerateFormatMarkers, countPendingStructs, readUndoStackItems

| Scenario | Targets | Outcome | Evidence |
|---|---|---|---|
| S5.1 `pendingstructs-third-state` | ticket 17 §6 — a dropped fragment leaves causally dependent structs in `pendingStructs` indefinitely, a third state neither accepted nor rejected that ticket 07 §10 cannot express | pass | B waits with 2 pending structs and no visible object — neither accepted nor rejected. A `Resync` recovers it: this state is reachable and is not self-healing. |
| S5.2 `encode-state-as-update-byte-identical-across-peers` | ticket 17 §7 — no primary source guarantees `encodeStateAsUpdate` produces identical *bytes* across peers, and ticket 14 §5's Replay Equivalence Check compares byte for byte. Ticket 17 explicitly asked for this spike. | pass | byte-identical (145B) for two converged peers, measured with no UndoManager attached to either peer — a byte-for-byte Replay Equivalence Check is viable on this evidence. (An UndoManager attached to both peers was measured to break this: see task-20-report.md.) |
| S5.3 `field-granularity-without-replica` | ticket 17 §5 — `parent` and `parentSub` are elided from the wire whenever `origin` is present, so a raw update does not reveal which field it belongs to without applying it to a replica | pass | a single-field write decodes to 1 struct(s) whose summaries do NOT name the field — confirming that field granularity needs a server-side replica |

## Traces

### S5.1

- A creates a title and types, emitting several updates
- drop the FIRST envelope, deliver the rest
-   -> B holds 1 pending structs; object visible: false
- A types again; B receives
-   -> after a further edit, B holds 2 pending structs

### S5.2

- A and B both edit, then fully converge
-   -> A encodes 145B, B encodes 145B

### S5.3

- A creates the title and B catches up
- A writes ONE field: x
-   -> decoded 1 structs: Item content=ContentAny id=1:12 len=1
