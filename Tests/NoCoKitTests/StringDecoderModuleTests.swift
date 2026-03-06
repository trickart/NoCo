import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - StringDecoder Basic Tests

@Test func stringDecoderDefaultEncoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder();
        decoder.encoding;
    """)
    #expect(result?.toString() == "utf8")
}

@Test func stringDecoderExplicitUtf8() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.encoding;
    """)
    #expect(result?.toString() == "utf8")
}

@Test func stringDecoderUtf8Dash() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf-8');
        decoder.encoding;
    """)
    #expect(result?.toString() == "utf8")
}

@Test func stringDecoderEncodingCaseInsensitive() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('UTF-8');
        decoder.encoding;
    """)
    #expect(result?.toString() == "utf8")
}

@Test func stringDecoderHexEncoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('hex');
        decoder.encoding;
    """)
    #expect(result?.toString() == "hex")
}

@Test func stringDecoderBase64Encoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('Base64');
        decoder.encoding;
    """)
    #expect(result?.toString() == "base64")
}

// MARK: - StringDecoder write() Tests

@Test func stringDecoderWriteBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(Buffer.from('hello'));
    """)
    #expect(result?.toString() == "hello")
}

@Test func stringDecoderWriteString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write('hello world');
    """)
    #expect(result?.toString() == "hello world")
}

@Test func stringDecoderWriteEmptyBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(Buffer.alloc(0));
    """)
    #expect(result?.toString() == "")
}

@Test func stringDecoderWriteNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(null);
    """)
    #expect(result?.toString() == "")
}

@Test func stringDecoderWriteUndefined() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(undefined);
    """)
    #expect(result?.toString() == "")
}

@Test func stringDecoderWriteMultipleChunks() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        var r1 = decoder.write(Buffer.from('hello'));
        var r2 = decoder.write(Buffer.from(' world'));
        r1 + r2;
    """)
    #expect(result?.toString() == "hello world")
}

@Test func stringDecoderWriteHexBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('hex');
        decoder.write(Buffer.from('hello'));
    """)
    #expect(result?.toString() == "68656c6c6f")
}

@Test func stringDecoderWriteBase64Buffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('base64');
        decoder.write(Buffer.from('hello'));
    """)
    #expect(result?.toString() == "aGVsbG8=")
}

// MARK: - StringDecoder end() Tests

@Test func stringDecoderEndWithBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.end(Buffer.from('final'));
    """)
    #expect(result?.toString() == "final")
}

@Test func stringDecoderEndWithoutBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.end();
    """)
    #expect(result?.toString() == "")
}

@Test func stringDecoderEndWithNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.end(null);
    """)
    #expect(result?.toString() == "")
}

@Test func stringDecoderEndWithEmptyBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.end(Buffer.alloc(0));
    """)
    #expect(result?.toString() == "")
}

// MARK: - StringDecoder write() + end() Combined Tests

@Test func stringDecoderWriteThenEnd() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        var r1 = decoder.write(Buffer.from('hello'));
        var r2 = decoder.end(Buffer.from(' world'));
        r1 + r2;
    """)
    #expect(result?.toString() == "hello world")
}

@Test func stringDecoderWriteThenEndEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        var r1 = decoder.write(Buffer.from('data'));
        var r2 = decoder.end();
        r1 + '|' + r2;
    """)
    #expect(result?.toString() == "data|")
}

// MARK: - StringDecoder with node: prefix

@Test func stringDecoderNodePrefix() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('node:string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(Buffer.from('hello'));
    """)
    #expect(result?.toString() == "hello")
}

// MARK: - StringDecoder Japanese text

@Test func stringDecoderJapaneseText() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder('utf8');
        decoder.write(Buffer.from('こんにちは'));
    """)
    #expect(result?.toString() == "こんにちは")
}

// MARK: - StringDecoder instanceof / type checks

@Test func stringDecoderIsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder();
        typeof decoder === 'object' && decoder !== null;
    """)
    #expect(result?.toBool() == true)
}

@Test func stringDecoderHasWriteMethod() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder();
        typeof decoder.write === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func stringDecoderHasEndMethod() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sd = require('string_decoder');
        var decoder = new sd.StringDecoder();
        typeof decoder.end === 'function';
    """)
    #expect(result?.toBool() == true)
}
