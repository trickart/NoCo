import Testing
import Foundation
@preconcurrency import JavaScriptCore
import Network
@testable import NoCoKit

// MARK: - Net Module Tests

@Test func netIsIP() {
    let runtime = NodeRuntime()
    let result4 = runtime.evaluate("require('net').isIP('127.0.0.1')")
    #expect(result4?.toInt32() == 4)

    let result6 = runtime.evaluate("require('net').isIP('::1')")
    #expect(result6?.toInt32() == 6)

    let result0 = runtime.evaluate("require('net').isIP('not-an-ip')")
    #expect(result0?.toInt32() == 0)
}

@Test func netIsIPv4() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('net').isIPv4('192.168.1.1')")
    #expect(result?.toBool() == true)

    let resultFalse = runtime.evaluate("require('net').isIPv4('::1')")
    #expect(resultFalse?.toBool() == false)
}

@Test func netIsIPv6() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('net').isIPv6('::1')")
    #expect(result?.toBool() == true)

    let resultFalse = runtime.evaluate("require('net').isIPv6('127.0.0.1')")
    #expect(resultFalse?.toBool() == false)
}

/// Helper: start an NWListener on a random port, return the listener and port.
private func startTCPServer(handler: @escaping @Sendable (NWConnection) -> Void) throws -> (NWListener, UInt16) {
    let listener = try NWListener(using: .tcp, on: .any)
    nonisolated(unsafe) var serverPort: UInt16 = 0
    let portReady = DispatchSemaphore(value: 0)

    listener.stateUpdateHandler = { state in
        if case .ready = state {
            serverPort = listener.port?.rawValue ?? 0
            portReady.signal()
        }
    }

    listener.newConnectionHandler = handler
    listener.start(queue: .global())
    portReady.wait()
    return (listener, serverPort)
}

@Test(.timeLimit(.minutes(1)))
func netConnectAndEcho() async throws {
    let (listener, port) = try startTCPServer { conn in
        conn.start(queue: .global())
        @Sendable func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                if let data = data, !data.isEmpty {
                    conn.send(content: data, completion: .contentProcessed { _ in
                        if !isComplete { receive() }
                    })
                }
                if isComplete {
                    conn.cancel()
                }
            }
        }
        receive()
    }
    defer { listener.cancel() }

    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var net = require('net');
        var conn = net.connect(\(port), '127.0.0.1');
        conn.on('connect', function() {
            console.log('connected');
            conn.write('hello');
        });
        conn.on('data', function(buf) {
            console.log('data:' + buf.toString());
            conn.destroy();
        });
        conn.on('close', function() {
            console.log('closed');
        });
    """)

    runtime.runEventLoop(timeout: 5)

    #expect(messages.contains("connected"))
    #expect(messages.contains("data:hello"))
    #expect(messages.contains("closed"))
}

@Test(.timeLimit(.minutes(1)))
func netConnectRefused() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Connect to a port that should be unused
    runtime.evaluate("""
        var net = require('net');
        var conn = net.connect(19999, '127.0.0.1');
        conn.on('error', function(err) {
            console.log('error:' + err.message);
        });
        conn.on('close', function() {
            console.log('closed');
        });
    """)

    runtime.runEventLoop(timeout: 5)

    let hasError = messages.contains { $0.hasPrefix("error:") }
    #expect(hasError)
}

@Test(.timeLimit(.minutes(1)))
func netDrainEvent() async throws {
    let (listener, port) = try startTCPServer { conn in
        conn.start(queue: .global())
        // Accept but do nothing
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in }
    }
    defer { listener.cancel() }

    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var net = require('net');
        var conn = net.connect(\(port), '127.0.0.1');
        conn.on('connect', function() {
            conn.write('test');
        });
        conn.on('drain', function() {
            console.log('drain');
            conn.destroy();
        });
    """)

    runtime.runEventLoop(timeout: 5)

    #expect(messages.contains("drain"))
}

@Test(.timeLimit(.minutes(1)))
func netSocketTimeout() async throws {
    let (listener, port) = try startTCPServer { conn in
        conn.start(queue: .global())
        // Accept but never send data
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in }
    }
    defer { listener.cancel() }

    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var net = require('net');
        var conn = net.connect(\(port), '127.0.0.1');
        conn.on('connect', function() {
            conn.setTimeout(200);
        });
        conn.on('timeout', function() {
            console.log('timeout');
            conn.destroy();
        });
    """)

    runtime.runEventLoop(timeout: 5)

    #expect(messages.contains("timeout"))
}
