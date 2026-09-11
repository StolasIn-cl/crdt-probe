# Vendored source: y-crdt (yrs + yffi)

This directory is a vendored (checked-in) snapshot of upstream y-crdt's
`yrs` and `yffi` crates, plus cargo's own offline dependency cache
(`vendor/`). It is not a git submodule and not a fork.

- Upstream URL: https://github.com/y-crdt/y-crdt
- Tag: `v0.27.3`
- Resolved commit hash: `ac476a47ecc68be26e8c5b48a4be035773636d3a`
- Date vendored: 2026-09-11
- Vendored via: `git clone --branch v0.27.3 --depth 1
  https://github.com/y-crdt/y-crdt.git`, then the `.git` directory was
  stripped.
- License: MIT. See `LICENSE` in this directory (copied unmodified from
  the upstream repository root at the pinned commit).

## What's included and what's not

Only the `yrs/` (core CRDT) and `yffi/` (C ABI) crates are vendored. The
upstream workspace also declares `ywasm` (WebAssembly bindings); it is not
needed to build `yrs.dll` for Dart FFI, so it was dropped from
`Cargo.toml`'s `members` and its directory was not copied. Also not
copied, for the same reason: `assets/` (bench input data, ~38MB),
`tests-wasm/`, `tests-ffi/`, `.github/`, `.well-known/`, `funding.json`,
`logo-yrs.svg`.

`yffi/Cargo.toml` declares `[lib] crate-type = ["staticlib", "cdylib"]`
and `name = "yrs"` — so `cargo build -p yffi --release` produces
`yrs.dll`/`yrs.lib`/`libyrs.a` under `target/<triple>/release/`, not
`yffi.*`. This project consumes the `cdylib` output (`yrs.dll`) via Dart
`dart:ffi`'s `DynamicLibrary.open`, the same way the previously-vendored
prebuilt binary was consumed — no Dart-side change needed.

## The one intentional deviation from upstream: `yrs/Cargo.toml`

`yrs/Cargo.toml`'s `[dev-dependencies]` (criterion, flate2, ropey,
proptest, proptest-derive, rand, assert_matches2, uuid) and both
`[[bench]]` targets are commented out, not deleted. This project only
ever builds `cargo build -p yffi --release` — it never runs `cargo
test`/`cargo bench` against this vendored `yrs`/`yffi` source — so those
dev-only dependencies exist only to bloat the offline `cargo vendor`
cache. Measured effect: `vendor/` shrank from ~220MB/131 crates to
~21MB/45 crates. This is the only line-for-line change from upstream;
`yffi/` is completely unmodified.

## Rust toolchain

Upstream's `v0.27.3` tag has no `rust-toolchain.toml`. This directory adds
one pinning `channel = "1.98.0"` — the stable version already installed
via rustup on the machines this was vendored and verified on. `cargo build
-p yffi --release --target x86_64-pc-windows-msvc --offline` was confirmed
to succeed cleanly with it (only warnings, no errors).

## Verifying a rebuild matches the previously-shipped binary

`dumpbin /exports` on a `yrs.dll` built from this directory was compared
against the previously-vendored official prebuilt `yrs.dll`
(`native/yffi/v0.27.3/`, SHA-256
`9AE2DC9CF393363F9367F7453852917B434A428AD39620E06A4E9C996FB9CAC9`): both
export exactly 206 symbols, with identical names — no additions, no
removals. The exact bytes differ (release builds are not bit-reproducible
across machines/toolchains by default), but the C ABI surface is
identical.
