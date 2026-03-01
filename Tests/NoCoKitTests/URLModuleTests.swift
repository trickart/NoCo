import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - URL Module Tests

@Test func urlParse() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var u = require('url').parse('http://example.com:8080/path?query=1#hash');
        u.protocol + '|' + u.hostname + '|' + u.port + '|' + u.pathname;
    """)
    #expect(result?.toString() == "http:|example.com|8080|/path")
}

@Test func urlFormat() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('url').format({
            protocol: 'https:',
            slashes: true,
            hostname: 'example.com',
            pathname: '/path'
        });
    """)
    #expect(result?.toString() == "https://example.com/path")
}

// MARK: - URL Module Edge Cases

@Test func urlParseQueryString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var u = require('url').parse('http://example.com/path?name=value&foo=bar', true);
        u.query.name + ':' + u.query.foo;
    """)
    #expect(result?.toString() == "value:bar")
}

@Test func urlParseAuth() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var u = require('url').parse('http://user:pass@example.com/path');
        u.auth;
    """)
    #expect(result?.toString() == "user:pass")
}

@Test func urlResolve() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('url').resolve('http://example.com/a/b', '/c/d')
    """)
    #expect(result?.toString() == "http://example.com/c/d")
}

@Test func urlFormatWithPort() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('url').format({
            protocol: 'http:',
            slashes: true,
            hostname: 'example.com',
            port: '3000',
            pathname: '/api'
        });
    """)
    #expect(result?.toString() == "http://example.com:3000/api")
}
