# Test-only yffi v0.27.3 Windows asset

This directory contains the exact Windows x64 native asset used by the
standalone `yjs_probe` experiment. It is not part of Promeo's production
runtime and must not be copied into `promeo_trunk`.

- Source release: https://github.com/y-crdt/y-crdt/releases/tag/v0.27.3
- Archive: `yffi-v0.27.3-x86_64-windows.zip`
- Extracted files: `yrs.dll`, `libyrs.h`
- SHA-256 (`yrs.dll`): `9AE2DC9CF393363F9367F7453852917B434A428AD39620E06A4E9C996FB9CAC9`
- License: the bundled header carries the y-crdt MIT license notice; this
  probe uses the binary only for local measurement.

The archive is a one-version test dependency. It is intentionally pinned so
the P3 report can identify the exact Yrs ABI and native runtime measured.
