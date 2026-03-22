# Vitest on NoCo 互換性テストレポート

**テスト日**: 2026-03-20（最終更新: 2026-03-22）
**Vitest バージョン**: v4.1.0
**NoCo ブランチ**: main

## 現在の到達状況

vitest の **テスト実行が完全に動作**。3/3 テストがパスし、結果がレポーターに正常表示され、**警告なしで正常終了**する。

```
 RUN  v4.1.0 /Users/trick/NoCo

 Test Files  1 passed (1)
      Tests  3 passed (3)
   Duration  931ms
```

## 詳細な検証結果

### `--pool=threads` の場合

- `worker_threads` モジュールが `env`, `stdout`, `stderr`, `execArgv` オプションに対応済み
- Worker の console 出力を親の PassThrough ストリーム経由で転送
- Worker exit 時に stdout/stderr ストリームを自動 end
- Worker のファイルロードが `require()` 経由になり ESM 変換が適用される
- Worker の起動・メッセージ通信・終了は正常に動作
- テスト自体は実行されるが、vitest の `@vitest/runner` がコレクションフェーズ（`onQueued`/`onCollected`）を発火しないため、レポーターに結果が表示されない
- 原因: vitest の `NativeModuleRunner` がテストファイルをインポートする際に `@vitest/runner` 内部のコレクション処理が正しく動作していない（`node:vm` / `node:async_hooks` / モジュールフック等の互換性問題の可能性）

## 残りの課題と対応優先度

1. **`--pool=threads` のレポーター問題** — vitest の NativeModuleRunner 内でテストコレクションが発火しない。`@vitest/runner` の `onCollectStart`/`onCollected` コールバック呼び出しに至るまでの実行パスの調査が必要。
