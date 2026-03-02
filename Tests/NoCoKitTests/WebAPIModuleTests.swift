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
            console.log('value:' + r.value);
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
                chunks.push(result.value);
                return pump();
            });
        }
        pump();
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("body:{\"cors\":true}"))
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
