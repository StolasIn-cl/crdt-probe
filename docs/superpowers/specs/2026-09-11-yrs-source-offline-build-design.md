# Yrs 原始碼離線建置設計

日期：2026-09-11

## 背景與目標

`native/yffi/v0.27.3/` 目前是直接下載官方 release 的預編譯 Windows 二進位
（`yrs.dll` + `libyrs.h`），沒有對應的 Rust 原始碼。這個設計要把它換成「從
實際的 y-crdt（yrs + yffi）Rust 原始碼、在本機離線建置出來」的版本，取代
預編譯二進位，同時：

- 保持行為與 ABI 完全一致（現有 `lib/runtime/yrs/yrs_ffi_bindings.dart`、
  `lib/runtime/yrs/yrs_runtime.dart` 不需要改）。
- 建置流程獨立於 `flutter build`/`flutter test`（不整合進 CMake），開發者
  需要「從原始碼建的 DLL」時手動跑一支建置腳本。
- 一旦 vendor 完成，之後的 `cargo build` 完全不接觸網路。

## 原始碼來源與 Provenance

- 上游：`https://github.com/y-crdt/y-crdt`，tag `v0.27.3`，解析出的 commit 為
  `ac476a47ecc68be26e8c5b48a4be035773636d3a`（與另一個既有專案裡獨立 vendor
  同一版本時記錄的 commit hash 一致，可交叉驗證）。
- 從 GitHub 全新 clone，不沿用任何其他專案裡可能已被修改過的副本。
- 只保留 workspace 內 `yrs/`、`yffi/` 兩個 crate（原始 workspace 還有
  `ywasm`，探測不需要 WASM 綁定，故從 `Cargo.toml` 的 `members` 移除，目錄也
  不納入）。
- 不納入 `assets/`（bench 用大型測試資料，約 38MB）、`tests-wasm/`、
  `tests-ffi/`、`.github/`、`.well-known/`、`funding.json`、`logo-yrs.svg`
  ——這些對建置 `yrs.dll` 沒有作用。
- 新增 `rust-toolchain.toml` 釘死 `channel = "1.98.0"`（上游這個 tag 本身沒有
  這個檔案；`1.98.0` 是這台機器上已安裝、且驗證過可以乾淨建置的版本）。

### 唯一的刻意偏離：註解掉 `yrs` 的 `[dev-dependencies]` / `[[bench]]`

`yrs/Cargo.toml` 的 `[dev-dependencies]`（criterion、ropey、proptest、rand、
uuid 等）與兩個 `[[bench]]` 目標被**註解掉、不是刪除**，並在原地留下說明
註解。這是唯一對上游原始碼的修改：

- 這個探測專案只會 `cargo build -p yffi --release`，產出 `yrs.dll` 給 Dart
  FFI 用；不會對 vendor 進來的 `yrs`/`yffi` 原始碼跑 `cargo test`/
  `cargo bench`，所以這些 dev-only 依賴只會讓離線 vendor cache 變大，對建置
  出的 `yrs.dll` 行為沒有任何影響。
- 實測效果：`cargo vendor` 產生的快取從 **~220MB / 131 個 crate** 降到
  **~21MB / 45 個 crate**。
- 這個偏離會記錄在 `native/yrs-src/PROVENANCE.md`（風格參考另一個既有專案的
  `PROVENANCE.md`，但重新撰寫），列出「這一行、這個原因、這個效果」，之後任
  何人重新 vendor 時知道為什麼原始 `Cargo.toml` 長得不太一樣。

## 檔案配置

新增：

```
native/yrs-src/
  Cargo.toml            # workspace，members = ["yrs", "yffi"]
  Cargo.lock
  rust-toolchain.toml    # channel = "1.98.0"
  LICENSE                # 上游 MIT license 原文
  PROVENANCE.md          # 來源、commit hash、vendor 方式、dev-deps 偏離說明
  .cargo/config.toml     # [source.crates-io] replace-with = "vendored-sources"
  vendor/                # cargo vendor 產生的離線依賴快取（~21MB，提交進 git）
  yrs/                   # 上游 yrs crate 原始碼（僅 dev-deps/bench 區塊被註解）
  yffi/                  # 上游 yffi crate 原始碼（完全未修改）

tool/build_yrs_native.ps1   # 建置腳本
```

`native/yffi/v0.27.3/`（現有目錄）維持存放「建置產物」`yrs.dll` +
`libyrs.h`，但其 `README.md` 要更新說明：這兩個檔案現在是「用
`tool/build_yrs_native.ps1` 從 `native/yrs-src/` 建出來的」，而不是下載官方
release 壓縮檔，並記錄重新建置後的 SHA-256。

## 建置腳本

`tool/build_yrs_native.ps1`：

1. 在 `native/yrs-src/` 下執行
   `cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline`。
2. 把 `target/x86_64-pc-windows-msvc/release/yrs.dll` 複製並覆蓋到
   `native/yffi/v0.27.3/yrs.dll`。
3. 重新計算 SHA-256，印出來（供人工回貼進
   `native/yffi/v0.27.3/README.md`）。
4. `libyrs.h` 不需要重新產生——已經逐行核對過，v0.27.3 上游的
   `tests-ffi/include/libyrs.h` 與現有 `native/yffi/v0.27.3/libyrs.h` 完全
   相同。

`flutter test`/`flutter build windows` 不會自動觸發這支腳本；沒跑過腳本時，
repo 裡原本的（或上一次建置留下的）`yrs.dll` 繼續被使用。

## 已完成的驗證（設計核准前的技術驗證）

在這台機器上實際跑過一次完整流程，證實可行：

- `git clone --branch v0.27.3 --depth 1` 與 `cargo vendor` 都能連上網路，
  解析出的 commit hash 與另一個既有專案裡獨立 vendor 同版本時記錄的一致。
- 註解掉 `yrs` 的 dev-dependencies 後重新 `cargo vendor`：快取從 220MB 降到
  21MB（131 → 45 個 crate 目錄）。
- `cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline`
  在完全離線（`--offline`）情況下建置成功（47 秒，僅有警告、無錯誤）。
- 用 `dumpbin /exports` 比對新建置出的 `yrs.dll` 與現有 repo 裡預編譯的
  `yrs.dll`：**兩者匯出符號數與名稱完全一致（206/206，無差異）**——換句話
  說這份建置產物在 C ABI 層級是可以直接替換的。

## 驗收方式（實作階段要做的事）

1. 把上述 `native/yrs-src/` 樹、`tool/build_yrs_native.ps1`、更新後的
   `native/yffi/v0.27.3/README.md` 加進 repo。
2. 跑一次建置腳本，用它產出的 `yrs.dll` 覆蓋現有檔案。
3. 重跑 `flutter test`（純 Dart 單元測試，28 個）與全部 23 個
   `integration_test/*.dart`（`-d windows`），確認結果與目前用預編譯 DLL 時
   一致（不需要期待數字全新，只需要「沒有因為換了 DLL 而變壞」）。
4. 順便完成使用者要求的「確認之前建立的測項都可以正常運作」——本次探索過程
   已經發現並修好一個既有問題：`build/windows/x64/CMakeCache.txt` 記著這個
   專案先前所在的舊路徑（`.../yjs_probe`，現在是 `.../crdt_probe`），導致所
   有 23 個 integration test 建置失敗；已刪除失效的 `build/` 快取目錄，
   `axis0_test.dart` 重跑後恢復 All tests passed，其餘 22 個預期同一成因，
   會在本次實作中一併全部重跑確認。

## Non-goals（明確不做的事）

- 不修改 `yrs`/`yffi` 的任何行為邏輯（唯一的原始碼偏離是註解掉
  dev-dependencies/bench，對 release 建置無影響）。
- 不把建置整合進 `flutter build windows` 的 CMake 流程。
- 不處理 macOS/Linux/其他平台的建置（這個探測專案本來就只鎖定
  Windows desktop）。
- 不升級 yrs 版本（維持 v0.27.3，與現有 `libyrs.h`/Dart bindings 對齊）。
