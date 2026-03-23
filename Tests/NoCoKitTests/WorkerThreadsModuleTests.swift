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

// MARK: - Basic Properties (Main Thread)

@Test(.timeLimit(.minutes(1)))
func workerThreadsIsMainThread() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        wt.isMainThread;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func workerThreadsThreadIdZero() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        wt.threadId;
    """)
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func workerThreadsParentPortNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        wt.parentPort === null;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func workerThreadsWorkerDataNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        wt.workerData === null;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Worker (eval mode)

@Test(.timeLimit(.minutes(1)))
func workerEvalPostMessage() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var results = [];
        var w = new wt.Worker(
            "var { parentPort } = require('worker_threads'); parentPort.on('message', function(m) { parentPort.postMessage(m * 2); });",
            { eval: true }
        );
        w.on('message', function(msg) {
            results.push(msg);
            w.terminate();
        });
        w.on('online', function() {
            w.postMessage(21);
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("results[0]")
    #expect(result?.toInt32() == 42)
}

@Test(.timeLimit(.minutes(1)))
func workerDataPassed() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var w = new wt.Worker(
            "var { parentPort, workerData } = require('worker_threads'); parentPort.postMessage(workerData);",
            { eval: true, workerData: { hello: 'world', num: 42 } }
        );
        w.on('message', function(msg) {
            received = msg;
            w.terminate();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == #"{"hello":"world","num":42}"#)
}

@Test(.timeLimit(.minutes(1)))
func workerExitEvent() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var exitCode = -1;
        var w = new wt.Worker(
            "/* do nothing, just exit */",
            { eval: true }
        );
        w.on('exit', function(code) {
            exitCode = code;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("exitCode")
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func workerErrorEvent() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var gotError = false;
        var w = new wt.Worker(
            "throw new Error('test error');",
            { eval: true }
        );
        w.on('error', function(err) {
            gotError = true;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("gotError")
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func workerTerminate() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var terminateResult = null;
        var w = new wt.Worker(
            "setInterval(function() {}, 1000);",
            { eval: true }
        );
        setTimeout(function() {
            w.terminate().then(function(code) {
                terminateResult = code;
            });
        }, 100);
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("terminateResult")
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func workerThreadIdIncrements() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var ids = [];
        var doneCount = 0;
        for (var i = 0; i < 3; i++) {
            var w = new wt.Worker("/* exit */", { eval: true });
            ids.push(w.threadId);
            w.on('exit', function() {
                doneCount++;
            });
        }
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let ids = runtime.evaluate("JSON.stringify(ids)")?.toString() ?? "[]"
    let doneCount = runtime.evaluate("doneCount")?.toInt32() ?? 0
    // All IDs should be unique
    let uniqueCheck = runtime.evaluate("""
        var s = new Set(ids);
        s.size === ids.length;
    """)
    #expect(uniqueCheck?.toBool() == true)
    #expect(doneCount == 3)
}

// MARK: - Worker (file mode)

@Test(.timeLimit(.minutes(1)))
func workerFromFile() async throws {
    let runtime = NodeRuntime()
    let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    let echoPath = fixtureDir.appendingPathComponent("worker_echo.js").path

    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var w = new wt.Worker('\(echoPath)');
        w.on('message', function(msg) {
            received = msg;
            w.terminate();
        });
        w.on('online', function() {
            w.postMessage('hello from parent');
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("received")
    #expect(result?.toString() == "hello from parent")
}

@Test(.timeLimit(.minutes(1)))
func workerFromFileWithWorkerData() async throws {
    let runtime = NodeRuntime()
    let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    let dataPath = fixtureDir.appendingPathComponent("worker_data.js").path

    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var w = new wt.Worker('\(dataPath)', { workerData: { key: 'value' } });
        w.on('message', function(msg) {
            received = msg;
            w.terminate();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == #"{"key":"value"}"#)
}

// MARK: - MessageChannel

@Test(.timeLimit(.minutes(1)))
func messageChannelBasic() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var mc = new wt.MessageChannel();
        mc.port2.on('message', function(msg) {
            received = msg;
        });
        mc.port1.postMessage({ test: 123 });
    """)
    await runEventLoopInBackground(runtime, timeout: 3)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == #"{"test":123}"#)
}

@Test(.timeLimit(.minutes(1)))
func messagePortClose() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = [];
        var mc = new wt.MessageChannel();
        mc.port2.on('message', function(msg) {
            received.push(msg);
        });
        mc.port1.postMessage('before');
        mc.port1.close();
        mc.port1.postMessage('after');
    """)
    await runEventLoopInBackground(runtime, timeout: 3)
    let result = runtime.evaluate("JSON.stringify(received)")
    #expect(result?.toString() == #"["before"]"#)
}

// MARK: - Worker env option

@Test(.timeLimit(.minutes(1)))
func workerEnvOption() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var w = new wt.Worker(
            "var { parentPort } = require('worker_threads'); parentPort.postMessage(process.env.MY_VAR);",
            { eval: true, env: { MY_VAR: 'hello_env' } }
        );
        w.on('message', function(msg) {
            received = msg;
            w.terminate();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("received")
    #expect(result?.toString() == "hello_env")
}

@Test(.timeLimit(.minutes(1)))
func workerEnvReplaces() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var received = null;
        var w = new wt.Worker(
            "var { parentPort } = require('worker_threads'); parentPort.postMessage(typeof process.env.PATH);",
            { eval: true, env: { ONLY_THIS: '1' } }
        );
        w.on('message', function(msg) {
            received = msg;
            w.terminate();
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("received")
    #expect(result?.toString() == "undefined")
}

// MARK: - Worker stdout/stderr streams

@Test(.timeLimit(.minutes(1)))
func workerStdoutStream() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var output = '';
        var w = new wt.Worker(
            "console.log('hello from worker');",
            { eval: true, stdout: true }
        );
        w.stdout.on('data', function(chunk) {
            output += chunk;
        });
        w.on('exit', function() {});
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("output")
    #expect(result?.toString()?.contains("hello from worker") == true)
}

@Test(.timeLimit(.minutes(1)))
func workerStderrStream() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var output = '';
        var w = new wt.Worker(
            "console.error('error from worker');",
            { eval: true, stderr: true }
        );
        w.stderr.on('data', function(chunk) {
            output += chunk;
        });
        w.on('exit', function() {});
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("output")
    #expect(result?.toString()?.contains("error from worker") == true)
}

@Test(.timeLimit(.minutes(1)))
func workerStdoutEnd() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var ended = false;
        var w = new wt.Worker(
            "/* just exit */",
            { eval: true, stdout: true }
        );
        w.stdout.on('end', function() {
            ended = true;
        });
        // Need to set up a reader so 'end' fires (flowing mode)
        w.stdout.on('data', function() {});
        w.on('exit', function() {});
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("ended")
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func workerExecArgvIgnored() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var wt = require('worker_threads');
        var exitCode = -1;
        var w = new wt.Worker(
            "/* exit */",
            { eval: true, execArgv: ['--experimental-vm-modules'] }
        );
        w.on('exit', function(code) {
            exitCode = code;
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let result = runtime.evaluate("exitCode")
    #expect(result?.toInt32() == 0)
}

@Test(.timeLimit(.minutes(1)))
func workerStdoutNull() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        var w = new wt.Worker("/* exit */", { eval: true });
        w.stdout === null;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - receiveMessageOnPort

@Test(.timeLimit(.minutes(1)))
func receiveMessageOnPortBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        var { port1, port2 } = new wt.MessageChannel();
        port1.postMessage('hello');
        var msg = wt.receiveMessageOnPort(port2);
        msg.message;
    """)
    #expect(result?.toString() == "hello")
}

@Test(.timeLimit(.minutes(1)))
func receiveMessageOnPortReturnsUndefinedWhenEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        var { port1, port2 } = new wt.MessageChannel();
        wt.receiveMessageOnPort(port2) === undefined;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func receiveMessageOnPortMultiple() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var wt = require('worker_threads');
        var { port1, port2 } = new wt.MessageChannel();
        port1.postMessage({ a: 1 });
        port1.postMessage({ b: 2 });
        var m1 = wt.receiveMessageOnPort(port2);
        var m2 = wt.receiveMessageOnPort(port2);
        var m3 = wt.receiveMessageOnPort(port2);
        m1.message.a + ':' + m2.message.b + ':' + (m3 === undefined);
    """)
    #expect(result?.toString() == "1:2:true")
}

@Test(.timeLimit(.minutes(1)))
func receiveMessageOnPortConsumesBeforeEmit() async throws {
    // receiveMessageOnPort consumes the message, so the 'message' event should not fire for it
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var wt = require('worker_threads');
        var { port1, port2 } = new wt.MessageChannel();
        var emitCount = 0;
        port2.on('message', function() { emitCount++; });
        port1.postMessage('sync');
        port1.postMessage('async');
        // Consume the first message synchronously
        var msg = wt.receiveMessageOnPort(port2);
        console.log('sync:' + msg.message);
    """)

    // Run event loop to process nextTick callbacks
    await runEventLoopInBackground(runtime, timeout: 0.5)

    runtime.evaluate("""
        console.log('emitCount:' + emitCount);
    """)

    #expect(messages.contains("sync:sync"))
    #expect(messages.contains("emitCount:1")) // only the second message should emit
}
