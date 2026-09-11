// QuickJS lacks these; lib0 (yjs's dependency) reaches for all three.
// `crypto.getRandomValues` is only used to mint a doc's initial clientID via
// lib0's random.uint32() — which this probe always overrides immediately after
// by assigning `doc.clientID` directly (Y.Doc's constructor has no clientID
// option; see bridge.js's createDoc) — but lib0 touches crypto at import time,
// so it must exist regardless. A counter is deliberately used instead of a
// random source: the probe must be reproducible.
let __randCounter = 1;
if (typeof globalThis.crypto === 'undefined') {
  globalThis.crypto = {
    getRandomValues(arr) {
      for (let i = 0; i < arr.length; i++) arr[i] = (__randCounter++) & 0xff;
      return arr;
    },
  };
}

if (typeof globalThis.performance === 'undefined') {
  let __t = 0;
  globalThis.performance = { now: () => (__t += 1) };
}

if (typeof globalThis.process === 'undefined') {
  globalThis.process = { env: {}, argv: [] };
}

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
