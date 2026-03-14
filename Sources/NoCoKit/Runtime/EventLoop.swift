import Foundation
import JavaScriptCore
import Synchronization

/// Manages the event loop: timers, nextTick queue, and microtask processing.
public final class EventLoop: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timers: [Int: TimerEntry] = [:]
    private var nextTimerId: Int = 1
    private var nextTickQueue: [JSValue] = []
    private let wakeup = DispatchSemaphore(value: 0)

    /// Thread-safe I/O state protected by Mutex.
    /// Accessed from both jsQueue and external queues (NIO, NWConnection, etc.).
    private struct IOState: Sendable {
        var pendingCallbacks: [@Sendable () -> Void] = []
        var activeHandles: Int = 0
        var running: Bool = false
    }
    private let ioState = Mutex(IOState())

    /// Called after each callback execution to check/clear uncaught JS exceptions.
    var onUncaughtException: (() -> Void)?

    /// Called after draining callbacks/timers to flush JSC's internal microtask queue.
    var drainMicrotasks: (() -> Void)?

    struct TimerEntry {
        let id: Int
        let callback: JSValue
        let delay: Double
        let repeats: Bool
        let fireTime: Date
    }

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
        wakeup.signal()
    }

    /// Drain the pending callbacks queue.
    func drainCallbacks() {
        let cbs = ioState.withLock { s in
            let cbs = s.pendingCallbacks
            s.pendingCallbacks.removeAll()
            return cbs
        }
        for cb in cbs {
            cb()
            onUncaughtException?()
        }
        if !cbs.isEmpty {
            drainMicrotasks?()
        }
    }

    /// Increment active I/O handle count. Thread-safe.
    func retainHandle() {
        ioState.withLock { $0.activeHandles += 1 }
    }

    /// Decrement active I/O handle count. Thread-safe.
    func releaseHandle() {
        ioState.withLock { $0.activeHandles -= 1 }
    }

    /// Check if there's pending work.
    var hasPendingWork: Bool {
        let (hasCallbacks, handles) = ioState.withLock { ($0.pendingCallbacks.isEmpty == false, $0.activeHandles) }
        return !timers.isEmpty || !nextTickQueue.isEmpty || hasCallbacks || handles > 0
    }

    /// Run the event loop until no pending work or timeout.
    func run(timeout: TimeInterval = 30) {
        ioState.withLock { $0.running = true }
        let deadline = timeout.isInfinite ? Date.distantFuture : Date().addingTimeInterval(timeout)

        while ioState.withLock({ $0.running }) && hasPendingWork && Date() < deadline {
            drainNextTick()
            drainCallbacks()

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
                            repeats: true, fireTime: now.addingTimeInterval(delaySeconds)
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

            let callbacksEmpty = ioState.withLock { $0.pendingCallbacks.isEmpty }
            if !firedAny && nextTickQueue.isEmpty && callbacksEmpty {
                // Wait until signaled, next timer fires, or run deadline expires
                let remaining = max(deadline.timeIntervalSinceNow, 0)
                let nextFire = timers.values.map(\.fireTime).min()
                let waitInterval: TimeInterval
                if let next = nextFire {
                    waitInterval = min(max(next.timeIntervalSinceNow, 0), remaining)
                } else {
                    waitInterval = min(0.1, remaining)
                }
                _ = wakeup.wait(timeout: .now() + waitInterval)
            }
        }
        ioState.withLock { $0.running = false }
    }

    /// Stop the event loop.
    func stop() {
        ioState.withLock { $0.running = false }
        wakeup.signal()
    }

    /// Cancel all timers and clear queues.
    func reset() {
        timers.removeAll()
        nextTickQueue.removeAll()
        ioState.withLock { s in
            s.pendingCallbacks.removeAll()
            s.activeHandles = 0
            s.running = false
        }
    }
}
