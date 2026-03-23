import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - EventEmitter Module Tests

@Test func eventEmitterOnEmit() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var result = '';
        emitter.on('test', function(data) { result = data; });
        emitter.emit('test', 'hello');
        result;
    """)
    #expect(result?.toString() == "hello")
}

@Test func eventEmitterOnce() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var count = 0;
        emitter.once('test', function() { count++; });
        emitter.emit('test');
        emitter.emit('test');
        count;
    """)
    #expect(result?.toInt32() == 1)
}

@Test func eventEmitterRemoveListener() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var count = 0;
        var fn = function() { count++; };
        emitter.on('test', fn);
        emitter.emit('test');
        emitter.removeListener('test', fn);
        emitter.emit('test');
        count;
    """)
    #expect(result?.toInt32() == 1)
}

// MARK: - EventEmitter Module Edge Cases

@Test func eventEmitterMultipleArgs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var received = [];
        emitter.on('test', function(a, b, c) { received = [a, b, c]; });
        emitter.emit('test', 1, 2, 3);
        received.join(',');
    """)
    #expect(result?.toString() == "1,2,3")
}

@Test func eventEmitterListenerCount() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        emitter.on('test', function() {});
        emitter.on('test', function() {});
        emitter.on('other', function() {});
        emitter.listenerCount('test');
    """)
    #expect(result?.toInt32() == 2)
}

@Test func eventEmitterEventNames() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        emitter.on('foo', function() {});
        emitter.on('bar', function() {});
        emitter.eventNames().sort().join(',');
    """)
    #expect(result?.toString() == "bar,foo")
}

@Test func eventEmitterRemoveAllListeners() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        emitter.on('test', function() {});
        emitter.on('test', function() {});
        emitter.on('other', function() {});
        emitter.removeAllListeners('test');
        emitter.listenerCount('test') + ':' + emitter.listenerCount('other');
    """)
    #expect(result?.toString() == "0:1")
}

@Test func eventEmitterPrependListener() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var order = [];
        emitter.on('test', function() { order.push('first'); });
        emitter.prependListener('test', function() { order.push('prepended'); });
        emitter.emit('test');
        order.join(',');
    """)
    #expect(result?.toString() == "prepended,first")
}

@Test func eventEmitterErrorThrows() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        try {
            emitter.emit('error', new Error('test error'));
        } catch(e) {
            console.log('caught:' + e.message);
        }
    """)
    #expect(messages.contains(where: { $0.1 == "caught:test error" }))
}

@Test func eventEmitterOff() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var count = 0;
        var fn = function() { count++; };
        emitter.on('test', fn);
        emitter.emit('test');
        emitter.off('test', fn);
        emitter.emit('test');
        count;
    """)
    #expect(result?.toInt32() == 1)
}

@Test func eventEmitterNewListenerEvent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var events = [];
        emitter.on('newListener', function(event, listener) {
            events.push(event);
        });
        emitter.on('foo', function() {});
        emitter.on('bar', function() {});
        events.join(',');
    """)
    #expect(result?.toString() == "foo,bar")
}

// MARK: - EventEmitter Lazy Initialization (mixin pattern)

@Test func eventEmitterLazyInitOnMixin() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        // Simulate Express-style mixin: copy methods without calling constructor
        var obj = {};
        Object.getOwnPropertyNames(EE.prototype).forEach(function(key) {
            if (key !== 'constructor') obj[key] = EE.prototype[key];
        });
        // _events is not initialized (no constructor call)
        // These should not throw due to lazy init
        obj.on('test', function() {});
        obj.emit('test');
        obj.listenerCount('test');
    """)
    #expect(result?.toInt32() == 1)
}

@Test func eventEmitterLazyInitAllMethods() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var obj = {};
        Object.getOwnPropertyNames(EE.prototype).forEach(function(key) {
            if (key !== 'constructor') obj[key] = EE.prototype[key];
        });
        var results = [];
        // Test each method works without constructor
        results.push(obj.eventNames().length === 0);
        results.push(obj.listeners('x').length === 0);
        results.push(obj.rawListeners('x').length === 0);
        results.push(obj.listenerCount('x') === 0);
        obj.setMaxListeners(20);
        results.push(obj.getMaxListeners() === 20);
        obj.prependListener('x', function() {});
        results.push(obj.listenerCount('x') === 1);
        obj.removeAllListeners();
        results.push(obj.listenerCount('x') === 0);
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - EventEmitterAsyncResource

@Test func eventEmitterAsyncResourceIsSubclass() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var ear = new EE.EventEmitterAsyncResource({ name: 'test' });
        (ear instanceof EE) + ':' + ear.asyncResource.type;
    """)
    #expect(result?.toString() == "true:test")
}

@Test func eventEmitterAsyncResourceEmitsEvents() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var ear = new EE.EventEmitterAsyncResource({ name: 'myResource' });
        var received = '';
        ear.on('data', function(v) { received = v; });
        ear.emit('data', 'hello');
        received;
    """)
    #expect(result?.toString() == "hello")
}

@Test func eventEmitterAsyncResourceMethods() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var EE = require('events');
        var ear = new EE.EventEmitterAsyncResource();
        var results = [];
        results.push(typeof ear.asyncResource.asyncId === 'function');
        results.push(typeof ear.asyncResource.triggerAsyncId === 'function');
        results.push(typeof ear.asyncResource.runInAsyncScope === 'function');
        results.push(ear.asyncResource.asyncId() === 0);
        results.push(ear.asyncResource.triggerAsyncId() === 0);
        // runInAsyncScope should call the function with the given thisArg and args
        var ctx = { val: 42 };
        var ran = ear.asyncResource.runInAsyncScope(function(a, b) { return this.val + a + b; }, ctx, 1, 2);
        results.push(ran === 45);
        results.push(ear.emitDestroy() === ear);
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - events.once()

@Test func eventsOnceResolvesOnEvent() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        EE.once(emitter, 'done').then(function(args) {
            console.log('once:' + args[0] + ':' + args[1]);
        });
        emitter.emit('done', 'a', 'b');
    """)
    runtime.context.evaluateScript("void 0") // drain microtasks

    #expect(messages.contains("once:a:b"))
}

@Test func eventsOnceRejectsOnError() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        EE.once(emitter, 'done').catch(function(err) {
            console.log('error:' + err.message);
        });
        emitter.emit('error', new Error('fail'));
    """)
    runtime.context.evaluateScript("void 0")

    #expect(messages.contains("error:fail"))
}

// MARK: - events.on()

@Test func eventsOnReturnsAsyncIterator() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var EE = require('events');
        var emitter = new EE();
        var iter = EE.on(emitter, 'data');
        // Symbol.asyncIterator should be defined
        console.log('asyncIter:' + (typeof iter[Symbol.asyncIterator] === 'function'));
        // Emit before consuming — should buffer
        emitter.emit('data', 'x');
        emitter.emit('data', 'y');
        iter.next().then(function(r) { console.log('v1:' + r.value[0] + ':' + r.done); });
        iter.next().then(function(r) { console.log('v2:' + r.value[0] + ':' + r.done); });
    """)
    runtime.context.evaluateScript("void 0")

    #expect(messages.contains("asyncIter:true"))
    #expect(messages.contains("v1:x:false"))
    #expect(messages.contains("v2:y:false"))
}
