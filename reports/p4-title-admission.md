# Ticket 05 — Yjs Title admission/refusal probe

這是 `yjs_probe` 的 disposable integration harness；它使用真實 Yjs update bytes、`YjsRuntime` projection 與 `pendingStructs`，不修改 production collaboration code。

## 測試結論

- 本輪從 10 個 smoke cases 擴成 20 個 scenario，涵蓋 23 筆實際 server refusal trace、四種 Title command kind 的 policy reject、dependency reject、future base、restart recovery、delivery permutation，以及 3 個 semantic-Q/canonical-B scenario。
- 每一筆拒絕都保留 `opId`、Title、Q command、U bytes、`dependsOn`、`baseSeq`、refusal reason、`serverSeq` 與 duplicate 狀態；拒絕不得改變 B，也不得讓 connection 被迫斷線。
- 原有 exact-U mode 證明 `Document A = accepted B + Pending Journal C` 可處理 acceptance/refusal out of order、self-echo、remote-before-local-reply、重連與 accepted insert/refused format；新增 semantic mode 則由 C 重做 Q，不再把 exact U 當成唯一 replay source。
- 重要反例：同一個 Yjs document 內，即使兩個 command 語意上作用於不同 Title，後者仍可能因同一 client clock chain 依賴被拒絕或在 A 留下 pending structs。Semantic `dependsOn` 不能單獨取代 Yjs causal dependency。
- semantic mode 實測：client 先以 B_client 執行 Q，server 再於較新的 B_server 執行同一 Q，回傳不同的 canonical U；multi-select 是一個 atomic opId，reject 後 surviving Q 可重做且 pending structs 維持 0。
- shared-document exact-U route 仍保留重要反例：若產品只能重播 client U，不能承諾拒絕 root 後所有語意獨立的同 client local edit 都保留；此時才需要 per-Title isolation、rebase 或 server-generated update。

## 架構與資料責任

| 元件 | 應保存什麼 | 為什麼 |
|---|---|---|
| A — speculative view | B snapshot 加上仍存活的 C entries replay 結果 | 提供立即的 user-visible state；拒絕時重建，不送 inverse update |
| B — accepted document | server canonical Q execution 產生的 Yjs state 與 contiguous `serverSeq` | 是所有 participant 的 canonical base；client optimistic U 不直接成為 B |
| C — Pending Journal | semantic Q + opId/targets/anchors/preconditions/baseSeq 或 state vector + optional optimistic U | rebuild 時重做 Q；U 可作 audit/debug/optimistic cache，但不能是 rejected predecessor 的唯一 replay source |

## Yrs 可行性結論

- **可以在 Yrs 實作**：Yrs 是 Yjs 的相容 Rust port；Yrs 的 `TransactionMut::apply_update`、`has_missing_updates`、state vector 與 candidate `Doc` 足以承接本次 Yjs probe 的 server-admission 形狀。
- 這不是把 Yjs 測試碼直接換成 Rust API：Yrs 不知道產品的 Title command、權限或 Q/U scope，仍需要 application-level envelope、server ledger、candidate validation 與 refusal message。
- 最大限制仍是 CRDT causal dependency：exact-U replay 會把 shared Yrs document 的前序 item 一起帶回；本 probe 的 semantic-Q replay 可避開這個來源，但前提是 Q 可在 client/server deterministic execution，且 canonical U 才是 authoritative。
- production 還要補上 candidate apply 的資源上限、B/ledger atomic commit、Q schema/version/determinism、multi-select precondition、IME/undo command boundary 與 Yrs FFI error mapping。

## Scenario evidence 與實際 reject 結果

### ordinary acceptance, self-echo, and duplicate

- Result: `PASS`
- Evidence: one accepted serverSeq=1; duplicate returned the same ticket; a same-opId/different-hash payload was refused; A, B, and server converged; no pending Yjs structs remained.
- Trace events: 6
- Trace: `client.proposed → server.accepted → server.duplicate → server.identity-conflict → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.duplicate | create-1 | title-a | accepted | 1 | true | 113 | `` | 0 |
| server.identity-conflict | create-1 | title-other | identityConflict | — | false | 113 | `` | 0 |

```json
[
  {
    "kind": "server.duplicate",
    "opId": "create-1",
    "outcome": "accepted",
    "serverSeq": 1,
    "refusal": null,
    "duplicate": true,
    "canonicalUpdateBytes": 113,
    "canonicalUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
    "envelope": {
      "opId": "create-1",
      "titleId": "title-a",
      "command": {
        "kind": "createTitle",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 113,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  },
  {
    "kind": "server.identity-conflict",
    "opId": "create-1",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "identityConflict",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "create-1",
      "titleId": "title-other",
      "command": {
        "kind": "createTitle",
        "titleId": "title-other",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 113,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-other\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-other\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 1,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### acceptance and refusal replies arrive out of order

- Result: `PASS`
- Evidence: the refusal removed only its named independent entry; the accepted reply then advanced B by contiguous server sequence and replayed A deterministically.
- Trace events: 19
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.accepted → server.refused → client.refused-withdrawn → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | reject-independent | title-b | policy | — | false | 34 | `` | 3 |

```json
[
  {
    "kind": "server.refused",
    "opId": "reject-independent",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-independent",
      "titleId": "title-b",
      "command": {
        "kind": "formatText",
        "titleId": "title-b",
        "index": 0,
        "length": 1,
        "text": null,
        "attributes": {
          "bold": true
        },
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 34,
      "yrsUpdateB64": "AQLeVgFG3VYABGJvbGQEdHJ1ZYbdVgAEYm9sZARudWxsAA==",
      "dependsOn": [],
      "baseSeq": 3,
      "baseStateVectorB64": "A91WAdxWCQEJ",
      "commandHash": "{\"titleId\":\"title-b\",\"command\":{\"kind\":\"formatText\",\"titleId\":\"title-b\",\"index\":0,\"length\":1,\"text\":null,\"attributes\":{\"bold\":true},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQLeVgFG3VYABGJvbGQEdHJ1ZYbdVgAEYm9sZARudWxsAA==\",\"dependsOn\":[],\"baseSeq\":3}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 4,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "A",
      "delta": [
        {
          "insert": "A"
        }
      ],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "B",
      "delta": [
        {
          "insert": "B"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "A",
      "delta": [
        {
          "insert": "A"
        }
      ],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "B",
      "delta": [
        {
          "insert": "B"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "A",
      "delta": [
        {
          "insert": "A"
        }
      ],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "B",
      "delta": [
        {
          "insert": "B"
        }
      ],
      "src": null
    }
  }
}
```

### direct refusal keeps the session alive

- Result: `PASS`
- Evidence: the refused CreateTitle produced no server sequence, no server object, no local pending entry, and no disconnect.
- Trace events: 3
- Trace: `client.proposed → server.refused → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | reject-create | title-refused | policy | — | false | 119 | `` | 0 |

```json
[
  {
    "kind": "server.refused",
    "opId": "reject-create",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-create",
      "titleId": "title-refused",
      "command": {
        "kind": "createTitle",
        "titleId": "title-refused",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 119,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMNdGl0bGUtcmVmdXNlZAEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-refused\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-refused\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMNdGl0bGUtcmVmdXNlZAEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 0,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {},
  "aProjection": {},
  "bProjection": {}
}
```

### refused CreateTitle withdraws dependent edit/delete/undo/format

- Result: `PASS`
- Evidence: removing the root from C withdrew the transitive semantic descendants; A was rebuilt from empty B without an inverse Yjs update or pending causal residue.
- Trace events: 7
- Trace: `client.proposed → client.proposed → client.proposed → client.proposed → client.proposed → server.refused → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | create-root | title-root | policy | — | false | 116 | `` | 0 |

```json
[
  {
    "kind": "server.refused",
    "opId": "create-root",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "create-root",
      "titleId": "title-root",
      "command": {
        "kind": "createTitle",
        "titleId": "title-root",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 116,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMKdGl0bGUtcm9vdAEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-root\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-root\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMKdGl0bGUtcm9vdAEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 0,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {},
  "aProjection": {},
  "bProjection": {}
}
```

### same-document independent local edit exposes Yjs causal coupling

- Result: `PASS`
- Evidence: a later edit on a different Title was semantically independent but its Yjs client clock depended on the refused root; the server detected a causal gap, and A exposed pending structs until the edit was also refused. Explicit semantic dependsOn alone is insufficient in one shared Yjs document.
- Trace events: 10
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.refused → server.refused → client.refused-withdrawn → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | reject-root | title-root | policy | — | false | 125 | `` | 1 |
| server.refused | local-edit-keep | title-keep | causalIncomplete | — | false | 20 | `` | 1 |

```json
[
  {
    "kind": "server.refused",
    "opId": "reject-root",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-root",
      "titleId": "title-root",
      "command": {
        "kind": "createTitle",
        "titleId": "title-root",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 125,
      "yrsUpdateB64": "AQncVgAnAQdvYmplY3RzCnRpdGxlLXJvb3QBKADcVgAEa2luZAF3BXRpdGxlKADcVgABeAF9ACgA3FYAAXkBfQAoANxWAAF3AX2kASgA3FYAAWgBfSgoANxWAAhyb3RhdGlvbgF9ACgA3FYAAXoBfQAnANxWAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 1,
      "baseStateVectorB64": "AQEJ",
      "commandHash": "{\"titleId\":\"title-root\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-root\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQncVgAnAQdvYmplY3RzCnRpdGxlLXJvb3QBKADcVgAEa2luZAF3BXRpdGxlKADcVgABeAF9ACgA3FYAAXkBfQAoANxWAAF3AX2kASgA3FYAAWgBfSgoANxWAAhyb3RhdGlvbgF9ACgA3FYAAXoBfQAnANxWAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":1}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "local-edit-keep",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "causalIncomplete",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "local-edit-keep",
      "titleId": "title-keep",
      "command": {
        "kind": "insertText",
        "titleId": "title-keep",
        "index": 0,
        "length": null,
        "text": "survives?",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 20,
      "yrsUpdateB64": "AQHcVgkEAAEICXN1cnZpdmVzPwA=",
      "dependsOn": [],
      "baseSeq": 1,
      "baseStateVectorB64": "AQEJ",
      "commandHash": "{\"titleId\":\"title-keep\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-keep\",\"index\":0,\"length\":null,\"text\":\"survives?\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHcVgkEAAEICXN1cnZpdmVzPwA=\",\"dependsOn\":[],\"baseSeq\":1}"
    },
    "pendingStructs": 1
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 1,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-keep": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "aProjection": {
    "title-keep": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "bProjection": {
    "title-keep": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### accepted insert survives a refused format

- Result: `PASS`
- Evidence: the refusal removed only the formatting command; the accepted insert remained in B and replayed cleanly in A.
- Trace events: 11
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.proposed → server.refused → client.refused-withdrawn → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | format-refused | title-a | policy | — | false | 34 | `insert-a` | 1 |

```json
[
  {
    "kind": "server.refused",
    "opId": "format-refused",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "format-refused",
      "titleId": "title-a",
      "command": {
        "kind": "formatText",
        "titleId": "title-a",
        "index": 0,
        "length": 5,
        "text": null,
        "attributes": {
          "bold": true
        },
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 34,
      "yrsUpdateB64": "AQLcVgVG3FYABGJvbGQEdHJ1ZYbcVgQEYm9sZARudWxsAA==",
      "dependsOn": [
        "insert-a"
      ],
      "baseSeq": 1,
      "baseStateVectorB64": "AQEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"formatText\",\"titleId\":\"title-a\",\"index\":0,\"length\":5,\"text\":null,\"attributes\":{\"bold\":true},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQLcVgVG3FYABGJvbGQEdHJ1ZYbcVgQEYm9sZARudWxsAA==\",\"dependsOn\":[\"insert-a\"],\"baseSeq\":1}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 2,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "plain",
      "delta": [
        {
          "insert": "plain"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "plain",
      "delta": [
        {
          "insert": "plain"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "plain",
      "delta": [
        {
          "insert": "plain"
        }
      ],
      "src": null
    }
  }
}
```

### remote accepted update before local reply

- Result: `PASS`
- Evidence: A advanced B with the remote accepted update, re-derived A with its own pending edit still visible, then settled the local ticket without an inverse or duplicate sequence.
- Trace events: 12
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → server.accepted → client.accepted-integrated → client.accepted-integrated`

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  }
}
```

### concurrent insert, delete, and range formatting converge

- Result: `PASS`
- Evidence: independent client IDs allowed Yjs to merge concurrent inserts and then a concurrent delete/range-format pair; delivery was intentionally reversed and all three projections still matched.
- Trace events: 24
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.accepted → server.accepted → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.accepted → server.accepted → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated`

**Final A/B/C state**

```json
{
  "serverSeq": 6,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "ABbc",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "A"
        },
        {
          "insert": "Bbc"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "ABbc",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "A"
        },
        {
          "insert": "Bbc"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "ABbc",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "A"
        },
        {
          "insert": "Bbc"
        }
      ],
      "src": null
    }
  }
}
```

### reconnect snapshot plus pending journal and duplicate replay

- Result: `PASS`
- Evidence: a fresh client restored accepted snapshot + outstanding C, then both first delivery and same-opId retry settled exactly once; server history stayed at one accepted sequence.
- Trace events: 7
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → server.duplicate`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.duplicate | unsubmitted-local | title-a | accepted | 2 | true | 12 | `` | 1 |

```json
[
  {
    "kind": "server.duplicate",
    "opId": "unsubmitted-local",
    "outcome": "accepted",
    "serverSeq": 2,
    "refusal": null,
    "duplicate": true,
    "canonicalUpdateBytes": 12,
    "canonicalUpdateB64": "AQHcVgAEAAEIAVAA",
    "envelope": {
      "opId": "unsubmitted-local",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "P",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 12,
      "yrsUpdateB64": "AQHcVgAEAAEIAVAA",
      "dependsOn": [],
      "baseSeq": 1,
      "baseStateVectorB64": "AQEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"P\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHcVgAEAAEIAVAA\",\"dependsOn\":[],\"baseSeq\":1}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 2,
  "connectionAlive": true,
  "pendingOpIds": [
    "unsubmitted-local"
  ],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "P",
      "delta": [
        {
          "insert": "P"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "P",
      "delta": [
        {
          "insert": "P"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### malformed, causally incomplete, and mismatched envelopes

- Result: `PASS`
- Evidence: empty and invalid U were refused before B mutation; a child-before-parent was refused without server mutation; Q naming Title A while U changed Title B was refused by candidate projection; direct Yjs observation showed child-first delivery leaves pending structs until its parent arrives.
- Trace events: 22
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → server.refused → server.refused → client.proposed → server.refused → client.refused-withdrawn → client.proposed → client.proposed → server.refused → server.accepted → client.refused-withdrawn → client.accepted-integrated → client.accepted-integrated → client.proposed → server.refused`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | malformed-empty | title-a | malformed | — | false | 0 | `` | 2 |
| server.refused | malformed-invalid-bytes | title-a | applyFailed | — | false | 3 | `` | 2 |
| server.refused | causal-child-first | title-a | missingDependency | — | false | 16 | `not-accepted-yet` | 2 |
| server.refused | causal-child | title-c | missingDependency | — | false | 17 | `causal-root` | 2 |
| server.refused | declared-title-a-actual-title-b | title-a | semanticMismatch | — | false | 13 | `` | 3 |

```json
[
  {
    "kind": "server.refused",
    "opId": "malformed-empty",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "malformed",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "malformed-empty",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "x",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 0,
      "yrsUpdateB64": "",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"x\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "malformed-invalid-bytes",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "applyFailed",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "malformed-invalid-bytes",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "x",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 3,
      "yrsUpdateB64": "AQID",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"x\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQID\",\"dependsOn\":[],\"baseSeq\":2}"
    },
    "error": "Bad state: bridge error for applyUpdate: Error: Unexpected end of array\n    at create$3 (<eval>)\n    at <anonymous> (<eval>:1187)\n    at <eval> (<eval>:13146)\n"
  },
  {
    "kind": "server.refused",
    "opId": "causal-child-first",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "missingDependency",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "causal-child-first",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "child",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 16,
      "yrsUpdateB64": "AQHdVgAEAAEIBWNoaWxkAA==",
      "dependsOn": [
        "not-accepted-yet"
      ],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWCQEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"child\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHdVgAEAAEIBWNoaWxkAA==\",\"dependsOn\":[\"not-accepted-yet\"],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "causal-child",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "missingDependency",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "causal-child",
      "titleId": "title-c",
      "command": {
        "kind": "insertText",
        "titleId": "title-c",
        "index": 0,
        "length": null,
        "text": "child",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 17,
      "yrsUpdateB64": "AQHeVgkEAN5WCAVjaGlsZAA=",
      "dependsOn": [
        "causal-root"
      ],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWCQEJ",
      "commandHash": "{\"titleId\":\"title-c\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-c\",\"index\":0,\"length\":null,\"text\":\"child\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHeVgkEAN5WCAVjaGlsZAA=\",\"dependsOn\":[\"causal-root\"],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "declared-title-a-actual-title-b",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "semanticMismatch",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "declared-title-a-actual-title-b",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "B",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 13,
      "yrsUpdateB64": "AQHgVgAEANxWCAFCAA==",
      "dependsOn": [],
      "baseSeq": 3,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"B\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHgVgAEANxWCAFCAA==\",\"dependsOn\":[],\"baseSeq\":3}"
    },
    "changedTitles": [
      "title-b"
    ]
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [
    "actual-title-b"
  ],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-c": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "B",
      "delta": [
        {
          "insert": "B"
        }
      ],
      "src": null
    },
    "title-c": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-c": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### policy rejection across every Title command kind

- Result: `PASS`
- Evidence: real client-generated Yjs updates for insert, delete, format, and undo were each refused with policy; the connection stayed alive, only the refused entries were withdrawn, and an unrelated pending operation could still be accepted afterward.
- Trace events: 24
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.refused → client.refused-withdrawn → client.proposed → server.refused → client.refused-withdrawn → client.proposed → server.refused → client.refused-withdrawn → client.proposed → client.proposed → server.refused → client.refused-withdrawn → server.accepted → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | reject-insert | title-a | policy | — | false | 12 | `` | 2 |
| server.refused | reject-delete | title-a | policy | — | false | 7 | `` | 2 |
| server.refused | reject-format | title-a | policy | — | false | 37 | `` | 2 |
| server.refused | reject-undo | title-a | policy | — | false | 7 | `` | 2 |

```json
[
  {
    "kind": "server.refused",
    "opId": "reject-insert",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-insert",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "x",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 12,
      "yrsUpdateB64": "AQHdVgBE3FYAAXgA",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWBAEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"x\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHdVgBE3FYAAXgA\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "reject-delete",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-delete",
      "titleId": "title-a",
      "command": {
        "kind": "deleteText",
        "titleId": "title-a",
        "index": 0,
        "length": 1,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 7,
      "yrsUpdateB64": "AAHcVgEAAQ==",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWBAEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"deleteText\",\"titleId\":\"title-a\",\"index\":0,\"length\":1,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AAHcVgEAAQ==\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "reject-format",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-format",
      "titleId": "title-a",
      "command": {
        "kind": "formatText",
        "titleId": "title-a",
        "index": 0,
        "length": 1,
        "text": null,
        "attributes": {
          "bold": true
        },
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 37,
      "yrsUpdateB64": "AQLfVgBG3FYABGJvbGQEdHJ1ZcbcVgDcVgEEYm9sZARudWxsAA==",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWBAEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"formatText\",\"titleId\":\"title-a\",\"index\":0,\"length\":1,\"text\":null,\"attributes\":{\"bold\":true},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQLfVgBG3FYABGJvbGQEdHJ1ZcbcVgDcVgEEYm9sZARudWxsAA==\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "reject-undo",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-undo",
      "titleId": "title-a",
      "command": {
        "kind": "undo",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": "undo-target",
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 7,
      "yrsUpdateB64": "AAHgVgEAAQ==",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWBAEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"undo\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":\"undo-target\",\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AAHgVgEAAQ==\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "useed",
      "delta": [
        {
          "insert": "useed"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "useed",
      "delta": [
        {
          "insert": "useed"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "useed",
      "delta": [
        {
          "insert": "useed"
        }
      ],
      "src": null
    }
  }
}
```

### dependency refusal after a refused root

- Result: `PASS`
- Evidence: child-before-parent received missingDependency; after the root was durably refused, a new retry received dependencyRefused; no refusal consumed serverSeq and B stayed empty.
- Trace events: 6
- Trace: `client.proposed → client.proposed → server.refused → server.refused → client.refused-withdrawn → server.refused`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | child-first | title-a | missingDependency | — | false | 15 | `root-refused` | 0 |
| server.refused | root-refused | title-a | policy | — | false | 113 | `` | 0 |
| server.refused | child-after-root-refusal | title-a | dependencyRefused | — | false | 15 | `root-refused` | 0 |

```json
[
  {
    "kind": "server.refused",
    "opId": "child-first",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "missingDependency",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "child-first",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "child",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 15,
      "yrsUpdateB64": "AQEBCQQAAQgFY2hpbGQA",
      "dependsOn": [
        "root-refused"
      ],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"child\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQEBCQQAAQgFY2hpbGQA\",\"dependsOn\":[\"root-refused\"],\"baseSeq\":0}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "root-refused",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "root-refused",
      "titleId": "title-a",
      "command": {
        "kind": "createTitle",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 113,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  },
  {
    "kind": "server.refused",
    "opId": "child-after-root-refusal",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "dependencyRefused",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "child-after-root-refusal",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "child",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 15,
      "yrsUpdateB64": "AQEBCQQAAQgFY2hpbGQA",
      "dependsOn": [
        "root-refused"
      ],
      "baseSeq": 0,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"child\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQEBCQQAAQgFY2hpbGQA\",\"dependsOn\":[\"root-refused\"],\"baseSeq\":0}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 0,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {},
  "aProjection": {},
  "bProjection": {}
}
```

### same-op retry after refusal is idempotent

- Result: `PASS`
- Evidence: the same rejected envelope returned the original refusal on retry with duplicate=true, no serverSeq, no second mutation, and no connection loss.
- Trace events: 5
- Trace: `client.proposed → server.refused → server.duplicate → client.refused-withdrawn → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | reject-once | title-a | policy | — | false | 113 | `` | 0 |
| server.duplicate | reject-once | title-a | policy | — | true | 113 | `` | 0 |

```json
[
  {
    "kind": "server.refused",
    "opId": "reject-once",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-once",
      "titleId": "title-a",
      "command": {
        "kind": "createTitle",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 113,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  },
  {
    "kind": "server.duplicate",
    "opId": "reject-once",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": true,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "reject-once",
      "titleId": "title-a",
      "command": {
        "kind": "createTitle",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 113,
      "yrsUpdateB64": "AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=",
      "dependsOn": [],
      "baseSeq": 0,
      "baseStateVectorB64": "AA==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"createTitle\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQkBACcBB29iamVjdHMHdGl0bGUtYQEoAAEABGtpbmQBdwV0aXRsZSgAAQABeAF9ACgAAQABeQF9ACgAAQABdwF9pAEoAAEAAWgBfSgoAAEACHJvdGF0aW9uAX0AKAABAAF6AX0AJwABAAR0ZXh0AgA=\",\"dependsOn\":[],\"baseSeq\":0}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 0,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {},
  "aProjection": {},
  "bProjection": {}
}
```

### future base refusal does not mutate server B

- Result: `PASS`
- Evidence: a future baseSeq was rejected before candidate apply; B projection and serverSeq were unchanged, and A removed the local entry without leaving pending structs.
- Trace events: 7
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.refused → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | future-base | title-a | futureBase | — | false | 12 | `` | 11 |

```json
[
  {
    "kind": "server.refused",
    "opId": "future-base",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "futureBase",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "future-base",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "x",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 12,
      "yrsUpdateB64": "AQHcVgAEAAEIAXgA",
      "dependsOn": [],
      "baseSeq": 11,
      "baseStateVectorB64": null,
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"x\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHcVgAEAAEIAXgA\",\"dependsOn\":[],\"baseSeq\":11}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 1,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### server restart restores accepted history and dedup ledger

- Result: `PASS`
- Evidence: a fresh server runtime restored B, accepted history, and headSeq; retrying an already accepted op returned the original sequence, while a new command continued at the next sequence.
- Trace events: 15
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → server.recovered → server.duplicate → client.proposed → server.accepted → server.accepted → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.duplicate | accepted-before-restart | title-a | accepted | 2 | true | 17 | `` | 1 |

```json
[
  {
    "kind": "server.duplicate",
    "opId": "accepted-before-restart",
    "outcome": "accepted",
    "serverSeq": 2,
    "refusal": null,
    "duplicate": true,
    "canonicalUpdateBytes": 17,
    "canonicalUpdateB64": "AQHcVgAEAAEIBmJlZm9yZQA=",
    "envelope": {
      "opId": "accepted-before-restart",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "before",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 17,
      "yrsUpdateB64": "AQHcVgAEAAEIBmJlZm9yZQA=",
      "dependsOn": [],
      "baseSeq": 1,
      "baseStateVectorB64": "AQEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"before\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHcVgAEAAEIBmJlZm9yZQA=\",\"dependsOn\":[],\"baseSeq\":1}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "before!",
      "delta": [
        {
          "insert": "before!"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "before!",
      "delta": [
        {
          "insert": "before!"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "before!",
      "delta": [
        {
          "insert": "before!"
        }
      ],
      "src": null
    }
  }
}
```

### remote acceptance remains visible around a local refusal

- Result: `PASS`
- Evidence: A integrated a remote accepted update while the local command was still pending, then removed only the refused local entry; the remote text remained in B and A.
- Trace events: 15
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.refused → server.accepted → client.accepted-integrated → client.accepted-integrated → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | local-refused | title-a | policy | — | false | 37 | `` | 2 |

```json
[
  {
    "kind": "server.refused",
    "opId": "local-refused",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "local-refused",
      "titleId": "title-a",
      "command": {
        "kind": "formatText",
        "titleId": "title-a",
        "index": 0,
        "length": 1,
        "text": null,
        "attributes": {
          "bold": true
        },
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 37,
      "yrsUpdateB64": "AQLdVgBG3FYABGJvbGQEdHJ1ZcbcVgDcVgEEYm9sZARudWxsAA==",
      "dependsOn": [],
      "baseSeq": 2,
      "baseStateVectorB64": "AtxWBAEJ",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"formatText\",\"titleId\":\"title-a\",\"index\":0,\"length\":1,\"text\":null,\"attributes\":{\"bold\":true},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQLdVgBG3FYABGJvbGQEdHJ1ZcbcVgDcVgEEYm9sZARudWxsAA==\",\"dependsOn\":[],\"baseSeq\":2}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "Rseed",
      "delta": [
        {
          "insert": "Rseed"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "Rseed",
      "delta": [
        {
          "insert": "Rseed"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "Rseed",
      "delta": [
        {
          "insert": "Rseed"
        }
      ],
      "src": null
    }
  }
}
```

### delivery permutations preserve the same accepted projection

- Result: `PASS`
- Evidence: three delivery schedules, including reverse delivery and duplicate ticket delivery, converged to the same server projection with contiguous serverSeq handling and no pending structs.
- Trace events: 12
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.accepted → server.accepted → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated → client.accepted-integrated`

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "AB",
      "delta": [
        {
          "insert": "AB"
        }
      ],
      "src": null
    }
  }
}
```

### semantic Q is re-executed on canonical server B

- Result: `PASS`
- Evidence: the client showed an optimistic insert against stale B_client; the server re-executed the same Q against newer B_server, returned a different canonical U, and A converged after canonical integration plus semantic replay.
- Trace events: 13
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.semantic-replayed → client.accepted-integrated → client.accepted-integrated`

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "LR",
      "delta": [
        {
          "insert": "LR"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "LR",
      "delta": [
        {
          "insert": "LR"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "LR",
      "delta": [
        {
          "insert": "LR"
        }
      ],
      "src": null
    }
  }
}
```

### semantic multi-select command is one atomic admission unit

- Result: `PASS`
- Evidence: one moveObjects Q updated every selected object together; a policy-refused group was removed as one opId and did not partially commit either target.
- Trace events: 15
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.refused → client.refused-withdrawn`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | group-policy-reject | title-a | policy | — | false | 39 | `` | 3 |

```json
[
  {
    "kind": "server.refused",
    "opId": "group-policy-reject",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "group-policy-reject",
      "titleId": "title-a",
      "command": {
        "kind": "moveObjects",
        "titleId": "title-a",
        "index": null,
        "length": null,
        "text": null,
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [
          "title-a",
          "title-b"
        ],
        "deltaX": 5.0,
        "deltaY": 5.0
      },
      "yrsUpdateBytes": 39,
      "yrsUpdateB64": "AQTeVgConkoAAX0PqJ5KAQF9GaieSgIBfQ+onkoDAX0ZAZ5KAQAE",
      "dependsOn": [],
      "baseSeq": 3,
      "baseStateVectorB64": "A55KBJ1KCZxKCQ==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"moveObjects\",\"titleId\":\"title-a\",\"index\":null,\"length\":null,\"text\":null,\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[\"title-a\",\"title-b\"],\"deltaX\":5.0,\"deltaY\":5.0},\"yrsUpdateB64\":\"AQTeVgConkoAAX0PqJ5KAQF9GaieSgIBfQ+onkoDAX0ZAZ5KAQAE\",\"dependsOn\":[],\"baseSeq\":3}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 3,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 10.0,
      "y": 20.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    }
  }
}
```

### semantic replay removes rejected root without causal residue

- Result: `PASS`
- Evidence: after a policy refusal, the surviving independent Q was re-executed from accepted B; no exact rejected U was replayed and Yjs pendingStructs stayed zero.
- Trace events: 20
- Trace: `client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → server.accepted → client.accepted-integrated → client.accepted-integrated → client.proposed → client.proposed → server.refused → server.accepted → client.refused-withdrawn → client.semantic-replayed → client.accepted-integrated → client.accepted-integrated`

**Actual server decisions**

| Event | opId | Title | outcome/reason | seq | duplicate | U bytes | dependsOn | baseSeq |
|---|---|---|---|---:|---|---:|---|---:|
| server.refused | semantic-reject-root | title-a | policy | — | false | 22 | `` | 3 |

```json
[
  {
    "kind": "server.refused",
    "opId": "semantic-reject-root",
    "outcome": "refused",
    "serverSeq": null,
    "refusal": "policy",
    "duplicate": false,
    "canonicalUpdateBytes": null,
    "canonicalUpdateB64": null,
    "envelope": {
      "opId": "semantic-reject-root",
      "titleId": "title-a",
      "command": {
        "kind": "insertText",
        "titleId": "title-a",
        "index": 0,
        "length": null,
        "text": "discard-me",
        "attributes": {},
        "targetOpId": null,
        "targetObjectIds": [],
        "deltaX": 0.0,
        "deltaY": 0.0
      },
      "yrsUpdateBytes": 22,
      "yrsUpdateB64": "AQHeVgAEAJxKCApkaXNjYXJkLW1lAA==",
      "dependsOn": [],
      "baseSeq": 3,
      "baseStateVectorB64": "A55KBJ1KCZxKCQ==",
      "commandHash": "{\"titleId\":\"title-a\",\"command\":{\"kind\":\"insertText\",\"titleId\":\"title-a\",\"index\":0,\"length\":null,\"text\":\"discard-me\",\"attributes\":{},\"targetOpId\":null,\"targetObjectIds\":[],\"deltaX\":0.0,\"deltaY\":0.0},\"yrsUpdateB64\":\"AQHeVgAEAJxKCApkaXNjYXJkLW1lAA==\",\"dependsOn\":[],\"baseSeq\":3}"
    }
  }
]
```

**Final A/B/C state**

```json
{
  "serverSeq": 4,
  "connectionAlive": true,
  "pendingOpIds": [],
  "pendingStructs": 0,
  "serverProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "seed",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "s"
        },
        {
          "insert": "eed"
        }
      ],
      "src": null
    }
  },
  "aProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "seed",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "s"
        },
        {
          "insert": "eed"
        }
      ],
      "src": null
    }
  },
  "bProjection": {
    "title-a": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "",
      "delta": [],
      "src": null
    },
    "title-b": {
      "kind": "title",
      "x": 0.0,
      "y": 0.0,
      "w": 100.0,
      "h": 40.0,
      "rotation": 0.0,
      "z": 0.0,
      "text": "seed",
      "delta": [
        {
          "attributes": {
            "bold": true
          },
          "insert": "s"
        },
        {
          "insert": "eed"
        }
      ],
      "src": null
    }
  }
}
```

## Protocol implications

1. Server checks durable `opId` before any Yjs apply; same identity + same hash returns the original ticket, while a hash conflict refuses without a second sequence.
2. Server validates explicit dependencies before candidate apply; it does not queue a missing dependency and does not assign a sequence to a refusal.
3. exact-U mode applies client U to a candidate; semantic mode instead executes Q on candidate B_server, validates the complete scope/group, then commits the generated canonical U to B and assigns one sequence. Client U is never blindly applied to live B in semantic mode.
4. Client integrates accepted canonical U by contiguous `serverSeq`, removes the accepted Q from C, and re-executes surviving Q entries from B_client. Refusal removes the named entry and its transitive semantic dependants before the same semantic rebuild.
5. Reconnect must persist accepted snapshot sequence plus versioned Q/targets/preconditions and optional optimistic U; retries use semantic identity for semantic mode and must tolerate an already-included sequence.

## Revisit conditions

- If Q cannot be executed deterministically on client and server, share one command interpreter or make the server canonical result authoritative with cross-runtime golden tests.
- If multi-select/group atomicity or resource limits fail, split only the affected feature family into a separate Collaboration Document; do not default to per-object Docs without measuring coordination cost.
- If candidate apply cannot be bounded for size/time, add resource limits and a refusal class before accepting U.
- If server-side Yjs is unavailable, do not fall back to opaque relay while retaining individual refusal semantics; that would reintroduce causal pending state.
