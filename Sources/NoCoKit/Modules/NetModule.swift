import Foundation
@preconcurrency import JavaScriptCore
import Network

/// Real TCP client implementation of Node.js `net` module using NWConnection.
public struct NetModule: NodeModule {
    public static let moduleName = "net"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Per-runtime socket storage (captured by closures below)
        final class SocketStorage {
            var sockets: [Int: TCPSocket] = [:]
            var nextSocketId: Int = 1
        }
        let storage = SocketStorage()

        // Register Swift-side native bridge functions

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
            guard let tcp = storage.sockets[id] else { return false }
            let len = Int(dataVal.forProperty("length")?.toInt32() ?? 0)
            var bytes = Data(count: len)
            for i in 0..<len {
                bytes[i] = UInt8(dataVal.atIndex(i).toInt32() & 0xFF)
            }
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
                connect: connect,
                createConnection: createConnection,
                createServer: function() {
                    throw new Error('net.createServer is not supported');
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

// MARK: - TCPSocket

/// Wraps NWConnection to provide TCP client functionality, dispatching events
/// back to the JS event loop.
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
                    sock.invokeMethod("emit", withArguments: ["close", true])
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
