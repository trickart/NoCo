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

// MARK: - stat Date Properties

@Test func fsStatSyncDateProperties() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_stat_date_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    FileManager.default.createFile(atPath: tmpPath, contents: "test".data(using: .utf8))

    let result = runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('\(tmpPath)');
        var isDate = (stat.mtime instanceof Date) && (stat.ctime instanceof Date) && (stat.birthtime instanceof Date);
        var canCall = typeof stat.mtime.toUTCString === 'function';
        isDate + ':' + canCall;
    """)
    #expect(result?.toString() == "true:true")
}

@Test func fsStatSyncHasInodeAndMode() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_stat_ino_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    FileManager.default.createFile(atPath: tmpPath, contents: "test".data(using: .utf8))

    let result = runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('\(tmpPath)');
        var results = [
            typeof stat.ino === 'number' && stat.ino > 0,
            typeof stat.dev === 'number',
            typeof stat.nlink === 'number' && stat.nlink >= 1,
            typeof stat.mode === 'number' && stat.mode > 0
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func fsStatSyncHasUidAndGid() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_stat_uidgid_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    FileManager.default.createFile(atPath: tmpPath, contents: "test".data(using: .utf8))

    let result = runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('\(tmpPath)');
        var results = [
            typeof stat.uid === 'number' && stat.uid >= 0,
            typeof stat.gid === 'number' && stat.gid >= 0
        ];
        results.every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func fsStatSyncUidMatchesCurrentUser() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_stat_uid_match_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    FileManager.default.createFile(atPath: tmpPath, contents: "test".data(using: .utf8))

    // File created by current user should have matching uid
    let result = runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('\(tmpPath)');
        stat.uid === process.getuid();
    """)
    #expect(result?.toBool() == true)
}

@Test func fsStatSyncModeIncludesFileType() async throws {
    let runtime = NodeRuntime()

    let result = runtime.evaluate("""
        var fs = require('fs');
        var fileStat = fs.statSync('/tmp');
        // /tmp is a directory: mode should have S_IFDIR (0o040000) bit set
        var isDirMode = (fileStat.mode & 0o170000) === 0o040000;
        isDirMode;
    """)
    #expect(result?.toBool() == true)
}

@Test func fsStatSyncDateConsistency() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_stat_date_cons_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    FileManager.default.createFile(atPath: tmpPath, contents: "test".data(using: .utf8))

    let result = runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('\(tmpPath)');
        (stat.mtime.getTime() === stat.mtimeMs) + ':' + (stat.birthtime.getTime() === stat.birthtimeMs);
    """)
    #expect(result?.toString() == "true:true")
}

// MARK: - createReadStream Tests

@Test(.timeLimit(.minutes(1)))
func fsCreateReadStreamBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_crs_basic_\(UUID().uuidString).txt"
    let content = "Hello, createReadStream!"
    FileManager.default.createFile(atPath: tmpPath, contents: content.data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var chunks = [];
        var stream = fs.createReadStream('\(tmpPath)');
        stream.on('data', function(chunk) {
            chunks.push(chunk);
        });
        stream.on('end', function() {
            clearTimeout(keepAlive);
            var result = Buffer.concat(chunks).toString('utf8');
            console.log('data:' + result);
        });
        stream.on('error', function(err) {
            clearTimeout(keepAlive);
            console.log('error:' + err.code);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("data:") || $0.hasPrefix("error:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("data:\(content)"))
}

@Test(.timeLimit(.minutes(1)))
func fsCreateReadStreamRange() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_crs_range_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "0123456789abcdef".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var chunks = [];
        var stream = fs.createReadStream('\(tmpPath)', { start: 4, end: 9 });
        stream.on('data', function(chunk) {
            chunks.push(chunk);
        });
        stream.on('end', function() {
            clearTimeout(keepAlive);
            var result = Buffer.concat(chunks).toString('utf8');
            console.log('range:' + result);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("range:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("range:456789"))
}

@Test(.timeLimit(.minutes(1)))
func fsCreateReadStreamNotFound() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var stream = fs.createReadStream('/nonexistent_file_crs_\(UUID().uuidString).txt');
        stream.on('error', function(err) {
            clearTimeout(keepAlive);
            console.log('err:' + err.code);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("err:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("err:ENOENT"))
}

@Test(.timeLimit(.minutes(1)))
func fsCreateReadStreamWithReadableStream() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_crs_rs_\(UUID().uuidString).txt"
    let content = "serve-static-test-content"
    FileManager.default.createFile(atPath: tmpPath, contents: content.data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var nodeStream = fs.createReadStream('\(tmpPath)');

        // Simulate serve-static's createStreamBody pattern
        var chunks = [];
        var rs = new ReadableStream({
            start: function(controller) {
                nodeStream.on('data', function(chunk) {
                    controller.enqueue(chunk);
                });
                nodeStream.on('end', function() {
                    controller.close();
                });
                nodeStream.on('error', function(err) {
                    controller.error(err);
                });
            }
        });

        // Read from the ReadableStream using the reader
        var reader = rs.getReader();
        function readNext() {
            reader.read().then(function(result) {
                if (result.done) {
                    clearTimeout(keepAlive);
                    var buf = Buffer.concat(chunks);
                    console.log('rs:' + buf.toString('utf8'));
                } else {
                    chunks.push(Buffer.from(result.value));
                    readNext();
                }
            });
        }
        readNext();
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("rs:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("rs:\(content)"))
}

// MARK: - createWriteStream Tests

@Test(.timeLimit(.minutes(1)))
func fsCreateWriteStreamBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_cws_basic_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var s = fs.createWriteStream('\(tmpPath)');
        s.on('close', function() {
            clearTimeout(keepAlive);
            var content = fs.readFileSync('\(tmpPath)', 'utf8');
            console.log('data:' + content);
            console.log('close:yes');
        });
        s.write('hello ');
        s.write('world');
        s.end();
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("data:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("data:hello world"))
    #expect(messages.contains("close:yes"))
}

@Test(.timeLimit(.minutes(1)))
func fsCreateWriteStreamAppend() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_cws_append_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "first ".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var s = fs.createWriteStream('\(tmpPath)', {flags: 'a'});
        s.on('close', function() {
            clearTimeout(keepAlive);
            console.log('data:' + fs.readFileSync('\(tmpPath)', 'utf8'));
        });
        s.write('second');
        s.end();
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("data:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("data:first second"))
}

@Test(.timeLimit(.minutes(1)))
func fsCreateWriteStreamBytesWritten() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_cws_bytes_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        var s = fs.createWriteStream('\(tmpPath)');
        s.on('open', function() {
            s.write('hello', function() {
                console.log('bytes:' + s.bytesWritten);
                s.end(function() {
                    clearTimeout(keepAlive);
                });
            });
        });
        s.on('close', function() {
            console.log('done');
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("bytes:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("bytes:5"))
}

// MARK: - fd-based API Tests

@Test func fsOpenSyncWriteSyncCloseSync() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_fd_write_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let result = runtime.evaluate("""
        var fs = require('fs');
        var fd = fs.openSync('\(tmpPath)', 'w');
        var written = fs.writeSync(fd, 'hello fd');
        fs.closeSync(fd);
        written + ':' + fs.readFileSync('\(tmpPath)', 'utf8');
    """)
    #expect(result?.toString() == "8:hello fd")
}

@Test func fsWriteSyncStdout() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.stdoutHandler = { msg in messages.append(msg) }

    runtime.evaluate("""
        var fs = require('fs');
        fs.writeSync(1, 'stdout test');
    """)
    #expect(messages.contains("stdout test"))
}

@Test(.timeLimit(.minutes(1)))
func fsOpenWriteCloseAsync() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_fd_async_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        fs.open('\(tmpPath)', 'w', function(err, fd) {
            if (err) { clearTimeout(keepAlive); console.log('error:' + err.message); return; }
            fs.write(fd, 'async hello', function(err2, written) {
                if (err2) { clearTimeout(keepAlive); console.log('error:' + err2.message); return; }
                fs.close(fd, function() {
                    clearTimeout(keepAlive);
                    console.log('result:' + written + ':' + fs.readFileSync('\(tmpPath)', 'utf8'));
                });
            });
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("result:") || $0.hasPrefix("error:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("result:11:async hello"))
}

@Test func fsFsyncSyncNoError() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_fd_fsync_\(UUID().uuidString).txt"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    let result = runtime.evaluate("""
        var fs = require('fs');
        var fd = fs.openSync('\(tmpPath)', 'w');
        fs.writeSync(fd, 'fsync test');
        fs.fsyncSync(fd);
        fs.closeSync(fd);
        fs.readFileSync('\(tmpPath)', 'utf8');
    """)
    #expect(result?.toString() == "fsync test")
}

@Test(.timeLimit(.minutes(1)))
func fsMkdirAsync() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpDir = NSTemporaryDirectory() + "noco_test_mkdir_async_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        fs.mkdir('\(tmpDir)', function(err) {
            clearTimeout(keepAlive);
            if (err) { console.log('error:' + err.message); return; }
            console.log('exists:' + fs.existsSync('\(tmpDir)'));
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("exists:") || $0.hasPrefix("error:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("exists:true"))
}

// MARK: - fs.Stats instanceof Tests

@Test func fsStatsInstanceof() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var fs = require('fs');
        var stat = fs.statSync('.');
        console.log('instanceof:' + (stat instanceof fs.Stats));
        console.log('hasStats:' + (typeof fs.Stats === 'function'));
        console.log('isDir:' + stat.isDirectory());
    """)
    #expect(messages.contains("instanceof:true"))
    #expect(messages.contains("hasStats:true"))
    #expect(messages.contains("isDir:true"))
}

// MARK: - fs.watchFile / fs.unwatchFile / fs.watch Tests

@Test(.timeLimit(.minutes(1)))
func fsWatchFileDetectsChange() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_watchfile_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "initial".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 30000);
        fs.watchFile('\(tmpPath)', {interval: 300}, function(curr, prev) {
            console.log('changed:' + curr.mtimeMs + ':' + prev.mtimeMs);
            fs.unwatchFile('\(tmpPath)');
            clearTimeout(keepAlive);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 30)
    }

    // Wait for watchFile polling to start, then modify the file.
    // Use sleep(2) to guarantee mtime changes (HFS+/APFS may have 1s granularity).
    try await Task.sleep(nanoseconds: 2_000_000_000)
    // Write non-atomically to ensure the same path is updated in-place
    try "modified".data(using: .utf8)!.write(to: URL(fileURLWithPath: tmpPath))

    // Wait for callback (up to 20 seconds for slow CI)
    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.hasPrefix("changed:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains(where: { $0.hasPrefix("changed:") }))
}

@Test(.timeLimit(.minutes(1)))
func fsUnwatchFileStopsPolling() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_unwatchfile_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "initial".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 30000);
        var callCount = 0;
        fs.watchFile('\(tmpPath)', {interval: 200}, function(curr, prev) {
            callCount++;
            console.log('call:' + callCount);
        });
        // Immediately unwatchFile
        fs.unwatchFile('\(tmpPath)');
        setTimeout(function() {
            console.log('done:' + callCount);
            clearTimeout(keepAlive);
        }, 1000);
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    // Modify file while unwatched
    try await Task.sleep(nanoseconds: 300_000_000)
    try "modified".write(toFile: tmpPath, atomically: true, encoding: .utf8)

    for _ in 0..<50 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.hasPrefix("done:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("done:0"))
}

@Test(.timeLimit(.minutes(1)))
func fsWatchDetectsChange() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_watch_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "initial".data(using: .utf8))
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 30000);
        var watcher = fs.watch('\(tmpPath)', function(eventType, filename) {
            console.log('event:' + eventType + ':' + filename);
            watcher.close();
            clearTimeout(keepAlive);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 10)
    }

    // Wait a bit then modify the file
    try await Task.sleep(nanoseconds: 300_000_000)
    try "modified".write(toFile: tmpPath, atomically: true, encoding: .utf8)

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 100_000_000)
        if messages.contains(where: { $0.hasPrefix("event:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    // atomically:true writes via rename, so kqueue may report "rename" or "change"
    #expect(messages.contains(where: { $0.hasPrefix("event:change:") || $0.hasPrefix("event:rename:") }))
}

// MARK: - fs.unlink (async) Tests

@Test(.timeLimit(.minutes(1)))
func fsUnlinkAsync() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_unlink_async_\(UUID().uuidString).txt"
    FileManager.default.createFile(atPath: tmpPath, contents: "temp".data(using: .utf8))

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        fs.unlink('\(tmpPath)', function(err) {
            clearTimeout(keepAlive);
            if (err) { console.log('error:' + err.code); return; }
            console.log('deleted:' + !fs.existsSync('\(tmpPath)'));
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("deleted:") || $0.hasPrefix("error:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("deleted:true"))
    #expect(!FileManager.default.fileExists(atPath: tmpPath))
}

@Test(.timeLimit(.minutes(1)))
func fsUnlinkAsyncNotFound() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var fs = require('fs');
        var keepAlive = setTimeout(function(){}, 10000);
        fs.unlink('/nonexistent_unlink_\(UUID().uuidString).txt', function(err) {
            clearTimeout(keepAlive);
            if (err) { console.log('error:' + err.code); return; }
            console.log('deleted:ok');
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackgroundFS(runtime, timeout: 5)
    }

    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("error:") || $0.hasPrefix("deleted:") }) { break }
    }

    runtime.eventLoop.stop()
    await eventLoopTask.value

    #expect(messages.contains("error:ENOENT"))
}

@Test func fsUtimesSyncWithNumber() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_utimes_\(UUID().uuidString).txt"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    let result = runtime.evaluate("""
        var fs = require('fs');
        fs.writeFileSync('\(tmpPath)', 'hello');
        fs.utimesSync('\(tmpPath)', 1000, 2000);
        var s = fs.statSync('\(tmpPath)');
        s.mtimeMs;
    """)
    #expect(result?.toDouble() == 2000000)
}

@Test func fsUtimesSyncENOENT() async throws {
    let runtime = NodeRuntime()

    let result = runtime.evaluate("""
        var fs = require('fs');
        try {
            fs.utimesSync('/nonexistent/path/file.txt', 1000, 2000);
            'no error';
        } catch (e) {
            e.code;
        }
    """)
    #expect(result?.toString() == "ENOENT")
}
