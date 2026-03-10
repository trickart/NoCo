import Testing
import JavaScriptCore
@testable import NoCoKit

@Test func utilPromisifyBasicCallback() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var util = require('util');
        var callbackFn = function(a, b, cb) { cb(null, a + b); };
        var promisified = util.promisify(callbackFn);
        var result = '';
        promisified(1, 2).then(function(val) { result = String(val); });
    """)
    runtime.eventLoop.run(timeout: 1.0)
    let result = runtime.evaluate("result")
    #expect(result?.toString() == "3")
}

@Test func utilPromisifyRejectsOnError() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var util = require('util');
        var failFn = function(cb) { cb(new Error('fail')); };
        var promisified = util.promisify(failFn);
        var errMsg = '';
        promisified().catch(function(e) { errMsg = e.message; });
    """)
    runtime.eventLoop.run(timeout: 1.0)
    let result = runtime.evaluate("errMsg")
    #expect(result?.toString() == "fail")
}

@Test func utilPromisifyCustomSymbol() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var util = require('util');
        function original(cb) { cb(null, 'original'); }
        original[util.promisify.custom] = function() { return Promise.resolve('custom'); };
        var promisified = util.promisify(original);
        var result = '';
        promisified().then(function(val) { result = val; });
    """)
    runtime.eventLoop.run(timeout: 1.0)
    let result = runtime.evaluate("result")
    #expect(result?.toString() == "custom")
}

@Test func utilPromisifyThrowsForNonFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        var threw = false;
        try { util.promisify('not a function'); } catch(e) { threw = true; }
        threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func utilInspectCustomSymbol() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        typeof util.inspect.custom === 'symbol' && util.inspect.custom === Symbol.for('nodejs.util.inspect.custom');
    """)
    #expect(result?.toBool() == true)
}

// MARK: - util.formatWithOptions

@Test func utilFormatWithOptionsBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        util.formatWithOptions({}, 'hello %s', 'world');
    """)
    #expect(result?.toString() == "hello world")
}

@Test func utilFormatWithOptionsMultipleArgs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        util.formatWithOptions({}, '%s + %d = %d', 'one', 2, 3);
    """)
    #expect(result?.toString() == "one + 2 = 3")
}

@Test func utilFormatWithOptionsNoFormatString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        util.formatWithOptions({}, 1, 2, 3);
    """)
    #expect(result?.toString() == "1 2 3")
}

@Test func utilFormatWithOptionsIsFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        typeof require('util').formatWithOptions === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func utilPromisifyCustomSymbolValue() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var util = require('util');
        util.promisify.custom === Symbol.for('nodejs.util.promisify.custom');
    """)
    #expect(result?.toBool() == true)
}
