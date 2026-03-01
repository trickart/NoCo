import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Timers Module Tests

@Test func setTimeoutBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("setTimeout(function() { console.log('fired'); }, 10)")
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("fired"))
}

@Test func clearTimeoutPreventsExecution() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var id = setTimeout(function() { console.log('should not fire'); }, 50);
        clearTimeout(id);
    """)
    runtime.runEventLoop(timeout: 0.2)

    #expect(!messages.contains("should not fire"))
}

@Test func setIntervalFires() async throws {
    let runtime = NodeRuntime()

    runtime.evaluate("""
        var count = 0;
        var id = setInterval(function() {
            count++;
            if (count >= 3) clearInterval(id);
        }, 10);
    """)
    runtime.runEventLoop(timeout: 1)

    let count = runtime.evaluate("count")?.toInt32()
    #expect(count != nil && count! >= 3)
}

// MARK: - Timers Module Additional Tests

@Test func setTimeoutWithArgs() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        setTimeout(function(a, b) { console.log(a + ':' + b); }, 10, 'hello', 'world');
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("hello:world"))
}

@Test func setTimeoutZeroDelay() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("setTimeout(function() { console.log('zero'); }, 0)")
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("zero"))
}

@Test func clearIntervalStops() async throws {
    let runtime = NodeRuntime()

    runtime.evaluate("""
        var count = 0;
        var id = setInterval(function() { count++; }, 10);
        setTimeout(function() { clearInterval(id); }, 50);
    """)
    runtime.runEventLoop(timeout: 1)

    let count = runtime.evaluate("count")?.toInt32() ?? 0
    // count should be limited (not running indefinitely)
    #expect(count > 0 && count < 100)
}

@Test func setTimeoutReturnsUniqueIds() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var id1 = setTimeout(function(){}, 1000);
        var id2 = setTimeout(function(){}, 1000);
        var id3 = setTimeout(function(){}, 1000);
        clearTimeout(id1); clearTimeout(id2); clearTimeout(id3);
        id1 !== id2 && id2 !== id3 && id1 !== id3;
    """)
    #expect(result?.toBool() == true)
}

@Test func timerModuleRequirable() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var timers = require('timers');
        typeof timers.setTimeout === 'function' &&
        typeof timers.setInterval === 'function' &&
        typeof timers.clearTimeout === 'function' &&
        typeof timers.clearInterval === 'function';
    """)
    #expect(result?.toBool() == true)
}
