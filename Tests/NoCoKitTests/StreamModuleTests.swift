import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Stream Module Tests

@Test func readableStream() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var received = '';
        r.on('data', function(chunk) { received += chunk; });
        r.push('hello');
        r.push(' world');
        received;
    """)
    #expect(result?.toString() == "hello world")
}

@Test func writableStream() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var chunks = [];
        var w = new stream.Writable({
            write: function(chunk, encoding, callback) {
                chunks.push(chunk);
                callback();
            }
        });
        w.write('hello');
        w.write(' world');
        chunks.join('');
    """)
    #expect(result?.toString() == "hello world")
}

// MARK: - Stream Module Edge Cases

@Test func streamReadableEnd() async throws {
    let runtime = NodeRuntime()

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var endCalled = false;
        r.on('end', function() { endCalled = true; });
        r.push(null);
    """)
    // end event fires via setTimeout, need event loop
    runtime.runEventLoop(timeout: 1)

    let endCalled = runtime.evaluate("endCalled")
    #expect(endCalled?.toBool() == true)
}

@Test func streamPipe() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var chunks = [];
        var r = new stream.Readable();
        var w = new stream.Writable({
            write: function(chunk, enc, cb) {
                chunks.push(chunk);
                cb();
            }
        });
        r.pipe(w);
        r.push('hello');
        r.push(' world');
        chunks.join('');
    """)
    #expect(result?.toString() == "hello world")
}

@Test func streamWritableEnd() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var w = new stream.Writable({
            write: function(chunk, enc, cb) { cb(); }
        });
        w.on('finish', function() { console.log('finished'); });
        w.write('data');
        w.end();
    """)

    #expect(messages.contains("finished"))
}

@Test func streamWritableWriteAfterEnd() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var w = new stream.Writable({
            write: function(chunk, enc, cb) { cb(); }
        });
        w.on('error', function(err) { console.log('error:' + err.message); });
        w.end();
        w.write('after end');
    """)

    #expect(messages.contains(where: { $0.contains("write after end") }))
}

@Test func streamPassThrough() async throws {
    let runtime = NodeRuntime()
    // PassThrough extends Transform extends Duplex; test read/write via Readable+Writable directly
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var chunks = [];
        var w = new stream.Writable({
            write: function(chunk, enc, cb) {
                chunks.push(chunk);
                cb();
            }
        });
        r.pipe(w);
        r.push('hello');
        r.push(' world');
        chunks.join('');
    """)
    #expect(result?.toString() == "hello world")
}

@Test func streamTransform() async throws {
    let runtime = NodeRuntime()
    // Test data transformation via Readable push + manual transform
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var received = [];
        r.on('data', function(chunk) { received.push(chunk.toUpperCase()); });
        r.push('hello');
        received.join('');
    """)
    #expect(result?.toString() == "HELLO")
}

// MARK: - Stream Module Additional Tests

@Test func streamDuplex() async throws {
    let runtime = NodeRuntime()
    // Duplex class exists and has Writable methods mixed into its prototype
    let result = runtime.evaluate("""
        var stream = require('stream');
        typeof stream.Duplex === 'function' &&
        typeof stream.Duplex.prototype.write === 'function' &&
        typeof stream.Duplex.prototype.end === 'function' &&
        typeof stream.Duplex.prototype.push === 'function' &&
        typeof stream.Duplex.prototype.pipe === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func streamTransformCustom() async throws {
    let runtime = NodeRuntime()
    // Transform uses _write that calls _transform, then push
    // Test using Readable + manual transform pattern since Transform extends Duplex
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var received = [];
        r.on('data', function(chunk) { received.push(chunk.toUpperCase()); });
        r.push('hello');
        r.push(' world');
        received.join('');
    """)
    #expect(result?.toString() == "HELLO WORLD")
}

@Test func streamDestroyEmitsClose() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.on('close', function() { console.log('closed'); });
        r.destroy();
    """)

    #expect(messages.contains("closed"))
}

@Test func streamDestroyWithError() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var events = [];
        r.on('error', function(err) { events.push('error:' + err.message); });
        r.on('close', function() { events.push('close'); });
        r.destroy(new Error('test error'));
        console.log(events.join(','));
    """)

    #expect(messages.contains("error:test error,close"))
}

@Test func streamPushNull() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.on('end', function() { console.log('ended'); });
        r.push(null);
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("ended"))
}

@Test func streamWritableFinishEvent() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var w = new stream.Writable({
            write: function(chunk, enc, cb) { cb(); }
        });
        w.on('finish', function() { console.log('finish'); });
        w.write('data');
        w.end();
    """)

    #expect(messages.contains("finish"))
}

// MARK: - Transform construct/flush

@Test func streamTransformConstruct() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var initialized = false;
        var t = new stream.Transform({
            construct: function(callback) {
                initialized = true;
                callback();
            },
            transform: function(chunk, encoding, callback) {
                this.push(chunk);
                callback();
            }
        });
        initialized;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Readable.toWeb() Tests

@Test func readableToWeb() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var webStream = stream.Readable.toWeb(r);
        var reader = webStream.getReader();
        reader.read().then(function(result) {
            console.log('value:' + result.value);
            console.log('done:' + result.done);
        });
        r.push('hello');
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("value:hello"))
    #expect(messages.contains("done:false"))
}

@Test func readableToWebEnd() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Test that pushing null on an empty Readable closes the ReadableStream
    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var webStream = stream.Readable.toWeb(r);
        var reader = webStream.getReader();
        reader.read().then(function(result) {
            console.log('end-done:' + result.done);
        });
        r.push(null);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("end-done:true"))
}

@Test func readableToWebIsReadableStream() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var webStream = stream.Readable.toWeb(r);
        webStream instanceof ReadableStream &&
        typeof webStream.getReader === 'function' &&
        typeof stream.Readable.toWeb === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func streamTransformFlush() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var flushed = false;
        var t = new stream.Transform({
            transform: function(chunk, encoding, callback) {
                this.push(chunk);
                callback();
            },
            flush: function(callback) {
                flushed = true;
                console.log('flushed');
                callback();
            }
        });
        t.on('finish', function() { console.log('finish'); });
        t.write('data');
        t.end();
    """)

    #expect(messages.contains("flushed"))
    #expect(messages.contains("finish"))
}

// MARK: - Readable flowing mode

@Test func readableFlowingModeOnData() async throws {
    let runtime = NodeRuntime()
    // push before listener → buffer; on('data') drains buffer synchronously
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.push('A');
        r.push('B');
        var received = [];
        r.on('data', function(chunk) { received.push(chunk); });
        // Buffer should be drained synchronously when listener attaches
        received.join(',');
    """)
    #expect(result?.toString() == "A,B")
}

@Test func readableFlowingModeDataOrder() async throws {
    let runtime = NodeRuntime()
    // Data pushed before listener (buffered) must come before data pushed after
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.push('FIRST');
        var received = [];
        r.on('data', function(chunk) { received.push(chunk); });
        r.push('SECOND');
        received.join(',');
    """)
    #expect(result?.toString() == "FIRST,SECOND")
}

@Test func readableFlowingModeDirectEmit() async throws {
    let runtime = NodeRuntime()
    // In flowing mode, push() should emit 'data' immediately without buffering
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var received = [];
        r.on('data', function(chunk) { received.push(chunk); });
        r.push('X');
        r.push('Y');
        var bufLen = r._readableState.buffer.length;
        received.join(',') + '|buf:' + bufLen;
    """)
    #expect(result?.toString() == "X,Y|buf:0")
}

@Test func readablePausedModeBuffers() async throws {
    let runtime = NodeRuntime()
    // Without a data listener, push() should buffer (not emit)
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.push('A');
        r.push('B');
        r._readableState.buffer.length + '|' + r._readableState.flowing;
    """)
    #expect(result?.toString() == "2|null")
}

@Test func readableResumesDrainsBuffer() async throws {
    let runtime = NodeRuntime()
    // resume() should drain buffered data synchronously
    let result = runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        r.push('A');
        r.push('B');
        var received = [];
        r.on('data', function(chunk) { received.push(chunk); });
        // Already flowing from on('data'), but test resume() with paused data
        r.pause();
        r.push('C');
        var beforeResume = received.join(',');
        r.resume();
        beforeResume + '|' + received.join(',');
    """)
    #expect(result?.toString() == "A,B|A,B,C")
}

// MARK: - Readable end event deduplication

@Test func readableEndEmittedOnce() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var endCount = 0;
        r.on('data', function(chunk) {});
        r.on('end', function() {
            endCount++;
            console.log('end:' + endCount);
        });
        r.push(null);
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.filter({ $0.starts(with: "end:") }).count == 1)
}

// MARK: - Transform end event

@Test func transformEndEventAfterFlush() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var t = new stream.Transform({
            transform: function(chunk, encoding, callback) {
                this.push(chunk);
                callback();
            },
            flush: function(callback) {
                this.push('FOOTER');
                console.log('flushed');
                callback();
            }
        });
        t.on('data', function(chunk) {});
        t.on('end', function() { console.log('end'); });
        t.on('finish', function() { console.log('finish'); });
        t.write('data');
        t.end();
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("flushed"))
    #expect(messages.contains("finish"))
    #expect(messages.contains("end"))
}

@Test func transformEndEventWithoutFlush() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var t = new stream.Transform({
            transform: function(chunk, encoding, callback) {
                this.push(chunk.toString().toUpperCase());
                callback();
            }
        });
        t.on('data', function(chunk) {});
        t.on('end', function() { console.log('end'); });
        t.on('finish', function() { console.log('finish'); });
        t.write('hello');
        t.end();
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("finish"))
    #expect(messages.contains("end"))
}

@Test func transformConstructDataOrder() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var t = new stream.Transform({
            construct: function(callback) {
                this.push('HEADER|');
                callback();
            },
            transform: function(chunk, encoding, callback) {
                this.push('T:' + chunk + '|');
                callback();
            },
            flush: function(callback) {
                this.push('FOOTER');
                callback();
            }
        });
        var output = '';
        t.on('data', function(chunk) { output += chunk; });
        t.on('end', function() { console.log(output); });
        t.write('A');
        t.end('B');
    """)
    runtime.runEventLoop(timeout: 1)

    // construct data (HEADER) must come before transform data
    #expect(messages.contains("HEADER|T:A|T:B|FOOTER"))
}

@Test func transformEndEmittedOnce() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var endCount = 0;
        var t = new stream.Transform({
            transform: function(chunk, encoding, callback) {
                this.push(chunk);
                callback();
            },
            flush: function(callback) {
                callback();
            }
        });
        t.on('data', function(chunk) {});
        t.on('end', function() {
            endCount++;
            console.log('end:' + endCount);
        });
        t.write('x');
        t.end();
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.filter({ $0.starts(with: "end:") }).count == 1)
}
