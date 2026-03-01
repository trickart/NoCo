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
