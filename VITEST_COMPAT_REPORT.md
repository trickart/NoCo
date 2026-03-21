# Vitest on NoCo 互換性テストレポート

**テスト日**: 2026-03-20（最終更新: 2026-03-20 PR #145, #146, #147, #148 後）
**Vitest バージョン**: v4.1.0
**NoCo ブランチ**: main (PR #141〜#148 マージ済み)

## 現在の到達状況

vitest が **`RUN v4.1.0`** バナーを表示し、`createVitest()` → vite `createServer()` → テスト実行フェーズまで到達。worker fork の起動で停止（worker 側の依存モジュール不足）。

## 動くようになった部分

- vitest CLI起動、設定読み込み、テストファイル検出
- forks pool workerのfork、IPC通信（親↔子間メッセージ送受信）
- workerの初期化とコマンド応答
- **イベントループの microtask drain（PR #141）** — fire-and-forget な Promise chain がループ開始前に処理される
- **ESM Top-Level Await の静的 import 対応（PR #142）** — `import { value } from './tla-module.mjs'` が正常動作
- **TLA false positive 対策（PR #143）** — `module.exports` 内容チェックによる回避策
- **ESM transform 性能改善（PR #144）** — vite require 9秒→1.7秒
- **node:vm / node:module API 拡充（PR #145）** — vitest worker が参照する `Module.wrap`, `_findPath`, `findPackageJSON`, `vm.constants` 等を追加
- **ESM トランスフォーマ excluded ranges バグ修正（PR #146）** — 16個以上の named imports を持つ ESM ファイルで後続の import が変換されない問題を修正
- **vite createServer に必要な API 追加（PR #147）** — `crypto.hash()`, `fs.rmSync()`, `fs.promises.rm` を実装
- **TLA 検出の brace stack 方式改善（PR #148）** — class body 内メソッドや制御フロー文内の `await` の TLA 誤検出を根本修正
- **npm 依存モジュールのロード** — `vite`(60 exports), `pathe`, `tinyrainbow`, `@vitest/utils`, `@vitest/runner`, `@vitest/snapshot`, `picomatch`, `tinyglobby`, `es-module-lexer`, `magic-string`, `vite/module-runner`(13 exports) 等がすべて正常にロード

## 詳細な検証結果

### ESM モジュール解決
- `import { describe, it, expect } from 'vitest'` — 正常に解決・読み込み可能
- `package.json` の `exports` 条件マップ（`import` / `require`）は `esmContext` フラグで正しく切り替わる
- **static import of TLA module** — PR #142 で修正。事前ロード方式で TLA Promise を drain
- dynamic `await import(...)` は TLA 対応済みで動作
- **大量の named imports を持つ ESM ファイル** — PR #146 で修正。`applyPattern` の excluded ranges 更新で後続 import が変換されない問題を解決

### vitest CLI（cac パーサー）
- `createCLI().parse()` でコマンドマッチ・オプション解析は正常動作
- `run` コマンドの async action は正しくマッチ・起動する
- キープアライブ付きで実行するとバナー `RUN v4.1.0 /Users/trick/NoCo` が表示され、テスト実行フェーズまで進む

### 大型 ESM ファイルのロード（PR #144, #146, #148 で解決）
- `vite/module-runner`（1258行, 54KB）— 正常ロード ✅
- `vite/dist/node/node.js`（巨大チャンク）— PR #144 で ESM transform 性能改善、1.7秒でロード ✅
- `vitest/dist/chunks/cli-api.DuT9iuvY.js`（14523行, 489KB, 63個の静的 import）— PR #146 の excluded ranges 修正で全 import が正しく変換、正常ロード ✅
- `vitest/dist/chunks/traces.CCmnQaNT.js`（class 内 await）— PR #148 の TLA 根本修正で正常ロード ✅
- `vitest/dist/chunks/index.Chj8NDwU.js`（関数内 await）— PR #148 の brace stack 方式で正常ロード ✅

### 起動フロー到達状況
- `vitest/dist/cli.js` → cac CLI パーサー → `run` アクション起動 ✅
- `createVitest()` → vite `createServer()` ✅（PR #147 で `crypto.hash`, `fs.rmSync` を追加）
- `_setServer()` → `new Traces()` ✅（PR #148 で TLA 誤検出を修正）
- テスト実行フェーズ → **worker fork で停止**（worker 側の依存モジュール不足）
- `createBirpc` は PR #148 で正常動作 ✅

### Worker fork
- `child_process.fork()` 自体は動作（基本的な IPC メッセージ送受信も OK）
- vitest は `serialization: "advanced"`（V8 structured clone）を指定 — NoCo は JSON シリアライゼーションのみ対応
- worker スクリプト (`dist/workers/forks.js`) の依存に `node:v8` 等の未実装モジュールが含まれるため停止
- 現在のブロッカー: worker 内での vitest モジュール初期化

### `--pool=threads` の場合
- `worker_threads` モジュールが基本スタブのため、forks にフォールバック

## 解決済みの問題

### ✅ `containsTopLevelAwait` の false positive（PR #148 で根本修正）
- class body 内メソッド（constructor, async method）の `await` を TLA と誤検出 → **brace stack 方式で解決**
- 制御フロー文（if/for/while）の `{}` で function scope depth がずれる問題 → **function scope と control-flow brace を区別して管理**
- PR #143 の回避策は不要に（ただし互換性のため残存）

### ✅ ESM transform の excluded ranges バグ（PR #146 で修正）
- `applyPattern` でマッチ内の excluded ranges が残り、16個以上の named imports 後の import が変換されない
- `compactMap` で replaced region 内の excluded ranges を削除するように修正

### ✅ vite createServer のエラー（PR #147 で修正）
- `crypto.hash("sha256", text, "hex")` — Node.js 21+ のワンショットハッシュ関数が未実装 → 追加
- `fs.promises.rm(path, { recursive: true, force: true })` — `rm`/`rmSync` が未実装 → 追加

### ✅ top-level await（PR #140, #142 で対応済み）
- 基本 TLA、静的 import 経由の TLA ともに正常動作
- 事前ロード方式（`preloadStaticImports`）で JS コールバック外から microtask drain を実行

### ✅ ESM transform の性能（PR #144 で改善）
- vite require 9秒→1.7秒に改善

## イベントループ改善（2026-03-21 実施）

### 実装済みの改善

1. **Microtask-aware ループ継続** — while 条件から `hasPendingWork` を除去し、ループ本体内で「最終 microtask ドレイン → 再チェック → break」パターンに変更。Promise `.then()` 内で登録された新しい仕事が見落とされなくなった。
2. **Timer ref/unref** — `TimerEntry.isRef` フラグ追加。`hasPendingWork` で ref タイマーのみカウント。JS 側 `wrapTimeout` の `ref()`/`unref()` が Swift の `__timerRef(id, bool)` を呼び出す。vitest 内部タイマーの `unref()` が正しく機能。
3. **setImmediate 専用キュー** — `immediateQueue` / `ImmediateEntry` 追加。タイマーフェーズ後、セマフォ wait 前に実行。Node.js の check フェーズに相当。
4. **`__importDynamic` の Promise ファクトリキャッシュ化** — `evaluateScript` を毎回呼ぶ代わりに、`Promise.resolve`/`Promise.reject` のファクトリ関数を `install()` 時に取得しキャッシュ。`evaluateScript` による不要な microtask drain を回避。

### ✅ keepalive なし vitest 実行（2026-03-21 解決）

#### 根本原因の特定

vitest の async chain: `start()` → `startVitest()` → `prepareVitest()` → `createVitest()` → `bundleConfigFile()` → `rolldown()` の過程で、rolldown の NAPI ネイティブバインディングが以下の処理を行う:

1. `napi_create_threadsafe_function` を 7-8 個作成（Rust/Tokio ランタイムとの通信用）
2. `napi_create_promise` で deferred Promise を作成（バンドル結果用）
3. バックグラウンドの Rust/Tokio スレッドで実際のバンドル処理を実行
4. 完了後 `napi_call_threadsafe_function` で JS スレッドにコールバック

**問題**: `napi_create_threadsafe_function` がイベントループの `retainHandle()` を呼んでいなかったため、バックグラウンド作業が完了する前にイベントループが「保留中の仕事なし」と判断して終了。

**50ms keepalive で動いた理由**: keepalive タイマーがイベントループを維持し、その間にバックグラウンドの rolldown ビルドが完了してコールバックがキューに入った。

#### 修正内容

| ファイル | 変更 |
|---------|------|
| `NAPIThreadSafe.swift` | TSF 作成時に `retainHandle()`、解放時に `releaseHandle()` |
| `NAPIAsyncWork.swift` | async work キュー投入時に `retainHandle()`、完了コールバック後に `releaseHandle()` |
| `NAPIPromise.swift` | `evaluateScript` → キャッシュされたファクトリ関数で microtask drain を回避 |

#### 結果

- keepalive なしで `RUN v4.1.0` バナー表示 → テストファイル検出 → worker fork フェーズまで到達
- rolldown のバンドル・config 読み込み・vite createServer がすべて正常完了
- worker fork タイムアウト（60秒）後にエラー表示して正常に終了

### 追加調査結果

- **ネストされた TLA drain の `evaluateScript("void 0")` が外部 microtask をドレインする問題を修正** — `loadFile` のネストされた TLA drain で `evaluateScript("void 0")` ループを削除。代わりに module.exports の内容で TLA false positive を判定し、真の TLA は Promise をそのまま返す。
- **`wrapAsNamespace` の `evaluateScript` キャッシュ化** — 毎回 `evaluateScript` を呼ぶ代わりに、コンテキストプロパティにキャッシュした関数を使用。
- **`__importDynamic` の Promise ファクトリキャッシュ化** — 同上。
- **`napi_create_promise` の `evaluateScript` キャッシュ化** — NAPI Promise 作成時の microtask drain を回避。

## 残りの課題と対応優先度

1. **worker 内のモジュール初期化** — vitest worker スクリプトが依存する API の調査と実装
2. **`node:v8` の serialize/deserialize** — `serialization: "advanced"` 対応（worker IPC に必要）
3. **`worker_threads` の実装強化** — threads pool 対応
