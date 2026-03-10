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

// MARK: - HTTPS Module Basic Tests

@Test func httpsModuleExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        typeof https === 'object' && typeof https.request === 'function' && typeof https.get === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsModuleHasCreateServer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        typeof https.createServer === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsGlobalAgent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        https.globalAgent.defaultPort === 443 && https.globalAgent.protocol === 'https:';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsRequestReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        var req = https.request({ hostname: 'localhost', port: 9999, path: '/test', protocol: 'https:' });
        typeof req === 'object' && typeof req.write === 'function' && typeof req.end === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsGetReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        var req = https.get({ hostname: 'localhost', port: 9999, path: '/test', protocol: 'https:' });
        typeof req === 'object' && typeof req.write === 'function' && typeof req.end === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsHasStatusCodes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var https = require('https');
        https.STATUS_CODES['200'] === 'OK' && https.STATUS_CODES['404'] === 'Not Found';
    """)
    #expect(result?.toBool() == true)
}

@Test func httpsCreateServerRequiresCertAndKey() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var https = require('https');
        var threw = false;
        try {
            https.createServer(function(req, res) {});
        } catch(e) {
            threw = true;
            console.log('error:' + e.message);
        }
        console.log('threw:' + threw);
    """)
    #expect(messages.contains("threw:true"))
    #expect(messages.contains(where: { $0.contains("requires") }))
}

// MARK: - HTTPS Client Tests

@Test(.timeLimit(.minutes(1)))
func httpsGetExternalAPI() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var https = require('https');
        https.get('https://jsonplaceholder.typicode.com/posts/1', function(res) {
            var data = '';
            res.on('data', function(chunk) { data += chunk; });
            res.on('end', function() {
                var parsed = JSON.parse(data);
                console.log('status:' + res.statusCode);
                console.log('hasUserId:' + (parsed.userId !== undefined));
                console.log('hasTitle:' + (parsed.title !== undefined));
            });
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 15)
    }

    // Wait for request to complete
    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("status:") }) {
            break
        }
    }

    #expect(messages.contains("status:200"))
    #expect(messages.contains("hasUserId:true"))
    #expect(messages.contains("hasTitle:true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func httpsRequestWithOptions() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var https = require('https');
        var req = https.request({
            hostname: 'jsonplaceholder.typicode.com',
            path: '/posts/1',
            method: 'GET',
            protocol: 'https:'
        }, function(res) {
            var data = '';
            res.on('data', function(chunk) { data += chunk; });
            res.on('end', function() {
                console.log('status:' + res.statusCode);
                console.log('hasData:' + (data.length > 0));
            });
        });
        req.end();
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 15)
    }

    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if messages.contains(where: { $0.hasPrefix("status:") }) {
            break
        }
    }

    #expect(messages.contains("status:200"))
    #expect(messages.contains("hasData:true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - PEM Helper Tests

@Test func pemParserCertificate() async throws {
    let certPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBkTCB+wIJALRiMLAh0EIAMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl
    c3RjYTAeFw0yMzAxMDEwMDAwMDBaFw0yNDAxMDEwMDAwMDBaMBExDzANBgNVBAMM
    BnRlc3RjYTBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC7o96h+ZhBMwGaAN5MFMXU
    MEZLQmEDaFOhAGbsHCMOSa4gDAJamEL9bnpBCP9GjTFfOPB0Jhr+JnG3kROPi1sC
    AwEAATANBgkqhkiG9w0BAQsFAANBAHCsKEJNB+1V6D7X1IlJGyhTsm3JO+LaA3sS
    E7FRMqeaLgZxfkaYBdWDl9rM2D5VaEeYb3dlVSfWMEYEqWNmLzQ=
    -----END CERTIFICATE-----
    """

    let data = PEMHelper.parsePEM(certPEM, type: "CERTIFICATE")
    #expect(data != nil)
    #expect(data!.count > 0)
}

@Test func pemParserPrivateKey() async throws {
    let keyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAu6PeofjYQTMBmgDe
    TBTF1DBGS0JhA2hToQBm7BwjDkmuIAwCWphC/W56QQj/Ro0xXzjwdCYa/iZxt5ET
    j4tbAgMBAAECQC5K6MyZi1yXJ/EUekQfYAs8fKMfM+AEsGFkMN6OIOP72j3aqGDo
    GWol0VDAkN3aTi/gRm+FJ+5JE0VaI5dC4JECIQD6mQW7yh0HB4/IhLwj+DR0bIM
    NKCG4HGmMrSgZ5m6kwIhAL9/Gw3nvVS3UrHmJW6Lkhrqtjv5LLn6X+WyNMRLbfJ
    AiA6lnZz8x2+sOS7W8LY8S8PKj7hLp0kJ2nnuB8ZqXjH9QIgQb69r7cz/FKmYtFh
    Rph4Hh0d+0kkjC9QXyGRjqWEITkCIQC8L6TpFvj3sE7R/dM4KOuPn4sMbgxRk8IP
    O26N5r3GQ==
    -----END PRIVATE KEY-----
    """

    let data = PEMHelper.parsePEM(keyPEM, type: "PRIVATE KEY")
    #expect(data != nil)
    #expect(data!.count > 0)
}

@Test func pemParserRSAPrivateKey() async throws {
    let keyPEM = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEAu6PeofjYQTMBmgDe
    TBTF1DBGS0JhA2hToQBm7BwjDkmuIAwCWphC/W56QQj/Ro0xXzjwdCYa/iZxt5ET
    j4tbAgMBAAECQC5K6MyZi1yXJ/EUekQfYAs8fKMfM+AEsGFkMN6OIOP72j3aqGDo
    GWol0VDAkN3aTi/gRm+FJ+5JE0VaI5dC4JECIQD6mQW7yh0HB4/IhLwj+DR0bIM
    NKCG4HGmMrSgZ5m6kwIhAL9/Gw3nvVS3UrHmJW6Lkhrqtjv5LLn6X+WyNMRLbfJ
    AiA6lnZz8x2+sOS7W8LY8S8PKj7hLp0kJ2nnuB8ZqXjH9QIgQb69r7cz/FKmYtFh
    Rph4Hh0d+0kkjC9QXyGRjqWEITkCIQC8L6TpFvj3sE7R/dM4KOuPn4sMbgxRk8IP
    O26N5r3GQ==
    -----END RSA PRIVATE KEY-----
    """

    let data = PEMHelper.parsePEM(keyPEM, type: "RSA PRIVATE KEY")
    #expect(data != nil)
    #expect(data!.count > 0)
}

@Test func pemParserInvalid() async throws {
    let data = PEMHelper.parsePEM("not a pem", type: "CERTIFICATE")
    #expect(data == nil)
}

// MARK: - HTTPS Server Tests (self-signed certificate)

@Test(.timeLimit(.minutes(1)))
func httpsCreateServerWithSelfSignedCert() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Generate self-signed certificate using openssl
    let certDir = NSTemporaryDirectory() + "noco-test-cert-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: certDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: certDir) }

    let keyPath = certDir + "/key.pem"
    let certPath = certDir + "/cert.pem"

    // Generate RSA key and self-signed certificate
    let genProc = Process()
    genProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    genProc.arguments = [
        "req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath,
        "-out", certPath, "-days", "1", "-nodes",
        "-subj", "/CN=localhost",
    ]
    genProc.standardOutput = FileHandle.nullDevice
    genProc.standardError = FileHandle.nullDevice
    try genProc.run()
    genProc.waitUntilExit()
    guard genProc.terminationStatus == 0 else {
        #expect(Bool(false), "Failed to generate test certificate")
        return
    }

    let certPEM = try String(contentsOfFile: certPath, encoding: .utf8)
    let keyPEM = try String(contentsOfFile: keyPath, encoding: .utf8)

    // Escape for JS string
    let certJS = certPEM.replacingOccurrences(of: "\n", with: "\\n")
    let keyJS = keyPEM.replacingOccurrences(of: "\n", with: "\\n")

    runtime.evaluate("""
        var https = require('https');
        var server = https.createServer({
            cert: "\(certJS)",
            key: "\(keyJS)"
        }, function(req, res) {
            console.log('encrypted:' + req.socket.encrypted);
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('Hello HTTPS!');
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 15)
    }

    // Wait for server to start
    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    // Make HTTPS request from Swift (skip cert validation for self-signed)
    let url = URL(string: "https://127.0.0.1:\(port)/test")!
    let delegate = TestInsecureDelegate()
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let (data, response) = try await session.data(from: url)
    let httpResponse = response as! HTTPURLResponse
    let body = String(data: data, encoding: .utf8)!

    #expect(httpResponse.statusCode == 200)
    #expect(body == "Hello HTTPS!")
    #expect(messages.contains("encrypted:true"))

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

/// URLSession delegate that accepts self-signed certificates for testing.
private final class TestInsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
