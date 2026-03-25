import Foundation
import JavaScriptCore
import Synchronization

/// Manages the event loop: timers, nextTick queue, and microtask processing.
/// Idle wait に CFRunLoop を使用し、JSC の DeferredWorkTimer（WebAssembly async 等）を処理可能にする。
public final class EventLoop: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timers: [Int: TimerEntry] = [:]
    private var nextTimerId: Int = 1
    private var nextTickQueue: [JSValue] = []

    /// Thread-safe I/O state protected by Mutex.
    /// Accessed from both jsQueue and external queues (NIO, NWConnection, etc.).
    private struct IOState: Sendable {
        var pendingCallbacks: [@Sendable () -> Void] = []
        var activeHandles: Int = 0
        var running: Bool = false
        /// process.exit() など明示的な停止が呼ばれた場合 true。
        /// run() 開始時に false にリセットしない。beforeExit の抑制に使用。
        var explicitlyStopped: Bool = false
    }
    private let ioState = Mutex(IOState())

    /// CFRunLoop wakeup state. Protected by Mutex for thread-safe signal from external queues.
    /// CFRunLoop/CFRunLoopSource are thread-safe (Core Foundation objects) but not marked Sendable.
    private struct RunLoopState: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var source: CFRunLoopSource?
    }
    private let runLoopState = Mutex(RunLoopState())

    /// Called after each callback execution to check/clear uncaught JS exceptions.
    var onUncaughtException: (() -> Void)?

    /// Called after draining callbacks/timers to flush JSC's internal microtask queue.
    var drainMicrotasks: (() -> Void)?

    /// Called when the event loop is about to exit (hasPendingWork == false).
    /// Returns true if new work was scheduled (loop should continue).
    var onBeforeExit: (() -> Bool)?

    /// Tracks whether retainHandle() was ever called during this EventLoop's lifetime.
    /// Used to apply a grace period only for programs that use NAPI async work.
    private let hasHadActiveHandles = Mutex(false)

    struct TimerEntry {
        let id: Int
        let callback: JSValue
        let delay: Double
        let repeats: Bool
        let fireTime: Date
        var isRef: Bool = true
    }

    struct ImmediateEntry {
        let id: Int
        let callback: JSValue
    }

    private var immediateQueue: [ImmediateEntry] = []
    private var nextImmediateId: Int = 1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Schedule a timer. Returns the timer ID.
    func scheduleTimer(
        callback: JSValue,
        delay: Double,
        repeats: Bool,
        context: JSContext
    ) -> Int {
        let id = nextTimerId
        nextTimerId += 1

        let delaySeconds = max(delay, 1) / 1000.0
        let entry = TimerEntry(
            id: id, callback: callback, delay: delay,
            repeats: repeats, fireTime: Date().addingTimeInterval(delaySeconds)
        )
        timers[id] = entry
        return id
    }

    /// Clear a timer by ID.
    func clearTimer(id: Int) {
        timers.removeValue(forKey: id)
    }

    /// Set timer ref/unref state.
    func setTimerRef(id: Int, ref: Bool) {
        timers[id]?.isRef = ref
    }

    /// Schedule an immediate callback. Returns the immediate ID.
    func scheduleImmediate(callback: JSValue) -> Int {
        let id = nextImmediateId
        nextImmediateId += 1
        immediateQueue.append(ImmediateEntry(id: id, callback: callback))
        wakeRunLoop()
        return id
    }

    /// Clear an immediate by ID.
    func clearImmediate(id: Int) {
        immediateQueue.removeAll { $0.id == id }
    }

    /// Queue a nextTick callback.
    func enqueueNextTick(_ callback: JSValue) {
        nextTickQueue.append(callback)
    }

    /// Drain the nextTick queue.
    func drainNextTick() {
        while !nextTickQueue.isEmpty {
            let callbacks = nextTickQueue
            nextTickQueue.removeAll()
            for cb in callbacks {
                cb.call(withArguments: [])
                onUncaughtException?()
            }
        }
    }

    /// Enqueue a callback from external sources (e.g. NWConnection).
    /// Thread-safe: can be called from any queue.
    func enqueueCallback(_ block: @escaping @Sendable () -> Void) {
        ioState.withLock { $0.pendingCallbacks.append(block) }
        wakeRunLoop()
    }

    /// Drain ONE pending callback (matching Node.js semantics where each I/O
    /// callback gets its own tick). Returns true if a callback was processed.
    @discardableResult
    func drainOneCallback() -> Bool {
        let cb = ioState.withLock { s -> (() -> Void)? in
            if s.pendingCallbacks.isEmpty { return nil }
            return s.pendingCallbacks.removeFirst()
        }
        guard let cb else { return false }
        cb()
        onUncaughtException?()
        drainMicrotasks?()
        return true
    }

    /// Drain all pending callbacks.
    func drainCallbacks() {
        while drainOneCallback() {}
    }

    /// Increment active I/O handle count. Thread-safe.
    func retainHandle() {
        ioState.withLock { $0.activeHandles += 1 }
        hasHadActiveHandles.withLock { $0 = true }
        wakeRunLoop()
    }

    /// Decrement active I/O handle count. Thread-safe.
    func releaseHandle() {
        ioState.withLock { $0.activeHandles -= 1 }
    }

    /// Check if there's pending work.
    var hasPendingWork: Bool {
        let (hasCallbacks, handles) = ioState.withLock { ($0.pendingCallbacks.isEmpty == false, $0.activeHandles) }
        let hasRefTimers = timers.values.contains { $0.isRef }
        return hasRefTimers || !nextTickQueue.isEmpty || hasCallbacks || handles > 0 || !immediateQueue.isEmpty
    }

    // MARK: - RunLoop wakeup

    /// Wake up the RunLoop from any thread. Thread-safe.
    private func wakeRunLoop() {
        runLoopState.withLock { state in
            if let source = state.source, let rl = state.runLoop {
                CFRunLoopSourceSignal(source)
                CFRunLoopWakeUp(rl)
            }
        }
    }

    /// Run the event loop until no pending work or timeout.
    func run(timeout: TimeInterval = 30) {
        ioState.withLock { $0.running = true }
        let deadline = timeout.isInfinite ? Date.distantFuture : Date().addingTimeInterval(timeout)

        // CFRunLoop セットアップ: 現在のスレッドの RunLoop を使用
        // JSC の DeferredWorkTimer (WebAssembly async 等) はこの RunLoop で fire する
        let rl = CFRunLoopGetCurrent()
        var sourceContext = CFRunLoopSourceContext()
        sourceContext.version = 0
        sourceContext.perform = { _ in
            // No-op: signal + wakeup でループを起こすだけ
        }
        let source = CFRunLoopSourceCreate(nil, 0, &sourceContext)!
        CFRunLoopAddSource(rl, source, .defaultMode)
        runLoopState.withLock { state in
            state.runLoop = rl
            state.source = source
        }

        defer {
            CFRunLoopRemoveSource(rl, source, .defaultMode)
            runLoopState.withLock { state in
                state.runLoop = nil
                state.source = nil
            }
        }

        // ループ前に microtask をドレインして fire-and-forget な Promise chain を処理
        // これにより chain 内で登録された timer/handle が hasPendingWork に反映される
        drainMicrotasks?()
        drainNextTick()

        while ioState.withLock({ $0.running }) && Date() < deadline {
            drainNextTick()
            // Process one callback per tick (Node.js delivers one I/O callback per tick)
            if drainOneCallback() {
                drainNextTick()
            }

            // Check for timers that should fire
            let now = Date()
            var firedAny = false
            for (id, entry) in timers {
                if now >= entry.fireTime {
                    firedAny = true
                    if entry.repeats {
                        let delaySeconds = max(entry.delay, 1) / 1000.0
                        timers[id] = TimerEntry(
                            id: id, callback: entry.callback, delay: entry.delay,
                            repeats: true, fireTime: now.addingTimeInterval(delaySeconds),
                            isRef: entry.isRef
                        )
                    } else {
                        timers.removeValue(forKey: id)
                    }
                    entry.callback.call(withArguments: [])
                    onUncaughtException?()
                }
            }
            if firedAny {
                drainMicrotasks?()
            }

            // Immediate phase (check phase): run after timers, before idle wait
            if !immediateQueue.isEmpty {
                let immediates = immediateQueue
                immediateQueue.removeAll()
                for entry in immediates {
                    entry.callback.call(withArguments: [])
                    onUncaughtException?()
                }
                drainMicrotasks?()
            }

            // 終了判定: 全フェーズ処理後に最終ドレイン
            if !hasPendingWork {
                drainMicrotasks?()
                drainNextTick()
                drainCallbacks()
                if !hasPendingWork {
                    // beforeExit イベントを fire（Node.js 互換）
                    // process.exit() による明示的終了では fire しない
                    let explicitStop = ioState.withLock { $0.explicitlyStopped }
                    if !explicitStop {
                        let scheduled = onBeforeExit?() ?? false
                        if scheduled || hasPendingWork { continue }
                    }

                    // Grace period: handle が使われたことがある場合、
                    // バックグラウンドスレッドからの callback を段階的に待つ。
                    // 非同期操作間の隙間（handle 解放後〜次の retain まで）を埋める。
                    if hasHadActiveHandles.withLock({ $0 }) {
                        var recovered = false
                        // 非同期操作間の隙間を埋める grace period。
                        // バックグラウンドスレッドからの callback を段階的に待つ:
                        // 10ms × 5 + 50ms × 5 + 100ms × 5 = 最大 800ms
                        let intervals: [TimeInterval] = [
                            0.01, 0.01, 0.01, 0.01, 0.01,
                            0.05, 0.05, 0.05, 0.05, 0.05,
                            0.1,  0.1,  0.1,  0.1,  0.1,
                        ]
                        for wait in intervals {
                            CFRunLoopRunInMode(.defaultMode, wait, true)
                            drainMicrotasks?()
                            drainNextTick()
                            drainCallbacks()
                            if hasPendingWork {
                                recovered = true
                                break
                            }
                        }
                        if !recovered { break }
                    } else {
                        break
                    }
                }
            }

            let callbacksEmpty = ioState.withLock { $0.pendingCallbacks.isEmpty }
            if !firedAny && nextTickQueue.isEmpty && callbacksEmpty && immediateQueue.isEmpty {
                // Idle wait: CFRunLoop を回して JSC の DeferredWorkTimer 等を処理
                let remaining = max(deadline.timeIntervalSinceNow, 0)
                let nextFire = timers.values.map(\.fireTime).min()
                let waitInterval: TimeInterval
                if let next = nextFire {
                    waitInterval = min(max(next.timeIntervalSinceNow, 0), remaining)
                } else {
                    waitInterval = min(0.1, remaining)
                }
                CFRunLoopRunInMode(.defaultMode, waitInterval, true)
            }
        }
        ioState.withLock { $0.running = false }
    }

    /// Stop the event loop.
    func stop() {
        ioState.withLock {
            $0.running = false
            $0.explicitlyStopped = true
        }
        wakeRunLoop()
    }

    /// Cancel all timers and clear queues.
    func reset() {
        timers.removeAll()
        nextTickQueue.removeAll()
        immediateQueue.removeAll()
        ioState.withLock { s in
            s.pendingCallbacks.removeAll()
            s.activeHandles = 0
            s.running = false
            s.explicitlyStopped = false
        }
    }
}
