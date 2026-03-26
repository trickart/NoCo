#if os(macOS)
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

// MARK: - execSync Tests

@Test(.timeLimit(.minutes(1)))
func execSyncBasicCommand() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        cp.execSync('echo hello', { encoding: 'utf8' }).trim();
    """)
    #expect(result?.toString() == "hello")
}

@Test(.timeLimit(.minutes(1)))
func execSyncReturnsBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var out = cp.execSync('echo hello');
        Buffer.isBuffer(out);
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execSyncCwdOption() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var out = cp.execSync('pwd', { encoding: 'utf8', cwd: '/tmp' }).trim();
        out === '/tmp' || out === '/private/tmp';
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execSyncThrowsOnError() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var caught = false;
        try {
            cp.execSync('exit 1');
        } catch (e) {
            caught = e.status === 1;
        }
        caught;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execSyncEnvOption() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        cp.execSync('echo $MY_VAR', { encoding: 'utf8', env: { MY_VAR: 'test123' } }).trim();
    """)
    #expect(result?.toString() == "test123")
}

@Test(.timeLimit(.minutes(1)))
func execSyncInputOption() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        cp.execSync('cat', { encoding: 'utf8', input: 'stdin data' });
    """)
    #expect(result?.toString() == "stdin data")
}

// MARK: - exec Tests

@Test(.timeLimit(.minutes(1)))
func execCallbackBasic() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = { called: false };
        cp.exec('echo hello', function(err, stdout, stderr) {
            result.called = true;
            result.err = err;
            result.hasStdout = stdout !== null && stdout !== undefined;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let called = runtime.evaluate("result.called")
    let errIsNull = runtime.evaluate("result.err === null")
    let hasStdout = runtime.evaluate("result.hasStdout")
    #expect(called?.toBool() == true)
    #expect(errIsNull?.toBool() == true)
    #expect(hasStdout?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execEncodingString() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = {};
        cp.exec('echo hello', { encoding: 'utf8' }, function(err, stdout, stderr) {
            result.type = typeof stdout;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let type = runtime.evaluate("result.type")
    #expect(type?.toString() == "string")
}

@Test(.timeLimit(.minutes(1)))
func execErrorCallback() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = {};
        cp.exec('exit 1', function(err, stdout, stderr) {
            result.hasErr = err !== null;
            result.status = err ? err.status : null;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let hasErr = runtime.evaluate("result.hasErr")
    let status = runtime.evaluate("result.status")
    #expect(hasErr?.toBool() == true)
    #expect(status?.toInt32() == 1)
}

@Test(.timeLimit(.minutes(1)))
func execReturnsChildProcess() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.exec('echo hello', function() {});
        typeof child.pid === 'number' && typeof child.kill === 'function';
    """)
    #expect(result?.toBool() == true)
}

// MARK: - spawnSync Tests

@Test(.timeLimit(.minutes(1)))
func spawnSyncBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var r = cp.spawnSync('echo', ['hello'], { encoding: 'utf8' });
        JSON.stringify({ status: r.status, stdout: r.stdout.trim(), signal: r.signal });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"status\":0"))
    #expect(json.contains("\"stdout\":\"hello\""))
    #expect(json.contains("\"signal\":null"))
}

@Test(.timeLimit(.minutes(1)))
func spawnSyncReturnsBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var r = cp.spawnSync('echo', ['hello']);
        Buffer.isBuffer(r.stdout);
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnSyncShellOption() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var r = cp.spawnSync('echo', ['$HOME'], { shell: true, encoding: 'utf8' });
        r.stdout.trim().length > 0 && r.stdout.trim() !== '$HOME';
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnSyncNonexistentCommand() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var r = cp.spawnSync('/nonexistent_cmd_xyz');
        r.error && r.error.code === 'ENOENT';
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnSyncInputOption() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var r = cp.spawnSync('cat', [], { input: 'hello stdin', encoding: 'utf8' });
        r.stdout;
    """)
    #expect(result?.toString() == "hello stdin")
}

// MARK: - spawn Tests

@Test(.timeLimit(.minutes(1)))
func spawnStdoutData() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = '';
        var child = cp.spawn('echo', ['hello spawn']);
        child.stdout.setEncoding('utf8');
        child.stdout.on('data', function(data) {
            result += data;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let result = runtime.evaluate("result.trim()")
    #expect(result?.toString() == "hello spawn")
}

@Test(.timeLimit(.minutes(1)))
func spawnStdoutAsyncIterator() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var lines = [];
        async function run() {
            var child = cp.spawn('printf', ['line1\\nline2\\nline3']);
            for await (var chunk of child.stdout) {
                var text = (typeof chunk === 'string') ? chunk : chunk.toString();
                text.split('\\n').forEach(function(l) { if (l) lines.push(l); });
            }
        }
        run();
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let result = runtime.evaluate("JSON.stringify(lines)")
    #expect(result?.toString() == #"["line1","line2","line3"]"#)
}

@Test(.timeLimit(.minutes(1)))
func spawnStdoutReadableStream() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var chunks = [];
        async function run() {
            var child = cp.spawn('echo', ['hello']);
            var reader = child.stdout._readableStream.getReader();
            while (true) {
                var r = await reader.read();
                if (r.done) break;
                chunks.push(r.value.toString().trim());
            }
        }
        run();
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let result = runtime.evaluate("chunks[0]")
    #expect(result?.toString() == "hello")
}

@Test(.timeLimit(.minutes(1)))
func spawnStdoutEventEmitterStillWorks() async throws {
    // Verify that adding ReadableStream doesn't break existing on('data') usage
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var dataResult = '';
        var endCalled = false;
        var child = cp.spawn('echo', ['compat_test']);
        child.stdout.on('data', function(d) { dataResult += d; });
        child.stdout.on('end', function() { endCalled = true; });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let data = runtime.evaluate("dataResult.trim()")
    let end = runtime.evaluate("endCalled")
    #expect(data?.toString() == "compat_test")
    #expect(end?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnExitAndCloseEvent() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var exitCode = -1;
        var child = cp.spawn('sh', ['-c', 'exit 42']);
        child.on('exit', function(code) {
            exitCode = code;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let exitCode = runtime.evaluate("exitCode")
    #expect(exitCode?.toInt32() == 42)
}

@Test(.timeLimit(.minutes(1)))
func spawnPidProperty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.spawn('echo', ['test']);
        typeof child.pid === 'number' && child.pid > 0;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnStderrData() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var errData = '';
        var child = cp.spawn('sh', ['-c', 'echo error >&2']);
        child.stderr.setEncoding('utf8');
        child.stderr.on('data', function(data) {
            errData += data;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let result = runtime.evaluate("errData.trim()")
    #expect(result?.toString() == "error")
}

@Test(.timeLimit(.minutes(1)))
func spawnKillMethod() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var closed = false;
        var child = cp.spawn('sleep', ['10']);
        child.on('close', function() {
            closed = true;
        });
        setTimeout(function() {
            child.kill();
        }, 100);
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let closed = runtime.evaluate("closed")
    #expect(closed?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnStdinWrite() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = '';
        var child = cp.spawn('cat');
        child.stdout.setEncoding('utf8');
        child.stdout.on('data', function(data) {
            result += data;
        });
        child.stdin.write('hello from stdin');
        child.stdin.end();
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let result = runtime.evaluate("result")
    #expect(result?.toString() == "hello from stdin")
}

@Test(.timeLimit(.minutes(1)))
func spawnBufferData() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var isBuffer = false;
        var child = cp.spawn('echo', ['test']);
        child.stdout.on('data', function(data) {
            isBuffer = Buffer.isBuffer(data);
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let isBuffer = runtime.evaluate("isBuffer")
    #expect(isBuffer?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func spawnErrorEvent() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var errCode = '';
        var child = cp.spawn('/nonexistent_cmd_xyz_abc');
        child.on('error', function(err) {
            errCode = err.code;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let errCode = runtime.evaluate("errCode")
    #expect(errCode?.toString() == "ENOENT")
}

// MARK: - execFileSync Tests

@Test(.timeLimit(.minutes(1)))
func execFileSyncBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        cp.execFileSync('/bin/echo', ['hello'], { encoding: 'utf8' }).trim();
    """)
    #expect(result?.toString() == "hello")
}

@Test(.timeLimit(.minutes(1)))
func execFileSyncWithArgs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        cp.execFileSync('/usr/bin/printf', ['%s %s', 'hello', 'world'], { encoding: 'utf8' });
    """)
    #expect(result?.toString() == "hello world")
}

@Test(.timeLimit(.minutes(1)))
func execFileSyncThrowsOnError() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var caught = false;
        try {
            cp.execFileSync('/nonexistent_file_xyz');
        } catch (e) {
            caught = true;
        }
        caught;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - execFile Tests

@Test(.timeLimit(.minutes(1)))
func execFileCallbackBasic() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = { called: false };
        cp.execFile('/bin/echo', ['hello'], function(err, stdout, stderr) {
            result.called = true;
            result.err = err;
            result.hasStdout = stdout !== null && stdout !== undefined;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let called = runtime.evaluate("result.called")
    let errIsNull = runtime.evaluate("result.err === null")
    let hasStdout = runtime.evaluate("result.hasStdout")
    #expect(called?.toBool() == true)
    #expect(errIsNull?.toBool() == true)
    #expect(hasStdout?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execFileErrorCallback() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var result = {};
        cp.execFile('/nonexistent_file_xyz', function(err, stdout, stderr) {
            result.hasErr = err !== null;
            result.code = err ? err.code : null;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    let hasErr = runtime.evaluate("result.hasErr")
    #expect(hasErr?.toBool() == true)
}

// MARK: - fork Tests

/// Find the noco binary in the build directory.
private func nocoExecPath() -> String {
    // During swift test, the binary is at .build/debug/noco
    let testBinary = ProcessInfo.processInfo.arguments[0]
    let buildDir = URL(fileURLWithPath: testBinary)
        .deletingLastPathComponent().path
    let candidate = buildDir + "/noco"
    if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    // Fallback: search relative to source tree
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        dir = dir.deletingLastPathComponent()
        let path = dir.appendingPathComponent(".build/debug/noco").path
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return candidate
}

@Test(.timeLimit(.minutes(1)))
func forkReceiveMessageFromChild() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"hello\":\"from child\"}")
}

@Test(.timeLimit(.minutes(1)))
func forkSendMessageToChild() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_echo.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
        child.send({ ping: 'pong' });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"ping\":\"pong\"}")
}

@Test(.timeLimit(.minutes(1)))
func forkDisconnect() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_echo.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var disconnected = false;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        child.on('disconnect', function() {
            disconnected = true;
        });
        // IPC 確立を ping/echo で確認してから disconnect
        // (setTimeout ベースだと IPC 接続完了前に fire する可能性がある)
        child.on('message', function() {
            child.disconnect();
        });
        child.send({ ping: true });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("disconnected")
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkChildExit() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var exitCode = -1;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        child.on('exit', function(code) {
            exitCode = code;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("exitCode")
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func forkSilentOption() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('\(fixturePath)', { silent: true, execPath: '\(execPath)' });
        var hasStdout = child.stdout !== null;
        var hasStderr = child.stderr !== null;
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let hasStdout = runtime.evaluate("hasStdout")
    let hasStderr = runtime.evaluate("hasStderr")
    #expect(hasStdout?.toBool() == true)
    #expect(hasStderr?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkStdioPipeOption() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('\(fixturePath)', { stdio: 'pipe', execPath: '\(execPath)' });
        var hasStdout = child.stdout !== null && child.stdout !== undefined;
        var hasStderr = child.stderr !== null && child.stderr !== undefined;
        child.on('message', function() { child.disconnect(); });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let hasStdout = runtime.evaluate("hasStdout")
    let hasStderr = runtime.evaluate("hasStderr")
    #expect(hasStdout?.toBool() == true)
    #expect(hasStderr?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkStdioPipeReceivesData() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { stdio: 'pipe', execPath: '\(execPath)' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"hello\":\"from child\"}")
}

@Test(.timeLimit(.minutes(1)))
func forkStdioPipeStdoutReceived() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_stdout.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var stdoutData = '';
        var child = cp.fork('\(fixturePath)', { stdio: 'pipe', execPath: '\(execPath)' });
        child.stdout.setEncoding('utf-8');
        child.stdout.on('data', function(chunk) { stdoutData += chunk; });
        child.on('message', function(msg) {
            if (msg && msg.done) child.disconnect();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("stdoutData.trim()")
    #expect(result?.toString() == "hello from child stdout")
}

@Test(.timeLimit(.minutes(1)))
func forkStdoutEventEmitterMethods() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('\(fixturePath)', { stdio: 'pipe', execPath: '\(execPath)' });
        var s = child.stdout;
        var results = [];
        results.push(typeof s.off === 'function');
        results.push(typeof s.removeAllListeners === 'function');
        results.push(typeof s.getMaxListeners === 'function');
        results.push(typeof s.setMaxListeners === 'function');
        results.push(typeof s.listenerCount === 'function');
        results.push(typeof s.listeners === 'function');
        results.push(typeof s.unpipe === 'function');
        results.push(s.getMaxListeners() === 10);
        s.setMaxListeners(20);
        results.push(s.getMaxListeners() === 20);
        s.on('data', function() {});
        s.on('data', function() {});
        results.push(s.listenerCount('data') === 2);
        child.on('message', function() { child.disconnect(); });
        results.every(function(r) { return r === true; });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkStderrEventEmitterMethods() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('\(fixturePath)', { stdio: 'pipe', execPath: '\(execPath)' });
        var s = child.stderr;
        var results = [];
        results.push(typeof s.off === 'function');
        results.push(typeof s.getMaxListeners === 'function');
        results.push(typeof s.unpipe === 'function');
        results.push(s.getMaxListeners() === 10);
        child.on('message', function() { child.disconnect(); });
        results.every(function(r) { return r === true; });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkSendUndefinedFromChild() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send_undefined.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        child.on('message', function(msg) {
            if (msg && msg.ok) {
                received = msg;
                child.disconnect();
            }
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"ok\":true}")
}

@Test(.timeLimit(.minutes(1)))
func forkSendUndefinedFromParent() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_echo.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        // undefined を送っても親がクラッシュしないことを確認
        child.send(undefined);
        // 次に有効なメッセージを送って echo で返ってくることを確認
        child.send({ test: 'ok' });
        child.on('message', function(msg) {
            if (msg && msg.test) {
                received = msg;
                child.disconnect();
            }
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"test\":\"ok\"}")
}

@Test(.timeLimit(.minutes(1)))
func forkOffRemovesListener() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var callCount = 0;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        function handler(msg) { callCount++; }
        child.on('message', handler);
        child.off('message', handler);
        // 'off' で除去済みなので message が来ても callCount は 0 のまま
        child.on('message', function() { child.disconnect(); });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("callCount")
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func forkOffIsFunction() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)' });
        var result = typeof child.off === 'function';
        child.on('message', function() { child.disconnect(); });
        result;
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func execOffRemovesListener() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.exec('echo hello');
        var hasOff = typeof child.off === 'function';
        var callCount = 0;
        function handler() { callCount++; }
        child.on('exit', handler);
        child.off('exit', handler);
        hasOff;
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    #expect(result?.toBool() == true)
    let count = runtime.evaluate("callCount")
    #expect(count?.toInt32() == 0)
}

// MARK: - Advanced serialization (circular references)

@Test(.timeLimit(.minutes(1)))
func forkAdvancedSerializationReceive() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_circular.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)', serialization: 'advanced' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    // Verify the circular reference was preserved
    let name = runtime.evaluate("received && received.name")
    #expect(name?.toString() == "test")
    let taskId = runtime.evaluate("received && received.tasks[0].id")
    #expect(taskId?.toInt32() == 1)
    let isCircular = runtime.evaluate("received && received.tasks[0].parent === received")
    #expect(isCircular?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func forkAdvancedSerializationEcho() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_circular_echo.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        var child = cp.fork('\(fixturePath)', { execPath: '\(execPath)', serialization: 'advanced' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
        // Send a circular object from parent to child
        var obj = { name: 'echo_test', items: [] };
        var item = { value: 42, root: obj };
        obj.items.push(item);
        child.send(obj);
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let name = runtime.evaluate("received && received.name")
    #expect(name?.toString() == "echo_test")
    let value = runtime.evaluate("received && received.items[0].value")
    #expect(value?.toInt32() == 42)
    let isCircular = runtime.evaluate("received && received.items[0].root === received")
    #expect(isCircular?.toBool() == true)
}

// MARK: - ref / unref

@Test(.timeLimit(.minutes(1)))
func spawnRefUnrefExist() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.spawn('echo', ['test']);
        typeof child.ref + ':' + typeof child.unref;
    """)
    #expect(result?.toString() == "function:function")
}

@Test(.timeLimit(.minutes(1)))
func spawnUnrefAllowsEventLoopExit() async throws {
    // After unref(), the event loop should be able to exit even if the child is still running
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.spawn('sleep', ['10']);
        child.unref();
    """)

    // Event loop should exit quickly (not wait 10 seconds for sleep)
    await runEventLoopInBackground(runtime, timeout: 2)
    // If we get here within the time limit, unref worked
}

@Test(.timeLimit(.minutes(1)))
func spawnRefReRefKeepsEventLoop() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.spawn('echo', ['hello']);
        child.unref();
        child.ref();
        // Double ref should not double-count
        child.ref();
        'ok';
    """)
    #expect(result?.toString() == "ok")
    await runEventLoopInBackground(runtime, timeout: 2)
}

@Test(.timeLimit(.minutes(1)))
func spawnUnrefReturnsSelf() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.spawn('echo', ['test']);
        var r1 = child.unref();
        var r2 = child.ref();
        (r1 === child) + ':' + (r2 === child);
    """)
    #expect(result?.toString() == "true:true")
}

// MARK: - IPC send fallback for cyclic references

@Test(.timeLimit(.minutes(1)))
func forkSendCyclicObjectFallback() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var cp = require('child_process');
        var child = cp.fork('/dev/null', [], {});
        // Create a cyclic object
        var a = { x: 1 };
        var b = { y: 2, ref: a };
        a.ref = b;
        // send() should not throw — falls back to structured clone
        var err = null;
        try {
            child.send(a);
        } catch(e) {
            err = e.message;
        }
        console.log('sendError:' + err);
        child.kill();
    """)
    await runEventLoopInBackground(runtime, timeout: 5)
    #expect(messages.contains("sendError:null"))
}

// MARK: - fork(path, undefined, options) — args が undefined でも options を正しくパースする

@Test(.timeLimit(.minutes(1)))
func forkUndefinedArgsWithOptions() async throws {
    let runtime = NodeRuntime()
    let execPath = nocoExecPath()
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fork_send.js").path
    runtime.evaluate("""
        var cp = require('child_process');
        var received = null;
        // tinypool calls fork(path, undefined, options) — args is undefined
        var child = cp.fork('\(fixturePath)', undefined, { execPath: '\(execPath)', stdio: 'pipe' });
        child.on('message', function(msg) {
            received = msg;
            child.disconnect();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == "{\"hello\":\"from child\"}")
}
#endif
