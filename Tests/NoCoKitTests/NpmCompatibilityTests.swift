import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - npm Package Compatibility Tests

private func fixturesPath() -> String {
    let testFile = #filePath
    return (testFile as NSString).deletingLastPathComponent + "/Fixtures"
}

/// Execute a JS script as if it were a file inside the Fixtures directory,
/// so that node_modules resolution works relative to Fixtures/.
private func evaluateInFixtures(_ runtime: NodeRuntime, script: String) -> JSValue {
    let dir = fixturesPath()
    let tmp = dir + "/__test_\(UUID().uuidString).js"
    try! script.write(toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    return runtime.moduleLoader.loadFile(at: tmp)
}

// MARK: - is-number

@Test func npmIsNumber() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var isNumber = require('is-number');
        var results = [
            isNumber(5),
            isNumber('5'),
            isNumber(Infinity),
            isNumber(NaN),
            isNumber('abc'),
            isNumber(null),
            isNumber(undefined),
            isNumber(''),
            isNumber(0),
            isNumber(1.1),
            isNumber('1.1'),
            isNumber(-1),
            isNumber('-1'),
            isNumber('0x1A'),
        ];
        module.exports = results.map(function(v) { return v ? 'T' : 'F'; }).join(',');
        """)
    #expect(result.toString() == "T,T,F,F,F,F,F,F,T,T,T,T,T,T")
}

// MARK: - escape-html

@Test func npmEscapeHtml() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var escapeHtml = require('escape-html');
        module.exports = [
            escapeHtml('<script>alert("xss")</script>'),
            escapeHtml('Hello & "World"'),
            escapeHtml("it's a test"),
            escapeHtml('no special chars'),
        ].join('|');
        """)
    #expect(result.toString() == "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;|Hello &amp; &quot;World&quot;|it&#39;s a test|no special chars")
}

// MARK: - ms

@Test func npmMsParse() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var ms = require('ms');
        module.exports = [
            ms('2 days'),
            ms('1d'),
            ms('10h'),
            ms('2.5 hrs'),
            ms('2h'),
            ms('1m'),
            ms('5s'),
            ms('1y'),
            ms('100'),
            ms('1ms'),
        ].join(',');
        """)
    #expect(result.toString() == "172800000,86400000,36000000,9000000,7200000,60000,5000,31557600000,100,1")
}

@Test func npmMsFormat() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var ms = require('ms');
        module.exports = [
            ms(60000),
            ms(2 * 60000),
            ms(-3 * 60000),
            ms(ms('10 hours')),
        ].join(',');
        """)
    #expect(result.toString() == "1m,2m,-3m,10h")
}

// MARK: - cookie

@Test func npmCookieParse() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var cookie = require('cookie');
        var obj = cookie.parse('foo=bar; equation=a%20%2B%20b; hello=world');
        module.exports = obj.foo + '|' + obj.equation + '|' + obj.hello;
        """)
    #expect(result.toString() == "bar|a + b|world")
}

@Test func npmCookieSerialize() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var cookie = require('cookie');
        module.exports = cookie.serialize('session', 'abc123', {
            httpOnly: true,
            maxAge: 60 * 60 * 24
        });
        """)
    #expect(result.toString() == "session=abc123; Max-Age=86400; HttpOnly")
}

// MARK: - inherits

@Test func npmInherits() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var inherits = require('inherits');
        function Animal(name) { this.name = name; }
        Animal.prototype.speak = function() { return this.name + ' speaks'; };
        function Dog(name) { Animal.call(this, name); }
        inherits(Dog, Animal);
        Dog.prototype.bark = function() { return this.name + ' barks'; };

        var d = new Dog('Rex');
        module.exports = [
            d.speak(),
            d.bark(),
            d instanceof Dog,
            d instanceof Animal,
            Dog.super_ === Animal,
        ].join('|');
        """)
    #expect(result.toString() == "Rex speaks|Rex barks|true|true|true")
}

// MARK: - safe-buffer

@Test func npmSafeBuffer() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var SafeBuffer = require('safe-buffer').Buffer;
        var buf = SafeBuffer.from('hello', 'utf8');
        module.exports = [
            typeof SafeBuffer.from,
            typeof SafeBuffer.alloc,
            typeof SafeBuffer.allocUnsafe,
            buf.toString('hex'),
        ].join('|');
        """)
    #expect(result.toString() == "function|function|function|68656c6c6f")
}

// MARK: - string_decoder (transitive dependency: string_decoder → safe-buffer → buffer builtin)

@Test func npmStringDecoder() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var StringDecoder = require('string_decoder').StringDecoder;
        module.exports = typeof StringDecoder;
        """)
    #expect(result.toString() == "function")
}

@Test func stringDecoderWrite() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var StringDecoder = require('string_decoder').StringDecoder;
        var decoder = new StringDecoder('utf8');
        module.exports = decoder.write('hello');
        """)
    #expect(result.toString() == "hello")
}

// MARK: - iconv-lite (real package via safer-buffer)

@Test func npmIconvLiteEncode() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var iconv = require('iconv-lite');
        var buf = iconv.encode('Hello', 'utf8');
        module.exports = buf.toString('hex');
        """)
    #expect(result.toString() == "48656c6c6f")
}

@Test func npmIconvLiteDecode() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var iconv = require('iconv-lite');
        var buf = Buffer.from('48656c6c6f', 'hex');
        module.exports = iconv.decode(buf, 'utf8');
        """)
    #expect(result.toString() == "Hello")
}

@Test func npmIconvLiteEncodingExists() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var iconv = require('iconv-lite');
        module.exports = [
            iconv.encodingExists('utf8'),
            iconv.encodingExists('ascii'),
        ].map(function(v) { return v ? 'T' : 'F'; }).join(',');
        """)
    #expect(result.toString() == "T,T")
}

// MARK: - pngjs (real package with zlib dependency)

@Test func npmPngjsSyncRoundtrip() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var PNG = require('pngjs').PNG;

        // Create a 1x1 red pixel PNG
        var png = new PNG({ width: 1, height: 1 });
        png.data = Buffer.alloc(4);
        png.data[0] = 255; // R
        png.data[1] = 0;   // G
        png.data[2] = 0;   // B
        png.data[3] = 255; // A

        var buf = PNG.sync.write(png);

        // Parse it back
        var parsed = PNG.sync.read(buf);
        module.exports = [
            parsed.width,
            parsed.height,
            parsed.data[0],
            parsed.data[1],
            parsed.data[2],
            parsed.data[3]
        ].join(',');
        """)
    #expect(result.toString() == "1,1,255,0,0,255")
}
