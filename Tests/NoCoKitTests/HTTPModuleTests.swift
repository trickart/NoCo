import Testing
import Foundation
import JavaScriptCore
@testable import NoCoKit

/// Helper: run the event loop on a background thread to avoid blocking cooperative threads.
private func runEventLoopInBackground(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

// MARK: - HTTP Module Tests

@Test func httpRequestReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var req = http.request({ hostname: 'localhost', port: 9999, path: '/test' });
        typeof req === 'object' && typeof req.write === 'function' && typeof req.end === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpRequestOptionsHostname() async throws {
    let runtime = NodeRuntime()
    // request() with options object builds URL from hostname/port/path
    // We can't verify the URL directly without a network call, but we can verify
    // the request object is created without errors
    let result = runtime.evaluate("""
        var http = require('http');
        var req = http.request({
            hostname: 'example.com',
            port: 8080,
            path: '/api/data'
        });
        req !== undefined && req !== null;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpRequestDefaultMethod() async throws {
    let runtime = NodeRuntime()
    // When no method is specified, http.request defaults to GET
    // GET requests have end() called automatically, verify write method exists (default behavior)
    let result = runtime.evaluate("""
        var http = require('http');
        var req = http.request({ hostname: 'localhost', path: '/' });
        typeof req.write === 'function' && typeof req.end === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpRequestCustomHeaders() async throws {
    let runtime = NodeRuntime()
    // Verify that request object is created when headers option is provided
    let result = runtime.evaluate("""
        var http = require('http');
        var req = http.request({
            hostname: 'localhost',
            path: '/',
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Custom': 'test' }
        });
        typeof req.write === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpStatusCodes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var codes = http.STATUS_CODES;
        [
            codes['200'] === 'OK',
            codes['404'] === 'Not Found',
            codes['500'] === 'Internal Server Error',
            codes['301'] === 'Moved Permanently',
            codes['400'] === 'Bad Request',
            codes['403'] === 'Forbidden'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpGetDelegatesToRequest() async throws {
    let runtime = NodeRuntime()
    // http.get() delegates to http.request() and returns a request object
    let result = runtime.evaluate("""
        var http = require('http');
        var req = http.get({ hostname: 'localhost', port: 9999, path: '/test' });
        typeof req === 'object' && typeof req.write === 'function' && typeof req.end === 'function';
    """)
    #expect(result?.toBool() == true)
}

// MARK: - IncomingMessage / ServerResponse Properties

@Test func httpIncomingMessageProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        // Simulate request via _handleRequest
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/test', { host: 'localhost' }, '1.1', '', ['Host', 'localhost']);
        [
            Array.isArray(captured.rawHeaders),
            captured.rawHeaders[0] === 'Host',
            captured.rawHeaders[1] === 'localhost',
            typeof captured.socket === 'object',
            captured.socket.remoteAddress === '127.0.0.1',
            captured.complete === true,
            captured.errored === null,
            typeof captured.destroy === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        var results = [
            res.headersSent === false,
            res.writable === true,
            res.writableFinished === false,
            typeof res.flushHeaders === 'function',
            typeof res.destroy === 'function'
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseDestroy() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        res.on('close', function() { console.log('res-closed'); });
        res.destroy();
    """)
    #expect(messages.contains("res-closed"))

    let result = runtime.evaluate("res.finished === true && res.writable === false")
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func httpServerRawHeaders() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            console.log('rawHeaders:' + JSON.stringify(req.rawHeaders));
            console.log('isArray:' + Array.isArray(req.rawHeaders));
            res.writeHead(200);
            res.end('ok');
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    var request = URLRequest(url: url)
    request.setValue("test-value", forHTTPHeaderField: "X-Test")
    let (_, _) = try await URLSession.shared.data(for: request)

    // Give time for the callback to fire
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(messages.contains(where: { $0.starts(with: "rawHeaders:") }))
    #expect(messages.contains("isArray:true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - IncomingMessage Readable Tests

@Test func httpIncomingMessageIsReadable() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var stream = require('stream');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        captured instanceof stream.Readable;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpIncomingMessageHasReadableMethods() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        [
            typeof captured.push === 'function',
            typeof captured.read === 'function',
            typeof captured.pipe === 'function',
            typeof captured.resume === 'function',
            typeof captured.pause === 'function',
            typeof captured.destroy === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpReadableToWeb() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var stream = require('stream');
        var Readable = stream.Readable;
        var server = http.createServer(function(req, res) {});
        var webStream;
        server.on('request', function(req, res) {
            webStream = Readable.toWeb(req);
        });
        server._handleRequest(1, 'POST', '/api', {}, '1.1', 'hello', []);
        webStream instanceof ReadableStream;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpStreamingBodyChunks() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var chunks = [];
        var ended = false;
        server.on('request', function(req, res) {
            req.on('data', function(chunk) {
                chunks.push(typeof chunk === 'string' ? chunk : chunk.toString());
            });
            req.on('end', function() {
                ended = true;
                console.log('chunks:' + chunks.join(','));
                console.log('rawBody:' + (req.rawBody ? req.rawBody.toString() : 'undefined'));
                console.log('complete:' + req.complete);
            });
        });
        // Use streaming mode (bodyStr = null)
        server._handleRequest(1, 'POST', '/api', {}, '1.1', null, []);
        server._pushBodyChunk(1, 'hello');
        server._pushBodyChunk(1, ' world');
        server._endBody(1);
        console.log('ended:' + ended);
    """)
    #expect(messages.contains("chunks:hello, world"))
    #expect(messages.contains("rawBody:hello world"))
    #expect(messages.contains("complete:true"))
    #expect(messages.contains("ended:true"))
}

@Test func httpStreamingBodyEmpty() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var dataCount = 0;
        var ended = false;
        server.on('request', function(req, res) {
            req.on('data', function() { dataCount++; });
            req.on('end', function() {
                ended = true;
                console.log('dataCount:' + dataCount);
                console.log('rawBody:' + (req.rawBody === undefined ? 'undefined' : 'defined'));
            });
        });
        server._handleRequest(1, 'GET', '/', {}, '1.1', null, []);
        server._endBody(1);
        console.log('ended:' + ended);
    """)
    #expect(messages.contains("dataCount:0"))
    #expect(messages.contains("rawBody:undefined"))
    #expect(messages.contains("ended:true"))
}

// MARK: - rawBody Tests

@Test func httpIncomingMessageRawBody() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'POST', '/api', { 'content-type': 'application/json' }, '1.1', '{"name":"test"}', []);
        [
            captured.rawBody instanceof Buffer,
            captured.rawBody.toString() === '{"name":"test"}'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpIncomingMessageNoRawBodyWhenEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        captured.rawBody === undefined;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - http.createServer Tests

@Test(.timeLimit(.minutes(1)))
func httpCreateServerGET() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('Hello World');
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
        });
    """)

    // Run event loop in background
    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    // Wait for server to start
    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    // Make HTTP request from Swift
    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello World")

    // Stop the event loop
    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerPOST() async throws {
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
                res.end(JSON.stringify({ received: body }));
            });
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    // Wait for server to start
    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    // POST request from Swift
    let url = URL(string: "http://127.0.0.1:\(port)/api")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = "test=hello".data(using: .utf8)

    let (data, response) = try await URLSession.shared.upload(for: request, from: request.httpBody!)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body.contains("\"received\":\"test=hello\""))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerBufferResponse() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            var buf = Buffer.from([72, 101, 108, 108, 111]);
            res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
            res.end(buf);
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello")

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - ServerResponse close Event Tests

@Test func httpServerResponseCloseAfterEnd() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var events = [];
        server.on('request', function(req, res) {
            res.on('finish', function() { events.push('finish:wf=' + res.writableFinished); });
            res.on('close', function() { events.push('close:wf=' + res.writableFinished); });
            res.end('ok');
        });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        console.log(events.join(','));
    """)
    // _handleRequest の finish リスナー (writableFinished=true) がテストの finish リスナーより先に実行される
    #expect(messages.contains("finish:wf=true,close:wf=true"))
}

@Test func httpServerResponseCloseNotEmittedTwice() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        var count = 0;
        res.on('close', function() { count++; });
        res._emitClose();
        res._emitClose();
        res._emitClose();
        console.log('count:' + count);
    """)
    #expect(messages.contains("count:1"))
}

@Test func httpServerResponseDestroyUsesEmitClose() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        var count = 0;
        res.on('close', function() { count++; });
        res.destroy();
        res.destroy();
        console.log('count:' + count);
        console.log('closed:' + res._closed);
    """)
    #expect(messages.contains("count:1"))
    #expect(messages.contains("closed:true"))
}

@Test func httpServerNotifyClosePrematureClose() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var closeWf;
        server.on('request', function(req, res) {
            res.on('close', function() { closeWf = res.writableFinished; });
        });
        server._handleRequest(42, 'GET', '/', {}, '1.1', '', []);
        // Simulate premature close (before res.end)
        server._notifyClose(42);
        console.log('premature:wf=' + closeWf);
    """)
    #expect(messages.contains("premature:wf=false"))
}

@Test func httpServerResponsesCleanup() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        server.on('request', function(req, res) {
            res.end('done');
        });
        server._handleRequest(99, 'GET', '/', {}, '1.1', '', []);
        // After end + close, _responses should be cleaned up
        server._responses[99] === undefined;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func httpServerCloseEventIntegration() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.on('close', function() {
                console.log('close:wf=' + res.writableFinished);
            });
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('Hello');
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse

    #expect(httpResponse.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == "Hello")

    // Give time for close event to fire
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(messages.contains("close:wf=true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - Uint8Array Response Tests

@Test(.timeLimit(.minutes(1)))
func httpCreateServerUint8ArrayResponse() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
            res.end(new Uint8Array([72, 101, 108, 108, 111]));
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello")

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - NIO Chunk Streaming Integration Tests

@Test(.timeLimit(.minutes(1)))
func httpCreateServerStreamingPOST() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            var chunks = [];
            req.on('data', function(chunk) {
                chunks.push(typeof chunk === 'string' ? chunk : chunk.toString());
            });
            req.on('end', function() {
                console.log('complete:' + req.complete);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ chunks: chunks, count: chunks.length }));
            });
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/api")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = #"{"key":"value"}"#
    request.httpBody = payload.data(using: .utf8)

    let (data, response) = try await URLSession.shared.upload(for: request, from: request.httpBody!)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body.contains("\"count\":1"))
    #expect(body.contains("key"))
    #expect(body.contains("value"))
    #expect(messages.contains("complete:true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerStreamingGETNoBody() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            var dataCount = 0;
            req.on('data', function() { dataCount++; });
            req.on('end', function() {
                console.log('dataCount:' + dataCount);
                console.log('complete:' + req.complete);
                res.writeHead(200);
                res.end('ok');
            });
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse

    #expect(httpResponse.statusCode == 200)
    #expect(String(data: data, encoding: .utf8) == "ok")
    #expect(messages.contains("complete:true"))
    #expect(messages.contains("dataCount:0"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerUint8ArrayWriteAndEnd() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.write(new Uint8Array([72, 101]));
            res.write(new Uint8Array([108, 108, 111]));
            res.end();
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello")

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - Backpressure / drain Tests

@Test func httpServerResponseWritableHighWaterMark() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        res.writableHighWaterMark === 16384 && res._writableNeedDrain === false;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerEmitDrainOnlyWhenNeeded() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var drainCount = 0;
        server.on('request', function(req, res) {
            res.on('drain', function() { drainCount++; });
        });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        // _emitDrain should NOT fire when _writableNeedDrain is false
        server._emitDrain(1);
        console.log('drain-no-need:' + drainCount);
        // Set _writableNeedDrain = true, then _emitDrain should fire
        server._responses[1]._writableNeedDrain = true;
        server._emitDrain(1);
        console.log('drain-needed:' + drainCount);
        // After firing, _writableNeedDrain should be reset
        console.log('reset:' + server._responses[1]._writableNeedDrain);
    """)
    #expect(messages.contains("drain-no-need:0"))
    #expect(messages.contains("drain-needed:1"))
    #expect(messages.contains("reset:false"))
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerChunkedStreaming() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            for (var i = 0; i < 5; i++) {
                res.write('chunk' + i + '\\n');
            }
            res.end('done\\n');
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    for i in 0..<5 {
        #expect(body.contains("chunk\(i)"))
    }
    #expect(body.contains("done"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpCreateServerEndWithDataContentLength() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('Hello World');
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    let url = URL(string: "http://127.0.0.1:\(port)/test")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello World")
    let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length")
    #expect(contentLength == "11")

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - Socket EventEmitter compatibility

@Test func httpIncomingMessageSocketIsEventEmitter() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        var sock = captured.socket;
        [
            typeof sock.on === 'function',
            typeof sock.emit === 'function',
            typeof sock.removeListener === 'function',
            typeof sock.once === 'function',
            sock.readable === true,
            sock.writable === true,
            typeof sock.destroy === 'function',
            typeof sock.setTimeout === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpIncomingMessageSocketEventListeners() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        var sock = captured.socket;
        sock.on('close', function() { console.log('socket-closed'); });
        sock.emit('close');
    """)
    #expect(messages.contains("socket-closed"))
}

@Test func httpIncomingMessageConnectionAlias() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        captured.connection === captured.socket;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseHasSocket() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedReq, capturedRes;
        server.on('request', function(req, res) { capturedReq = req; capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        [
            capturedRes.socket === capturedReq.socket,
            capturedRes.connection === capturedReq.socket,
            typeof capturedRes.socket.on === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseGetHeaderNames() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.setHeader('Content-Type', 'text/html');
        capturedRes.setHeader('X-Custom', 'val');
        var names = capturedRes.getHeaderNames();
        [
            Array.isArray(names),
            names.length === 2,
            names.indexOf('content-type') !== -1,
            names.indexOf('x-custom') !== -1
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseGetHeaders() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.setHeader('Content-Type', 'application/json');
        capturedRes.setHeader('X-Foo', 'bar');
        var headers = capturedRes.getHeaders();
        [
            typeof headers === 'object',
            headers['content-type'] === 'application/json',
            headers['x-foo'] === 'bar',
            Object.keys(headers).length === 2
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseHasHeader() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.setHeader('Content-Type', 'text/plain');
        [
            capturedRes.hasHeader('Content-Type') === true,
            capturedRes.hasHeader('content-type') === true,
            capturedRes.hasHeader('X-Missing') === false
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseSetHeaderReturnsThis() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.setHeader('X-A', '1') === capturedRes;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseGetHeaderNamesEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        var names = capturedRes.getHeaderNames();
        Array.isArray(names) && names.length === 0;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseGetHeadersIsCopy() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedRes;
        server.on('request', function(req, res) { capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.setHeader('X-Test', 'original');
        var headers = capturedRes.getHeaders();
        headers['x-test'] = 'modified';
        capturedRes.getHeader('X-Test') === 'original';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpStatusCodesCompleteness() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var codes = [100, 101, 200, 201, 202, 204, 206, 301, 302, 303, 304, 307, 308,
                     400, 401, 403, 404, 405, 408, 409, 413, 416, 422, 429,
                     500, 501, 502, 503, 504];
        codes.every(function(c) { return typeof http.STATUS_CODES[c] === 'string'; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Express Compat Phase 3 Tests

@Test func httpIncomingMessageHttpVersionParts() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        [
            captured.httpVersion === '1.1',
            captured.httpVersionMajor === 1,
            captured.httpVersionMinor === 1
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpIncomingMessageHttpVersionParts10() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.0', '', []);
        [
            captured.httpVersion === '1.0',
            captured.httpVersionMajor === 1,
            captured.httpVersionMinor === 0
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseStatusMessage() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        var init = res.statusMessage === 'OK';
        res.writeHead(404, 'Not Found', {});
        var after = res.statusMessage === 'Not Found' && res.statusCode === 404;
        init && after;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseStatusMessageWithObjectArg() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.statusMessage === 'OK';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpIncomingMessageUpgradeProperty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var captured;
        server.on('request', function(req, res) { captured = req; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        captured.upgrade === false;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseSocketInit() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var res = new http.ServerResponse(1);
        res.socket === null && res.connection === null;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpServerResponseSocketSetInHandleRequest() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http = require('http');
        var server = http.createServer(function(req, res) {});
        var capturedReq, capturedRes;
        server.on('request', function(req, res) { capturedReq = req; capturedRes = res; });
        server._handleRequest(1, 'GET', '/', {}, '1.1', '', []);
        capturedRes.socket === capturedReq.socket && capturedRes.connection === capturedReq.socket && capturedRes.socket !== null;
    """)
    #expect(result?.toBool() == true)
}

@Test func httpStreamPipeErrorPropagation() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var stream = require('stream');
        var source = new stream.Readable({ read: function() {} });
        var dest = new stream.Writable({
            write: function(chunk, enc, cb) { cb(); }
        });
        var destroyCalled = false;
        var origDestroy = dest.destroy.bind(dest);
        dest.destroy = function(err) {
            destroyCalled = true;
            console.log('destroy-err:' + err.message);
        };
        dest.on('error', function() {}); // prevent uncaught error
        source.pipe(dest);
        source.emit('error', new Error('test-error'));
        console.log('destroyCalled:' + destroyCalled);
    """)
    #expect(messages.contains("destroyCalled:true"))
    #expect(messages.contains("destroy-err:test-error"))
}
