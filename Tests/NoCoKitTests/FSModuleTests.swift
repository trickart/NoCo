import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - FS Module Tests

@Test func fsWriteAndReadSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_\(UUID().uuidString).txt"

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'hello nodecore');
        fs.readFileSync('\(tmpPath)', 'utf8');
    """)
    #expect(result?.toString() == "hello nodecore")

    // Cleanup
    try? FileManager.default.removeItem(atPath: tmpPath)
}

@Test func fsExistsSync() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("require('fs').existsSync('/tmp')")
    let r2 = runtime.evaluate("require('fs').existsSync('/nonexistent_path_xyz')")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == false)
}

@Test func fsStatSync() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var stat = require('fs').statSync('/tmp');
        stat.isDirectory();
    """)
    #expect(result?.toBool() == true)
}

@Test func fsMkdirAndReaddirSync() async throws {
    let runtime = NodeRuntime()
    let tmpDir = NSTemporaryDirectory() + "nodecore_test_dir_\(UUID().uuidString)"

    runtime.evaluate("""
        var fs = require('fs');
        fs.mkdirSync('\(tmpDir)');
        fs.writeFileSync('\(tmpDir)/test.txt', 'content');
    """)

    let result = runtime.evaluate("require('fs').readdirSync('\(tmpDir)')")
    let items = result?.toArray() as? [String]
    #expect(items?.contains("test.txt") == true)

    // Cleanup
    try? FileManager.default.removeItem(atPath: tmpDir)
}

// MARK: - FS Module Edge Cases

@Test func fsUnlinkSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_unlink_\(UUID().uuidString).txt"

    runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'temp');
    """)
    #expect(FileManager.default.fileExists(atPath: tmpPath))

    runtime.evaluate("require('fs').unlinkSync('\(tmpPath)')")
    #expect(!FileManager.default.fileExists(atPath: tmpPath))
}

@Test func fsRenameSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath1 = NSTemporaryDirectory() + "nodecore_test_rename_src_\(UUID().uuidString).txt"
    let tmpPath2 = NSTemporaryDirectory() + "nodecore_test_rename_dst_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath1)
        try? FileManager.default.removeItem(atPath: tmpPath2)
    }

    runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath1)', 'content');
        fs.renameSync('\(tmpPath1)', '\(tmpPath2)');
    """)
    #expect(!FileManager.default.fileExists(atPath: tmpPath1))
    #expect(FileManager.default.fileExists(atPath: tmpPath2))
}

@Test func fsCopyFileSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath1 = NSTemporaryDirectory() + "nodecore_test_copy_src_\(UUID().uuidString).txt"
    let tmpPath2 = NSTemporaryDirectory() + "nodecore_test_copy_dst_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath1)
        try? FileManager.default.removeItem(atPath: tmpPath2)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath1)', 'copy me');
        fs.copyFileSync('\(tmpPath1)', '\(tmpPath2)');
        fs.readFileSync('\(tmpPath2)', 'utf8');
    """)
    #expect(result?.toString() == "copy me")
}

@Test func fsAppendFileSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_append_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'hello');
        fs.appendFileSync('\(tmpPath)', ' world');
        fs.readFileSync('\(tmpPath)', 'utf8');
    """)
    #expect(result?.toString() == "hello world")
}

@Test func fsStatSyncFile() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_stat_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'content');
        var stat = fs.statSync('\(tmpPath)');
        stat.isFile() + ':' + stat.isDirectory();
    """)
    #expect(result?.toString() == "true:false")
}

@Test func fsMkdirSyncRecursive() async throws {
    let runtime = NodeRuntime()
    let baseName = "nodecore_test_mkdir_\(UUID().uuidString)"
    let rootDir = NSTemporaryDirectory() + baseName
    let tmpDir = rootDir + "/sub/dir"
    defer {
        try? FileManager.default.removeItem(atPath: rootDir)
    }

    runtime.evaluate("""
        var fs = require('fs');
        fs.mkdirSync('\(tmpDir)', {recursive: true});
    """)

    let exists = runtime.evaluate("require('fs').existsSync('\(tmpDir)')")
    #expect(exists?.toBool() == true)
}

@Test func fsReadFileSyncBuffer() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_readbuf_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'hello');
        var buf = fs.readFileSync('\(tmpPath)');
        Buffer.isBuffer(buf) + ':' + buf.length;
    """)
    #expect(result?.toString() == "true:5")
}

@Test func fsReadFileSyncNotFound() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        var fs = require('fs');
        try {
            fs.readFileSync('/nonexistent_file_xyz_12345.txt', 'utf8');
        } catch(e) {
            console.log('error:' + e.code);
        }
    """)
    #expect(messages.contains(where: { $0.1 == "error:ENOENT" }))
}

/// Helper: run the event loop on a background thread to avoid blocking cooperative threads.
private func runEventLoopInBackgroundFS(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func fsReadFileAsyncDuringEventLoop() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_readfile_async_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "async hello".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        fs.readFile('\(tmpPath)', 'utf8', function(err, data) {
            clearTimeout(keepAlive);
            if (err) { console.log('error:' + err.message); }
            else { console.log('result:' + data); }
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    // Wait for the callback to fire
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        if messages.contains(where: { $0.hasPrefix("result:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("result:async hello"))
}
