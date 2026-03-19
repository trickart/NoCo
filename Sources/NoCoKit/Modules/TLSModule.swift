import Foundation
@preconcurrency import JavaScriptCore
import Network
import NIOCore
import NIOTransportServices
import Security
import Synchronization

/// Implements Node.js `tls` module with TLS client/server support.
/// Client uses NWConnection with TLS; server uses NIOTransportServices with TLS.
public struct TLSModule: NodeModule {
    public static let moduleName = "tls"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Per-runtime storage
        final class TLSStorage {
            var sockets: [Int: TLSTCPSocket] = [:]
            var nextSocketId: Int = 1
            var servers: [Int: NIOTLSServer] = [:]
            var nextServerId: Int = 1
            var nioSockets: [Int: NIOAcceptedSocket] = [:]
        }
        let storage = TLSStorage()
        let nioSocketIdCounter = AtomicCounter(initial: 200000)

        // __tlsConnect(host, port, servername, rejectUnauthorized, cert, key, ca, jsSocket) -> socketId
        let connectBlock: @convention(block) (String, Int, JSValue, Bool, JSValue, JSValue, JSValue, JSValue) -> Int = {
            host, port, servernameVal, rejectUnauthorized, certVal, keyVal, caVal, jsSocket in
            let id = storage.nextSocketId
            storage.nextSocketId += 1

            let servername = servernameVal.isUndefined || servernameVal.isNull ? host : servernameVal.toString()!
            let cert = certVal.isUndefined || certVal.isNull ? nil : certVal.toString()
            let key = keyVal.isUndefined || keyVal.isNull ? nil : keyVal.toString()

            let tlsOptions = TLSModule.createClientTLSOptions(
                servername: servername,
                rejectUnauthorized: rejectUnauthorized,
                certPEM: cert,
                keyPEM: key
            )

            let tcp = TLSTCPSocket(
                host: host,
                port: UInt16(port),
                eventLoop: runtime.eventLoop,
                tlsOptions: tlsOptions
            )
            tcp.jsSocket = jsSocket
            storage.sockets[id] = tcp
            runtime.eventLoop.retainHandle()
            tcp.start()
            return id
        }
        context.setObject(connectBlock, forKeyedSubscript: "__tlsConnect" as NSString)

        // __tlsWrite(socketId, dataArray, callback) -> Bool
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
        context.setObject(writeBlock, forKeyedSubscript: "__tlsWrite" as NSString)

        // __tlsDestroy(socketId)
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
        context.setObject(destroyBlock, forKeyedSubscript: "__tlsDestroy" as NSString)

        // __tlsSetTimeout(socketId, timeoutMs)
        let setTimeoutBlock: @convention(block) (Int, Int) -> Void = { id, ms in
            storage.sockets[id]?.setIdleTimeout(ms: ms)
        }
        context.setObject(setTimeoutBlock, forKeyedSubscript: "__tlsSetTimeout" as NSString)

        // __tlsCreateServer(certPEM, keyPEM) -> serverId or -1
        let createServerBlock: @convention(block) (String, String) -> Int = { certPEM, keyPEM in
            guard let tlsOpts = PEMHelper.createTLSOptions(certPEM: certPEM, keyPEM: keyPEM, passphrase: nil) else {
                return -1
            }
            let id = storage.nextServerId
            storage.nextServerId += 1
            let server = NIOTLSServer(
                eventLoop: runtime.eventLoop,
                nioSocketIdCounter: nioSocketIdCounter,
                tlsOptions: tlsOpts
            ) { nioSock in
                storage.nioSockets[nioSock.socketId] = nioSock
                runtime.eventLoop.retainHandle()
            }
            storage.servers[id] = server
            return id
        }
        context.setObject(createServerBlock, forKeyedSubscript: "__tlsCreateServer" as NSString)

        // __tlsServerListen(serverId, port, host, jsServer)
        let serverListenBlock: @convention(block) (Int, Int, String, JSValue) -> Void = { id, port, host, jsServer in
            guard let server = storage.servers[id] else { return }
            server.jsServer = jsServer
            runtime.eventLoop.retainHandle()
            server.bind(host: host, port: port)
        }
        context.setObject(serverListenBlock, forKeyedSubscript: "__tlsServerListen" as NSString)

        // __tlsServerClose(serverId)
        let serverCloseBlock: @convention(block) (Int) -> Void = { id in
            guard let server = storage.servers[id] else { return }
            for (sid, nioSock) in storage.nioSockets {
                nioSock.close()
                storage.nioSockets.removeValue(forKey: sid)
                runtime.eventLoop.releaseHandle()
            }
            server.close()
            storage.servers.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(serverCloseBlock, forKeyedSubscript: "__tlsServerClose" as NSString)

        // __tlsServerAddress(serverId)
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
        context.setObject(serverAddressBlock, forKeyedSubscript: "__tlsServerAddress" as NSString)

        // __tlsNioSocketSetOnData(socketId, jsSocket)
        let nioSocketSetOnDataBlock: @convention(block) (Int, JSValue) -> Void = { id, jsSocket in
            guard let nioSock = storage.nioSockets[id] else { return }
            nioSock.jsSocket = jsSocket
        }
        context.setObject(nioSocketSetOnDataBlock, forKeyedSubscript: "__tlsNioSocketSetOnData" as NSString)

        // JS implementation
        let script = """
        (function() {
            var EventEmitter = this.__NoCo_EventEmitter;
            var net = require('net');

            // TLSSocket extends net.Socket
            function TLSSocket(options) {
                if (!(this instanceof TLSSocket)) return new TLSSocket(options);
                this._events = Object.create(null);
                this._maxListeners = 10;
                this.readable = true;
                this.writable = true;
                this.destroyed = false;
                this.connecting = false;
                this.encrypted = true;
                this.authorized = false;
                this.authorizationError = null;
                this.remoteAddress = null;
                this.remotePort = null;
                this._socketId = -1;
                this._timeoutMs = 0;
                this._encoding = null;
            }
            TLSSocket.prototype = Object.create(EventEmitter.prototype);
            TLSSocket.prototype.constructor = TLSSocket;

            TLSSocket.prototype.write = function(data, encoding, callback) {
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
                    arr.push(buf[i]);
                }
                return __tlsWrite(this._socketId, arr, callback || null);
            };

            TLSSocket.prototype.end = function(data, encoding, callback) {
                if (typeof data === 'function') { callback = data; data = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                if (data) this.write(data, encoding);
                this.destroy();
                if (callback) callback();
                return this;
            };

            TLSSocket.prototype.destroy = function(err) {
                if (this.destroyed) return this;
                this.destroyed = true;
                this.writable = false;
                this.readable = false;
                if (this._socketId >= 0) {
                    __tlsDestroy(this._socketId);
                }
                if (err) this.emit('error', err);
                return this;
            };

            TLSSocket.prototype.setTimeout = function(timeout, callback) {
                if (callback) this.once('timeout', callback);
                this._timeoutMs = timeout;
                if (this._socketId >= 0) {
                    __tlsSetTimeout(this._socketId, timeout);
                }
                return this;
            };

            TLSSocket.prototype.setNoDelay = function() { return this; };
            TLSSocket.prototype.setKeepAlive = function() { return this; };
            TLSSocket.prototype.ref = function() { return this; };
            TLSSocket.prototype.unref = function() { return this; };

            TLSSocket.prototype.setEncoding = function(enc) {
                this._encoding = enc;
                return this;
            };

            TLSSocket.prototype.getPeerCertificate = function() {
                return {};
            };

            TLSSocket.prototype.getCipher = function() {
                return { name: 'TLS_AES_256_GCM_SHA384', standardName: 'TLS_AES_256_GCM_SHA384', version: 'TLSv1.3' };
            };

            TLSSocket.prototype.getProtocol = function() {
                return 'TLSv1.3';
            };

            TLSSocket.prototype.pipe = function(dest) {
                var self = this;
                this.on('data', function(chunk) { dest.write(chunk); });
                this.on('end', function() { if (typeof dest.end === 'function') dest.end(); });
                return dest;
            };

            var origEmit = EventEmitter.prototype.emit;
            TLSSocket.prototype.emit = function(event) {
                if (event === 'data' && this._encoding && arguments[1] instanceof Buffer) {
                    arguments[1] = arguments[1].toString(this._encoding);
                }
                return origEmit.apply(this, arguments);
            };

            // tls.Server
            function Server(options, secureConnectionListener) {
                if (!(this instanceof Server)) return new Server(options, secureConnectionListener);
                if (typeof options === 'function') {
                    secureConnectionListener = options;
                    options = {};
                }
                options = options || {};
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._options = options;
                this.listening = false;
                this.maxConnections = 0;

                var certPEM = options.cert ? options.cert.toString() : '';
                var keyPEM = options.key ? options.key.toString() : '';
                this._serverId = __tlsCreateServer(certPEM, keyPEM);
                if (this._serverId < 0) {
                    throw new Error('Failed to parse TLS certificate/key');
                }

                if (secureConnectionListener) this.on('secureConnection', secureConnectionListener);
            }
            Server.prototype = Object.create(EventEmitter.prototype);
            Server.prototype.constructor = Server;

            Server.prototype.listen = function(port, host, backlog, callback) {
                if (typeof host === 'function') { callback = host; host = '0.0.0.0'; }
                if (typeof backlog === 'function') { callback = backlog; backlog = undefined; }
                if (!host) host = '0.0.0.0';
                if (callback) this.once('listening', callback);
                this.listening = true;
                __tlsServerListen(this._serverId, port || 0, host, this);
                return this;
            };

            Server.prototype.close = function(callback) {
                if (callback) this.once('close', callback);
                this.listening = false;
                __tlsServerClose(this._serverId);
                this.emit('close');
                return this;
            };

            Server.prototype.address = function() {
                return __tlsServerAddress(this._serverId);
            };

            Server.prototype.ref = function() { return this; };
            Server.prototype.unref = function() { return this; };

            Server.prototype._handleConnection = function(socketId, remoteAddr, remotePort) {
                var socket = new TLSSocket();
                socket._socketId = socketId;
                socket.remoteAddress = remoteAddr;
                socket.remotePort = remotePort;
                socket.connecting = false;
                socket.authorized = true;
                __tlsNioSocketSetOnData(socketId, socket);
                this.emit('secureConnection', socket);
            };

            // tls.connect(options, callback)
            function connect(port, host, options, callback) {
                // Parse arguments: connect(port[, host][, options][, callback])
                // or connect(options[, callback])
                if (typeof port === 'object' && port !== null) {
                    // connect(options[, callback])
                    callback = host;
                    options = port;
                    port = options.port;
                    host = options.host || 'localhost';
                } else {
                    if (typeof host === 'function') {
                        callback = host;
                        host = 'localhost';
                        options = {};
                    } else if (typeof host === 'object' && host !== null) {
                        callback = options;
                        options = host;
                        host = options.host || 'localhost';
                    } else if (typeof options === 'function') {
                        callback = options;
                        options = {};
                    }
                    if (!host) host = 'localhost';
                    if (!options) options = {};
                }

                var socket = new TLSSocket();
                socket.connecting = true;
                socket.remoteAddress = host;
                socket.remotePort = port;

                if (callback) socket.once('secureConnect', callback);

                var servername = options.servername || host;
                var rejectUnauthorized = options.rejectUnauthorized !== false;
                var cert = options.cert || null;
                var key = options.key || null;
                var ca = options.ca || null;

                socket._socketId = __tlsConnect(
                    host, port,
                    servername,
                    rejectUnauthorized,
                    cert ? cert.toString() : null,
                    key ? key.toString() : null,
                    ca ? ca.toString() : null,
                    socket
                );

                return socket;
            }

            function createServer(options, secureConnectionListener) {
                return new Server(options, secureConnectionListener);
            }

            function createSecureContext(options) {
                options = options || {};
                return {
                    cert: options.cert || null,
                    key: options.key || null,
                    ca: options.ca || null,
                    minVersion: options.minVersion || 'TLSv1.2',
                    maxVersion: options.maxVersion || 'TLSv1.3'
                };
            }

            return {
                TLSSocket: TLSSocket,
                Server: Server,
                connect: connect,
                createServer: createServer,
                createSecureContext: createSecureContext,
                DEFAULT_MIN_VERSION: 'TLSv1.2',
                DEFAULT_MAX_VERSION: 'TLSv1.3',
                rootCertificates: [],
                getCiphers: function() {
                    return ['TLS_AES_256_GCM_SHA384', 'TLS_CHACHA20_POLY1305_SHA256', 'TLS_AES_128_GCM_SHA256'];
                }
            };
        })();
        """

        return context.evaluateScript(script)!
    }

    // MARK: - Client TLS Options

    /// Create NWProtocolTLS.Options for a TLS client connection.
    static func createClientTLSOptions(
        servername: String,
        rejectUnauthorized: Bool,
        certPEM: String?,
        keyPEM: String?
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions

        // Set SNI
        sec_protocol_options_set_tls_server_name(secOptions, servername)

        // Set minimum TLS version
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)

        // Skip server certificate verification if rejectUnauthorized is false
        if !rejectUnauthorized {
            sec_protocol_options_set_verify_block(secOptions, { _, _, completionHandler in
                completionHandler(true)
            }, DispatchQueue.global())
        }

        // Client certificate (mTLS)
        if let certPEM, let keyPEM {
            if let tlsIdentityOptions = PEMHelper.createTLSOptions(certPEM: certPEM, keyPEM: keyPEM, passphrase: nil) {
                let identitySecOptions = tlsIdentityOptions.securityProtocolOptions
                // Copy identity from the PEMHelper-created options
                // We need to get the identity and set it on our options
                // PEMHelper sets it via sec_protocol_options_set_local_identity
                // For simplicity, just use the PEMHelper options directly
                // but add our SNI and verify settings
                sec_protocol_options_set_tls_server_name(identitySecOptions, servername)
                if !rejectUnauthorized {
                    sec_protocol_options_set_verify_block(identitySecOptions, { _, _, completionHandler in
                        completionHandler(true)
                    }, DispatchQueue.global())
                }
                return tlsIdentityOptions
            }
        }

        return options
    }
}

// MARK: - TLSTCPSocket (client)

/// TLS-enabled TCP client using NWConnection with TLS parameters.
final class TLSTCPSocket: @unchecked Sendable {
    let connection: NWConnection
    let eventLoop: EventLoop
    var jsSocket: JSValue?
    private var idleTimeoutMs: Int = 0
    private var idleTimer: DispatchWorkItem?

    init(host: String, port: UInt16, eventLoop: EventLoop, tlsOptions: NWProtocolTLS.Options, connectionTimeoutSec: Int = 10) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = connectionTimeoutSec
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
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
                    sock.setValue(true, forProperty: "authorized")
                    sock.invokeMethod("emit", withArguments: ["connect"])
                    sock.invokeMethod("emit", withArguments: ["secureConnect"])
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

// MARK: - NIOTLSServer

/// TLS server using NIOTransportServices (NIOTSListenerBootstrap) with TLS.
final class NIOTLSServer: TCPServerDelegate, @unchecked Sendable {
    let eventLoop: EventLoop
    let nioSocketIdCounter: AtomicCounter
    let onRegister: (NIOAcceptedSocket) -> Void
    let tlsOptions: NWProtocolTLS.Options
    var jsServer: JSValue?
    var boundPort: Int = 0
    var boundHost: String = ""
    private var group: NIOTSEventLoopGroup?
    private var channel: Channel?

    init(eventLoop: EventLoop, nioSocketIdCounter: AtomicCounter, tlsOptions: NWProtocolTLS.Options, onRegister: @escaping (NIOAcceptedSocket) -> Void) {
        self.eventLoop = eventLoop
        self.nioSocketIdCounter = nioSocketIdCounter
        self.tlsOptions = tlsOptions
        self.onRegister = onRegister
    }

    func bind(host: String, port: Int) {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        self.group = group
        let serverRef = self

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .tlsOptions(tlsOptions)
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
        DispatchQueue.global().async {
            ch?.close(promise: nil)
            try? g?.syncShutdownGracefully()
        }
    }

    func nextSocketId() -> Int {
        nioSocketIdCounter.next()
    }
}
