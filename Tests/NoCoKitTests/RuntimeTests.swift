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

// MARK: - Error.captureStackTrace / Error.prepareStackTrace

@Test func errorCaptureStackTraceExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        typeof Error.captureStackTrace === 'function' && typeof Error.stackTraceLimit === 'number';
    """)
    #expect(result?.toBool() == true)
}

@Test func errorCaptureStackTraceAddsStack() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = {};
        Error.captureStackTrace(obj);
        typeof obj.stack === 'string';
    """)
    #expect(result?.toBool() == true)
}

@Test func errorPrepareStackTraceCallSiteObjects() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        (function() {
            var callSites;
            Error.prepareStackTrace = function(err, stack) {
                callSites = stack;
                return stack;
            };
            function inner() {
                var obj = {};
                Error.captureStackTrace(obj);
                return obj.stack;
            }
            inner();
            Error.prepareStackTrace = undefined;
            // callSites should be an array of call site objects
            var ok = Array.isArray(callSites) && callSites.length > 0;
            if (!ok) return false;
            var site = callSites[0];
            ok = ok && typeof site.getFileName === 'function';
            ok = ok && typeof site.getLineNumber === 'function';
            ok = ok && typeof site.getColumnNumber === 'function';
            ok = ok && typeof site.getFunctionName === 'function';
            ok = ok && typeof site.isEval === 'function';
            ok = ok && typeof site.isNative === 'function';
            ok = ok && typeof site.toString === 'function';
            return ok;
        })();
    """)
    #expect(result?.toBool() == true)
}

@Test func errorCaptureStackTraceWithPrepare() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        // Simulate depd pattern: override prepareStackTrace to get raw call sites
        function getStack() {
            var prep = Error.prepareStackTrace;
            Error.prepareStackTrace = function(obj, stack) { return stack; };
            var obj = {};
            Error.captureStackTrace(obj);
            var stack = obj.stack;
            Error.prepareStackTrace = prep;
            return stack;
        }
        function caller() { return getStack(); }
        var stack = caller();
        Array.isArray(stack) && stack.length > 0;
    """)
    #expect(result?.toBool() == true)
}
