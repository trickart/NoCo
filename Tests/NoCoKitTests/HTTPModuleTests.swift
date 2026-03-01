import Testing
import JavaScriptCore
@testable import NoCoKit

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
