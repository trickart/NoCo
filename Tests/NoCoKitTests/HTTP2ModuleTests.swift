import Testing
import Foundation
import JavaScriptCore
@testable import NoCoKit
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2

/// Helper: run the event loop on a background thread to avoid blocking cooperative threads.
private func runEventLoopInBackground(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

// MARK: - HTTP/2 Module API Tests

@Test func http2ModuleLoads() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        typeof http2.createServer === 'function' &&
        typeof http2.createSecureServer === 'function' &&
        typeof http2.connect === 'function' &&
        typeof http2.getDefaultSettings === 'function' &&
        typeof http2.getPackedSettings === 'function' &&
        typeof http2.getUnpackedSettings === 'function' &&
        typeof http2.constants === 'object' &&
        typeof http2.sensitiveHeaders === 'symbol';
    """)
    #expect(result?.toBool() == true)
}

@Test func http2Constants() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var c = require('http2').constants;
        [
            c.HTTP2_HEADER_STATUS === ':status',
            c.HTTP2_HEADER_METHOD === ':method',
            c.HTTP2_HEADER_AUTHORITY === ':authority',
            c.HTTP2_HEADER_SCHEME === ':scheme',
            c.HTTP2_HEADER_PATH === ':path',
            c.HTTP2_METHOD_GET === 'GET',
            c.HTTP2_METHOD_POST === 'POST',
            c.HTTP2_METHOD_DELETE === 'DELETE',
            c.HTTP_STATUS_OK === 200,
            c.HTTP_STATUS_NOT_FOUND === 404,
            c.HTTP_STATUS_INTERNAL_SERVER_ERROR === 500,
            c.NGHTTP2_NO_ERROR === 0,
            c.NGHTTP2_PROTOCOL_ERROR === 1,
            c.NGHTTP2_DEFAULT_WEIGHT === 16
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

@Test func http2GetDefaultSettings() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var s = require('http2').getDefaultSettings();
        s.headerTableSize === 4096 &&
        s.enablePush === true &&
        s.initialWindowSize === 65535 &&
        s.maxFrameSize === 16384 &&
        s.maxConcurrentStreams === 4294967295 &&
        s.maxHeaderListSize === 65535 &&
        s.enableConnectProtocol === false;
    """)
    #expect(result?.toBool() == true)
}

@Test func http2CreateServerAPI() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        var server = http2.createServer(function(req, res) {});
        typeof server.listen === 'function' &&
        typeof server.close === 'function' &&
        typeof server.address === 'function' &&
        typeof server.on === 'function' &&
        typeof server.emit === 'function' &&
        typeof server.setTimeout === 'function' &&
        typeof server.ref === 'function' &&
        typeof server.unref === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func http2ClassInstances() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        typeof http2.Http2ServerRequest === 'function' &&
        typeof http2.Http2ServerResponse === 'function' &&
        typeof http2.Http2Stream === 'function' &&
        typeof http2.Http2Session === 'function' &&
        typeof http2.Http2Server === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func http2ServerCompatibilityAPI() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    // Test that the request handler receives correct data via _handleRequest
    runtime.evaluate("""
        var http2 = require('http2');
        var server = http2.createServer(function(req, res) {
            console.log('method:' + req.method);
            console.log('url:' + req.url);
            console.log('version:' + req.httpVersion);
            console.log('host:' + req.headers.host);
            res.writeHead(200, { 'content-type': 'text/plain' });
            res.end('OK');
        });
        // Simulate a request
        server._handleRequest(1, 'GET', '/test', { host: 'localhost' }, '2.0', '');
    """)

    #expect(messages.contains("method:GET"))
    #expect(messages.contains("url:/test"))
    #expect(messages.contains("version:2.0"))
    #expect(messages.contains("host:localhost"))
}

@Test func http2ServerResponseMethods() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        var res = new http2.Http2ServerResponse(1);
        res.setHeader('content-type', 'text/html');
        var ct = res.getHeader('content-type');
        res.removeHeader('content-type');
        var ct2 = res.getHeader('content-type');
        ct === 'text/html' && ct2 === undefined;
    """)
    #expect(result?.toBool() == true)
}

@Test func http2StreamAPI() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        var stream = new http2.Http2Stream(42);
        stream.id === 42 &&
        stream.destroyed === false &&
        stream.closed === false &&
        typeof stream.respond === 'function' &&
        typeof stream.write === 'function' &&
        typeof stream.end === 'function' &&
        typeof stream.close === 'function';
    """)
    #expect(result?.toBool() == true)
}

@Test func http2SessionAPI() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var http2 = require('http2');
        var session = new http2.Http2Session();
        session.destroyed === false &&
        session.closed === false &&
        typeof session.destroy === 'function' &&
        typeof session.close === 'function' &&
        typeof session.settings === 'function' &&
        session.localSettings.headerTableSize === 4096;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - HTTP/2 Server Integration Tests

@Test(.timeLimit(.minutes(1)))
func http2ServerListens() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http2 = require('http2');
        var server = http2.createServer(function(req, res) {
            res.writeHead(200, { 'content-type': 'text/plain' });
            res.end('Hello HTTP/2');
        });
        server.listen(0, '127.0.0.1', function() {
            var addr = server.address();
            console.log('listening:' + addr.port);
        });
    """)

    let eventLoopTask = Task.detached {
        await runEventLoopInBackground(runtime, timeout: 10)
    }

    // Wait for server to start
    var port = 0
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        if let msg = messages.first(where: { $0.hasPrefix("listening:") }) {
            port = Int(msg.replacingOccurrences(of: "listening:", with: "")) ?? 0
            break
        }
    }
    #expect(port > 0)

    runtime.eventLoop.stop()
    await eventLoopTask.value
}

@Test(.timeLimit(.minutes(1)))
func http2ServerHandlesH2CRequest() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var http2 = require('http2');
        var server = http2.createServer(function(req, res) {
            res.writeHead(200, { 'content-type': 'text/plain' });
            res.end('Hello HTTP/2');
        });
        server.listen(0, '127.0.0.1', function() {
            console.log('listening:' + server.address().port);
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

    // Create NIO HTTP/2 client for h2c (prior knowledge)
    let (statusCode, body) = try await makeH2CRequest(host: "127.0.0.1", port: port, path: "/test")
    #expect(statusCode == 200)
    #expect(body == "Hello HTTP/2")

    // Cleanup
    runtime.eventLoop.stop()
    await eventLoopTask.value
}

// MARK: - h2c Client Helper

/// Handler to collect the HTTP/2 response.
private final class H2ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    let promise: NIOCore.EventLoopPromise<(Int, String)>
    var status: Int = 0
    var body: String = ""

    init(promise: NIOCore.EventLoopPromise<(Int, String)>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
        case .body(var buf):
            body += buf.readString(length: buf.readableBytes) ?? ""
        case .end:
            promise.succeed((status, body))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}

/// Holder for the HTTP2StreamMultiplexer reference.
private final class MuxHolder: @unchecked Sendable {
    var multiplexer: HTTP2StreamMultiplexer?
}

/// Make an h2c (HTTP/2 cleartext with prior knowledge) request using NIO.
/// Runs synchronous NIO operations on a background DispatchQueue to avoid blocking Swift concurrency.
private func makeH2CRequest(host: String, port: Int, path: String) async throws -> (Int, String) {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                defer { try? clientGroup.syncShutdownGracefully() }

                let holder = MuxHolder()

                let clientChannel = try ClientBootstrap(group: clientGroup)
                    .channelInitializer { channel in
                        channel.configureHTTP2Pipeline(mode: .client, position: .last) { streamChannel in
                            streamChannel.eventLoop.makeSucceededVoidFuture()
                        }.map { multiplexer in
                            holder.multiplexer = multiplexer
                        }
                    }
                    .connect(host: host, port: port)
                    .wait()

                guard let multiplexer = holder.multiplexer else {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No multiplexer"])
                }

                let responsePromise = clientChannel.eventLoop.makePromise(of: (Int, String).self)
                let streamPromise = clientChannel.eventLoop.makePromise(of: Channel.self)

                multiplexer.createStreamChannel(promise: streamPromise) { streamChannel in
                    streamChannel.pipeline.addHandlers([
                        HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http),
                        H2ResponseHandler(promise: responsePromise),
                    ])
                }

                let streamChannel = try streamPromise.futureResult.wait()

                var reqHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: path)
                reqHead.headers.add(name: "host", value: "\(host):\(port)")
                streamChannel.write(HTTPClientRequestPart.head(reqHead), promise: nil)
                try streamChannel.writeAndFlush(HTTPClientRequestPart.end(nil)).wait()

                let result = try responsePromise.futureResult.wait()

                try? clientChannel.close().wait()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
