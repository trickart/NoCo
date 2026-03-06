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
#endif
