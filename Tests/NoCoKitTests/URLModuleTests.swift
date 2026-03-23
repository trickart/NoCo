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

// MARK: - URL.canParse

@Test func urlCanParseValid() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("URL.canParse('https://example.com/path')")
    #expect(result?.toBool() == true)
}

@Test func urlCanParseConsistentWithConstructor() async throws {
    // canParse should return false when URL constructor would throw
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var threw = false;
        try { new URL(''); } catch(e) { threw = true; }
        URL.canParse('') === !threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func urlCanParseWithBase() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("URL.canParse('/path', 'https://example.com')")
    #expect(result?.toBool() == true)
}

@Test func urlCanParseFromUrlModule() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('url').URL.canParse('https://example.com')")
    #expect(result?.toBool() == true)
}

// MARK: - url module URL/URLSearchParams exports

@Test func urlModuleExportsURL() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var URL = require('url').URL;
        var u = new URL('https://example.com:8080/path?q=1');
        u.hostname + ':' + u.port + ':' + u.pathname;
    """)
    #expect(result?.toString() == "example.com:8080:/path")
}

@Test func urlModuleExportsURLSearchParams() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var URLSearchParams = require('url').URLSearchParams;
        var p = new URLSearchParams('a=1&b=2');
        p.get('a') + ':' + p.get('b');
    """)
    #expect(result?.toString() == "1:2")
}

@Test func urlModuleURLMatchesGlobal() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('url').URL === URL")
    #expect(result?.toBool() == true)
}

@Test func urlModuleURLSearchParamsMatchesGlobal() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('url').URLSearchParams === URLSearchParams")
    #expect(result?.toBool() == true)
}
