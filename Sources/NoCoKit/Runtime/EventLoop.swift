import Foundation
import JavaScriptCore

/// Manages the event loop: timers, nextTick queue, and microtask processing.
public final class EventLoop: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timers: [Int: TimerEntry] = [:]
    private var nextTimerId: Int = 1
    private var nextTickQueue: [JSValue] = []
    private var running = false
    /// Dedicated queue for thread-safe access to pendingCallbacks and _activeHandles.
    /// Separate from `queue` (jsQueue) to avoid deadlock when run() executes on jsQueue.
    private let ioLock = DispatchQueue(label: "com.nodecore.eventloop.io")
    private var pendingCallbacks: [() -> Void] = []
    /// Number of active I/O handles (e.g. TCP sockets) keeping the loop alive.
    private var _activeHandles: Int = 0

    /// Called after each callback execution to check/clear uncaught JS exceptions.
    var onUncaughtException: (() -> Void)?

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
            }
        }
    }

    /// Enqueue a callback from external sources (e.g. NWConnection).
    /// Thread-safe: can be called from any queue.
    func enqueueCallback(_ block: @escaping @Sendable () -> Void) {
        ioLock.async { [self] in
            pendingCallbacks.append(block)
        }
    }

    /// Drain the pending callbacks queue.
    func drainCallbacks() {
        var cbs: [() -> Void] = []
        ioLock.sync { [self] in
            cbs = pendingCallbacks
            pendingCallbacks.removeAll()
        }
        for cb in cbs {
            cb()
            onUncaughtException?()
        }
    }

    /// Increment active I/O handle count. Thread-safe.
    func retainHandle() {
        ioLock.sync { [self] in _activeHandles += 1 }
    }

    /// Decrement active I/O handle count. Thread-safe.
    func releaseHandle() {
        ioLock.sync { [self] in _activeHandles -= 1 }
    }

    /// Check if there's pending work.
    var hasPendingWork: Bool {
        var hasCallbacks = false
        var handles = 0
        ioLock.sync { [self] in
            hasCallbacks = !pendingCallbacks.isEmpty
            handles = _activeHandles
        }
        return !timers.isEmpty || !nextTickQueue.isEmpty || hasCallbacks || handles > 0
    }

    /// Run the event loop until no pending work or timeout.
    func run(timeout: TimeInterval = 30) {
        running = true
        let deadline = timeout.isInfinite ? Date.distantFuture : Date().addingTimeInterval(timeout)

        while running && hasPendingWork && Date() < deadline {
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
                }
            }

            let callbacksEmpty = ioLock.sync { [self] in pendingCallbacks.isEmpty }
            if !firedAny && nextTickQueue.isEmpty && callbacksEmpty {
                // Sleep briefly to avoid busy-waiting
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        running = false
    }

    /// Stop the event loop.
    func stop() {
        running = false
    }

    /// Cancel all timers and clear queues.
    func reset() {
        timers.removeAll()
        nextTickQueue.removeAll()
        pendingCallbacks.removeAll()
        ioLock.sync { [self] in _activeHandles = 0 }
        running = false
    }
}
