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

// MARK: - Basic SharedArrayBuffer

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferByteLength() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(1024);
        sab.byteLength;
    """)
    #expect(result?.toInt32() == 1024)
}

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferInstanceof() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(16);
        sab instanceof SharedArrayBuffer;
    """)
    #expect(result?.toBool() == true)
}

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferToStringTag() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(8);
        Object.prototype.toString.call(sab);
    """)
    #expect(result?.toString() == "[object SharedArrayBuffer]")
}

// MARK: - TypedArray integration

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferWithInt32Array() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(16);
        var view = new Int32Array(sab);
        view[0] = 42;
        view[1] = 100;
        JSON.stringify([view[0], view[1], view.length]);
    """)
    #expect(result?.toString() == "[42,100,4]")
}

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferWithUint8Array() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(4);
        var view = new Uint8Array(sab);
        view[0] = 255;
        view[3] = 128;
        JSON.stringify([view[0], view[3]]);
    """)
    #expect(result?.toString() == "[255,128]")
}

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferTypedArrayInstanceof() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var a = new Int32Array(4);
        var sab = new SharedArrayBuffer(16);
        var b = new Int32Array(sab);
        JSON.stringify([a instanceof Int32Array, b instanceof Int32Array]);
    """)
    #expect(result?.toString() == "[true,true]")
}

// MARK: - slice

@Test(.timeLimit(.minutes(1)))
func sharedArrayBufferSlice() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(16);
        var view = new Int32Array(sab);
        view[0] = 10; view[1] = 20; view[2] = 30; view[3] = 40;
        var sliced = sab.slice(4, 12);
        var sv = new Int32Array(sliced);
        JSON.stringify([sliced.byteLength, sv[0], sv[1], sliced instanceof SharedArrayBuffer]);
    """)
    #expect(result?.toString() == "[8,20,30,true]")
}

// MARK: - Atomics

@Test(.timeLimit(.minutes(1)))
func atomicsStoreLoad() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(16);
        var view = new Int32Array(sab);
        Atomics.store(view, 0, 42);
        Atomics.store(view, 1, 99);
        JSON.stringify([Atomics.load(view, 0), Atomics.load(view, 1)]);
    """)
    #expect(result?.toString() == "[42,99]")
}

@Test(.timeLimit(.minutes(1)))
func atomicsWaitNotEqual() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(4);
        var view = new Int32Array(sab);
        Atomics.store(view, 0, 5);
        Atomics.wait(view, 0, 0, 0);
    """)
    #expect(result?.toString() == "not-equal")
}

@Test(.timeLimit(.minutes(1)))
func atomicsWaitTimeout() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var sab = new SharedArrayBuffer(4);
        var view = new Int32Array(sab);
        Atomics.store(view, 0, 0);
        Atomics.wait(view, 0, 0, 1);
    """)
    #expect(result?.toString() == "timed-out")
}

// MARK: - Worker sharing via workerData

@Test(.timeLimit(.minutes(1)))
func workerSharedArrayBufferViaWorkerData() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.consoleHandler = { _, msg in output.append(msg) }

    runtime.evaluate("""
        var wt = require('worker_threads');
        var sab = new SharedArrayBuffer(4);
        var view = new Int32Array(sab);
        view[0] = 100;

        var w = new wt.Worker(
            'var {parentPort, workerData} = require("worker_threads"); ' +
            'var v = new Int32Array(workerData); ' +
            'v[0] += 1; ' +
            'parentPort.postMessage(v[0]);',
            { eval: true, workerData: sab }
        );

        w.on('message', function(m) {
            console.log('worker:' + m);
            console.log('main:' + view[0]);
            w.terminate();
        });

        w.on('error', function(e) {
            console.log('error:' + e.message);
            w.terminate();
        });
    """)

    await runEventLoopInBackground(runtime, timeout: 10)

    #expect(output.contains("worker:101"))
    #expect(output.contains("main:101"))
}

// MARK: - Worker sharing via postMessage

@Test(.timeLimit(.minutes(1)))
func workerSharedArrayBufferViaPostMessage() async throws {
    let runtime = NodeRuntime()
    var output: [String] = []
    runtime.consoleHandler = { _, msg in output.append(msg) }

    runtime.evaluate("""
        var wt = require('worker_threads');
        var sab = new SharedArrayBuffer(8);
        var view = new Int32Array(sab);
        view[0] = 42;
        view[1] = 84;

        var w = new wt.Worker(
            'var {parentPort} = require("worker_threads"); ' +
            'parentPort.on("message", function(msg) { ' +
            '  var v = new Int32Array(msg); ' +
            '  v[0] = 999; ' +
            '  parentPort.postMessage("done"); ' +
            '});',
            { eval: true }
        );

        w.on('online', function() {
            w.postMessage(sab);
        });

        w.on('message', function(m) {
            console.log('v0:' + view[0]);
            console.log('v1:' + view[1]);
            w.terminate();
        });

        w.on('error', function(e) {
            console.log('error:' + e.message);
            w.terminate();
        });
    """)

    await runEventLoopInBackground(runtime, timeout: 10)

    #expect(output.contains("v0:999"))
    #expect(output.contains("v1:84"))
}
