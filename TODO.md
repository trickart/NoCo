# NoCo 追加機能リスト

## 実装済みモジュール（21個）

`assert`, `async_hooks`, `buffer`, `child_process`（macOSのみ）, `console`, `crypto`, `events`, `fs` (`fs/promises`含む), `http`, `http2`, `net`, `os`, `path`, `process`, `querystring`, `stream`, `string_decoder`, `timers`, `tty`, `url`, `util`, `zlib`

### 実装済み Web API

`CompressionStream`, `DecompressionStream`, `ReadableStream`, `WritableStream`, `TransformStream`, `Request`, `Response`, `URL`, `URLSearchParams`, `TextEncoder`, `TextDecoder`, `crypto.subtle` (HMAC sign/verify, digest, importKey, exportKey), `crypto.getRandomValues`, `crypto.randomUUID`, `Blob`, `File`, `FormData`, `fetch`, `atob`, `btoa`, `Cache API` (`globalThis.caches`)

---

## 優先度: 高（実用性・npm互換性に大きく貢献）

### 1. `https` / TLS サポート

- `https.createServer()`, `https.request()`, `https.get()`
- NIOTransportServices は Network.framework 経由で TLS をネイティブサポートしているため、比較的自然に追加可能
- 現代のWebアプリでは事実上必須

### 3. `crypto` の暗号化/復号化

- `createCipheriv()`, `createDecipheriv()` (AES-128-CBC, AES-256-GCM 等)
- Apple CryptoKit で AES-GCM は直接サポート、CBC は CommonCrypto で実装可能
- 認証トークンや暗号化処理を行う npm パッケージに必要

## 優先度: 中（機能の幅を広げる）

### 4. `readline` モジュール

- 対話型 CLI ツール（REPL、プロンプト入力）の構築に必要
- `createInterface()`, `question()`, `prompt()`
- stdin/stdout の EventEmitter 統合

### 5. `dgram` モジュール (UDP)

- `createSocket()`, `send()`, `bind()`
- Network.framework の `NWConnection` で UDP もサポートされている
- DNS リゾルバや mDNS 系ツールに必要

### 6. `dns` モジュール

- `lookup()`, `resolve()`, `resolve4()`, `resolve6()`
- Foundation の `CFHost` または Network.framework で実装可能
- HTTP クライアントの名前解決をJS側で制御可能に

## 優先度: 低（発展的機能）

### 7. ES Modules (ESM) サポート

- `import/export` 構文のサポート
- JavaScriptCore は ES6 モジュールを部分的にサポートしているが、独自のモジュールローダーとの統合が課題
- 最新の npm パッケージは ESM のみで配布されるケースが増加

### 8. REPL モード

- `noco` を引数なしで実行した時の対話モード
- readline + EventLoop の統合、`.help`, `.exit` などの特殊コマンド
- Node.js の開発体験に不可欠

### 9. `worker_threads` モジュール

- JavaScriptCore の `JSVirtualMachine` を複数インスタンス化して並列実行
- `SharedArrayBuffer` / `MessagePort` による通信
- 実装コストは高いが、CPU バウンドな処理に有用

### 10. `perf_hooks` / パフォーマンス計測

- `performance.now()`, `performance.mark()`, `performance.measure()`
- `mach_absolute_time()` で高精度タイマーを実装可能

### 11. `crypto.subtle` の拡充

- 未実装: `generateKey`, `deriveKey`, `deriveBits`, `encrypt`, `decrypt`, `wrapKey`, `unwrapKey`
- 基本的な JWT (HMAC) は動作するが、RSA/ECDSA ベースの JWT や暗号化操作は不可

### 12. WebSocket

- Hono の WebSocket ヘルパー (`hono/websocket`) が動作しない
- 大きな機能追加が必要

## おすすめの実装順序

```
crypto拡張 → https → readline → REPL → dns → dgram → ESM
```

---

## キラーアプリ・ライブラリ互換性ロードマップ

NoCo の実用性を証明するために、実際の Node.js ライブラリを動かすことを目標にする。

### 達成済みマイルストーン

#### Hono ✅

軽量 Web フレームワーク。`@hono/node-server` 経由で NoCo 上で動作確認済み。

動作する機能: コアルーティング、ミドルウェア（cors, logger, jwt 等）、ヘルパー（cookie, html 等）、全ルーター。詳細は `hono-todo.md` を参照。

残課題: `serve-static`（`createReadStream` 実装済み、要再テスト）、`hono/compress`（要再テスト）

### 次のターゲット：Express.js

「Node.js ランタイム」の信頼性の試金石。Deno も Bun も Express 互換を重要マイルストーンにしている。

NoCo には既に `http`, `net`, `stream`, `events`, `path`, `url`, `querystring`, `fs`, `buffer`, `crypto` があるため、土台はかなり揃っている。Express の主要な依存パッケージ（`qs`, `path-to-regexp`, `merge-descriptors` 等）はほぼ Pure JS なので、足りない部分は限定的なはず。

```js
const express = require('express')
const app = express()
app.get('/', (req, res) => res.send('Hello from NoCo!'))
app.listen(3000)
```

これが動けば、NoCo の実用性を一気に証明できる。

#### Express.js 動作確認済み（基本ルーティング）

`GET /` と `GET /json` の動作を確認。以下の4つの変更が必要だった:

1. **`tty` モジュール新規実装** — ✅ PR #57 で対応済み
2. **`http.METHODS` 追加** — ✅ PR #56 で対応済み
3. **`Error.captureStackTrace` ポリフィル** — `depd` パッケージが V8 の `Error.captureStackTrace`/`Error.prepareStackTrace` に依存。JSC スタックトレース文字列をパースして V8 互換 call site オブジェクトを返すポリフィルが必要
4. **EventEmitter 遅延初期化** — Express は `mixin()` で EventEmitter メソッドだけをコピーするため、コンストラクタが呼ばれず `this._events` が未初期化。各メソッドに `_initEvents()` 遅延初期化を追加

残課題:
- `console.log` によるサーバー起動メッセージが表示されない（イベントループのタイミング問題の可能性）
- ミドルウェア（body-parser、serve-static 等）の動作は未検証

### 狙いたいライブラリ一覧

| 優先度 | ライブラリ | 状態 |
|---|---|---|
| ★★★ | **Hono** | ✅ コアルーティング動作確認済み |
| ★★★ | **Express.js** | 基本ルーティング動作確認済み（残: captureStackTrace, EventEmitter遅延初期化） |
| ★★☆ | **receiptline** | ✅ v4.0.0 全機能動作確認済み（SVG/テキスト/ESC/POS/StarPRNT/QRコード/ストリーム） |
| ★★☆ | **dotenv** | ✅ v17.3.1 動作確認済み（`require('dotenv').config()` で `.env` 読み込み・`process.env` 注入） |
| ★★☆ | **Commander.js / yargs** | ✅ Commander.js v14.0.3 動作確認済み（child_process, fs.realpathSync, process拡張で対応） |
| ★★☆ | **zx** | `readline`, `util.promisify` が不足。詳細は下記 |
| ★★☆ | **ws** | WebSocket ライブラリ。`https`/`tls` が前提 |
| ★☆☆ | **Prettier / ESLint** | 依存が大きい |
| ★☆☆ | **TypeScript (tsc)** | コンパイラ自体が Pure JS。動けばインパクト大だがかなり巨大 |

### zx v8.8.5 対応に必要な変更

zx のロード時に以下の順でエラーが発生する:

1. **`tty` モジュール** — ✅ 実装済み
2. **`readline` モジュール** — `createInterface()`, `rl.question()`, `rl.close()` が必要（zx の `question()` 関数）
3. **`util.promisify`** — `util.promisify(child_process.execFile)` で使用。Node.js スタイルのコールバック関数を Promise 化する汎用関数

### 段階的な攻略プラン

```
Step 1: dotenv, Commander.js など小さいものを動かす ✅ dotenv, Commander.js 達成
Step 2: Hono を動かす ✅ 達成
Step 3: Express を動かす（キラー実績）
```

---

### 未実装モジュール一覧

#### 優先度：高（よく使われる・依存されやすい）

| モジュール | 概要 |
|---|---|
| **https** | HTTPS サーバー/クライアント。`http` が実装済みなので拡張しやすい |
| **readline** | 対話的な行入力インターフェース |
| **dns** | DNS名前解決（`dns.lookup`, `dns.resolve`） |
| **tls** | TLS/SSL ソケット。`https` の基盤 |
| **worker_threads** | マルチスレッド処理 |
| **timers/promises** | `setTimeout`, `setInterval` の Promise 版 |
| **module** | `module.createRequire()` など、モジュールシステムのメタAPI |

#### 優先度：中（特定用途で必要）

| モジュール | 概要 |
|---|---|
| **dgram** | UDP ソケット |
| **tty** | ✅ 実装済み。`isatty()`, `ReadStream`, `WriteStream` |
| **vm** | 仮想コンテキストでのコード実行（JSCでは `JSContext` ベースの代替実装が必要） |
| **perf_hooks** | パフォーマンス計測API（`performance.now()` など） |
| **cluster** | マルチプロセスクラスタリング |

#### 優先度：低（特殊用途・非推奨含む）

| モジュール | 概要 |
|---|---|
| **diagnostics_channel** | 診断データのパブリッシュ/サブスクライブ |
| **trace_events** | トレースイベント |
| **repl** | 対話型REPL |
| **punycode** | 国際化ドメイン名変換（非推奨） |
| **domain** | エラーハンドリングドメイン（非推奨） |
