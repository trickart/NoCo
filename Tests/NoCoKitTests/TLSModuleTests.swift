import Testing
import Foundation
@preconcurrency import JavaScriptCore
@testable import NoCoKit

// MARK: - TLS Module Tests

/// Helper: run the event loop on a background thread to avoid blocking cooperative threads.
private func runEventLoopAsync(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

/// Helper: generate self-signed cert+key PEM using openssl, returns (cert, key).
private func generateSelfSignedCert() throws -> (cert: String, key: String) {
    let tmpDir = NSTemporaryDirectory() + "noco-tls-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let keyPath = tmpDir + "/key.pem"
    let certPath = tmpDir + "/cert.pem"

    // Generate RSA key
    let keyProc = Process()
    keyProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    keyProc.arguments = ["genrsa", "-out", keyPath, "2048"]
    keyProc.standardOutput = FileHandle.nullDevice
    keyProc.standardError = FileHandle.nullDevice
    try keyProc.run()
    keyProc.waitUntilExit()
    guard keyProc.terminationStatus == 0 else {
        throw NSError(domain: "TLSTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate RSA key"])
    }

    // Generate self-signed cert
    let certProc = Process()
    certProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    certProc.arguments = [
        "req", "-new", "-x509", "-key", keyPath, "-out", certPath,
        "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"
    ]
    certProc.standardOutput = FileHandle.nullDevice
    certProc.standardError = FileHandle.nullDevice
    try certProc.run()
    certProc.waitUntilExit()
    guard certProc.terminationStatus == 0 else {
        throw NSError(domain: "TLSTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate self-signed cert"])
    }

    let key = try String(contentsOfFile: keyPath, encoding: .utf8)
    let cert = try String(contentsOfFile: certPath, encoding: .utf8)
    return (cert: cert, key: key)
}

@Test func tlsModuleBasicProperties() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("var tls = require('tls'); JSON.stringify(Object.keys(tls).sort())")
    let keys = result?.toString() ?? ""
    #expect(keys.contains("connect"))
    #expect(keys.contains("createServer"))
    #expect(keys.contains("createSecureContext"))
    #expect(keys.contains("TLSSocket"))
    #expect(keys.contains("Server"))
    #expect(keys.contains("DEFAULT_MIN_VERSION"))
    #expect(keys.contains("DEFAULT_MAX_VERSION"))
    #expect(keys.contains("getCiphers"))
    #expect(keys.contains("rootCertificates"))
}

@Test func tlsDefaultVersions() {
    let runtime = NodeRuntime()
    let minVersion = runtime.evaluate("require('tls').DEFAULT_MIN_VERSION")
    #expect(minVersion?.toString() == "TLSv1.2")
    let maxVersion = runtime.evaluate("require('tls').DEFAULT_MAX_VERSION")
    #expect(maxVersion?.toString() == "TLSv1.3")
}

@Test func tlsCreateSecureContext() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var tls = require('tls');
        var ctx = tls.createSecureContext({ minVersion: 'TLSv1.3' });
        JSON.stringify(ctx);
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("TLSv1.3"))
    #expect(json.contains("minVersion"))
}

@Test func tlsGetCiphers() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('tls').getCiphers().length")
    #expect(result?.toInt32() ?? 0 > 0)
}

@Test(.timeLimit(.minutes(1)))
func tlsServerAndClientEcho() async throws {
    let certs = try generateSelfSignedCert()

    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in
        messages.append(msg)
        print("[TLS] \(msg)")
    }

    // Escape PEM strings for JS
    let certJS = certs.cert.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "'", with: "\\'")
    let keyJS = certs.key.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "'", with: "\\'")

    runtime.evaluate("""
        var tls = require('tls');
        var server = tls.createServer({
            cert: '\(certJS)',
            key: '\(keyJS)'
        }, function(socket) {
            console.log('server:secureConnection');
            socket.on('data', function(data) {
                console.log('server:data:' + data.toString());
                socket.write(data); // echo back
            });
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);

            var client = tls.connect({
                port: addr.port,
                host: '127.0.0.1',
                rejectUnauthorized: false
            }, function() {
                console.log('client:secureConnect');
                client.write('hello-tls');
            });
            client.on('data', function(buf) {
                console.log('client:data:' + buf.toString());
                client.destroy();
                server.close();
            });
        });
    """)

    await runEventLoopAsync(runtime, timeout: 15)

    #expect(messages.contains { $0.hasPrefix("listening:") })
    #expect(messages.contains("server:secureConnection"))
    #expect(messages.contains("client:secureConnect"))
    #expect(messages.contains("server:data:hello-tls"))
    #expect(messages.contains("client:data:hello-tls"))
}

@Test(.timeLimit(.minutes(1)))
func tlsSocketEncryptedProperty() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var tls = require('tls');
        var socket = new tls.TLSSocket();
        console.log('encrypted:' + socket.encrypted);
        console.log('authorized:' + socket.authorized);
    """)

    await runEventLoopAsync(runtime, timeout: 3)

    #expect(messages.contains("encrypted:true"))
    #expect(messages.contains("authorized:false"))
}

@Test(.timeLimit(.minutes(1)))
func tlsGetCipherAndProtocol() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var tls = require('tls');
        var socket = new tls.TLSSocket();
        var cipher = socket.getCipher();
        console.log('cipher:' + cipher.name);
        console.log('protocol:' + socket.getProtocol());
    """)

    await runEventLoopAsync(runtime, timeout: 3)

    #expect(messages.contains("cipher:TLS_AES_256_GCM_SHA384"))
    #expect(messages.contains("protocol:TLSv1.3"))
}

@Test(.timeLimit(.minutes(1)))
func tlsServerListening() async throws {
    let certs = try generateSelfSignedCert()

    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in
        messages.append(msg)
        print("[TLS] \(msg)")
    }

    let certJS = certs.cert.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "'", with: "\\'")
    let keyJS = certs.key.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "'", with: "\\'")

    runtime.evaluate("""
        var tls = require('tls');
        var server = tls.createServer({
            cert: '\(certJS)',
            key: '\(keyJS)'
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
            server.close();
        });
    """)

    await runEventLoopAsync(runtime, timeout: 10)

    #expect(messages.contains { $0.hasPrefix("listening:") })
}

@Test(.timeLimit(.minutes(1)))
func tlsConnectArgParsing() {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Test that tls.connect parses options correctly (will fail to connect but should not throw)
    runtime.evaluate("""
        var tls = require('tls');
        try {
            var socket = tls.connect({ port: 1, host: '127.0.0.1', rejectUnauthorized: false });
            console.log('created:' + socket.encrypted);
            console.log('connecting:' + socket.connecting);
            socket.destroy();
        } catch (e) {
            console.log('error:' + e.message);
        }
    """)

    #expect(messages.contains("created:true"))
    #expect(messages.contains("connecting:true"))
}
