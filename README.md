# yjs_probe

一個獨立的 Flutter (Windows desktop) 實驗專案，用來探測 **Yjs**（JS 端 CRDT 實作）與
**Yrs**（Rust 端、經 `yffi` 提供 C ABI 的同款 CRDT 實作）在真實 Runtime 下的行為細節，
最初是為了替 Promeo 的協同編輯（collaboration）功能評估 CRDT 方案而建立。

> **狀態：封存紀錄。** 本專案原本存放於 Promeo 主 repo（`promeo-pc-promeo-memory-profiler`）
> 的 `yjs_probe/` 之下，後續不會再被 Promeo 使用，這份副本是從該 repo 的 git 追蹤檔案
> 原樣抽出，單獨保存以便日後查閱當時的觀察與結論。

## 這個專案在做什麼

它不是一個產品功能，而是一系列針對 CRDT 語意的**探測（probe）與情境測試（scenario）**，
目的是回答「Yjs / Yrs 在特定操作序列下究竟如何收斂」這類問題，而不是靠讀文件猜測。
重要發現都寫成 `reports/` 底下的個別報告，`NOTES-quickjs.md` 則記錄了讓 Yjs（一個
JS 函式庫）在 Flutter 的 QuickJS 引擎上跑起來時踩到的實際限制（例如 QuickJS 沒有全域
`BigInt`）。

主要探測的問題包含：
- 兩個 CRDT 實作（Yjs / native Yrs）在 undo/redo、格式化標記（bold/italic 等）、
  多人同時編輯、IME 組字（composition）等情境下的收斂行為是否一致。
- Title 欄位在「exact-U」與「semantic-Q」兩種 admission 策略下，各自的正確性邊界。
- 原生 Yrs runtime（透過 FFI）與瀏覽器端 Yjs runtime 之間的跨 runtime 互通性。

## 架構總覽

```
lib/
  core/       # 與 runtime 無關的基礎型別（envelope、id、projection、write gate）
  runtime/
    yjs/      # 透過 flutter_js（QuickJS）驅動的 Yjs runtime，經 assets/js/yjs_bridge.js 橋接
    yrs/      # 透過 dart:ffi 呼叫 native/yffi 下 yrs.dll 的 native Yrs runtime
    promeo/   # 模擬 Promeo 既有欄位寫入語意的 runtime，供跨 runtime 比較
  transport/  # In-memory 的「thin server + post office」，模擬多 client 之間的訊息傳遞
  harness/    # scenario runner：把一組操作序列跑在指定 runtime 上並收集結果
  driver/     # script driver：把人可讀的操作腳本轉成對 runtime 的呼叫
  diagnostics/# 事件記錄與 JSON 匯出，供產生 reports/ 內容使用
  ui/         # 讓人可以手動操作、觀察 runtime 行為的 Flutter 介面（lib/main.dart 進入點）

js/           # Yjs 橋接層原始碼（Rollup 打包），輸出到 assets/js/yjs_bridge.js
native/yffi/  # 釘死版本的 y-crdt (yffi) v0.27.3 Windows x64 預編譯產物（yrs.dll + 標頭）
test/         # 純 Dart 單元測試（不需要跑在裝置上）
integration_test/ # 需要 `-d windows` 才能跑的 Flutter integration_test（會啟動真正的 exe）
tool/         # 一次性的命令列探測腳本，個別對應某個 report
reports/      # 每個探測問題的書面結論（已回答的問題，含背景、方法與結果）
docs/architecture/ # 架構相關的補充文件
```

兩個 runtime 刻意做成同一組介面（`lib/runtime/crdt_runtime.dart`），這樣同一份
scenario 腳本才能分別跑在 Yjs 與 Yrs 上做行為比對。

## 環境需求

- Flutter（本專案以 `3.41.6` / Dart `3.11.4` 驗證）並啟用 Windows desktop 支援：
  ```bash
  flutter config --enable-windows-desktop
  ```
- Windows 上需要能建置 Flutter Windows 應用的工具鏈（Visual Studio 的 C++ 桌面開發工作負載）。
- `native/yffi/v0.27.3/yrs.dll` 已經隨 repo 一併提供（釘死版本，詳見該目錄下的
  `README.md`），不需要另外編譯 Rust。
- `assets/js/yjs_bridge.js` 是已建置好並提交的 bundle，一般開發/測試/建置**不需要**
  跑 Node/npm；只有要修改 `js/src/*.js` 橋接層原始碼時才需要在 `js/` 下
  `npm install && npm run build` 重新產生它。

## 如何執行

安裝相依套件：

```bash
flutter pub get
```

跑純 Dart 單元測試（`test/`，不需裝置）：

```bash
flutter test
```

跑 integration test（`integration_test/`，需要指定裝置，會實際建置並啟動 Windows exe）：

```bash
flutter test integration_test/yjs_bootstrap_test.dart -d windows
flutter test integration_test/yrs_runtime_test.dart -d windows
# 其餘檔案同理，一次跑一個檔案
```

靜態分析：

```bash
flutter analyze
```

建置 Windows release：

```bash
flutter build windows --release
```

建置產物位於 `build/windows/x64/runner/Release/`（`yjs_probe.exe` 連同
`yrs.dll`、`quickjs_c_bridge.dll`、`flutter_js_plugin.dll` 等相依 DLL）。

## 本副本的驗證紀錄

這份副本從 Promeo repo 的 git 追蹤內容原樣複製後，在本機重新驗證過一次：

- `flutter pub get` — 成功解析相依套件。
- `flutter test` — `test/` 下 28 個單元測試全數通過。
- `flutter test integration_test/yjs_bootstrap_test.dart -d windows` — 3 個測試全數通過
  （驗證 QuickJS + Yjs 橋接路徑可正常建置與執行）。
- `flutter test integration_test/yrs_runtime_test.dart -d windows` — 4 個測試全數通過
  （驗證 native Yrs FFI 路徑可正常建置與執行）。
- `flutter analyze` — 0 個 error/warning，僅 `tool/` 下的 CLI 探測腳本有
  `avoid_print`（info 等級，探測腳本本就是靠印出結果來使用，予以保留）。
- `flutter build windows --release` — 成功產出 `yjs_probe.exe`。

其餘 `integration_test/` 下的檔案沿用同一套 harness（`flutter test <檔案> -d windows`），
未在本次驗證中逐一全部重跑；各自的背景與結論可在 `reports/` 對應報告中查閱。

## 延伸閱讀

- `NOTES-quickjs.md` — 讓 Yjs 在 Flutter 的 QuickJS 上跑起來時的實測限制與修法。
- `reports/*.md` — 各個探測問題的完整報告（依編號大致對應探測的先後順序）。
- `docs/architecture/` — 架構相關補充文件。
- `native/yffi/v0.27.3/README.md` — 釘死的 native Yrs 二進位版本資訊與雜湊值。
