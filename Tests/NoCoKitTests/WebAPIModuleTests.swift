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
        req.body === '{"key":"value"}';
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
        cloned.body === 'hello' &&
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
        res.body === 'Hello' &&
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
            jsonRes.body === '{"key":"value"}',
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
            typeof DOMException === 'function',
            typeof queueMicrotask === 'function',
            typeof structuredClone === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}
