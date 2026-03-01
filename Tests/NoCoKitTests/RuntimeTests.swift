import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Runtime Tests

@Test func evaluateReturnsValue() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("1 + 2")
    #expect(result?.toInt32() == 3)
}

@Test func evaluateString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("'hello' + ' ' + 'world'")
    #expect(result?.toString() == "hello world")
}

// MARK: - Runtime Edge Cases

@Test func noCoErrorDescriptions() async throws {
    let errors: [NoCoError] = [
        .jsException("test"),
        .moduleNotFound("mymod"),
        .fileNotFound("/tmp/missing.js"),
        .evaluationFailed("eval error"),
        .sandboxViolation("sandbox error"),
    ]

    #expect(errors[0].description == "JSException: test")
    #expect(errors[1].description == "Cannot find module 'mymod'")
    #expect(errors[2].description == "ENOENT: no such file or directory, open '/tmp/missing.js'")
    #expect(errors[3].description == "EvaluationFailed: eval error")
    #expect(errors[4].description == "SandboxViolation: sandbox error")
}

@Test func evaluateFileNotFound() async throws {
    let runtime = NodeRuntime()
    do {
        try runtime.evaluateFile(at: "/nonexistent_path_xyz/file.js")
        #expect(Bool(false), "Should have thrown")
    } catch let error as NoCoError {
        #expect(error.description.contains("ENOENT"))
    }
}

@Test func evaluateWithSourceURL() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("1 + 1", sourceURL: "test://source.js")
    #expect(result?.toInt32() == 2)
}

@Test func runtimeConfigureClosure() async throws {
    var configured = false
    let runtime = NodeRuntime { _ in
        configured = true
    }
    #expect(configured)
    // Ensure runtime is usable after configure
    let result = runtime.evaluate("42")
    #expect(result?.toInt32() == 42)
}

@Test func jsExceptionHandler() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("throw new Error('test exception')")

    #expect(messages.contains(where: { $0.0 == .error && $0.1.contains("test exception") }))
}
