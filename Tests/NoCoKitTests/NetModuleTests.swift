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
/// Uses withCheckedThrowingContinuation instead of DispatchSemaphore to avoid
/// blocking cooperative threads (which causes CI hangs with limited thread pools).
private func startTCPServer(handler: @escaping @Sendable (NWConnection) -> Void) async throws -> (NWListener, UInt16) {
    let listener = try NWListener(using: .tcp, on: .any)

    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.resume(returning: listener.port?.rawValue ?? 0)
            case .failed(let error):
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = handler
        listener.start(queue: .global())
    }

    return (listener, port)
}

/// Helper: run the event loop on a background thread to avoid blocking cooperative threads.
private func runEventLoopAsync(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func netConnectAndEcho() async throws {
    let (listener, port) = try await startTCPServer { conn in
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

    await runEventLoopAsync(runtime, timeout: 5)

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

    await runEventLoopAsync(runtime, timeout: 5)

    let hasError = messages.contains { $0.hasPrefix("error:") }
    #expect(hasError)
}

@Test(.timeLimit(.minutes(1)))
func netDrainEvent() async throws {
    let (listener, port) = try await startTCPServer { conn in
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

    await runEventLoopAsync(runtime, timeout: 5)

    #expect(messages.contains("drain"))
}

@Test(.timeLimit(.minutes(1)))
func netSocketTimeout() async throws {
    let (listener, port) = try await startTCPServer { conn in
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

    await runEventLoopAsync(runtime, timeout: 5)

    #expect(messages.contains("timeout"))
}

// MARK: - net.createServer Tests

@Test(.timeLimit(.minutes(1)))
func netCreateServerListening() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var net = require('net');
        var server = net.createServer(function(socket) {});
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
            server.close();
        });
    """)

    await runEventLoopAsync(runtime, timeout: 10)

    let hasListening = messages.contains { $0.hasPrefix("listening:") }
    #expect(hasListening)
}

@Test(.timeLimit(.minutes(1)))
func netCreateServerEcho() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in
        messages.append(msg)
        print("[JS] \(msg)")
    }

    runtime.evaluate("""
        var net = require('net');
        var server = net.createServer(function(socket) {
            socket.on('data', function(data) {
                socket.write(data); // echo
            });
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);

            var client = net.connect(addr.port, '127.0.0.1');
            client.on('connect', function() {
                client.write('hello');
            });
            client.on('data', function(buf) {
                console.log('echo:' + buf.toString());
                client.destroy();
                server.close();
            });
        });
    """)

    await runEventLoopAsync(runtime, timeout: 10)

    let hasListeningEcho = messages.contains { $0.hasPrefix("listening:") }
    #expect(hasListeningEcho)
    #expect(messages.contains("echo:hello"))
}

@Test(.timeLimit(.minutes(1)))
func netAndHttpDualServerListening() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in
        messages.append(msg)
    }

    runtime.evaluate("""
        var net = require('net');
        var http = require('http');

        var tcpServer = net.createServer(function(socket) {});
        tcpServer.listen(0, function() {
            var addr = tcpServer.address();
            console.log('tcp-listening:' + addr.port);
            tcpServer.close();
        });

        var httpServer = http.createServer(function(req, res) {
            res.end('ok');
        });
        httpServer.listen(0, '127.0.0.1', function() {
            var addr = httpServer.address();
            console.log('http-listening:' + addr.port);
            httpServer.close();
        });
    """)

    await runEventLoopAsync(runtime, timeout: 10)

    let hasTcp = messages.contains { $0.hasPrefix("tcp-listening:") }
    let hasHttp = messages.contains { $0.hasPrefix("http-listening:") }
    #expect(hasTcp, "TCP server listen callback should fire")
    #expect(hasHttp, "HTTP server listen callback should fire")
}
