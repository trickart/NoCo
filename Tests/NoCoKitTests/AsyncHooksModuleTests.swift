import Testing
import JavaScriptCore
@testable import NoCoKit

@Test func asyncLocalStorageRunAndGetStore() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        storage.run('myStore', function() {
            console.log('inside:' + storage.getStore());
        });
        console.log('outside:' + storage.getStore());
    """)

    #expect(messages.contains("inside:myStore"))
    #expect(messages.contains("outside:undefined"))
}

@Test func asyncLocalStorageNestedRun() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        storage.run('outer', function() {
            console.log('outer:' + storage.getStore());
            storage.run('inner', function() {
                console.log('inner:' + storage.getStore());
            });
            console.log('restored:' + storage.getStore());
        });
    """)

    #expect(messages.contains("outer:outer"))
    #expect(messages.contains("inner:inner"))
    #expect(messages.contains("restored:outer"))
}

@Test func asyncLocalStorageAsyncCallback() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        storage.run('asyncStore', function() {
            return Promise.resolve().then(function() {
                console.log('promise:' + storage.getStore());
            });
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("promise:asyncStore"))
}

@Test func asyncLocalStorageExceptionRestores() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        storage.run('before', function() {
            try {
                storage.run('during', function() {
                    throw new Error('test');
                });
            } catch(e) {}
            console.log('after:' + storage.getStore());
        });
    """)

    #expect(messages.contains("after:before"))
}

@Test func asyncLocalStorageNodePrefix() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ah = require('node:async_hooks');
        typeof ah.AsyncLocalStorage === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func asyncLocalStorageObjectStore() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var AsyncLocalStorage = require('async_hooks').AsyncLocalStorage;
        var storage = new AsyncLocalStorage();
        var ctx = { id: 42, name: 'test' };
        storage.run(ctx, function() {
            var s = storage.getStore();
            console.log('id:' + s.id);
            console.log('same:' + (s === ctx));
        });
    """)

    #expect(messages.contains("id:42"))
    #expect(messages.contains("same:true"))
}

@Test func asyncLocalStorageHonoPattern() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var AsyncLocalStorage = require('node:async_hooks').AsyncLocalStorage;
        var als = new AsyncLocalStorage();

        // Simulate Hono context-storage middleware pattern
        var fakeContext = { req: { url: '/test' } };
        var result = als.run(fakeContext, function() {
            // Simulate async middleware chain
            return Promise.resolve().then(function() {
                var ctx = als.getStore();
                console.log('url:' + ctx.req.url);
                console.log('same:' + (ctx === fakeContext));
                return 'done';
            });
        });
        result.then(function(v) { console.log('result:' + v); });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("url:/test"))
    #expect(messages.contains("same:true"))
    #expect(messages.contains("result:done"))
}

@Test func asyncLocalStorageRunReturnsPromiseSubclass() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Verify that run() does not break Promise subclasses that use
    // Symbol.species (e.g. zx's ProcessPromise). The key issue was that
    // .then() on the return value triggered Symbol.species, re-invoking
    // the subclass constructor without proper initialization.
    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        var SHOT = Symbol('shot');

        class TestPromise extends Promise {
            constructor(executor) {
                var _resolve;
                super(function(resolve, reject) {
                    _resolve = resolve;
                    executor(resolve, reject);
                });
                this._shot = executor[SHOT];
                if (!this._shot) {
                    this._disarmed = true;
                } else {
                    this._disarmed = false;
                }
            }
        }

        function within(cb) {
            return storage.run(Object.assign({}, storage.getStore() || {}), cb);
        }

        var result = within(function() {
            var cb = function() { cb[SHOT] = { halt: true }; };
            var p = new TestPromise(cb);
            return p;
        });

        console.log('disarmed:' + result._disarmed);
        console.log('shot:' + JSON.stringify(result._shot));
    """)

    #expect(messages.contains("disarmed:false"))
    #expect(messages.contains { $0.hasPrefix("shot:") && $0.contains("halt") })
}

@Test func asyncLocalStorageRunNestedRestoresCorrectly() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var als = require('async_hooks').AsyncLocalStorage;
        var storage = new als();
        storage.run('outer', function() {
            console.log('a:' + storage.getStore());
            storage.run('inner', function() {
                console.log('b:' + storage.getStore());
            });
            console.log('c:' + storage.getStore());
        });
        console.log('d:' + storage.getStore());
    """)

    #expect(messages.contains("a:outer"))
    #expect(messages.contains("b:inner"))
    #expect(messages.contains("c:outer"))
    #expect(messages.contains("d:undefined"))
}
