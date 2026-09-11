# NOTES: Yjs under `flutter_js`'s QuickJS on Windows

This records what Task 1's walking-skeleton spike actually found. Every claim below is
tagged with its source: **[observed]** means it came from an error message or debug
output produced while running this code, **[source]** means it came from reading
`yjs`'s own source under `node_modules`, and **[doc]** means it came from the task
brief / prior documentation, never independently triggered here.

**Update (fix round 1):** the coordinator independently verified the `clientID`
finding against `js/node_modules/yjs/dist/yjs.cjs:459-463` and corrected the plan's
Global Constraint accordingly (commit `8b32c90c2a` in the plan's own history): a
prior ticket's `YOptions.id` is **yffi's** knob, over-generalised in the plan to
apply to Yjs itself, which it does not. `bridge.js`'s `createDoc` now pins
`clientID` by assigning `doc.clientID` immediately after construction, and all
three bootstrap tests pass. The sections below are updated to match.

## Harness that loads the JS engine

`flutter test integration_test/yjs_bootstrap_test.dart -d windows` loads
`flutter_js`'s native QuickJS library directly — no fallback to `flutter drive` or a
plain `flutter test test/...` copy was needed. **[observed]**: the very first run of
this command built the Windows exe and executed all three tests, so
`getJavascriptRuntime()` never failed to find its native library on this machine.
Every later task in this plan should use this same harness.

## `yjs` version resolved

`npm install` against `"yjs": "^13.6.20"` resolved **13.6.32**. **[observed]**
(read from `js/node_modules/yjs/package.json` after install).

## Generated bundle

`npm run build` (Rollup, `format: 'iife'`) produced `assets/js/yjs_bridge.js` at
**350783 bytes** (final size, after both fix-round changes to `bridge.js` and
`shims.js`). **[observed]**.

The bundle's first line is `(function () {`, not `var YjsProbeBridge = (function () {`
as the brief's Step 7 anticipated. **[observed]**: because `src/bridge.js` has no
top-level `export`, Rollup's `iife` format has nothing to assign to the `name:
'YjsProbeBridge'` output option, so it emits a bare, immediately-invoked function
expression instead of a named variable. This is harmless — the file still defines
`globalThis.__probe` as a side effect when evaluated — but the file does not begin
with the exact string the brief predicted.

## Globals `shims.js` needed

Three globals were shimmed pre-emptively, straight from the brief, before the test
was ever run — the bundle loaded cleanly on the very first attempt without
triggering a `ReferenceError` for any of them, so no error message confirms they were
individually necessary on this QuickJS build:

- `crypto.getRandomValues` **[doc]**
- `performance.now` **[doc]**
- `process.env` / `process.argv` **[doc]**

One further global was discovered empirically, by running the test and reading the
actual error:

- **`BigInt`** **[observed]**. The bundle evaluated fine and the first two tests'
  JS calls (`yjsVersion`, `createDoc`) succeeded, but the third test's first
  `Y.Map.set()` call threw `ReferenceError: 'BigInt' is not defined`. Root cause,
  found by reading `yjs`'s source **[source]**: `typeMapSet` in
  `src/types/AbstractType.js` does `switch (value.constructor) { case Number: ...
  case BigInt: ... }` — merely mentioning the identifier `BigInt` in a `switch`
  branch requires evaluating it, and this QuickJS build (as exposed through
  `flutter_js`) does not define a global `BigInt` at all. This throws the first time
  *any* value of *any* type is stored in a `Y.Map`, regardless of whether the stored
  value is actually a bigint. The `typeMapSet` attribution is directly confirmed:
  it was the named frame in the observed stack trace
  (`at typeMapSet (<eval>:7365)`).

  The shim (in `js/src/shims.js`, amended in fix round 1 to make its cost explicit
  rather than latent) is:
  ```js
  // QuickJS in flutter_js 0.8.7 defines no global BigInt, and Yjs's typeMapSet
  // references it while classifying a value's type — so the FIRST write to any
  // Y.Map throws `ReferenceError: 'BigInt' is not defined` without this.
  // The probe never stores a bigint, so a stub that throws on actual USE is
  // correct and keeps the failure loud: if this message ever appears, some Yjs
  // path started genuinely needing bigint support and needs a real polyfill.
  if (typeof globalThis.BigInt === 'undefined') {
    globalThis.BigInt = function BigInt() {
      throw new Error('yjs-probe shims.js: BigInt is a stub, QuickJS has none. A real polyfill is now needed.');
    };
  }
  ```
  The throw message now names the shim itself (`yjs-probe shims.js: BigInt is a
  stub...`), so if a later task ever hits it, the message is self-explaining
  rather than a bare, unattributed error. After adding this one shim and
  rebuilding, no further error appeared and test 3 passed outright — the iteration
  loop ran exactly one cycle beyond the brief's starting shim set.

A related, secondary finding **[observed]**: QuickJS's `Error.prototype.stack` does
not prepend the `Name: message` header line the way V8's does. Printing
`String(e.stack)` alone (as `bridge.js`'s `call()` does) showed only the raw
`at functionName (<eval>:N)` frames with no leading error text, which made the
`BigInt` `ReferenceError` initially look like an unlabelled crash. Capturing
`e.message` and `e.name` separately, via a temporary diagnostic op, was what actually
surfaced the string `'BigInt' is not defined`. Anything that inspects JS errors from
Dart in later tasks should read `.message`/`.name` explicitly rather than relying on
`.stack` alone to carry the message.

## `clientID` pinning mechanism (corrected in fix round 1)

`Y.Doc`'s constructor in `yjs` 13.6.32 (`src/utils/Doc.js`, and confirmed again
independently by the coordinator at `dist/yjs.cjs:459-463`) is
`constructor ({ guid = random.uuidv4(), collectionid = null, gc = true, gcFilter
= () => true, meta = null, autoLoad = false, shouldLoad = true } = {})` — there is
**no `clientID` field** in the destructured options at all, and
`this.clientID = generateNewClientId()` (i.e. `lib0/random.uint32()`) is set
unconditionally on line 463, ignoring anything passed under that key. **[source]**

The task brief's original global constraint — "`clientID` is set only through
`new Y.Doc({clientID})`" — did not match the real `yjs` API. The plan has since
been corrected (the constraint's origin was ticket 17 §4's `YOptions.id`, which is
**yffi's** knob, not Yjs's, and had been over-generalised). The bridge now pins
`clientID` the way the corrected plan directs: by assigning the `doc.clientID`
property immediately after construction, before any content is created (`clientID`
is read when an `Item` is created, so the assignment must happen before the first
write):
```js
const doc = new Y.Doc();
doc.clientID = clientId;
```
This is a plain property assignment on a public field — it does not modify Yjs
itself, and it now makes the "a pinned clientID is honoured rather than randomised"
test pass deterministically.

## Final state of the three bootstrap tests

Running `flutter test integration_test/yjs_bootstrap_test.dart -d windows` after
fix round 1 (the `createDoc` property-assignment fix and the amended `BigInt` shim
comment):

1. **`yjs loads and exposes YText and YMap under QuickJS`** — **PASS**. **[observed]**
2. **`a pinned clientID is honoured rather than randomised`** — **PASS**
   (previously **FAIL**, `Expected: <7> Actual: <32>`, before the `doc.clientID =
   clientId` fix above). **[observed]**
3. **`text inserted on one doc converges onto another through base64 updates`** —
   **PASS**. **[observed]**

All 3 of 3 tests now pass.

## Observed-error vs. documentation-sourced findings (explicit)

- **From an observed error message:**
  - The `BigInt` global is missing on this QuickJS build (`ReferenceError:
    'BigInt' is not defined`, frame `typeMapSet`).
  - QuickJS's `Error.prototype.stack` does not prepend a `Name: message` header
    line the way V8's does — `String(e.stack)` alone printed only bare
    `at fn (<eval>:N)` frames with no error text, which is why the first BigInt
    failure initially looked unlabelled. Capturing `e.message`/`e.name`
    separately (via a temporary diagnostic op) is what surfaced the actual string.
  - `flutter test integration_test/yjs_bootstrap_test.dart -d windows` successfully
    loads the native QuickJS library on this machine (i.e., the harness works —
    this was not assumed, it was run).
  - The original clientID mismatch (`Expected: <7> Actual: <32>`) and its
    disappearance after switching to property assignment.
  - Test-3's original failure and its disappearance after the `BigInt` shim.
- **From reading `yjs` source (not an error, but not documentation either):**
  - `typeMapSet`'s `switch` statement containing `case BigInt:` (explains *why*
    the `BigInt` reference is evaluated).
  - `Y.Doc`'s constructor has no `clientID` option, confirmed independently at two
    source locations (`src/utils/Doc.js` and `dist/yjs.cjs:459-463`).
  - `yjs`'s `index.js` re-exports `YMap as Map` / `YText as Text` (checked while
    ruling out an export-aliasing theory for the test-3 failure).
- **From documentation / the brief, never independently triggered here:**
  - The need for `crypto.getRandomValues`, `performance.now`, and
    `process.env`/`argv` shims — these were written before the first test run and
    the bundle loaded cleanly with them in place, so no `ReferenceError` for any of
    them was ever personally observed.

## Bottom line

Yjs 13.6.32 runs under `flutter_js`'s QuickJS on Windows, and a string-only
JSON-in/JSON-out bridge across that boundary works, including base64-encoded
update convergence between two `Y.Doc`s and a deterministically pinned `clientID`.
The architecture is not invalidated. All three bootstrap tests pass. Two concrete
gaps were found along the way and are both now handled: (1) this particular
QuickJS build has no global `BigInt`, which breaks on the very first write to any
`Y.Map` unless shimmed — now shimmed with a loud, self-naming stub; (2) `yjs` has
no constructor-based way to pin `clientID` — the plan's premise about this was
corrected, and the bridge now pins it via a post-construction `doc.clientID =`
property assignment.
