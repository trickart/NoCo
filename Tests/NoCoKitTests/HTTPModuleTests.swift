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
