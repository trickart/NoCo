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
