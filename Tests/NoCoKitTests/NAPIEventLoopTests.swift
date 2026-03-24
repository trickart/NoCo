import Testing
import JavaScriptCore
import Synchronization
@testable import NoCoKit

// MARK: - NAPI handle retention: イベントループがバックグラウンド作業完了まで存続する

@Test func retainHandleKeepsLoopAlive() async throws {
    // retainHandle() があればイベントループは hasPendingWork = true を返す
    let runtime = NodeRuntime()
    runtime.eventLoop.retainHandle()
    #expect(runtime.eventLoop.hasPendingWork == true)
    runtime.eventLoop.releaseHandle()
    #expect(runtime.eventLoop.hasPendingWork == false)
}

@Test func retainHandleMultiple() async throws {
    // 複数回 retainHandle → 同数の releaseHandle が必要
    let runtime = NodeRuntime()
    runtime.eventLoop.retainHandle()
    runtime.eventLoop.retainHandle()
    runtime.eventLoop.retainHandle()
    runtime.eventLoop.releaseHandle()
    #expect(runtime.eventLoop.hasPendingWork == true)
    runtime.eventLoop.releaseHandle()
    #expect(runtime.eventLoop.hasPendingWork == true)
    runtime.eventLoop.releaseHandle()
    #expect(runtime.eventLoop.hasPendingWork == false)
}

@Test func retainHandleKeepsLoopRunningForCallback() async throws {
    // retainHandle でループが生存し、enqueueCallback の結果を受け取れる
    let runtime = NodeRuntime()
    let messages = Mutex<[String]>([])
    runtime.consoleHandler = { _, msg in messages.withLock { $0.append(msg) } }

    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // 少し待ってからバックグラウンドスレッドでコールバックを投入
    try await Task.sleep(for: .milliseconds(50))
    runtime.eventLoop.enqueueCallback {
        runtime.context.evaluateScript("console.log('from-background')")
        runtime.eventLoop.releaseHandle()
    }

    await loopDone

    #expect(messages.withLock { $0 }.contains("from-background"))
}

@Test func asyncWorkPatternKeepsLoopAlive() async throws {
    // napi_queue_async_work のパターン: retainHandle → background work → enqueueCallback → releaseHandle
    let runtime = NodeRuntime()
    let messages = Mutex<[String]>([])
    runtime.consoleHandler = { _, msg in messages.withLock { $0.append(msg) } }

    // Simulate napi_queue_async_work pattern
    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // バックグラウンドスレッドでの作業をシミュレート
    DispatchQueue.global(qos: .userInitiated).async {
        // 重い処理のシミュレート
        Thread.sleep(forTimeInterval: 0.1)

        runtime.eventLoop.enqueueCallback {
            runtime.context.evaluateScript("console.log('async-work-done')")
            runtime.eventLoop.releaseHandle()
        }
    }

    await loopDone

    #expect(messages.withLock { $0 }.contains("async-work-done"))
}

@Test func tsfPatternKeepsLoopAlive() async throws {
    // napi_create_threadsafe_function のパターン:
    // retainHandle (TSF作成) → 複数回の enqueueCallback → releaseHandle (TSF解放)
    let runtime = NodeRuntime()
    let messages = Mutex<[String]>([])
    runtime.consoleHandler = { _, msg in messages.withLock { $0.append(msg) } }

    // TSF 作成: retainHandle
    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // 複数回のバックグラウンドからのコールバック
    for i in 0..<3 {
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.05 + 0.05) {
            runtime.eventLoop.enqueueCallback {
                runtime.context.evaluateScript("console.log('tsf-call-\(i)')")
            }
        }
    }

    // TSF 解放: releaseHandle
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
        runtime.eventLoop.enqueueCallback {
            runtime.eventLoop.releaseHandle()
        }
    }

    await loopDone

    let msgs = messages.withLock { $0 }
    #expect(msgs.contains("tsf-call-0"))
    #expect(msgs.contains("tsf-call-1"))
    #expect(msgs.contains("tsf-call-2"))
}

// MARK: - NAPI Buffer: napi_create_external_buffer シンボルエクスポート

@Test func napiCreateExternalBufferSymbolExists() async throws {
    // napi_create_external_buffer が実行バイナリからエクスポートされていることを確認
    // NAPI ネイティブアドオン（rollup 等）がこのシンボルを dlsym で解決する
    let handle = dlopen(nil, RTLD_NOW)
    defer { if let handle { dlclose(handle) } }
    let sym = dlsym(handle, "napi_create_external_buffer")
    #expect(sym != nil, "napi_create_external_buffer should be exported from the binary")
}

// MARK: - NAPI Promise + async chain: microtask drain 回避

@Test func napiPromiseResolvedViaCallback() async throws {
    // NAPI deferred promise パターン: Promise を作り、バックグラウンドから resolve
    let runtime = NodeRuntime()
    let messages = Mutex<[String]>([])
    runtime.consoleHandler = { _, msg in messages.withLock { $0.append(msg) } }

    // JS 側で deferred pattern を作成し、resolve 関数を global に保存
    runtime.evaluate("""
        var _resolve;
        var p = new Promise(function(resolve) { _resolve = resolve; });
        p.then(function(v) { console.log('resolved:' + v); });
    """)

    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // バックグラウンドから resolve を呼ぶ（NAPI の napi_resolve_deferred と同等）
    try await Task.sleep(for: .milliseconds(50))
    runtime.eventLoop.enqueueCallback {
        runtime.context.evaluateScript("_resolve('hello')")
        runtime.eventLoop.releaseHandle()
    }

    await loopDone

    #expect(messages.withLock { $0 }.contains("resolved:hello"))
}

@Test func asyncAwaitChainWithDeferredPromise() async throws {
    // async function が deferred promise を await し、
    // バックグラウンドからの resolve 後に chain が継続する
    let runtime = NodeRuntime()
    let messages = Mutex<[String]>([])
    runtime.consoleHandler = { _, msg in messages.withLock { $0.append(msg) } }

    runtime.evaluate("""
        var _resolve;
        (async function() {
            console.log('before-await');
            var result = await new Promise(function(resolve) { _resolve = resolve; });
            console.log('after-await:' + result);
            // chain 継続: さらに await
            await Promise.resolve();
            console.log('chain-continued');
        })();
    """)

    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    try await Task.sleep(for: .milliseconds(50))
    runtime.eventLoop.enqueueCallback {
        runtime.context.evaluateScript("_resolve('data')")
        runtime.eventLoop.releaseHandle()
    }

    await loopDone

    let msgs = messages.withLock { $0 }
    #expect(msgs.contains("before-await"))
    #expect(msgs.contains("after-await:data"))
    #expect(msgs.contains("chain-continued"))
}

// MARK: - Fire-and-forget async chain without keepalive

@Test func fireAndForgetAsyncChainProgresses() async throws {
    // parse() → start() パターン: fire-and-forget の async chain が
    // イベントループの drainMicrotasks() で進行する
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        async function inner() {
            await Promise.resolve(1);
            console.log('inner-done');
            return 42;
        }
        async function middle() {
            var result = await inner();
            console.log('middle-done:' + result);
            return result;
        }
        async function outer() {
            var result = await middle();
            console.log('outer-done:' + result);
            // chain 内で timer を登録
            setTimeout(function() { console.log('timer-from-chain'); }, 10);
        }
        // fire-and-forget
        outer();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("inner-done"))
    #expect(messages.contains("middle-done:42"))
    #expect(messages.contains("outer-done:42"))
    #expect(messages.contains("timer-from-chain"))
}

@Test func fireAndForgetWithDynamicImport() async throws {
    // fire-and-forget async chain 内の dynamic import (via __importDynamic) が正常に解決する
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        (async function() {
            var path = await __importDynamic('path', '/');
            console.log('path-imported:' + typeof path.join);
            var fs = await __importDynamic('fs', '/');
            console.log('fs-imported:' + typeof fs.readFileSync);
            setTimeout(function() { console.log('all-done'); }, 10);
        })();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("path-imported:function"))
    #expect(messages.contains("fs-imported:function"))
    #expect(messages.contains("all-done"))
}

// MARK: - Microtask drain does not exit loop prematurely

@Test func microtaskDrainAfterCallbackKeepsLoopAlive() async throws {
    // コールバック → microtask drain → 新しい仕事の登録 がループを維持する
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        setTimeout(function() {
            // タイマーコールバック内で Promise chain を開始
            Promise.resolve().then(function() {
                console.log('microtask-1');
                // microtask 内で新しいタイマーを登録
                setTimeout(function() {
                    console.log('timer-from-microtask');
                }, 10);
            });
        }, 10);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("microtask-1"))
    #expect(messages.contains("timer-from-microtask"))
}

@Test func promiseThenChainInCallbackFullyDrains() async throws {
    // タイマーコールバック後の microtask drain で .then chain が完全に処理される
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        setTimeout(function() {
            Promise.resolve('a')
                .then(function(v) { console.log(v); return 'b'; })
                .then(function(v) { console.log(v); return 'c'; })
                .then(function(v) { console.log(v); return 'd'; })
                .then(function(v) {
                    console.log(v);
                    setTimeout(function() { console.log('end'); }, 10);
                });
        }, 10);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages == ["a", "b", "c", "d", "end"])
}

// MARK: - ESM evaluateScript cache: wrapNamespace と importDynamic のキャッシュ

@Test func dynamicImportDoesNotDrainPendingMicrotasks() async throws {
    // __importDynamic が既存の pending microtask を不意にドレインしないことを確認
    // (Promise ファクトリがキャッシュされている)
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var canary = false;
        Promise.resolve().then(function() { canary = true; });

        // この時点で canary microtask は pending
        // dynamic import が canary を勝手に drain してはいけない
        // (import 自体は同期的に解決する)
        var importPromise = import('path');

        // canary はまだ false のはず（同じ evaluateScript 内）
        console.log('canary-before-drain:' + canary);
    """)

    // イベントループで drain すると canary が true になる
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("canary-before-drain:false"))
}

@Test func wrapNamespaceCachedAcrossImports() async throws {
    // 複数回の __importDynamic で wrapAsNamespace のファクトリがキャッシュされ再利用される
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        (async function() {
            var path = await __importDynamic('path', '/');
            var fs = await __importDynamic('fs', '/');
            var os = await __importDynamic('os', '/');
            console.log('imports-ok:' + [typeof path.join, typeof fs.readFileSync, typeof os.platform].join(','));
        })();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("imports-ok:function,function,function"))
}
