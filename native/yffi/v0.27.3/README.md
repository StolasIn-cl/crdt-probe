# yrs.dll: built from vendored y-crdt source

This directory holds `yrs.dll` (the C ABI binary Dart FFI loads) and
`libyrs.h` (its header, used only as documentation for the Dart bindings
in `lib/runtime/yrs/yrs_ffi_bindings.dart` -- Dart FFI does not parse C
headers itself).

`yrs.dll` is **no longer a downloaded prebuilt binary**. It is built
locally, offline, from the vendored y-crdt source under
`native/yrs-src/` -- run `tool/build_yrs_native.ps1` from the repo root to
reproduce it. See `native/yrs-src/PROVENANCE.md` for exactly what was
vendored, from where, and the one intentional deviation from upstream.

- Source: `native/yrs-src/` (y-crdt v0.27.3, commit
  `ac476a47ecc68be26e8c5b48a4be035773636d3a`)
- Built with: `cargo build -p yffi --release --target
  x86_64-pc-windows-msvc --offline`
- SHA-256 (`yrs.dll`, this build): `B3FAE3C9696283B42306C633CAB12F06FFE827462E92C2ED31614C394089C2DD`
- License: the bundled header carries the y-crdt MIT license notice; see
  `native/yrs-src/LICENSE` for the full text.

`libyrs.h` was diffed line-for-line against the upstream `v0.27.3` header
(`tests-ffi/include/libyrs.h` in the vendored source) and found identical
-- it was not regenerated, and the existing Dart FFI bindings did not need
any change.
