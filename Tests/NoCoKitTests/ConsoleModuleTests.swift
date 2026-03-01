import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Console Module Tests

@Test func consoleLog() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.log('hello', 'world')")
    #expect(messages.count >= 1)
    #expect(messages.first?.0 == .log)
    #expect(messages.first?.1 == "hello world")
}

@Test func consoleWarnError() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.warn('warning'); console.error('error')")
    #expect(messages.contains(where: { $0.0 == .warn && $0.1 == "warning" }))
    #expect(messages.contains(where: { $0.0 == .error && $0.1 == "error" }))
}

@Test func consoleFormattingTypes() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        console.log(42);
        console.log(true);
        console.log(null);
        console.log(undefined);
        console.log([1,2,3]);
    """)

    #expect(messages.count == 5)
    #expect(messages[0] == "42")
    #expect(messages[1] == "true")
    #expect(messages[2] == "null")
    #expect(messages[3] == "undefined")
    #expect(messages[4] == "[1,2,3]")
}

// MARK: - Console Module Edge Cases

@Test func consoleInfo() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.info('info message')")
    #expect(messages.contains(where: { $0.0 == .info && $0.1 == "info message" }))
}

@Test func consoleDebug() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.debug('debug message')")
    #expect(messages.contains(where: { $0.0 == .debug && $0.1 == "debug message" }))
}

@Test func consoleTime() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.time('myTimer')")
    try await Task.sleep(nanoseconds: 10_000_000)
    runtime.evaluate("console.timeEnd('myTimer')")
    #expect(messages.contains(where: { $0.0 == .log && $0.1.hasPrefix("myTimer:") && $0.1.hasSuffix("ms") }))
}

@Test func consoleAssertFail() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.assert(false, 'assertion msg')")
    #expect(messages.contains(where: { $0.0 == .error && $0.1.contains("Assertion failed") && $0.1.contains("assertion msg") }))
}

@Test func consoleAssertPass() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.assert(true, 'should not appear')")
    #expect(messages.isEmpty)
}

@Test func consoleDir() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        messages.append((level, msg))
    }
    runtime.evaluate("console.dir({a: 1})")
    #expect(messages.count >= 1)
    #expect(messages.first?.0 == .log)
    #expect(messages.first?.1.contains("a") == true)
}

// MARK: - Console Output Redirection

@Test func consoleHandlerCapturesAllOutput() async throws {
    let runtime = NodeRuntime()
    var captured: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in
        captured.append((level, msg))
    }

    runtime.evaluate("""
        console.log('log msg');
        console.info('info msg');
        console.warn('warn msg');
        console.error('error msg');
        console.debug('debug msg');
        console.dir({key: 'value'});
        console.assert(false, 'assert msg');
    """)

    #expect(captured.count == 7)
    #expect(captured[0] == (.log, "log msg"))
    #expect(captured[1] == (.info, "info msg"))
    #expect(captured[2] == (.warn, "warn msg"))
    #expect(captured[3] == (.error, "error msg"))
    #expect(captured[4] == (.debug, "debug msg"))
    #expect(captured[5].0 == .log)
    #expect(captured[5].1.contains("key"))
    #expect(captured[6] == (.error, "Assertion failed: assert msg"))
}

@Test func consoleHandlerReplaceable() async throws {
    let runtime = NodeRuntime()

    var first: [String] = []
    runtime.consoleHandler = { _, msg in first.append(msg) }
    runtime.evaluate("console.log('first')")

    var second: [String] = []
    runtime.consoleHandler = { _, msg in second.append(msg) }
    runtime.evaluate("console.log('second')")

    #expect(first == ["first"])
    #expect(second == ["second"])
}

@Test func consoleTimeEndCaptured() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("console.time('t')")
    runtime.evaluate("console.timeEnd('t')")

    #expect(messages.count == 1)
    #expect(messages[0].hasPrefix("t:"))
    #expect(messages[0].hasSuffix("ms"))
}

@Test func consoleMultipleArgsConcatenated() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("console.log('a', 'b', 'c')")
    runtime.evaluate("console.warn(1, 2, 3)")

    #expect(messages[0] == "a b c")
    #expect(messages[1] == "1 2 3")
}
