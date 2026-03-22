# Vitest on NoCo 互換性テストレポート

**テスト日**: 2026-03-20（最終更新: 2026-03-22 PR #150〜#156 後）
**Vitest バージョン**: v4.1.0
**NoCo ブランチ**: main (PR #141〜#156 マージ済み)

## 現在の到達状況

vitest の **テスト実行が完全に動作**。3/3 テストがパスし、結果がレポーターに正常表示される。

```
 RUN  v4.1.0 /Users/trick/NoCo

 Test Files  1 passed (1)
      Tests  3 passed (3)
   Duration  935ms
```

終了時に `close timed out after 10000ms` 警告が出るが、プロセスは EXIT CODE: 0 で正常終了する。

## 詳細な検証結果

### 現在の軽微な問題: close timeout 警告

vitest 終了時に以下の警告が出る（テスト結果には影響なし、EXIT CODE: 0 で正常終了）:

```
close timed out after 10000ms
Tests closed successfully but something prevents Vite server from exiting
```

原因: vitest の forks pool close で `runner.stop()` が子プロセスに `stop` IPC メッセージを送り `stopped` 応答を待つが、子プロセスのイベントループが `enqueueCallback` を適時に処理できないケースがある。CFRunLoop の idle wait からの wakeup タイミングの問題。

### `--pool=threads` の場合

- `worker_threads` モジュールが `env`, `stdout`, `stderr`, `execArgv` オプションに対応済み
- Worker の console 出力を親の PassThrough ストリーム経由で転送
- Worker exit 時に stdout/stderr ストリームを自動 end
- Worker のファイルロードが `require()` 経由になり ESM 変換が適用される
- Worker の起動・メッセージ通信・終了は正常に動作
- テスト自体は実行されるが、vitest の `@vitest/runner` がコレクションフェーズ（`onQueued`/`onCollected`）を発火しないため、レポーターに結果が表示されない
- 原因: vitest の `NativeModuleRunner` がテストファイルをインポートする際に `@vitest/runner` 内部のコレクション処理が正しく動作していない（`node:vm` / `node:async_hooks` / モジュールフック等の互換性問題の可能性）

## 残りの課題と対応優先度

1. **close timeout 警告の解消** — 子プロセスのイベントループが `enqueueCallback` を適時に処理できない問題。CFRunLoop の wakeup メカニズムの調査が必要。
2. **`--pool=threads` のレポーター問題** — vitest の NativeModuleRunner 内でテストコレクションが発火しない。`@vitest/runner` の `onCollectStart`/`onCollected` コールバック呼び出しに至るまでの実行パスの調査が必要。
