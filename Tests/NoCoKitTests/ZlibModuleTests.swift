import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Zlib Constants Tests

@Test func zlibConstants() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        JSON.stringify({
            Z_NO_FLUSH: zlib.Z_NO_FLUSH,
            Z_FINISH: zlib.Z_FINISH,
            Z_OK: zlib.Z_OK,
            Z_DEFAULT_COMPRESSION: zlib.Z_DEFAULT_COMPRESSION,
            Z_BEST_SPEED: zlib.Z_BEST_SPEED,
            Z_BEST_COMPRESSION: zlib.Z_BEST_COMPRESSION,
            Z_NO_COMPRESSION: zlib.Z_NO_COMPRESSION,
            Z_DEFAULT_STRATEGY: zlib.Z_DEFAULT_STRATEGY,
            Z_DEFAULT_CHUNK: zlib.Z_DEFAULT_CHUNK,
            Z_MAX_WINDOWBITS: zlib.Z_MAX_WINDOWBITS,
            Z_DEFAULT_MEMLEVEL: zlib.Z_DEFAULT_MEMLEVEL,
            Z_STREAM_ERROR: zlib.Z_STREAM_ERROR,
            Z_DATA_ERROR: zlib.Z_DATA_ERROR
        })
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"Z_NO_FLUSH\":0"))
    #expect(json.contains("\"Z_FINISH\":4"))
    #expect(json.contains("\"Z_OK\":0"))
    #expect(json.contains("\"Z_DEFAULT_COMPRESSION\":-1"))
    #expect(json.contains("\"Z_BEST_SPEED\":1"))
    #expect(json.contains("\"Z_BEST_COMPRESSION\":9"))
    #expect(json.contains("\"Z_NO_COMPRESSION\":0"))
    #expect(json.contains("\"Z_DEFAULT_STRATEGY\":0"))
    #expect(json.contains("\"Z_DEFAULT_CHUNK\":16384"))
    #expect(json.contains("\"Z_MAX_WINDOWBITS\":15"))
    #expect(json.contains("\"Z_DEFAULT_MEMLEVEL\":8"))
    #expect(json.contains("\"Z_STREAM_ERROR\":-2"))
    #expect(json.contains("\"Z_DATA_ERROR\":-3"))
}

// MARK: - deflateSync / inflateSync Tests

@Test func deflateSyncBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        var buf = Buffer.from('hello world');
        var compressed = zlib.deflateSync(buf);
        Buffer.isBuffer(compressed) ? 'true' : 'false'
    """)
    #expect(result?.toString() == "true")
}

@Test func deflateSyncAndInflateSync() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        var original = 'hello world';
        var compressed = zlib.deflateSync(Buffer.from(original));
        var decompressed = zlib.inflateSync(compressed);
        decompressed.toString()
    """)
    #expect(result?.toString() == "hello world")
}

@Test func deflateSyncLargeData() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        var original = 'abcdefghij'.repeat(1000);
        var compressed = zlib.deflateSync(Buffer.from(original));
        var decompressed = zlib.inflateSync(compressed);
        var result = decompressed.toString();
        (result === original && result.length === 10000) ? 'ok' : 'fail: ' + result.length
    """)
    #expect(result?.toString() == "ok")
}

@Test func inflateSyncInvalidInput() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var zlib = require('zlib');
        try {
            zlib.inflateSync(Buffer.from([0x00, 0x01, 0x02, 0x03]));
            console.log('no-error');
        } catch(e) {
            console.log('error:' + e.message);
        }
    """)
    #expect(messages.contains(where: { $0.1.contains("error:") }))
}

@Test func deflateSyncInvalidInput() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var zlib = require('zlib');
        try {
            zlib.deflateSync('not a buffer');
            console.log('no-error');
        } catch(e) {
            console.log('error:' + e.message);
        }
    """)
    #expect(messages.contains(where: { $0.1.contains("error:") }))
}

// MARK: - createDeflate / createInflate Stream Tests

@Test func createDeflateStream() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var zlib = require('zlib');
        var deflate = zlib.createDeflate();
        var chunks = [];
        deflate.on('data', function(chunk) {
            chunks.push(chunk);
        });
        deflate.on('end', function() {
            var totalLen = 0;
            for (var i = 0; i < chunks.length; i++) {
                totalLen += chunks[i].length;
            }
            console.log('compressed-length:' + totalLen);
        });
        deflate.write(Buffer.from('hello world'));
        deflate.end();
    """)
    #expect(messages.contains(where: { $0.1.hasPrefix("compressed-length:") }))
    let lenMsg = messages.first(where: { $0.1.hasPrefix("compressed-length:") })
    if let lenStr = lenMsg?.1.split(separator: ":").last, let len = Int(lenStr) {
        #expect(len > 0)
    }
}

@Test func createInflateStream() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var zlib = require('zlib');
        var compressed = zlib.deflateSync(Buffer.from('hello world'));
        var inflate = zlib.createInflate();
        inflate.on('data', function(chunk) {
            console.log('result:' + chunk.toString());
        });
        inflate.on('end', function() {
            console.log('end');
        });
        inflate.write(compressed);
        inflate.end();
    """)
    #expect(messages.contains(where: { $0.1 == "result:hello world" }))
}

// MARK: - Inflate / Deflate Constructor Tests

@Test func inflateConstructor() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        var inf = new zlib.Inflate();
        JSON.stringify({
            isObject: typeof inf === 'object',
            hasHandle: typeof inf._handle === 'object',
            hasClose: typeof inf.close === 'function',
            hasChunkSize: typeof inf._chunkSize === 'number',
            chunkSize: inf._chunkSize
        })
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isObject\":true"))
    #expect(json.contains("\"hasHandle\":true"))
    #expect(json.contains("\"hasClose\":true"))
    #expect(json.contains("\"hasChunkSize\":true"))
    #expect(json.contains("\"chunkSize\":16384"))
}

@Test func deflateConstructor() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        var def = new zlib.Deflate();
        JSON.stringify({
            isObject: typeof def === 'object',
            hasChunkSize: typeof def._chunkSize === 'number',
            chunkSize: def._chunkSize,
            level: def._level,
            strategy: def._strategy
        })
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isObject\":true"))
    #expect(json.contains("\"hasChunkSize\":true"))
    #expect(json.contains("\"chunkSize\":16384"))
    #expect(json.contains("\"level\":-1"))
    #expect(json.contains("\"strategy\":0"))
}

// MARK: - require Test

@Test func zlibRequire() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var zlib = require('zlib');
        typeof zlib === 'object' && typeof zlib.deflateSync === 'function' && typeof zlib.inflateSync === 'function' ? 'ok' : 'fail'
    """)
    #expect(result?.toString() == "ok")
}
