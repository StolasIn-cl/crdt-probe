# Yrs 原始碼離線建置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `native/yffi/v0.27.3/yrs.dll`（目前是下載官方預編譯二進位）換成
「從 vendor 進 repo 的 y-crdt（yrs + yffi）v0.27.3 原始碼、完全離線建置出來」
的版本，行為與現有 C ABI 完全一致，不需要改動任何現有 Dart FFI 綁定。

**Architecture:** 新增 `native/yrs-src/`，內含 y-crdt v0.27.3 的 `yrs`/`yffi`
兩個 crate 原始碼、`cargo vendor` 產生的離線依賴快取、`.cargo/config.toml`
（把 crates-io 換成本機 vendor 目錄）與釘死版本的 `rust-toolchain.toml`。新
增一支獨立的 `tool/build_yrs_native.ps1`，開發者手動執行它來
`cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline`，
並把產出的 `yrs.dll` 複製覆蓋到 `native/yffi/v0.27.3/yrs.dll`。`flutter
build`/`flutter test` 完全不觸發這支腳本；`libyrs.h`、Dart FFI 綁定都不變。

**Tech Stack:** Rust 1.98.0（stable，rustup 已裝）、Cargo（`cargo vendor`
離線快取）、PowerShell（建置腳本）、既有 Flutter/Dart FFI 綁定。

## Global Constraints

- 原始碼來源必須是 `https://github.com/y-crdt/y-crdt` 的 `v0.27.3` tag（解析
  出的 commit 應為 `ac476a47ecc68be26e8c5b48a4be035773636d3a`），不得沿用其
  他專案裡可能已被修改過的副本。
- `native/yrs-src/` 一旦 vendor 完成，`cargo build ... --offline` 之後不得
  再需要網路。
- 對上游原始碼唯一允許的修改：把 `yrs/Cargo.toml` 的 `[dev-dependencies]` 與
  兩個 `[[bench]]` 區塊註解掉（不刪除），並在 `native/yrs-src/PROVENANCE.md`
  記錄原因與效果。`yffi/` 原始碼完全不修改。
- 不整合進 `flutter build windows` 的 CMake 流程；建置腳本必須是獨立、手動
  執行的。
- 不升級 yrs 版本、不新增/移除任何 C ABI 匯出符號——建出來的 `yrs.dll` 匯出
  符號表必須與現有 `native/yffi/v0.27.3/yrs.dll` 完全一致（同樣 206 個匯出
  符號，逐一比對名稱相同）。
- 本機 `core.autocrlf` 為 `true` 且 repo 目前沒有 `.gitattributes`——提交
  `native/yrs-src/` 之前必須先加上 `.gitattributes` 規則,避免 git 之後把
  vendor 進來的檔案做 CRLF/LF 轉換,弄壞 `cargo vendor` 自己記錄的
  `.cargo-checksum.json` 雜湊(這是另一個既有專案曾經真的踩到、事後才修好的
  同一種問題,這裡要在提交前就避免它發生)。

---

### Task 1: Vendor y-crdt v0.27.3 原始碼進 `native/yrs-src/`

**Files:**
- Create: `native/yrs-src/Cargo.toml`
- Create: `native/yrs-src/Cargo.lock`
- Create: `native/yrs-src/rust-toolchain.toml`
- Create: `native/yrs-src/LICENSE`
- Create: `native/yrs-src/PROVENANCE.md`
- Create: `native/yrs-src/.cargo/config.toml`
- Create: `native/yrs-src/yrs/**`（上游 `yrs` crate 原始碼，`Cargo.toml` 的
  `[dev-dependencies]`/`[[bench]]` 區塊改成註解）
- Create: `native/yrs-src/yffi/**`（上游 `yffi` crate 原始碼，完全不修改）
- Create: `native/yrs-src/vendor/**`（`cargo vendor` 產生的離線依賴快取）
- Create/Modify: `.gitattributes`（repo 根目錄，新增，如果之後任務發現已存
  在則追加規則）

**Interfaces:**
- Produces：`native/yrs-src/` 這個可以 `cd` 進去跑
  `cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline`
  的 workspace，之後任務（Task 2、Task 3）直接依賴這個路徑與這個指令。

- [ ] **Step 1: 建立 `.gitattributes`，先於任何 vendor 檔案被 `git add` 之前**

在 repo 根目錄新增 `.gitattributes`（如果之後才發現已有這個檔案，改成在檔
尾追加下面這一段，不要覆蓋掉既有內容）：

```gitattributes
# native/yrs-src is a vendored (checked-in) snapshot of upstream y-crdt plus
# cargo's own vendor/ cache. cargo records a SHA-256 of every vendored
# file's exact bytes in each crate's .cargo-checksum.json; if git rewrites
# line endings on checkout (this repo has core.autocrlf=true), that
# checksum stops matching and `cargo build --offline` fails to resolve the
# vendored crate. Keep every byte under native/yrs-src exactly as vendored.
native/yrs-src/** -text
```

- [ ] **Step 2: 在 repo 外的暫存位置 clone 上游 y-crdt 並核對 commit**

```bash
cd "$(mktemp -d)" 2>/dev/null || cd /tmp
git clone --branch v0.27.3 --depth 1 https://github.com/y-crdt/y-crdt.git y-crdt-src
cd y-crdt-src
git log -1 --format="%H"
```

Expected：印出 `ac476a47ecc68be26e8c5b48a4be035773636d3a`。如果不是這個
hash，停下來，不要繼續——代表 `v0.27.3` tag 的內容跟這份計畫預期的不一樣。

- [ ] **Step 3: 修剪 workspace，只留 `yrs`、`yffi`**

編輯 clone 下來的 `Cargo.toml`（工作目錄根目錄），把 `members` 裡的
`"ywasm"` 拿掉，變成：

```toml
[workspace]

members = [
  "yrs",
  "yffi"
]

[profile.release]
# optimization over all codebase ( better optimization, slower build )
codegen-units = 1
opt-level = 3
lto = true
panic = 'abort'
```

- [ ] **Step 4: 把 `yrs/Cargo.toml` 的 dev-dependencies/bench 區塊改成註解**

把 `yrs/Cargo.toml` 整份內容換成（`[dependencies]` 以上與 `[lib]` 以外的部
分完全比照上游，只有下面這段從真實區塊變成註解）：

```toml
[package]
name = "yrs"
version = "0.27.3"
description = "High performance implementation of the Yjs CRDT"
license = "MIT"
authors = ["Kevin Jahns <kevin.jahns@pm.me>", "Bartosz Sypytkowski <b.sypytkowski@gmail.com>"]
keywords = ["crdt", "yrs"]
edition = "2018"
homepage = "https://github.com/y-crdt/y-crdt/"
repository = "https://github.com/y-crdt/y-crdt/"
readme = "./README.md"

[features]
default = []
weak = []
sync = []
small-client = []

[dependencies]
thiserror = "2"
fastrand = { version = "2", features = ["js"] }
smallstr = { version = "0.3", features = ["union"] }
smallvec = { version = "1.13", features = ["union", "const_generics", "const_new"] }
async-lock = "3.4"
async-trait = "0.1"
arc-swap = "1.7"
serde = { version = "1.0", features = ["derive", "rc"] }
serde_json = "1.0"
dashmap = "6.0"

# crdt_probe note: upstream's [dev-dependencies] (criterion, ropey, proptest,
# rand, uuid, ...) and both [[bench]] targets are commented out, not deleted.
# This vendored copy is only ever built as `cargo build -p yffi --release`
# (producing yrs.dll for Dart FFI) -- nothing here runs `cargo test`/`cargo
# bench` against the vendored yrs/yffi source itself, so these crates would
# only exist to bloat the offline `cargo vendor` cache. See
# native/yrs-src/PROVENANCE.md for the full rationale; this is the only
# intentional deviation from upstream's Cargo.toml.
#
# [dev-dependencies]
# criterion = "0.8"
# flate2 = "1"
# ropey = "1.6.0"
# proptest = "1.2"
# proptest-derive = "0.8.0"
# rand = "0.10"
# assert_matches2 = "0.1"
# uuid = "1.16.0"
#
# [[bench]]
# name = "benches"
# harness = false
#
# [[bench]]
# name = "id_set"
# harness = false

[lib]
doctest = true
bench = false
doc = true
```

- [ ] **Step 5: 產生離線 vendor 快取**

```bash
rm -f Cargo.lock
cargo vendor vendor
```

Expected：輸出結尾印出建議的 `.cargo/config.toml` 內容；`vendor/` 目錄大約
21MB、45 個子目錄（`du -sh vendor` 確認）。如果看到 100MB 以上或
100+ 個子目錄，代表 Step 3/4 的修剪沒有生效，回頭檢查。

- [ ] **Step 6: 建立 `.cargo/config.toml`**

```toml
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
```

- [ ] **Step 7: 新增 `rust-toolchain.toml`**

上游這個 tag 本身沒有這個檔案；新增：

```toml
[toolchain]
channel = "1.98.0"
targets = ["x86_64-pc-windows-msvc"]
```

- [ ] **Step 8: 驗證離線建置成功，且匯出符號與現有 DLL 完全一致**

```bash
cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline
```

Expected：`Finished \`release\` profile [optimized] target(s) in ...`，只有
warning、沒有 error。接著（PowerShell，找得到 `dumpbin` 的話）：

```powershell
$env:PATH += ";C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64"
$new = "<這個暫存目錄>\target\x86_64-pc-windows-msvc\release\yrs.dll"
$old = "C:\Users\stolas_in\Desktop\crdt_probe\native\yffi\v0.27.3\yrs.dll"
dumpbin /exports $new | Out-File new_exports.txt
dumpbin /exports $old | Out-File old_exports.txt
$newSyms = Select-String -Path new_exports.txt -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
$oldSyms = Select-String -Path old_exports.txt -Pattern '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
"new: $($newSyms.Count) old: $($oldSyms.Count)"
Compare-Object $oldSyms $newSyms
```

Expected：`new: 206 old: 206`，`Compare-Object` 沒有輸出任何差異行。

- [ ] **Step 9: 寫 `native/yrs-src/PROVENANCE.md`**

```markdown
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
```

- [ ] **Step 10: 把驗證過的檔案複製進 repo 的 `native/yrs-src/`**

從暫存 clone 複製以下項目到 `C:\Users\stolas_in\Desktop\crdt_probe\native\yrs-src\`：
`Cargo.toml`、`Cargo.lock`、`rust-toolchain.toml`、`LICENSE`、`.cargo/`、
`vendor/`、`yrs/`、`yffi/`（**不要**複製 `target/`、`.git/`、`ywasm/`、
`assets/`、`tests-wasm/`、`tests-ffi/`、`.github/`、`.well-known/`、
`funding.json`、`logo-yrs.svg`、`README.md`、`.gitignore`）。再把 Step 9 寫
好的 `PROVENANCE.md` 放進同一個目錄。

- [ ] **Step 11: 確認 `.gitattributes` 生效，再 commit**

```bash
cd "C:\Users\stolas_in\Desktop\crdt_probe"
git check-attr text native/yrs-src/vendor/thiserror/Cargo.toml
```

Expected：輸出包含 `text: unset`（代表 `-text` 生效，git 不會對這個路徑做
line-ending 轉換）。

- [ ] **Step 12: Commit**

```bash
git add .gitattributes native/yrs-src
git commit -m "build: vendor y-crdt v0.27.3 (yrs+yffi) source for offline builds

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: 建置腳本 `tool/build_yrs_native.ps1`

**Files:**
- Create: `tool/build_yrs_native.ps1`

**Interfaces:**
- Consumes：Task 1 產出的 `native/yrs-src/`（相對於 repo 根目錄的固定路
  徑），以及 `cargo build -p yffi --release --target x86_64-pc-windows-msvc
  --offline` 這個指令。
- Produces：覆蓋 `native/yffi/v0.27.3/yrs.dll`；在終端機印出這個新檔案的
  SHA-256（給 Task 3 回填進 README）。

- [ ] **Step 1: 寫腳本**

```powershell
# tool/build_yrs_native.ps1
#
# Builds yrs.dll from the vendored y-crdt source under native/yrs-src/ and
# copies it over native/yffi/v0.27.3/yrs.dll. Fully offline (--offline) --
# run tool/build_yrs_native.ps1 only when you've changed something under
# native/yrs-src/ and want a fresh yrs.dll; ordinary `flutter test`/
# `flutter build windows` never invoke this automatically.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot "native\yrs-src"
$outDll = Join-Path $repoRoot "native\yffi\v0.27.3\yrs.dll"
$builtDll = Join-Path $srcDir "target\x86_64-pc-windows-msvc\release\yrs.dll"

if (-not (Test-Path $srcDir)) {
    throw "Vendored source not found at $srcDir -- see native/yrs-src/PROVENANCE.md"
}

Write-Host "Building yffi (release, offline) from $srcDir ..."
Push-Location $srcDir
try {
    cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $builtDll)) {
    throw "Expected build output not found at $builtDll"
}

Copy-Item -Path $builtDll -Destination $outDll -Force
$hash = (Get-FileHash -Path $outDll -Algorithm SHA256).Hash
Write-Host ""
Write-Host "Copied $builtDll"
Write-Host "    -> $outDll"
Write-Host ""
Write-Host "SHA-256: $hash"
Write-Host "(paste this into native/yffi/v0.27.3/README.md)"
```

- [ ] **Step 2: 執行腳本，確認它真的把 DLL 換掉了**

```powershell
Copy-Item "C:\Users\stolas_in\Desktop\crdt_probe\native\yffi\v0.27.3\yrs.dll" "$env:TEMP\yrs.dll.before-rebuild"
powershell -File "C:\Users\stolas_in\Desktop\crdt_probe\tool\build_yrs_native.ps1"
(Get-FileHash "C:\Users\stolas_in\Desktop\crdt_probe\native\yffi\v0.27.3\yrs.dll" -Algorithm SHA256).Hash
(Get-FileHash "$env:TEMP\yrs.dll.before-rebuild" -Algorithm SHA256).Hash
```

Expected：腳本印出 `SHA-256: ...` 且執行過程沒有丟出例外；重建後的雜湊值
與重建前（`$env:TEMP\yrs.dll.before-rebuild`，也就是官方預編譯版本）**不
同**——證明檔案確實被換成本機建置的版本，而不是複製了同一個檔案。記下這個
新雜湊值，Task 3 要用。

- [ ] **Step 3: Commit**

```bash
git add tool/build_yrs_native.ps1
git commit -m "build: add standalone script to rebuild yrs.dll from vendored source

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: 更新 `native/yffi/v0.27.3/README.md` 與換掉的 `yrs.dll`

**Files:**
- Modify: `native/yffi/v0.27.3/README.md`
- Modify: `native/yffi/v0.27.3/yrs.dll`（Task 2 Step 2 已經覆蓋過，這裡是把
  它跟文件一起提交）

**Interfaces:**
- Consumes：Task 2 Step 2 產生的新 SHA-256。

- [ ] **Step 1: 改寫 README**

```markdown
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
- SHA-256 (`yrs.dll`, this build): `<Task 2 Step 2 的雜湊值貼在這裡>`
- License: the bundled header carries the y-crdt MIT license notice; see
  `native/yrs-src/LICENSE` for the full text.

`libyrs.h` was diffed line-for-line against the upstream `v0.27.3` header
(`tests-ffi/include/libyrs.h` in the vendored source) and found identical
-- it was not regenerated, and the existing Dart FFI bindings did not need
any change.
```

- [ ] **Step 2: 確認新 `yrs.dll` 已經在工作目錄裡（來自 Task 2 Step 2）**

```bash
git status --short native/yffi/v0.27.3/
```

Expected：看到 `yrs.dll` 顯示為 modified。

- [ ] **Step 3: Commit**

```bash
git add native/yffi/v0.27.3/README.md native/yffi/v0.27.3/yrs.dll
git commit -m "build: switch native/yffi/v0.27.3/yrs.dll to a source-built binary

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: 用整組既有測試驗證換掉的 DLL 沒有改變行為

**Files:**
- 不新增/修改檔案（純驗證任務）；如果任何測試因為這次替換而變紅，回頭修
  Task 1-3 產出的東西，不要改測試本身去遷就它。

**Interfaces:**
- Consumes：Task 3 提交的新 `native/yffi/v0.27.3/yrs.dll`。

- [ ] **Step 1: 跑純 Dart 單元測試**

```bash
cd "C:\Users\stolas_in\Desktop\crdt_probe"
flutter test
```

Expected：`All tests passed!`（28 個測試，跟這次動手前的基準一致）。

- [ ] **Step 2: 跑全部 23 個 Windows integration test**

```bash
cd "C:\Users\stolas_in\Desktop\crdt_probe"
for f in integration_test/*.dart; do
  echo "=== $f ==="
  flutter test "$f" -d windows || echo "RESULT: FAIL $f"
done
```

Expected：全部 23 個檔案都印出 `All tests passed!`，沒有任何 `RESULT: FAIL`
行。（這次動手前，這整批测试因為 `build/windows/x64/CMakeCache.txt` 記著
舊路徑 `.../yjs_probe` 而全部建置失敗；那個問題已經在設計階段修好——刪除了
失效的 `build/` 快取目錄——`axis0_test.dart` 當時單獨重跑已經恢復正常，這
一步是把其餘 22 個檔案也一起跑過，確認全部連帶恢復,同時驗證換成源碼建置
的 `yrs.dll` 之後行為沒有跟著壞掉。）

- [ ] **Step 3: 如果全部通過，沒有東西需要 commit（Task 1-3 已經各自
  commit 過)；如果有測試失敗，記錄下失敗的檔案與錯誤訊息，回到對應的
  Task 重新檢查（例如：匯出符號是否真的一致、DLL 是否真的被換掉、
  `libyrs.h` 是否真的沒變)，修好後回到 Step 1 重跑整組測試。**
