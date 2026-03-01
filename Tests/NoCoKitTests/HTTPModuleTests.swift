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
