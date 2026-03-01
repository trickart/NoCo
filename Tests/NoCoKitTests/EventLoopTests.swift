import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Event Loop Tests

@Test func eventLoopReset() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("setTimeout(function() {}, 10000)")
    #expect(runtime.eventLoop.hasPendingWork == true)
    runtime.eventLoop.reset()
    #expect(runtime.eventLoop.hasPendingWork == false)
}

@Test func eventLoopStop() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        setTimeout(function() { console.log('first'); }, 10);
        setTimeout(function() { console.log('second'); }, 5000);
    """)
    // Run briefly then stop
    runtime.eventLoop.stop()
    runtime.runEventLoop(timeout: 0.1)

    // The loop should have stopped quickly; 'second' should not fire
    #expect(!messages.contains("second"))
}

@Test func nextTickOrder() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        setTimeout(function() { console.log('timeout'); }, 0);
        process.nextTick(function() { console.log('nextTick'); });
    """)
    runtime.runEventLoop(timeout: 1)

    // nextTick should appear before timeout
    let tickIndex = messages.firstIndex(of: "nextTick")
    let timeoutIndex = messages.firstIndex(of: "timeout")
    #expect(tickIndex != nil)
    #expect(timeoutIndex != nil)
    if let t = tickIndex, let to = timeoutIndex {
        #expect(t < to)
    }
}

@Test func nextTickMultiple() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        process.nextTick(function() { console.log('a'); });
        process.nextTick(function() { console.log('b'); });
        process.nextTick(function() { console.log('c'); });
    """)
    runtime.runEventLoop(timeout: 1)

    let filtered = messages.filter { ["a", "b", "c"].contains($0) }
    #expect(filtered == ["a", "b", "c"])
}

@Test func enqueueCallbackWakesUpImmediately() async throws {
    let runtime = NodeRuntime()
    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // コールバック往復でイベントループが確実に起動済みであることを確認
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        runtime.eventLoop.enqueueCallback {
            continuation.resume()
        }
    }
    // ループがアイドル待機に戻る時間を確保
    try await Task.sleep(for: .milliseconds(10))

    let enqueueTime = DispatchTime.now().uptimeNanoseconds
    let callbackTime: UInt64 = await withCheckedContinuation { continuation in
        runtime.eventLoop.enqueueCallback {
            let time = DispatchTime.now().uptimeNanoseconds
            runtime.eventLoop.releaseHandle()
            continuation.resume(returning: time)
        }
    }

    let elapsedMs = Double(callbackTime - enqueueTime) / 1_000_000
    #expect(elapsedMs < 50, "enqueueCallback should wake up the loop immediately, but took \(elapsedMs)ms")

    await loopDone
}

@Test func stopWakesUpImmediately() async throws {
    let runtime = NodeRuntime()
    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // コールバック往復でイベントループが確実に起動済みであることを確認
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        runtime.eventLoop.enqueueCallback {
            continuation.resume()
        }
    }
    // ループがアイドル待機に戻る時間を確保
    try await Task.sleep(for: .milliseconds(10))

    let stopTime = DispatchTime.now().uptimeNanoseconds
    runtime.eventLoop.stop()

    await loopDone
    let doneTime = DispatchTime.now().uptimeNanoseconds

    let elapsedMs = Double(doneTime - stopTime) / 1_000_000
    #expect(elapsedMs < 50, "stop() should wake up the loop immediately, but took \(elapsedMs)ms")
}

@Test func multipleEnqueueCallbacksProcessedInOrder() async throws {
    let runtime = NodeRuntime()
    nonisolated(unsafe) var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.eventLoop.retainHandle()

    async let loopDone: Void = withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: 5)
            continuation.resume()
        }
    }

    // コールバック往復でイベントループが確実に起動済みであることを確認
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        runtime.eventLoop.enqueueCallback {
            continuation.resume()
        }
    }
    // ループがアイドル待機に戻る時間を確保
    try await Task.sleep(for: .milliseconds(10))

    for i in 0..<10 {
        runtime.eventLoop.enqueueCallback {
            runtime.context.evaluateScript("console.log('callback-\(i)')")
        }
    }

    // 最後のコールバックでループを終了させる
    runtime.eventLoop.enqueueCallback {
        runtime.eventLoop.releaseHandle()
    }

    await loopDone

    let expected = (0..<10).map { "callback-\($0)" }
    #expect(messages == expected)
}
