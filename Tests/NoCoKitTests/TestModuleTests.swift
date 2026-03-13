import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Test Module Tests

@Test func testModuleBasicPass() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('passing test', function(t) {
            t.assert.ok(true);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("TAP version 13"))
    #expect(joined.contains("ok 1 - passing test"))
    #expect(joined.contains("# pass 1"))
    #expect(joined.contains("# fail 0"))
}

@Test func testModuleBasicFail() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('failing test', function(t) {
            t.assert.strictEqual(1, 2);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("not ok 1 - failing test"))
    #expect(joined.contains("# fail 1"))

    let exitCode = runtime.evaluate("process.exitCode")
    #expect(exitCode?.toInt32() == 1)
}

@Test func testModuleSkipOption() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('skipped', { skip: 'not ready' }, function(t) {
            t.assert.ok(false);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("ok 1 - skipped # SKIP not ready"))
    #expect(joined.contains("# skip 1"))
}

@Test func testModuleSkipShorthand() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test.skip('skipped shorthand', function(t) {
            t.assert.ok(false);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# SKIP"))
    #expect(joined.contains("# skip 1"))
}

@Test func testModuleTodoOption() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('my todo', { todo: 'implement later' }, function(t) {});
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# TODO implement later"))
    #expect(joined.contains("# todo 1"))
}

@Test func testModuleTodoShorthand() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test.todo('future feature');
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# TODO"))
    #expect(joined.contains("# todo 1"))
}

@Test func testModuleDescribeIt() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var { describe, it } = require('node:test');
        describe('math', function() {
            it('adds', function(t) { t.assert.strictEqual(1+1, 2); });
            it('subtracts', function(t) { t.assert.strictEqual(3-1, 2); });
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# Subtest: math"))
    #expect(joined.contains("ok 1 - adds"))
    #expect(joined.contains("ok 2 - subtracts"))
    #expect(joined.contains("# pass 2"))
}

@Test func testModuleLifecycleHooks() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }
    var consoleOutput: [String] = []
    runtime.consoleHandler = { _, msg in consoleOutput.append(msg) }

    runtime.evaluate("""
        var { describe, it, before, after, beforeEach, afterEach } = require('node:test');
        var order = [];
        describe('hooks', function() {
            before(function() { order.push('before'); });
            after(function() { order.push('after'); });
            beforeEach(function() { order.push('beforeEach'); });
            afterEach(function() { order.push('afterEach'); });
            it('test1', function() { order.push('test1'); });
            it('test2', function() { order.push('test2'); });
        });
        // Log order after all tests run
        setTimeout(function() {
            console.log(JSON.stringify(order));
        }, 100);
    """)
    runtime.runEventLoop(timeout: 2)

    let orderStr = consoleOutput.first(where: { $0.contains("before") }) ?? ""
    let order = orderStr
    #expect(order.contains("before"))
    #expect(order.contains("beforeEach"))
    #expect(order.contains("afterEach"))
    #expect(order.contains("after"))
}

@Test func testModuleAsyncTest() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('async test', function(t) {
            return new Promise(function(resolve) {
                setTimeout(function() {
                    t.assert.ok(true);
                    resolve();
                }, 10);
            });
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("ok 1 - async test"))
    #expect(joined.contains("# pass 1"))
}

@Test func testModuleSubtest() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('parent', function(t) {
            t.test('child', function(t2) {
                t2.assert.ok(true);
            });
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("ok") && joined.contains("child"))
}

@Test func testModuleDiagnostic() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('with diagnostic', function(t) {
            t.diagnostic('some info');
            t.assert.ok(true);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# some info"))
}

@Test func testModuleRuntimeSkip() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('runtime skip', function(t) {
            t.skip('skipping at runtime');
            t.assert.ok(false); // should not matter
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# SKIP skipping at runtime"))
    #expect(joined.contains("# skip 1"))
}

@Test func testModuleDescribeSkip() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var { describe, it } = require('node:test');
        describe.skip('skipped suite', function() {
            it('should not run', function(t) { t.assert.ok(false); });
        });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# SKIP"))
    #expect(joined.contains("# skip 1"))
}

@Test func testModuleMultipleTests() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('first', function(t) { t.assert.ok(true); });
        test('second', function(t) { t.assert.ok(true); });
        test('third', function(t) { t.assert.strictEqual(1, 2); });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("1..3"))
    #expect(joined.contains("ok 1 - first"))
    #expect(joined.contains("ok 2 - second"))
    #expect(joined.contains("not ok 3 - third"))
    #expect(joined.contains("# pass 2"))
    #expect(joined.contains("# fail 1"))
}

@Test func testModuleRequireWithoutNodePrefix() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('test');
        test('works without prefix', function(t) { t.assert.ok(true); });
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("ok 1 - works without prefix"))
}

@Test func testModuleTestWithNoFnIsTodo() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.stdoutHandler = { str in output.append(str) }

    runtime.evaluate("""
        var test = require('node:test');
        test('placeholder');
    """)
    runtime.runEventLoop(timeout: 2)

    let joined = output.joined()
    #expect(joined.contains("# TODO"))
    #expect(joined.contains("# todo 1"))
}
