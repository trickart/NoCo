# Hono 未対応機能

## 動作しない機能 (FAIL)

| 機能 | 原因 | 備考 |
|---|---|---|
| **`hono/css`** | `document` 未実装 | DOM 操作が必要。サーバーサイド非対応 |
| **`WebSocket`** | 未実装 | `hono/websocket` ヘルパー。大きな機能追加が必要 |
| ~~**`conninfo`**~~ | ~~Hono 側が型定義のみ~~ | PASS — `req.socket.remoteAddress/remotePort/remoteFamily` を実接続情報から設定 |
| ~~**`cache`**~~ | ~~`globalThis.caches` (Cache API) 未実装~~ | PASS — インメモリ Cache API 実装済み (`wait: true` オプション推奨) |

## 動作確認済み機能 (PASS)

### 基本機能（既確認済み）
- 基本ルーティング, JSON/text/HTML, パラメータ, クエリ, POST, ヘッダー, ステータス, リダイレクト
- ミドルウェア, ルートグループ, エラーハンドリング, CORS, compress, serve-static

### ミドルウェア
| 機能 | テスト | 備考 |
|---|---|---|
| **powered-by** | PASS | X-Powered-By ヘッダー付与 |
| **pretty-json** | PASS | `?pretty` で JSON 整形出力 |
| **logger** | PASS | コンソールログ出力 |
| **request-id** | PASS | X-Request-Id UUID 付与 |
| **basic-auth** | PASS | Basic 認証（crypto.subtle.digest 使用） |
| **bearer-auth** | PASS | Bearer トークン認証 |
| **csrf** | PASS | Origin チェックによる CSRF 防護 |
| **secure-headers** | PASS | セキュリティヘッダー群（CSP, HSTS等） |
| **ip-restriction** | PASS | IP 許可/拒否リスト |
| **jwt** | PASS | JWT 生成（sign）・検証（verify）・ミドルウェア |
| **timing** | PASS | Server-Timing ヘッダー |
| **body-limit** | PASS | ボディサイズ制限（413 応答） |
| **method-override** | PASS | HTTP メソッドオーバーライド |
| **combine** | PASS | every/some/except |
| **timeout** | PASS | タイムアウト制御（408 応答） |
| **language** | PASS | Accept-Language 解析 |
| **trailing-slash** | PASS | URL プロパティセッター修正により動作 (#44) |
| **etag** | PASS | Response.body の Uint8Array 化により正しい SHA-1 ハッシュ生成 |
| **context-storage** | PASS | AsyncLocalStorage 経由のコンテキスト |
| **jwk** | PASS | JWK ベース JWT 認証（未認証時 401 応答） |

### ヘルパー
| 機能 | テスト | 備考 |
|---|---|---|
| **cookie** | PASS | Set-Cookie / Cookie 読み取り / 削除 |
| **html** | PASS | テンプレートリテラル + raw |
| **accepts** | PASS | Accept ヘッダー解析 |
| **validator** | PASS | リクエストバリデーション |
| **factory** | PASS | createFactory / createMiddleware |
| **http-exception** | PASS | HTTPException throw → カスタムエラー |
| **signed cookie** | PASS | setSignedCookie / getSignedCookie（HMAC 署名検証） |
| **adapter** | PASS | getRuntimeKey / env（環境変数取得） |
| **dev** | PASS | inspectRoutes / showRoutes / getRouterName |
| **route** | PASS | routePath / matchedRoutes |
| **hono/client (hc)** | PASS | Proxy ベース型安全クライアント（URL 生成・fetch 連携） |

### ストリーミング
| 機能 | テスト | 備考 |
|---|---|---|
| **stream()** | PASS | バイナリストリーム |
| **streamText()** | PASS | テキストストリーム |
| **streamSSE()** | PASS | Server-Sent Events |

### JSX
| 機能 | テスト | 備考 |
|---|---|---|
| **hono/jsx** | PASS | createElement による SSR |
| **jsx Fragment** | PASS | フラグメント |
| **jsx-renderer** | PASS | Layout + c.render() |
| **jsx/streaming** | PASS | Suspense + renderToReadableStream |

### プリセット・ユーティリティ
| 機能 | テスト | 備考 |
|---|---|---|
| **hono/tiny** | PASS | PatternRouter プリセット |
| **hono/quick** | PASS | SmartRouter プリセット |
| **testClient** | PASS | テスト用クライアント |
| **app.request()** | PASS | サーバーなしリクエスト |
| **ssg** | PASS | 静的サイト生成（fs/promises 使用） |
| **proxy** | PASS | モジュールロード確認（fetch ベース） |

### ルーター
| 機能 | テスト | 備考 |
|---|---|---|
| **RegExpRouter** | PASS | `hono/router/reg-exp-router` |
| **TrieRouter** | PASS | `hono/router/trie-router` |
| **LinearRouter** | PASS | `hono/router/linear-router` |
| **PatternRouter** | PASS | `hono/router/pattern-router` |
| **SmartRouter** | PASS | デフォルト（hono/quick プリセット） |
