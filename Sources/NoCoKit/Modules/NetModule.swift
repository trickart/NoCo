import Foundation
@preconcurrency import JavaScriptCore
import Network
import NIOCore
import NIOTransportServices
import Synchronization

/// Real TCP client + server implementation of Node.js `net` module.
/// Client uses NWConnection; server uses NIOTransportServices (NIOTSListenerBootstrap).
public struct NetModule: NodeModule {
    public static let moduleName = "net"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Per-runtime storage (captured by closures below, accessed only from jsQueue)
        final class NetStorage {
            var sockets: [Int: TCPSocket] = [:]
            var nextSocketId: Int = 1
            var servers: [Int: NIOTCPServer] = [:]
            var nextServerId: Int = 1
            var nioSockets: [Int: NIOAcceptedSocket] = [:]
        }
        let storage = NetStorage()
        // Thread-safe counter for NIO socket IDs (accessed from NIO thread)
        let nioSocketIdCounter = AtomicCounter(initial: 100000)

        // __netConnect(host, port, jsSocket) -> socketId
        let connectBlock: @convention(block) (String, Int, JSValue) -> Int = { host, port, jsSocket in
            let id = storage.nextSocketId
            storage.nextSocketId += 1
            let tcp = TCPSocket(host: host, port: UInt16(port), eventLoop: runtime.eventLoop)
            tcp.jsSocket = jsSocket
            storage.sockets[id] = tcp
            runtime.eventLoop.retainHandle()
            tcp.start()
            return id
        }
        context.setObject(connectBlock, forKeyedSubscript: "__netConnect" as NSString)

        // __netWrite(socketId, dataArray, callback) -> Bool
        let writeBlock: @convention(block) (Int, JSValue, JSValue) -> Bool = { id, dataVal, cb in
            let len = Int(dataVal.forProperty("length")?.toInt32() ?? 0)
            var bytes = Data(count: len)
            for i in 0..<len {
                bytes[i] = UInt8(dataVal.atIndex(i).toInt32() & 0xFF)
            }

            if let nioSock = storage.nioSockets[id] {
                nioSock.write(bytes) {
                    if !cb.isNull && !cb.isUndefined {
                        runtime.eventLoop.enqueueCallback {
                            cb.call(withArguments: [])
                        }
                    }
                }
                return true
            }

            guard let tcp = storage.sockets[id] else { return false }
            tcp.write(bytes) { _ in
                if !cb.isNull && !cb.isUndefined {
                    cb.call(withArguments: [])
                }
            }
            return true
        }
        context.setObject(writeBlock, forKeyedSubscript: "__netWrite" as NSString)

        // __netDestroy(socketId)
        let destroyBlock: @convention(block) (Int) -> Void = { id in
            if let nioSock = storage.nioSockets[id] {
                nioSock.close()
                storage.nioSockets.removeValue(forKey: id)
                runtime.eventLoop.releaseHandle()
                return
            }
            storage.sockets[id]?.destroy()
            storage.sockets.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(destroyBlock, forKeyedSubscript: "__netDestroy" as NSString)

        // __netSetTimeout(socketId, timeoutMs)
        let setTimeoutBlock: @convention(block) (Int, Int) -> Void = { id, ms in
            storage.sockets[id]?.setIdleTimeout(ms: ms)
        }
        context.setObject(setTimeoutBlock, forKeyedSubscript: "__netSetTimeout" as NSString)

        // __netCreateServer() -> serverId
        let createServerBlock: @convention(block) () -> Int = {
            let id = storage.nextServerId
            storage.nextServerId += 1
            let server = NIOTCPServer(eventLoop: runtime.eventLoop, nioSocketIdCounter: nioSocketIdCounter) { nioSock in
                // Called from eventLoop callback (on jsQueue) to register the socket
                storage.nioSockets[nioSock.socketId] = nioSock
                runtime.eventLoop.retainHandle()
            }
            storage.servers[id] = server
            return id
        }
        context.setObject(createServerBlock, forKeyedSubscript: "__netCreateServer" as NSString)

        // __netServerListen(serverId, port, host, jsServer)
        let serverListenBlock: @convention(block) (Int, Int, String, JSValue) -> Void = { id, port, host, jsServer in
            guard let server = storage.servers[id] else { return }
            server.jsServer = jsServer
            runtime.eventLoop.retainHandle()
            server.bind(host: host, port: port)
        }
        context.setObject(serverListenBlock, forKeyedSubscript: "__netServerListen" as NSString)

        // __netServerClose(serverId)
        let serverCloseBlock: @convention(block) (Int) -> Void = { id in
            guard let server = storage.servers[id] else { return }
            // Close all accepted sockets belonging to this server
            for (sid, nioSock) in storage.nioSockets {
                nioSock.close()
                storage.nioSockets.removeValue(forKey: sid)
                runtime.eventLoop.releaseHandle()
            }
            server.close()
            storage.servers.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(serverCloseBlock, forKeyedSubscript: "__netServerClose" as NSString)

        // __netServerAddress(serverId)
        let serverAddressBlock: @convention(block) (Int) -> JSValue = { id in
            let ctx = JSContext.current()!
            guard let server = storage.servers[id] else {
                return JSValue(nullIn: ctx)
            }
            let obj = JSValue(newObjectIn: ctx)!
            obj.setValue(server.boundPort, forProperty: "port")
            obj.setValue(server.boundHost, forProperty: "address")
            obj.setValue("IPv4", forProperty: "family")
            return obj
        }
        context.setObject(serverAddressBlock, forKeyedSubscript: "__netServerAddress" as NSString)

        // __netNioSocketSetOnData(socketId, jsSocket)
        let nioSocketSetOnDataBlock: @convention(block) (Int, JSValue) -> Void = { id, jsSocket in
            guard let nioSock = storage.nioSockets[id] else { return }
            nioSock.jsSocket = jsSocket
        }
        context.setObject(nioSocketSetOnDataBlock, forKeyedSubscript: "__netNioSocketSetOnData" as NSString)

        let script = """
        (function() {
            var EventEmitter = this.__NoCo_EventEmitter;

            function Socket(options) {
                if (!(this instanceof Socket)) {
                    return new Socket(options);
                }
                this._events = Object.create(null);
                this._maxListeners = 10;
                this.readable = true;
                this.writable = true;
                this.destroyed = false;
                this.connecting = false;
                this.remoteAddress = null;
                this.remotePort = null;
                this._socketId = -1;
                this._timeoutMs = 0;
                this._encoding = null;
            }
            Socket.prototype = Object.create(EventEmitter.prototype);
            Socket.prototype.constructor = Socket;

            Socket.prototype.connect = function(port, host, callback) {
                if (typeof host === 'function') { callback = host; host = 'localhost'; }
                if (!host) host = 'localhost';
                this.connecting = true;
                this.remoteAddress = host;
                this.remotePort = port;
                if (callback) this.once('connect', callback);
                this._socketId = __netConnect(host, port, this);
                return this;
            };

            Socket.prototype.write = function(data, encoding, callback) {
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                encoding = encoding || 'utf8';
                var buf;
                if (typeof data === 'string') {
                    buf = Buffer.from(data, encoding);
                } else if (data instanceof Buffer) {
                    buf = data;
                } else {
                    buf = Buffer.from(data);
                }
                var arr = [];
                for (var i = 0; i < buf.length; i++) {
                    arr.push(buf._data ? buf._data[i] : buf[i]);
                }
                return __netWrite(this._socketId, arr, callback || null);
            };

            Socket.prototype.end = function(data, encoding, callback) {
                if (typeof data === 'function') { callback = data; data = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                if (data) this.write(data, encoding);
                this.destroy();
                if (callback) callback();
                return this;
            };

            Socket.prototype.destroy = function(err) {
                if (this.destroyed) return this;
                this.destroyed = true;
                this.writable = false;
                this.readable = false;
                if (this._socketId >= 0) {
                    __netDestroy(this._socketId);
                }
                if (err) this.emit('error', err);
                return this;
            };

            Socket.prototype.setTimeout = function(timeout, callback) {
                if (callback) this.once('timeout', callback);
                this._timeoutMs = timeout;
                if (this._socketId >= 0) {
                    __netSetTimeout(this._socketId, timeout);
                }
                return this;
            };

            Socket.prototype.setNoDelay = function() { return this; };
            Socket.prototype.setKeepAlive = function() { return this; };
            Socket.prototype.ref = function() { return this; };
            Socket.prototype.unref = function() { return this; };

            Socket.prototype.setEncoding = function(enc) {
                this._encoding = enc;
                return this;
            };

            Socket.prototype.pipe = function(dest) {
                var self = this;
                this.on('data', function(chunk) {
                    dest.write(chunk);
                });
                this.on('end', function() {
                    if (typeof dest.end === 'function') dest.end();
                });
                return dest;
            };

            var origEmit = EventEmitter.prototype.emit;
            Socket.prototype.emit = function(event) {
                if (event === 'data' && this._encoding && arguments[1] instanceof Buffer) {
                    arguments[1] = arguments[1].toString(this._encoding);
                }
                return origEmit.apply(this, arguments);
            };

            function Server(options, connectionListener) {
                if (!(this instanceof Server)) return new Server(options, connectionListener);
                if (typeof options === 'function') {
                    connectionListener = options;
                    options = {};
                }
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._serverId = __netCreateServer();
                this.listening = false;
                this.maxConnections = 0;
                if (connectionListener) this.on('connection', connectionListener);
            }
            Server.prototype = Object.create(EventEmitter.prototype);
            Server.prototype.constructor = Server;

            Server.prototype.listen = function(port, host, backlog, callback) {
                if (typeof host === 'function') { callback = host; host = '0.0.0.0'; }
                if (typeof backlog === 'function') { callback = backlog; backlog = undefined; }
                if (!host) host = '0.0.0.0';
                if (callback) this.once('listening', callback);
                this.listening = true;
                __netServerListen(this._serverId, port || 0, host, this);
                return this;
            };

            Server.prototype.close = function(callback) {
                if (callback) this.once('close', callback);
                this.listening = false;
                __netServerClose(this._serverId);
                this.emit('close');
                return this;
            };

            Server.prototype.address = function() {
                return __netServerAddress(this._serverId);
            };

            Server.prototype.ref = function() { return this; };
            Server.prototype.unref = function() { return this; };

            Server.prototype._handleConnection = function(socketId, remoteAddr, remotePort) {
                var socket = new Socket();
                socket._socketId = socketId;
                socket.remoteAddress = remoteAddr;
                socket.remotePort = remotePort;
                socket.connecting = false;
                __netNioSocketSetOnData(socketId, socket);
                this.emit('connection', socket);
            };

            function connect(port, host, callback) {
                if (typeof port === 'object') {
                    var opts = port;
                    callback = host;
                    return new Socket().connect(opts.port, opts.host || 'localhost', callback);
                }
                return new Socket().connect(port, host, callback);
            }

            function createConnection(port, host, callback) {
                return connect(port, host, callback);
            }

            function isIP(input) {
                if (typeof input !== 'string') return 0;
                if (/^(\\d{1,3}\\.){3}\\d{1,3}$/.test(input)) {
                    var parts = input.split('.');
                    for (var i = 0; i < 4; i++) {
                        if (parseInt(parts[i], 10) > 255) return 0;
                    }
                    return 4;
                }
                if (input.indexOf(':') !== -1 && /^[0-9a-fA-F:]+$/.test(input)) return 6;
                return 0;
            }

            function isIPv4(input) { return isIP(input) === 4; }
            function isIPv6(input) { return isIP(input) === 6; }

            return {
                Socket: Socket,
                Server: Server,
                connect: connect,
                createConnection: createConnection,
                createServer: function(options, connectionListener) {
                    return new Server(options, connectionListener);
                },
                isIP: isIP,
                isIPv4: isIPv4,
                isIPv6: isIPv6
            };
        })();
        """

        return context.evaluateScript(script)!
    }
}

// MARK: - TCPSocket (client)

/// Wraps NWConnection to provide TCP client functionality.
final class TCPSocket: @unchecked Sendable {
    let connection: NWConnection
    let eventLoop: EventLoop
    var jsSocket: JSValue?
    private var idleTimeoutMs: Int = 0
    private var idleTimer: DispatchWorkItem?

    init(host: String, port: UInt16, eventLoop: EventLoop, connectionTimeoutSec: Int = 10) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = connectionTimeoutSec
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        self.connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.eventLoop = eventLoop
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.eventLoop.enqueueCallback {
                    guard let sock = self.jsSocket else { return }
                    sock.setValue(false, forProperty: "connecting")
                    sock.invokeMethod("emit", withArguments: ["connect"])
                }
                self.startReceiving()
            case .failed(let error):
                self.eventLoop.enqueueCallback {
                    guard let sock = self.jsSocket, let ctx = sock.context else { return }
                    let err = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                    sock.invokeMethod("emit", withArguments: ["error", err as Any])
                    sock.invokeMethod("destroy", withArguments: [])
                }
            case .waiting(let error):
                self.eventLoop.enqueueCallback {
                    guard let sock = self.jsSocket, let ctx = sock.context else { return }
                    let err = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                    sock.invokeMethod("emit", withArguments: ["error", err as Any])
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func write(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.eventLoop.enqueueCallback {
                if let error {
                    guard let sock = self.jsSocket, let ctx = sock.context else { return }
                    let err = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                    sock.invokeMethod("emit", withArguments: ["error", err as Any])
                    completion(false)
                } else {
                    self.jsSocket?.invokeMethod("emit", withArguments: ["drain"])
                    completion(true)
                }
            }
        })
    }

    func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let data = content, !data.isEmpty {
                self.resetIdleTimer()
                self.eventLoop.enqueueCallback {
                    guard let sock = self.jsSocket, let ctx = sock.context else { return }
                    let bufCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)
                    let bytes = [UInt8](data)
                    let jsArr = JSValue(newArrayIn: ctx)!
                    for (i, byte) in bytes.enumerated() {
                        jsArr.setValue(byte, at: i)
                    }
                    let buf = bufCtor?.invokeMethod("from", withArguments: [jsArr])
                    sock.invokeMethod("emit", withArguments: ["data", buf as Any])
                }
            }
            if isComplete {
                self.eventLoop.enqueueCallback {
                    self.jsSocket?.invokeMethod("emit", withArguments: ["end"])
                    self.jsSocket?.invokeMethod("emit", withArguments: ["close", false])
                }
            } else if error == nil {
                self.startReceiving()
            }
        }
    }

    func destroy() {
        idleTimer?.cancel()
        idleTimer = nil
        connection.cancel()
        let sock = jsSocket
        jsSocket = nil
        eventLoop.enqueueCallback {
            sock?.invokeMethod("emit", withArguments: ["close", false])
        }
    }

    func setIdleTimeout(ms: Int) {
        idleTimeoutMs = ms
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
        guard idleTimeoutMs > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventLoop.enqueueCallback {
                self.jsSocket?.invokeMethod("emit", withArguments: ["timeout"])
            }
        }
        idleTimer = item
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(idleTimeoutMs),
            execute: item
        )
    }
}

// MARK: - NIOTCPServer

/// TCP server using NIOTransportServices (NIOTSListenerBootstrap).
final class NIOTCPServer: @unchecked Sendable {
    let eventLoop: EventLoop
    let nioSocketIdCounter: AtomicCounter
    let onRegister: (NIOAcceptedSocket) -> Void
    var jsServer: JSValue?
    var boundPort: Int = 0
    var boundHost: String = ""
    private var group: NIOTSEventLoopGroup?
    private var channel: Channel?

    init(eventLoop: EventLoop, nioSocketIdCounter: AtomicCounter, onRegister: @escaping (NIOAcceptedSocket) -> Void) {
        self.eventLoop = eventLoop
        self.nioSocketIdCounter = nioSocketIdCounter
        self.onRegister = onRegister
    }

    func bind(host: String, port: Int) {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        self.group = group
        let serverRef = self

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(TCPBridgeHandler(server: serverRef))
            }

        bootstrap.bind(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let ch):
                self.channel = ch
                if let addr = ch.localAddress {
                    self.boundPort = addr.port ?? port
                    self.boundHost = addr.ipAddress ?? host
                }
                self.eventLoop.enqueueCallback {
                    self.jsServer?.invokeMethod("emit", withArguments: ["listening"])
                }
            case .failure(let error):
                self.eventLoop.enqueueCallback {
                    guard let js = self.jsServer, let ctx = js.context else { return }
                    let err = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                    js.invokeMethod("emit", withArguments: ["error", err as Any])
                }
            }
        }
    }

    func close() {
        let ch = channel
        let g = group
        channel = nil
        group = nil
        // Perform shutdown on a background queue to avoid blocking jsQueue
        DispatchQueue.global().async {
            ch?.close(promise: nil)
            try? g?.syncShutdownGracefully()
        }
    }

    func nextSocketId() -> Int {
        nioSocketIdCounter.next()
    }
}

// MARK: - TCPBridgeHandler

/// NIO ChannelInboundHandler for raw TCP (no HTTP codec).
final class TCPBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let server: NIOTCPServer
    var acceptedSocket: NIOAcceptedSocket?

    init(server: NIOTCPServer) {
        self.server = server
    }

    func channelActive(context: ChannelHandlerContext) {
        let remoteAddr = context.remoteAddress?.ipAddress ?? "127.0.0.1"
        let remotePort = context.remoteAddress?.port ?? 0
        let socketId = server.nextSocketId()
        let nioSock = NIOAcceptedSocket(socketId: socketId, channel: context.channel, eventLoop: server.eventLoop)
        self.acceptedSocket = nioSock

        server.eventLoop.enqueueCallback { [weak self] in
            guard let self else { return }
            self.server.onRegister(nioSock)
            self.server.jsServer?.invokeMethod("_handleConnection", withArguments: [socketId, remoteAddr, remotePort])
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        acceptedSocket?.deliverData(bytes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        acceptedSocket?.deliverEnd()
    }
}

// MARK: - NIOAcceptedSocket

/// Represents a server-accepted TCP connection via NIO channel.
final class NIOAcceptedSocket: @unchecked Sendable {
    let socketId: Int
    var channel: Channel?
    let eventLoop: EventLoop
    var jsSocket: JSValue?

    init(socketId: Int, channel: Channel, eventLoop: EventLoop) {
        self.socketId = socketId
        self.channel = channel
        self.eventLoop = eventLoop
    }

    func write(_ data: Data, completion: @escaping () -> Void) {
        guard let channel = channel else { return }
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        channel.writeAndFlush(buf, promise: nil)
        completion()
    }

    func close() {
        channel?.close(promise: nil)
        channel = nil
    }

    func deliverData(_ bytes: [UInt8]) {
        eventLoop.enqueueCallback { [weak self] in
            guard let self, let sock = self.jsSocket, let ctx = sock.context else { return }
            let bufCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)
            let jsArr = JSValue(newArrayIn: ctx)!
            for (i, byte) in bytes.enumerated() {
                jsArr.setValue(byte, at: i)
            }
            let buf = bufCtor?.invokeMethod("from", withArguments: [jsArr])
            sock.invokeMethod("emit", withArguments: ["data", buf as Any])
        }
    }

    func deliverEnd() {
        eventLoop.enqueueCallback { [weak self] in
            guard let self, let sock = self.jsSocket else { return }
            sock.invokeMethod("emit", withArguments: ["end"])
            sock.invokeMethod("emit", withArguments: ["close", false])
        }
    }
}

// MARK: - AtomicCounter

/// Simple thread-safe counter using Mutex.
final class AtomicCounter: Sendable {
    private let state: Mutex<Int>

    init(initial: Int) {
        self.state = Mutex(initial)
    }

    func next() -> Int {
        state.withLock { value in
            let current = value
            value += 1
            return current
        }
    }
}
