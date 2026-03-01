import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Integration Tests

@Test func multiModuleIntegration() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var path = require('path');
        var crypto = require('crypto');

        var filePath = path.join('/tmp', 'test', 'file.txt');
        var hash = crypto.createHash('sha256').update(filePath).digest('hex');
        var ext = path.extname(filePath);

        ext + ':' + hash.substring(0, 8);
    """)
    let str = result?.toString() ?? ""
    #expect(str.hasPrefix(".txt:"))
    #expect(str.count > 5)
}

// MARK: - Integration Edge Cases

@Test func bufferCryptoIntegration() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var buf = Buffer.from('hello world');
        crypto.createHash('sha256').update(buf).digest('hex');
    """)
    // SHA-256 of "hello world" (when read from Buffer bytes)
    let hex = result?.toString() ?? ""
    #expect(hex.count == 64)
}

@Test func fsPathIntegration() async throws {
    let runtime = NodeRuntime()
    let tmpDir = NSTemporaryDirectory()
    let filename = "nodecore_integration_\(UUID().uuidString).txt"
    let expectedPath = tmpDir + filename
    defer {
        try? FileManager.default.removeItem(atPath: expectedPath)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        var path = require('path');
        var fullPath = path.join('\(tmpDir)', '\(filename)');
        fs.writeFileSync(fullPath, 'integration test');
        fs.readFileSync(fullPath, 'utf8');
    """)
    #expect(result?.toString() == "integration test")
}

@Test func eventEmitterStreamIntegration() async throws {
    let runtime = NodeRuntime()

    runtime.evaluate("""
        var stream = require('stream');
        var r = new stream.Readable();
        var dataChunks = [];
        r.on('data', function(chunk) { dataChunks.push(chunk); });
        r.push('chunk1');
        r.push('chunk2');
    """)

    let chunks = runtime.evaluate("dataChunks.join(',')")
    #expect(chunks?.toString() == "chunk1,chunk2")

    // Verify EventEmitter listenerCount works on streams
    let count = runtime.evaluate("r.listenerCount('data')")
    #expect(count?.toInt32() == 1)
}

// MARK: - Integration Additional Tests

@Test func integrationTimerWithNextTick() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var order = [];
        setTimeout(function() { order.push('timeout'); console.log(order.join(',')); }, 10);
        process.nextTick(function() { order.push('nextTick'); });
    """)
    runtime.runEventLoop(timeout: 1)

    // nextTick should fire before setTimeout
    #expect(messages.contains("nextTick,timeout"))
}

@Test func integrationStreamPipeToBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stream = require('stream');
        var chunks = [];
        var r = new stream.Readable();
        var w = new stream.Writable({
            write: function(chunk, enc, cb) {
                chunks.push(chunk);
                cb();
            }
        });
        r.pipe(w);
        r.push('part1');
        r.push('part2');
        r.push('part3');
        chunks.join('+');
    """)
    #expect(result?.toString() == "part1+part2+part3")
}

@Test func integrationRequireAndUseModule() async throws {
    let runtime = NodeRuntime()
    let fixturesDir = (#filePath as NSString).deletingLastPathComponent + "/Fixtures"
    let result = runtime.evaluate("""
        var math = require('\(fixturesDir)/math.js');
        math.add(3, 4) + ':' + math.multiply(5, 6);
    """)
    #expect(result?.toString() == "7:30")
}

@Test func integrationConsoleFromModule() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let fixturesDir = (#filePath as NSString).deletingLastPathComponent + "/Fixtures"
    runtime.evaluate("require('\(fixturesDir)/hello.js')")

    #expect(messages.contains("Hello from NoCo"))
}

@Test func integrationProcessExitStopsTimers() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Use process.nextTick to call exit before the timer fires
    runtime.evaluate("""
        setTimeout(function() { console.log('should not run'); }, 500);
        process.nextTick(function() { process.exit(0); });
    """)
    runtime.runEventLoop(timeout: 0.3)

    // process.exit() stops the event loop, so the timer should not fire
    let hasExitMsg = messages.contains(where: { $0.contains("process.exit") })
    #expect(hasExitMsg)
    #expect(!messages.contains("should not run"))
}

@Test func integrationErrorPropagation() async throws {
    let runtime = NodeRuntime()
    var errorMessages: [String] = []
    runtime.consoleHandler = { level, msg in
        if level == .error {
            errorMessages.append(msg)
        }
    }

    runtime.evaluate("throw new Error('test exception');")

    #expect(errorMessages.contains(where: { $0.contains("test exception") }))
}
