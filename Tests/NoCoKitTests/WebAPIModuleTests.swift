import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Headers Tests

@Test func headersBasicOperations() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var h = new Headers();
        h.append('Content-Type', 'text/html');
        h.set('X-Custom', 'value1');
        var results = [
            h.get('content-type') === 'text/html',
            h.get('x-custom') === 'value1',
            h.has('content-type') === true,
            h.has('nonexistent') === false
        ];
        h.delete('x-custom');
        results.push(h.has('x-custom') === false);
        results.push(h.get('x-custom') === null);
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func headersFromArray() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var h = new Headers([['Content-Type', 'application/json'], ['Accept', 'text/html']]);
        h.get('content-type') === 'application/json' && h.get('accept') === 'text/html';
    """)
    #expect(result?.toBool() == true)
}

@Test func headersFromObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var h = new Headers({ 'Content-Type': 'application/json', 'Accept': 'text/html' });
        h.get('content-type') === 'application/json' && h.get('accept') === 'text/html';
    """)
    #expect(result?.toBool() == true)
}

@Test func headersIterable() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var h = new Headers({ 'X-A': '1', 'X-B': '2' });
        var pairs = [];
        for (var entry of h) {
            pairs.push(entry[0] + '=' + entry[1]);
        }
        pairs.length === 2 && pairs.indexOf('x-a=1') !== -1 && pairs.indexOf('x-b=2') !== -1;
    """)
    #expect(result?.toBool() == true)
}

@Test func headersAppendMultipleValues() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var h = new Headers();
        h.append('Set-Cookie', 'a=1');
        h.append('Set-Cookie', 'b=2');
        h.get('set-cookie') === 'a=1, b=2';
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Request Tests

@Test func requestBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var req = new Request('https://example.com/api');
        req.method === 'GET' &&
        req.url === 'https://example.com/api' &&
        req.headers instanceof Headers &&
        req.body === null &&
        req.bodyUsed === false;
    """)
    #expect(result?.toBool() == true)
}

@Test func requestWithInit() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var req = new Request('https://example.com/api', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: '{"key":"value"}'
        });
        req.method === 'POST' &&
        req.headers.get('content-type') === 'application/json' &&
        req._bodySource === '{"key":"value"}';
    """)
    #expect(result?.toBool() == true)
}

@Test func requestClone() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var original = new Request('https://example.com', {
            method: 'POST',
            headers: { 'X-Test': 'value' },
            body: 'hello'
        });
        var cloned = original.clone();
        cloned.url === original.url &&
        cloned.method === original.method &&
        cloned.headers.get('x-test') === 'value' &&
        cloned._bodySource === 'hello' &&
        cloned !== original &&
        cloned.headers !== original.headers;
    """)
    #expect(result?.toBool() == true)
}

@Test func requestExtendable() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        function MyRequest(input, init) {
            Request.call(this, input, init);
            this.custom = true;
        }
        MyRequest.prototype = Object.create(Request.prototype);
        MyRequest.prototype.constructor = MyRequest;
        var req = new MyRequest('https://example.com', { method: 'PUT' });
        req.custom === true &&
        req.url === 'https://example.com' &&
        req.method === 'PUT' &&
        typeof req.clone === 'function';
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Response Tests

@Test func responseBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var res = new Response('Hello', { status: 201 });
        res.status === 201 &&
        res.ok === true &&
        res.body instanceof ReadableStream &&
        res._bodySource === 'Hello' &&
        res.headers instanceof Headers;
    """)
    #expect(result?.toBool() == true)
}

@Test func responseOkProperty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ok = new Response(null, { status: 200 });
        var notOk = new Response(null, { status: 404 });
        ok.ok === true && notOk.ok === false;
    """)
    #expect(result?.toBool() == true)
}

@Test func responseStaticMethods() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var jsonRes = Response.json({ key: 'value' });
        var redirectRes = Response.redirect('https://example.com');
        var errorRes = Response.error();
        [
            jsonRes.status === 200,
            jsonRes.headers.get('content-type') === 'application/json',
            jsonRes._bodySource === '{"key":"value"}',
            redirectRes.status === 302,
            redirectRes.headers.get('location') === 'https://example.com',
            errorRes.status === 0,
            errorRes.type === 'error'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - AbortController Tests

@Test func abortControllerSignal() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ac = new AbortController();
        var before = ac.signal.aborted;
        ac.abort();
        var after = ac.signal.aborted;
        before === false && after === true && ac.signal.reason instanceof DOMException;
    """)
    #expect(result?.toBool() == true)
}

@Test func abortControllerEventListener() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ac = new AbortController();
        var called = false;
        ac.signal.addEventListener('abort', function() { called = true; });
        ac.abort();
        called === true;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - ReadableStream Tests

@Test func readableStreamBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = new ReadableStream({
            start: function(controller) {
                controller.enqueue('hello');
                controller.enqueue(' world');
                controller.close();
            }
        });
        var reader = stream.getReader();
        reader.read().then(function(r) { console.log(r.value); });
        reader.read().then(function(r) { console.log(r.value); });
        reader.read().then(function(r) { console.log('done:' + r.done); });
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("hello"))
    #expect(messages.contains(" world"))
    #expect(messages.contains("done:true"))
}

@Test func readableStreamLocked() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = new ReadableStream({ start: function(c) { c.close(); } });
        var before = stream.locked;
        stream.getReader();
        var after = stream.locked;
        before === false && after === true;
    """)
    #expect(result?.toBool() == true)
}

@Test func readableStreamAlreadyLocked() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = new ReadableStream({ start: function(c) { c.close(); } });
        stream.getReader();
        var threw = false;
        try { stream.getReader(); } catch(e) { threw = true; }
        threw;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - queueMicrotask / structuredClone Tests

@Test func queueMicrotaskExists() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        typeof queueMicrotask === 'function';
    """)
    let isFn = runtime.evaluate("typeof queueMicrotask === 'function'")
    #expect(isFn?.toBool() == true)

    runtime.evaluate("""
        queueMicrotask(function() { console.log('microtask'); });
    """)
    runtime.runEventLoop(timeout: 1)
    #expect(messages.contains("microtask"))
}

@Test func structuredCloneBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var original = { a: 1, b: { c: [2, 3] } };
        var cloned = structuredClone(original);
        cloned.a === 1 &&
        cloned.b.c[0] === 2 &&
        cloned.b.c[1] === 3 &&
        cloned !== original &&
        cloned.b !== original.b &&
        cloned.b.c !== original.b.c;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - ReadableStream Body Tests

@Test func requestTextFromReadableStream() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = new ReadableStream({
            start: function(controller) {
                controller.enqueue('{"name":');
                controller.enqueue('"test"}');
                controller.close();
            }
        });
        var req = new Request('http://localhost', { method: 'POST', body: stream });
        req.text().then(function(t) {
            console.log('text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("text:{\"name\":\"test\"}"))
}

@Test func requestJsonFromReadableStream() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = new ReadableStream({
            start: function(controller) {
                controller.enqueue('{"key":"value"}');
                controller.close();
            }
        });
        var req = new Request('http://localhost', { method: 'POST', body: stream });
        req.json().then(function(obj) {
            console.log('key:' + obj.key);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("key:value"))
}

@Test func responseTextFromReadableStream() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = new ReadableStream({
            start: function(controller) {
                controller.enqueue('hello world');
                controller.close();
            }
        });
        var res = new Response(stream);
        res.text().then(function(t) {
            console.log('res-text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("res-text:hello world"))
}

// MARK: - Response.body ReadableStream Tests

@Test func responseBodyIsReadableStream() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var res = new Response('Hello');
        console.log('isStream:' + (res.body instanceof ReadableStream));
        var reader = res.body.getReader();
        reader.read().then(function(r) {
            console.log('value:' + new TextDecoder().decode(r.value));
            return reader.read();
        }).then(function(r) {
            console.log('done:' + r.done);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("isStream:true"))
    #expect(messages.contains("value:Hello"))
    #expect(messages.contains("done:true"))
}

@Test func responseBodyNullWhenEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var res = new Response();
        res.body === null;
    """)
    #expect(result?.toBool() == true)
}

@Test func responseBodyReadableStreamPassthrough() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = new ReadableStream({
            start: function(c) { c.enqueue('data'); c.close(); }
        });
        var res = new Response(stream);
        res.body === stream;
    """)
    #expect(result?.toBool() == true)
}

@Test func requestBodyIsReadableStream() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var req = new Request('http://localhost', { method: 'POST', body: 'test' });
        req.body instanceof ReadableStream;
    """)
    #expect(result?.toBool() == true)
}

@Test func responseBodyGetReaderWorkflow() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var res = new Response('{"cors":true}', {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
        });
        // Simulate @hono/node-server responseViaResponseObject path
        var reader = res.body.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(result) {
                if (result.done) {
                    console.log('body:' + chunks.join(''));
                    return;
                }
                chunks.push(new TextDecoder().decode(result.value));
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("body:{\"cors\":true}"))
}

@Test func responseBodyStreamEmitsUint8Array() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var res = new Response('Hello');
        var reader = res.body.getReader();
        reader.read().then(function(r) {
            console.log('isUint8Array:' + (r.value instanceof Uint8Array));
            console.log('decoded:' + new TextDecoder().decode(r.value));
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("isUint8Array:true"))
    #expect(messages.contains("decoded:Hello"))
}

@Test func responseCloneBodyDigest() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var res = new Response('Hello World');
        var clone = res.clone();
        var reader = clone.body.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(result) {
                if (result.done) {
                    var totalLen = 0;
                    chunks.forEach(function(c) { totalLen += c.length; });
                    var merged = new Uint8Array(totalLen);
                    var offset = 0;
                    chunks.forEach(function(c) { merged.set(c, offset); offset += c.length; });
                    return crypto.subtle.digest('SHA-1', merged);
                }
                chunks.push(result.value);
                return pump();
            });
        }
        pump().then(function(hashBuf) {
            var arr = new Uint8Array(hashBuf);
            var hex = Array.from(arr).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
            console.log('sha1:' + hex);
        });
    """)
    runtime.runEventLoop(timeout: 3)

    // SHA-1 of "Hello World" = 0a4d55a8d778e5022fab701977c5d840bbc486d0
    #expect(messages.contains("sha1:0a4d55a8d778e5022fab701977c5d840bbc486d0"))
}

@Test func requestBodyStreamEmitsUint8Array() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var req = new Request('http://localhost', { method: 'POST', body: 'test data' });
        var reader = req.body.getReader();
        reader.read().then(function(r) {
            console.log('isUint8Array:' + (r.value instanceof Uint8Array));
            console.log('decoded:' + new TextDecoder().decode(r.value));
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("isUint8Array:true"))
    #expect(messages.contains("decoded:test data"))
}

// MARK: - WritableStream Tests

@Test func writableStreamBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var chunks = [];
        var ws = new WritableStream({
            write: function(chunk) { chunks.push(chunk); },
            close: function() { console.log('chunks:' + chunks.join(',')); }
        });
        var writer = ws.getWriter();
        writer.write('a').then(function() {
            return writer.write('b');
        }).then(function() {
            return writer.close();
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("chunks:a,b"))
}

@Test func writableStreamLocked() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new WritableStream();
        var before = ws.locked;
        ws.getWriter();
        var after = ws.locked;
        before === false && after === true;
    """)
    #expect(result?.toBool() == true)
}

@Test func writableStreamAlreadyLocked() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new WritableStream();
        ws.getWriter();
        var threw = false;
        try { ws.getWriter(); } catch(e) { threw = true; }
        threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func writableStreamReleaseLock() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new WritableStream();
        var w1 = ws.getWriter();
        w1.releaseLock();
        var w2 = ws.getWriter();
        ws.locked === true;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - TransformStream Tests

@Test func transformStreamIdentity() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var ts = new TransformStream();
        var writer = ts.writable.getWriter();
        var reader = ts.readable.getReader();

        // Write first, then read sequentially
        writer.write('hello');
        writer.write('world');

        reader.read().then(function(r) {
            console.log('v1:' + r.value);
            return reader.read();
        }).then(function(r) {
            console.log('v2:' + r.value);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("v1:hello"))
    #expect(messages.contains("v2:world"))
}

@Test func transformStreamCustomTransform() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var ts = new TransformStream({
            transform: function(chunk, controller) {
                controller.enqueue(chunk.toUpperCase());
            }
        });
        var writer = ts.writable.getWriter();
        var reader = ts.readable.getReader();

        reader.read().then(function(r) { console.log('upper:' + r.value); });
        writer.write('hello');
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("upper:HELLO"))
}

@Test func transformStreamClosePropagate() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var ts = new TransformStream();
        var writer = ts.writable.getWriter();
        var reader = ts.readable.getReader();

        writer.write('data');
        writer.close();

        reader.read().then(function(r) { console.log('data:' + r.value); });
        reader.read().then(function(r) { console.log('done:' + r.done); });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("data:data"))
    #expect(messages.contains("done:true"))
}

// MARK: - pipeTo / pipeThrough Tests

@Test func readableStreamPipeTo() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var chunks = [];
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue('a');
                c.enqueue('b');
                c.close();
            }
        });
        var ws = new WritableStream({
            write: function(chunk) { chunks.push(chunk); },
            close: function() { console.log('piped:' + chunks.join(',')); }
        });
        rs.pipeTo(ws);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("piped:a,b"))
}

@Test func readableStreamPipeToPreventClose() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var chunks = [];
        var closeCalled = false;
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue('x');
                c.close();
            }
        });
        var ws = new WritableStream({
            write: function(chunk) { chunks.push(chunk); },
            close: function() { closeCalled = true; }
        });
        rs.pipeTo(ws, { preventClose: true }).then(function() {
            console.log('chunks:' + chunks.join(','));
            console.log('closed:' + closeCalled);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("chunks:x"))
    #expect(messages.contains("closed:false"))
}

@Test func readableStreamPipeThrough() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue('hello');
                c.close();
            }
        });
        var ts = new TransformStream({
            transform: function(chunk, ctrl) {
                ctrl.enqueue(chunk + '!');
            }
        });
        var result = rs.pipeThrough(ts);
        var reader = result.getReader();
        reader.read().then(function(r) { console.log('piped:' + r.value); });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("piped:hello!"))
}

@Test func honoStreamingApiPattern() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        // Simulate Hono's StreamingApi pattern
        var ts = new TransformStream();
        var readable = ts.readable;
        var writable = ts.writable;
        var writer = writable.getWriter();

        // Read side
        var reader = readable.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    console.log('body:' + chunks.join(''));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();

        // Write side (simulating stream helper)
        writer.write('Hello').then(function() {
            return writer.write(' ');
        }).then(function() {
            return writer.write('World');
        }).then(function() {
            return writer.close();
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("body:Hello World"))
}

// MARK: - Global Web APIs Existence

@Test func globalWebAPIs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        [
            typeof Request === 'function',
            typeof Response === 'function',
            typeof Headers === 'function',
            typeof AbortController === 'function',
            typeof AbortSignal === 'function',
            typeof ReadableStream === 'function',
            typeof WritableStream === 'function',
            typeof TransformStream === 'function',
            typeof CompressionStream === 'function',
            typeof DecompressionStream === 'function',
            typeof DOMException === 'function',
            typeof queueMicrotask === 'function',
            typeof structuredClone === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - CompressionStream / DecompressionStream Tests

@Test func compressionStreamGzipBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue(new TextEncoder().encode('Hello World'));
                c.close();
            }
        });
        var cs = new CompressionStream('gzip');
        var compressed = rs.pipeThrough(cs);
        var reader = compressed.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    var first = chunks[0];
                    console.log('magic:' + (first[0] === 0x1f && first[1] === 0x8b));
                    console.log('hasData:' + (first.length > 0));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("magic:true"))
    #expect(messages.contains("hasData:true"))
}

@Test func compressionStreamDeflateBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue(new TextEncoder().encode('Hello World'));
                c.close();
            }
        });
        var cs = new CompressionStream('deflate');
        var compressed = rs.pipeThrough(cs);
        var reader = compressed.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    console.log('hasData:' + (chunks.length > 0 && chunks[0].length > 0));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("hasData:true"))
}

@Test func decompressionStreamGzipRoundtrip() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var original = 'Hello, CompressionStream roundtrip test!';
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue(new TextEncoder().encode(original));
                c.close();
            }
        });
        var compressed = rs.pipeThrough(new CompressionStream('gzip'));
        var decompressed = compressed.pipeThrough(new DecompressionStream('gzip'));
        var reader = decompressed.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    var totalLen = 0;
                    for (var i = 0; i < chunks.length; i++) totalLen += chunks[i].length;
                    var combined = new Uint8Array(totalLen);
                    var off = 0;
                    for (var i = 0; i < chunks.length; i++) {
                        combined.set(chunks[i], off);
                        off += chunks[i].length;
                    }
                    var result = new TextDecoder().decode(combined);
                    console.log('match:' + (result === original));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("match:true"))
}

@Test func decompressionStreamDeflateRoundtrip() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var original = 'Deflate roundtrip test data 12345';
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue(new TextEncoder().encode(original));
                c.close();
            }
        });
        var compressed = rs.pipeThrough(new CompressionStream('deflate'));
        var decompressed = compressed.pipeThrough(new DecompressionStream('deflate'));
        var reader = decompressed.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    var totalLen = 0;
                    for (var i = 0; i < chunks.length; i++) totalLen += chunks[i].length;
                    var combined = new Uint8Array(totalLen);
                    var off = 0;
                    for (var i = 0; i < chunks.length; i++) {
                        combined.set(chunks[i], off);
                        off += chunks[i].length;
                    }
                    var result = new TextDecoder().decode(combined);
                    console.log('match:' + (result === original));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("match:true"))
}

@Test func compressionStreamInvalidFormat() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var threw = false;
        try { new CompressionStream('brotli'); } catch(e) {
            threw = e instanceof TypeError;
        }
        threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func compressionStreamPipeThrough() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var rs = new ReadableStream({
            start: function(c) {
                c.enqueue(new TextEncoder().encode('pipeThrough test'));
                c.close();
            }
        });
        var result = rs.pipeThrough(new CompressionStream('gzip'));
        console.log('isReadable:' + (result instanceof ReadableStream));
        var reader = result.getReader();
        reader.read().then(function(r) {
            console.log('hasChunk:' + (!r.done && r.value.length > 0));
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("isReadable:true"))
    #expect(messages.contains("hasChunk:true"))
}

@Test func compressionStreamHonoPattern() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var originalBody = 'Hello World! This is a test body for compression.';
        var originalResponse = new Response(originalBody, {
            status: 200,
            headers: { 'Content-Type': 'text/plain' }
        });
        var compressedStream = originalResponse.body.pipeThrough(new CompressionStream('gzip'));
        var compressedResponse = new Response(compressedStream, {
            status: originalResponse.status,
            headers: originalResponse.headers
        });
        var reader = compressedResponse.body.getReader();
        var chunks = [];
        function pump() {
            return reader.read().then(function(r) {
                if (r.done) {
                    var totalLen = 0;
                    for (var i = 0; i < chunks.length; i++) totalLen += chunks[i].length;
                    var combined = new Uint8Array(totalLen);
                    var off = 0;
                    for (var i = 0; i < chunks.length; i++) {
                        combined.set(chunks[i], off);
                        off += chunks[i].length;
                    }
                    console.log('gzipMagic:' + (combined[0] === 0x1f && combined[1] === 0x8b));
                    console.log('compressed:' + (combined.length > 0));
                    return;
                }
                chunks.push(r.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("gzipMagic:true"))
    #expect(messages.contains("compressed:true"))
}

// MARK: - Blob Tests

@Test func blobConstructorString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var blob = new Blob(['hello']);
        blob.size === 5 && blob.type === '';
    """)
    #expect(result?.toBool() == true)
}

@Test func blobConstructorWithType() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var blob = new Blob(['x'], { type: 'text/plain' });
        blob.type === 'text/plain';
    """)
    #expect(result?.toBool() == true)
}

@Test func blobArrayBuffer() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var blob = new Blob(['Hi']);
        blob.arrayBuffer().then(function(ab) {
            var u8 = new Uint8Array(ab);
            console.log('len:' + u8.length);
            console.log('bytes:' + u8[0] + ',' + u8[1]);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("len:2"))
    #expect(messages.contains("bytes:72,105"))
}

@Test func blobText() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var blob = new Blob(['Hello, World!']);
        blob.text().then(function(t) {
            console.log('text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("text:Hello, World!"))
}

@Test func blobMultipleParts() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var blob = new Blob(['ab', 'cd']);
        console.log('size:' + blob.size);
        blob.text().then(function(t) {
            console.log('text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("size:4"))
    #expect(messages.contains("text:abcd"))
}

@Test func blobSlice() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var blob = new Blob(['hello']);
        var sliced = blob.slice(1, 3);
        console.log('size:' + sliced.size);
        sliced.text().then(function(t) {
            console.log('text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("size:2"))
    #expect(messages.contains("text:el"))
}

@Test func blobInstanceof() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var blob = new Blob(['test']);
        blob instanceof Blob;
    """)
    #expect(result?.toBool() == true)
}

@Test func blobFromUint8Array() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var blob = new Blob([new Uint8Array([72, 105])]);
        console.log('size:' + blob.size);
        blob.text().then(function(t) {
            console.log('text:' + t);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("size:2"))
    #expect(messages.contains("text:Hi"))
}

// MARK: - Fetch Tests

private func runEventLoopInBackground(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

@Test func fetchReturnsPromise() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        typeof fetch === 'function' &&
        fetch('http://example.com') instanceof Promise;
    """)
    #expect(result?.toBool() == true)
}

@Test func fetchAbortedSignalRejects() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var ac = new AbortController();
        ac.abort();
        fetch('http://example.com', { signal: ac.signal }).catch(function(err) {
            console.log('name:' + err.name);
            console.log('rejected:true');
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("name:AbortError"))
    #expect(messages.contains("rejected:true"))
}

@Test func fetchWithRequestObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var req = new Request('http://example.com/api', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: '{"key":"value"}'
        });
        var p = fetch(req);
        p instanceof Promise;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func fetchGetFromLocalServer() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ hello: 'world' }));
        });
        server.listen(0, '127.0.0.1', function() {
            var port = server.address().port;
            console.log('listening:' + port);
            fetch('http://127.0.0.1:' + port + '/test').then(function(res) {
                console.log('status:' + res.status);
                console.log('ok:' + res.ok);
                console.log('type:' + res.type);
                return res.json();
            }).then(function(data) {
                console.log('hello:' + data.hello);
                server.close();
            }).catch(function(err) {
                console.log('error:' + err.message);
                server.close();
            });
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.starts(with: "hello:") }) {
            break
        }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("status:200"))
    #expect(messages.contains("ok:true"))
    #expect(messages.contains("type:basic"))
    #expect(messages.contains("hello:world"))
}

@Test(.timeLimit(.minutes(1)))
func fetchPostWithBody() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            var body = '';
            req.on('data', function(chunk) { body += chunk; });
            req.on('end', function() {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ method: req.method, body: body }));
            });
        });
        server.listen(0, '127.0.0.1', function() {
            var port = server.address().port;
            console.log('listening:' + port);
            fetch('http://127.0.0.1:' + port + '/api', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: 'test' })
            }).then(function(res) {
                return res.json();
            }).then(function(data) {
                console.log('method:' + data.method);
                console.log('body:' + data.body);
                server.close();
            }).catch(function(err) {
                console.log('error:' + err.message);
                server.close();
            });
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.starts(with: "body:") }) {
            break
        }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("method:POST"))
    #expect(messages.contains("body:{\"name\":\"test\"}"))
}

@Test(.timeLimit(.minutes(1)))
func fetchResponseHeaders() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, {
                'Content-Type': 'text/plain',
                'X-Custom': 'hello'
            });
            res.end('ok');
        });
        server.listen(0, '127.0.0.1', function() {
            var port = server.address().port;
            console.log('listening:' + port);
            fetch('http://127.0.0.1:' + port).then(function(res) {
                console.log('ct:' + res.headers.get('content-type'));
                console.log('custom:' + res.headers.get('x-custom'));
                console.log('hasHeaders:' + (res.headers instanceof Headers));
                server.close();
            }).catch(function(err) {
                console.log('error:' + err.message);
                server.close();
            });
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.starts(with: "hasHeaders:") }) {
            break
        }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("ct:text/plain"))
    #expect(messages.contains("custom:hello"))
    #expect(messages.contains("hasHeaders:true"))
}

@Test(.timeLimit(.minutes(1)))
func fetchAbortDuringRequest() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            // Delay response to allow abort
            setTimeout(function() {
                res.writeHead(200);
                res.end('late');
            }, 5000);
        });
        server.listen(0, '127.0.0.1', function() {
            var port = server.address().port;
            console.log('listening:' + port);
            var ac = new AbortController();
            fetch('http://127.0.0.1:' + port, { signal: ac.signal }).catch(function(err) {
                console.log('abortName:' + err.name);
                server.close();
            });
            // Abort after a short delay
            setTimeout(function() {
                ac.abort();
            }, 100);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.starts(with: "abortName:") }) {
            break
        }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("abortName:AbortError"))
}

// MARK: - File Tests

@Test func fileBasicProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var f = new File(['hello'], 'test.txt', { type: 'text/plain' });
        var results = [
            f.name === 'test.txt',
            f.type === 'text/plain',
            f.size === 5,
            typeof f.lastModified === 'number',
            f.lastModified > 0,
            f instanceof File,
            f instanceof Blob
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func fileCustomLastModified() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var f = new File(['data'], 'a.bin', { lastModified: 1234567890 });
        f.lastModified === 1234567890;
    """)
    #expect(result?.toBool() == true)
}

@Test func fileInheritsBlob() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var f = new File(['ab', 'cd'], 'multi.txt');
        var results = [
            f.size === 4,
            f instanceof Blob,
            f.name === 'multi.txt'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - FormData Tests

@Test func formDataAppendAndGet() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('key', 'value');
        fd.get('key') === 'value';
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataGetReturnsNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.get('nonexistent') === null;
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataAppendMultiple() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('key', 'a');
        fd.append('key', 'b');
        var all = fd.getAll('key');
        var results = [
            fd.get('key') === 'a',
            all.length === 2,
            all[0] === 'a',
            all[1] === 'b'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataSet() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('key', 'a');
        fd.append('key', 'b');
        fd.set('key', 'c');
        var all = fd.getAll('key');
        var results = [
            all.length === 1,
            all[0] === 'c'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataHasAndDelete() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('key', 'value');
        var had = fd.has('key');
        fd.delete('key');
        var results = [
            had === true,
            fd.has('key') === false,
            fd.get('key') === null
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataForEach() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('a', '1');
        fd.append('b', '2');
        var keys = [];
        var values = [];
        fd.forEach(function(value, key) {
            keys.push(key);
            values.push(value);
        });
        var results = [
            keys.length === 2,
            keys[0] === 'a',
            keys[1] === 'b',
            values[0] === '1',
            values[1] === '2'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataIterable() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        fd.append('x', '10');
        fd.append('y', '20');
        var pairs = [];
        var iter = fd.entries();
        var next = iter.next();
        while (!next.done) {
            pairs.push(next.value[0] + '=' + next.value[1]);
            next = iter.next();
        }
        pairs.join('&') === 'x=10&y=20';
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataAppendFile() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        var f = new File(['content'], 'doc.txt', { type: 'text/plain' });
        fd.append('file', f);
        var got = fd.get('file');
        var results = [
            got instanceof File,
            got.name === 'doc.txt',
            got.type === 'text/plain',
            got.size === 7
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func formDataAppendBlobConvertsToFile() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var fd = new FormData();
        var b = new Blob(['data'], { type: 'application/octet-stream' });
        fd.append('field', b, 'upload.bin');
        var got = fd.get('field');
        var results = [
            got instanceof File,
            got.name === 'upload.bin',
            got.type === 'application/octet-stream'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func requestFormDataUrlEncoded() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var req = new Request('http://localhost/', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'name=hello+world&age=30'
        });
        req.formData().then(function(fd) {
            console.log('name:' + fd.get('name'));
            console.log('age:' + fd.get('age'));
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("name:hello world"))
    #expect(messages.contains("age:30"))
}

@Test func requestFormDataMultipart() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var boundary = '----WebKitFormBoundary7MA4YWxk';
        var body = '------WebKitFormBoundary7MA4YWxk\\r\\n' +
            'Content-Disposition: form-data; name="field1"\\r\\n\\r\\n' +
            'value1\\r\\n' +
            '------WebKitFormBoundary7MA4YWxk\\r\\n' +
            'Content-Disposition: form-data; name="file1"; filename="test.txt"\\r\\n' +
            'Content-Type: text/plain\\r\\n\\r\\n' +
            'file content here\\r\\n' +
            '------WebKitFormBoundary7MA4YWxk--\\r\\n';
        var req = new Request('http://localhost/', {
            method: 'POST',
            headers: { 'Content-Type': 'multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxk' },
            body: body
        });
        req.formData().then(function(fd) {
            console.log('field1:' + fd.get('field1'));
            var file = fd.get('file1');
            console.log('isFile:' + (file instanceof File));
            console.log('fileName:' + file.name);
            console.log('fileType:' + file.type);
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("field1:value1"))
    #expect(messages.contains("isFile:true"))
    #expect(messages.contains("fileName:test.txt"))
    #expect(messages.contains("fileType:text/plain"))
}

@Test func responseFormDataUrlEncoded() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var res = new Response('foo=bar&baz=qux', {
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
        });
        res.formData().then(function(fd) {
            console.log('foo:' + fd.get('foo'));
            console.log('baz:' + fd.get('baz'));
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("foo:bar"))
    #expect(messages.contains("baz:qux"))
}

@Test func formDataGlobalExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var results = [
            typeof FormData === 'function',
            typeof File === 'function'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Cache API Tests

@Test func cacheStorageExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var results = [
            typeof caches === 'object',
            typeof caches.open === 'function',
            typeof caches.has === 'function',
            typeof caches.delete === 'function',
            typeof caches.keys === 'function'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func cacheOpenAndPut() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        caches.open('test').then(function(cache) {
            return cache.put('https://example.com/api', new Response('hello world', {
                status: 200,
                headers: { 'Content-Type': 'text/plain' }
            }));
        }).then(function() {
            return caches.open('test');
        }).then(function(cache) {
            return cache.match('https://example.com/api');
        }).then(function(resp) {
            console.log('status:' + resp.status);
            console.log('ct:' + resp.headers.get('content-type'));
            return resp.text();
        }).then(function(text) {
            console.log('body:' + text);
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("status:200"))
    #expect(messages.contains("ct:text/plain"))
    #expect(messages.contains("body:hello world"))
}

@Test func cacheMatchMiss() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        caches.open('miss-test').then(function(cache) {
            return cache.match('https://example.com/nonexistent');
        }).then(function(resp) {
            console.log('result:' + (resp === undefined ? 'undefined' : 'found'));
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("result:undefined"))
}

@Test func cacheMultipleEntries() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        caches.open('multi').then(function(cache) {
            return cache.put('/a', new Response('alpha'))
                .then(function() { return cache.put('/b', new Response('beta')); })
                .then(function() { return cache; });
        }).then(function(cache) {
            return Promise.all([cache.match('/a'), cache.match('/b')]);
        }).then(function(results) {
            return Promise.all([results[0].text(), results[1].text()]);
        }).then(function(texts) {
            console.log('a:' + texts[0]);
            console.log('b:' + texts[1]);
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("a:alpha"))
    #expect(messages.contains("b:beta"))
}

@Test func cacheDelete() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        caches.open('del').then(function(cache) {
            return cache.put('/x', new Response('data'))
                .then(function() { return cache.delete('/x'); });
        }).then(function(deleted) {
            console.log('deleted:' + deleted);
            return caches.open('del');
        }).then(function(cache) {
            return cache.match('/x');
        }).then(function(resp) {
            console.log('after:' + (resp === undefined ? 'gone' : 'found'));
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("deleted:true"))
    #expect(messages.contains("after:gone"))
}

@Test func cachePutOverwrites() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        caches.open('overwrite').then(function(cache) {
            return cache.put('/key', new Response('old'))
                .then(function() { return cache.put('/key', new Response('new')); })
                .then(function() { return cache; });
        }).then(function(cache) {
            return cache.match('/key');
        }).then(function(resp) {
            return resp.text();
        }).then(function(text) {
            console.log('val:' + text);
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("val:new"))
}

@Test func cacheStorageMultipleCaches() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        Promise.all([caches.open('c1'), caches.open('c2')]).then(function(caches) {
            return caches[0].put('/k', new Response('from-c1'))
                .then(function() { return caches[1].put('/k', new Response('from-c2')); })
                .then(function() { return caches; });
        }).then(function(caches) {
            return Promise.all([caches[0].match('/k'), caches[1].match('/k')]);
        }).then(function(results) {
            return Promise.all([results[0].text(), results[1].text()]);
        }).then(function(texts) {
            console.log('c1:' + texts[0]);
            console.log('c2:' + texts[1]);
        }).catch(function(e) { console.log('ERROR:' + e); });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("c1:from-c1"))
    #expect(messages.contains("c2:from-c2"))
}
