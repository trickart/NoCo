import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - assert.deepEqual / assert.deepStrictEqual

@Test func assertDeepEqualObjects() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepEqual({a: 1, b: 2}, {a: 1, b: 2}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDeepEqualArrays() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepEqual([1, 2, 3], [1, 2, 3]); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDeepEqualNested() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepEqual({a: {b: [1, 2]}}, {a: {b: [1, 2]}}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDeepEqualFailsOnDifference() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepEqual({a: 1}, {a: 2}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

@Test func assertDeepStrictEqualObjects() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepStrictEqual({x: 'y'}, {x: 'y'}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDeepStrictEqualFailsOnDifference() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.deepStrictEqual([1, 2], [1, 3]); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

// MARK: - assert.notDeepEqual / assert.notDeepStrictEqual

@Test func assertNotDeepEqualPasses() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.notDeepEqual({a: 1}, {a: 2}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertNotDeepEqualFailsOnSame() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.notDeepEqual({a: 1}, {a: 1}); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

@Test func assertNotDeepStrictEqualPasses() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.notDeepStrictEqual([1], [2]); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

// MARK: - assert.throws (enhanced)

@Test func assertThrowsWithRegExp() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try {
            assert.throws(function() { throw new Error('hello world'); }, /hello/);
            'pass';
        } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertThrowsRegExpMismatch() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try {
            assert.throws(function() { throw new Error('hello'); }, /goodbye/);
            'pass';
        } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

@Test func assertThrowsWithErrorClass() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try {
            assert.throws(function() { throw new TypeError('bad'); }, TypeError);
            'pass';
        } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertThrowsWithObjectMatch() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try {
            assert.throws(function() { throw new Error('expected'); }, {message: 'expected'});
            'pass';
        } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertThrowsObjectMatchFails() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try {
            assert.throws(function() { throw new Error('actual'); }, {message: 'expected'});
            'pass';
        } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

// MARK: - assert.doesNotThrow

@Test func assertDoesNotThrowPasses() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.doesNotThrow(function() { return 1; }); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDoesNotThrowFails() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.doesNotThrow(function() { throw new Error('oops'); }); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

// MARK: - assert.rejects

@Test(.timeLimit(.minutes(1)))
func assertRejectsPasses() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var assert = require('assert');
        var keepAlive = setTimeout(function(){}, 10000);
        assert.rejects(
            function() { return Promise.reject(new Error('rejected')); },
            {message: 'rejected'}
        ).then(function() {
            console.log('pass');
            clearTimeout(keepAlive);
        }).catch(function(e) {
            console.log('fail:' + e.message);
            clearTimeout(keepAlive);
        });
    """)

    let eventLoopTask = Task.detached {
        runtime.eventLoop.run(timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if !messages.isEmpty { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("pass"))
}

@Test(.timeLimit(.minutes(1)))
func assertRejectsFailsOnResolve() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var assert = require('assert');
        var keepAlive = setTimeout(function(){}, 10000);
        assert.rejects(
            function() { return Promise.resolve('ok'); }
        ).then(function() {
            console.log('unexpected');
            clearTimeout(keepAlive);
        }).catch(function(e) {
            console.log('caught');
            clearTimeout(keepAlive);
        });
    """)

    let eventLoopTask = Task.detached {
        runtime.eventLoop.run(timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if !messages.isEmpty { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("caught"))
}

// MARK: - assert.doesNotReject

@Test(.timeLimit(.minutes(1)))
func assertDoesNotRejectPasses() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var assert = require('assert');
        var keepAlive = setTimeout(function(){}, 10000);
        assert.doesNotReject(
            function() { return Promise.resolve('ok'); }
        ).then(function() {
            console.log('pass');
            clearTimeout(keepAlive);
        }).catch(function(e) {
            console.log('fail');
            clearTimeout(keepAlive);
        });
    """)

    let eventLoopTask = Task.detached {
        runtime.eventLoop.run(timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if !messages.isEmpty { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("pass"))
}

// MARK: - assert.ifError

@Test func assertIfErrorPassesOnNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.ifError(null); assert.ifError(undefined); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertIfErrorThrowsOnValue() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.ifError(new Error('oops')); 'pass'; } catch(e) { e.message; }
    """)
    #expect(result?.toString() == "oops")
}

// MARK: - assert.match / assert.doesNotMatch

@Test func assertMatchPasses() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.match('hello world', /world/); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertMatchFails() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.match('hello', /world/); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}

@Test func assertDoesNotMatchPasses() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.doesNotMatch('hello', /world/); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "pass")
}

@Test func assertDoesNotMatchFails() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var assert = require('assert');
        try { assert.doesNotMatch('hello world', /world/); 'pass'; } catch(e) { 'fail'; }
    """)
    #expect(result?.toString() == "fail")
}
