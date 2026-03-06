import Foundation
@preconcurrency import JavaScriptCore
import NIOCore
import NIOHTTP1
import NIOTransportServices

/// Implements Node.js `http` module. Client uses URLSession; server uses NIOHTTP1.
public struct HTTPModule: NodeModule {
    public static let moduleName = "http"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let http = JSValue(newObjectIn: context)!

        // Per-runtime server storage
        final class HTTPStorage {
            var servers: [Int: NIOHTTPServer] = [:]
            var nextServerId: Int = 1
            var pendingRequests: [Int: HTTPRequestState] = [:]
        }
        let storage = HTTPStorage()

        // --- Server bridge functions ---

        // __httpCreateServer() -> serverId
        let createServerBlock: @convention(block) () -> Int = {
            let id = storage.nextServerId
            storage.nextServerId += 1
            let server = NIOHTTPServer(eventLoop: runtime.eventLoop) { reqState in
                storage.pendingRequests[reqState.requestId] = reqState
            }
            storage.servers[id] = server
            return id
        }
        context.setObject(createServerBlock, forKeyedSubscript: "__httpCreateServer" as NSString)

        // __httpServerListen(serverId, port, host, jsServer)
        let serverListenBlock: @convention(block) (Int, Int, String, JSValue) -> Void = { id, port, host, jsServer in
            guard let server = storage.servers[id] else { return }
            server.jsServer = jsServer
            runtime.eventLoop.retainHandle()
            server.bind(host: host, port: port)
        }
        context.setObject(serverListenBlock, forKeyedSubscript: "__httpServerListen" as NSString)

        // __httpServerClose(serverId)
        let serverCloseBlock: @convention(block) (Int) -> Void = { id in
            guard let server = storage.servers[id] else { return }
            server.close()
            storage.servers.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(serverCloseBlock, forKeyedSubscript: "__httpServerClose" as NSString)

        // __httpServerAddress(serverId)
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
        context.setObject(serverAddressBlock, forKeyedSubscript: "__httpServerAddress" as NSString)

        // __httpWriteHead(requestId, statusCode, headersArray)
        let writeHeadBlock: @convention(block) (Int, Int, JSValue) -> Void = { reqId, statusCode, jsHeaders in
            guard let state = storage.pendingRequests[reqId] else { return }
            state.statusCode = statusCode
            let len = Int(jsHeaders.forProperty("length")?.toInt32() ?? 0)
            var i = 0
            while i < len - 1 {
                let key = jsHeaders.atIndex(i).toString() ?? ""
                let value = jsHeaders.atIndex(i + 1).toString() ?? ""
                state.responseHeaders.append((key, value))
                i += 2
            }
        }
        context.setObject(writeHeadBlock, forKeyedSubscript: "__httpWriteHead" as NSString)

        // __httpWriteBody(requestId, data) -> Bool (channel.isWritable)
        let writeBodyBlock: @convention(block) (Int, JSValue) -> Bool = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return true }
            return state.writeChunk(httpExtractBytes(from: dataVal))
        }
        context.setObject(writeBodyBlock, forKeyedSubscript: "__httpWriteBody" as NSString)

        // __httpEnd(requestId, data?)
        let endBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            let finalBytes: [UInt8]? = (!dataVal.isNull && !dataVal.isUndefined)
                ? httpExtractBytes(from: dataVal) : nil
            state.sendEnd(withFinalBody: finalBytes)
            storage.pendingRequests.removeValue(forKey: reqId)
        }
        context.setObject(endBlock, forKeyedSubscript: "__httpEnd" as NSString)

        // --- JS-side http.createServer ---
        let createServerJS = """
        (function(http) {
            var EventEmitter = this.__NoCo_EventEmitter;
            var Stream = require('stream');
            var Readable = Stream.Readable;

            function IncomingMessage(reqId, method, url, headers, httpVersion, rawHeaders, remoteAddr, remotePort) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this.readable = true;
                this._readableState = {
                    buffer: [],
                    ended: false,
                    flowing: null,
                    encoding: null
                };
                this._reqId = reqId;
                this.method = method;
                this.url = url;
                this.headers = headers;
                this.httpVersion = httpVersion;
                this._encoding = null;
                this._body = [];
                this._ended = false;
                this.complete = false;
                this.errored = null;
                this.rawHeaders = rawHeaders || [];
                var addr = remoteAddr || '127.0.0.1';
                var port = remotePort || 0;
                this.socket = {
                    encrypted: false,
                    remoteAddress: addr,
                    remotePort: port,
                    remoteFamily: addr.indexOf(':') !== -1 ? 'IPv6' : 'IPv4'
                };
            }
            IncomingMessage.prototype = Object.create(Readable.prototype);
            IncomingMessage.prototype.constructor = IncomingMessage;
            IncomingMessage.prototype.setEncoding = function(enc) { this._encoding = enc; return this; };
            IncomingMessage.prototype.destroy = function(err) {
                this._ended = true;
                if (err) this.errored = err;
                this.emit('close');
                return this;
            };

            function ServerResponse(reqId) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._reqId = reqId;
                this.statusCode = 200;
                this._headers = {};
                this._headersSent = false;
                this.finished = false;
                this.writable = true;
                this.writableFinished = false;
                this._closed = false;
                this._writableNeedDrain = false;
                this.writableHighWaterMark = 16384;
            }
            ServerResponse.prototype = Object.create(EventEmitter.prototype);
            ServerResponse.prototype.constructor = ServerResponse;
            Object.defineProperty(ServerResponse.prototype, 'headersSent', {
                get: function() { return this._headersSent; }
            });
            ServerResponse.prototype.flushHeaders = function() {
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
            };
            ServerResponse.prototype._emitClose = function() {
                if (this._closed) return;
                this._closed = true;
                this.emit('close');
            };
            ServerResponse.prototype.destroy = function(err) {
                this.finished = true;
                this.writable = false;
                if (err) this.emit('error', err);
                this._emitClose();
                return this;
            };

            ServerResponse.prototype.setHeader = function(name, value) {
                this._headers[name.toLowerCase()] = value;
            };
            ServerResponse.prototype.getHeader = function(name) {
                return this._headers[name.toLowerCase()];
            };
            ServerResponse.prototype.removeHeader = function(name) {
                delete this._headers[name.toLowerCase()];
            };
            ServerResponse.prototype.writeHead = function(statusCode, reasonOrHeaders, headers) {
                this.statusCode = statusCode;
                var h = headers || (typeof reasonOrHeaders === 'object' ? reasonOrHeaders : null);
                if (h) {
                    var keys = Object.keys(h);
                    for (var i = 0; i < keys.length; i++) {
                        this._headers[keys[i].toLowerCase()] = h[keys[i]];
                    }
                }
                this._headersSent = true;
                var flat = [];
                var hkeys = Object.keys(this._headers);
                for (var j = 0; j < hkeys.length; j++) {
                    flat.push(hkeys[j]);
                    flat.push(String(this._headers[hkeys[j]]));
                }
                __httpWriteHead(this._reqId, this.statusCode, flat);
                return this;
            };
            ServerResponse.prototype.write = function(data, encoding) {
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
                if (data) {
                    var ok = __httpWriteBody(this._reqId, data);
                    if (!ok) this._writableNeedDrain = true;
                    return ok;
                }
                return true;
            };
            ServerResponse.prototype.end = function(data, encoding, callback) {
                if (typeof data === 'function') { callback = data; data = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
                this.finished = true;
                __httpEnd(this._reqId, data || null);
                this.emit('finish');
                if (callback) callback();
                this._emitClose();
            };

            function Server(requestListener) {
                if (!(this instanceof Server)) return new Server(requestListener);
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._serverId = __httpCreateServer();
                this._responses = {};
                this._requests = {};
                this.listening = false;
                if (requestListener) this.on('request', requestListener);
            }
            Server.prototype = Object.create(EventEmitter.prototype);
            Server.prototype.constructor = Server;

            Server.prototype.listen = function(port, host, backlog, callback) {
                if (typeof host === 'function') { callback = host; host = '0.0.0.0'; }
                if (typeof backlog === 'function') { callback = backlog; backlog = undefined; }
                if (!host) host = '0.0.0.0';
                if (callback) this.once('listening', callback);
                this.listening = true;
                __httpServerListen(this._serverId, port || 0, host, this);
                return this;
            };

            Server.prototype.close = function(callback) {
                if (callback) this.once('close', callback);
                this.listening = false;
                __httpServerClose(this._serverId);
                this.emit('close');
                return this;
            };

            Server.prototype.address = function() {
                return __httpServerAddress(this._serverId);
            };

            Server.prototype.setTimeout = function() { return this; };
            Server.prototype.ref = function() { return this; };
            Server.prototype.unref = function() { return this; };

            Server.prototype._notifyClose = function(reqId) {
                var res = this._responses[reqId];
                var req = this._requests[reqId];
                if (res) res._emitClose();
                if (req && !req._ended) {
                    req._ended = true;
                    req._readableState.ended = true;
                    req.emit('error', new Error('Connection closed'));
                    req.emit('close');
                }
            };

            Server.prototype._pushBodyChunk = function(reqId, chunk) {
                var req = this._requests[reqId];
                if (!req || req._ended) return;
                req._body.push(chunk);
                req.emit('data', chunk);
            };

            Server.prototype._endBody = function(reqId) {
                var req = this._requests[reqId];
                if (!req || req._ended) return;
                if (req._body.length > 0) {
                    req.rawBody = Buffer.concat(req._body.map(function(c) {
                        return Buffer.isBuffer(c) ? c : Buffer.from(c, 'utf8');
                    }));
                }
                req._ended = true;
                req.complete = true;
                req._readableState.ended = true;
                req.emit('end');
            };

            Server.prototype._emitDrain = function(reqId) {
                var res = this._responses[reqId];
                if (res && res._writableNeedDrain) {
                    res._writableNeedDrain = false;
                    res.emit('drain');
                }
            };

            Server.prototype._handleRequest = function(reqId, method, url, headersObj, httpVersion, bodyStr, rawHeaders, remoteAddr, remotePort) {
                var req = new IncomingMessage(reqId, method, url, headersObj, httpVersion, rawHeaders || [], remoteAddr, remotePort);
                var res = new ServerResponse(reqId);
                var self = this;
                self._responses[reqId] = res;
                self._requests[reqId] = req;
                res.on('finish', function() {
                    res.writableFinished = true;
                    res.writable = false;
                });
                res.on('close', function() {
                    delete self._responses[reqId];
                    delete self._requests[reqId];
                });
                if (bodyStr != null && bodyStr.length > 0) {
                    req._body.push(bodyStr);
                    req.rawBody = Buffer.from(bodyStr, 'utf8');
                }
                this.emit('request', req, res);
                if (bodyStr != null) {
                    for (var i = 0; i < req._body.length; i++) {
                        req.emit('data', req._body[i]);
                    }
                    req._ended = true;
                    req.complete = true;
                    req._readableState.ended = true;
                    req.emit('end');
                }
            };

            http.createServer = function(options, requestListener) {
                if (typeof options === 'function') {
                    requestListener = options;
                }
                return new Server(requestListener);
            };

            http.Server = Server;
            http.IncomingMessage = IncomingMessage;
            http.ServerResponse = ServerResponse;
        })
        """
        let setupFn = context.evaluateScript(createServerJS)!
        setupFn.call(withArguments: [http])

        // --- Client-side http.request (URLSession-based) ---
        let request: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard !args.isEmpty else { return JSValue(undefinedIn: JSContext.current()) }
            let ctx = JSContext.current()!

            var urlString: String
            var options: JSValue?
            var callback: JSValue?

            if args[0].isString {
                urlString = args[0].toString()
                if args.count > 1 && args[1].isObject && !args[1].hasProperty("on") {
                    options = args[1]
                    callback = args.count > 2 ? args[2] : nil
                } else {
                    callback = args.count > 1 ? args[1] : nil
                }
            } else {
                options = args[0]
                callback = args.count > 1 ? args[1] : nil
                let proto = options?.property("protocol")?.toString() ?? "http:"
                let hostname = options?.property("hostname")?.toString()
                    ?? options?.property("host")?.toString() ?? "localhost"
                let port = options?.property("port")?.toString()
                let path = options?.property("path")?.toString() ?? "/"
                let portStr = port != nil ? ":\(port!)" : ""
                urlString = "\(proto)//\(hostname)\(portStr)\(path)"
            }

            let method = options?.property("method")?.toString()?.uppercased() ?? "GET"
            let headers = options?.property("headers")
            let capturedCallback = callback

            let reqScript = """
            (function() {
                var EventEmitter = this.__NoCo_EventEmitter;
                var req = new EventEmitter();
                req._body = [];
                req.write = function(chunk) { req._body.push(chunk); };
                req.end = function(chunk) {
                    if (chunk) req._body.push(chunk);
                    req._ended = true;
                    req.emit('_send');
                };
                req.abort = function() { req.emit('abort'); };
                req.setTimeout = function(ms, cb) { if(cb) req.on('timeout', cb); };
                return req;
            })()
            """
            let req = ctx.evaluateScript(reqScript)!

            let onSend: @convention(block) () -> Void = {
                guard let url = URL(string: urlString) else {
                    let err = ctx.createError("Invalid URL: \(urlString)")
                    req.invokeMethod("emit", withArguments: ["error", err])
                    return
                }

                var urlReq = URLRequest(url: url)
                urlReq.httpMethod = method

                if let headers = headers, !headers.isUndefined {
                    let keys = ctx.evaluateScript("Object.keys")?.call(withArguments: [headers])
                    let keyCount = Int(keys?.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<keyCount {
                        let key = keys?.atIndex(i)?.toString() ?? ""
                        let value = headers.forProperty(key)?.toString() ?? ""
                        urlReq.setValue(value, forHTTPHeaderField: key)
                    }
                }

                let bodyParts = req.forProperty("_body")!
                let bodyLen = Int(bodyParts.forProperty("length")?.toInt32() ?? 0)
                if bodyLen > 0 {
                    var bodyData = Data()
                    for i in 0..<bodyLen {
                        let part = bodyParts.atIndex(i)!
                        if part.isString {
                            bodyData.append(part.toString()!.data(using: .utf8)!)
                        }
                    }
                    urlReq.httpBody = bodyData
                }

                let task = URLSession.shared.dataTask(with: urlReq) { data, response, error in
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        if let error = error {
                            let jsErr = ctx.createError(error.localizedDescription)
                            req.invokeMethod("emit", withArguments: ["error", jsErr])
                            return
                        }

                        guard let httpResp = response as? HTTPURLResponse else { return }

                        let resScript = """
                        (function() {
                            var EventEmitter = this.__NoCo_EventEmitter;
                            var res = new EventEmitter();
                            res.readable = true;
                            res._chunks = [];
                            res.setEncoding = function(enc) { res._encoding = enc; return res; };
                            res.on = function(event, handler) {
                                EventEmitter.prototype.on.call(res, event, handler);
                                if (event === 'data' && res._chunks.length > 0) {
                                    var chunks = res._chunks.slice();
                                    res._chunks = [];
                                    for (var i = 0; i < chunks.length; i++) {
                                        handler(chunks[i]);
                                    }
                                    if (res._ended) {
                                        setTimeout(function() { res.emit('end'); }, 0);
                                    }
                                }
                                return res;
                            };
                            return res;
                        })()
                        """
                        let res = ctx.evaluateScript(resScript)!

                        res.setValue(httpResp.statusCode, forProperty: "statusCode")
                        res.setValue(httpResp.allHeaderFields.description, forProperty: "statusMessage")

                        let headersObj = JSValue(newObjectIn: ctx)!
                        for (key, value) in httpResp.allHeaderFields {
                            headersObj.setValue(
                                "\(value)", forProperty: "\(key)".lowercased())
                        }
                        res.setValue(headersObj, forProperty: "headers")

                        if let cb = capturedCallback, !cb.isUndefined {
                            cb.call(withArguments: [res])
                        }
                        req.invokeMethod("emit", withArguments: ["response", res])

                        if let data = data, !data.isEmpty {
                            let str = String(data: data, encoding: .utf8) ?? ""
                            res.forProperty("_chunks")?.invokeMethod("push", withArguments: [str])
                            res.invokeMethod("emit", withArguments: ["data", str])
                        }

                        res.setValue(true, forProperty: "_ended")
                        res.invokeMethod("emit", withArguments: ["end"])
                    }
                }
                task.resume()
            }
            req.invokeMethod("on", withArguments: ["_send", unsafeBitCast(onSend, to: AnyObject.self)])

            if method == "GET" || method == "HEAD" {
                req.invokeMethod("end", withArguments: [])
            }

            return req
        }
        http.setValue(unsafeBitCast(request, to: AnyObject.self), forProperty: "request")

        // http.get
        let get: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            let req = http.invokeMethod("request", withArguments: args)!
            return req
        }
        http.setValue(unsafeBitCast(get, to: AnyObject.self), forProperty: "get")

        // http.METHODS
        let methods = context.evaluateScript("""
            ['ACL','BIND','CHECKOUT','CONNECT','COPY','DELETE','GET','HEAD',
             'LINK','LOCK','M-SEARCH','MERGE','MKACTIVITY','MKCALENDAR',
             'MKCOL','MOVE','NOTIFY','OPTIONS','PATCH','POST','PROPFIND',
             'PROPPATCH','PURGE','PUT','REBIND','REPORT','SEARCH','SOURCE',
             'SUBSCRIBE','TRACE','UNBIND','UNLINK','UNLOCK','UNSUBSCRIBE']
        """)!
        http.setValue(methods, forProperty: "METHODS")

        // http.STATUS_CODES
        let statusCodes = JSValue(newObjectIn: context)!
        let codes: [Int: String] = [
            100: "Continue", 200: "OK", 201: "Created", 204: "No Content",
            301: "Moved Permanently", 302: "Found", 304: "Not Modified",
            400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
            500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
        ]
        for (code, msg) in codes {
            statusCodes.setValue(msg, forProperty: String(code))
        }
        http.setValue(statusCodes, forProperty: "STATUS_CODES")

        return http
    }
}

// MARK: - NIOHTTPServer

/// HTTP server using NIOTransportServices + NIOHTTP1 codec.
final class NIOHTTPServer: @unchecked Sendable {
    let eventLoop: EventLoop
    let onRegisterRequest: (HTTPRequestState) -> Void
    var jsServer: JSValue?
    var boundPort: Int = 0
    var boundHost: String = ""
    private var group: NIOTSEventLoopGroup?
    private var channel: Channel?
    private let requestIdCounter = AtomicCounter(initial: 1)

    init(eventLoop: EventLoop, onRegisterRequest: @escaping (HTTPRequestState) -> Void) {
        self.eventLoop = eventLoop
        self.onRegisterRequest = onRegisterRequest
    }

    func bind(host: String, port: Int) {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        self.group = group
        let serverRef = self

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder()),
                    HTTPResponseEncoder(),
                    HTTPBridgeHandler(server: serverRef),
                ])
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

    func nextRequestId() -> Int {
        requestIdCounter.next()
    }
}

// MARK: - Helper

/// Extract bytes from a JSValue (String, Buffer, or Uint8Array).
private func httpExtractBytes(from dataVal: JSValue) -> [UInt8] {
    if dataVal.isString, let str = dataVal.toString() {
        return Array(str.utf8)
    }
    let bufData = dataVal.forProperty("_data")!
    let source = bufData.isUndefined ? dataVal : bufData
    let len = Int(source.forProperty("length")?.toInt32() ?? 0)
    var bytes = [UInt8]()
    bytes.reserveCapacity(len)
    for i in 0..<len {
        bytes.append(UInt8(source.atIndex(i).toInt32() & 0xFF))
    }
    return bytes
}

// MARK: - HTTPRequestState

/// Manages per-request state and streams the HTTP response via NIO channel.
final class HTTPRequestState: @unchecked Sendable {
    let requestId: Int
    let channel: Channel
    let keepAlive: Bool
    var statusCode: Int = 200
    var responseHeaders: [(String, String)] = []
    private var headSent: Bool = false
    private var hasWrittenBody: Bool = false

    init(requestId: Int, channel: Channel, keepAlive: Bool) {
        self.requestId = requestId
        self.channel = channel
        self.keepAlive = keepAlive
    }

    /// Send HTTP head to NIO channel (idempotent — only executes on first call).
    /// Adds `transfer-encoding: chunked` when neither Content-Length nor Transfer-Encoding is set.
    func sendHead() {
        guard !headSent else { return }
        headSent = true

        let status = HTTPResponseStatus(statusCode: statusCode)
        var head = HTTPResponseHead(version: .http1_1, status: status)
        for (key, value) in responseHeaders {
            head.headers.add(name: key, value: value)
        }
        if !head.headers.contains(name: "content-length") && !head.headers.contains(name: "transfer-encoding") {
            head.headers.add(name: "transfer-encoding", value: "chunked")
        }
        if keepAlive {
            head.headers.replaceOrAdd(name: "connection", value: "keep-alive")
        }
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
    }

    /// Write a body chunk immediately to the NIO channel.
    /// Returns `channel.isWritable` for backpressure signaling.
    @discardableResult
    func writeChunk(_ bytes: [UInt8]) -> Bool {
        sendHead()
        hasWrittenBody = true
        if !bytes.isEmpty {
            var buf = channel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        }
        return channel.isWritable
    }

    /// Finish the response. When no prior `writeChunk` was called, uses Content-Length
    /// for a single-shot response (avoiding chunked encoding).
    func sendEnd(withFinalBody bytes: [UInt8]?) {
        if !hasWrittenBody && !headSent {
            // Optimization: single-shot response with Content-Length
            let bodyBytes = bytes ?? []
            let status = HTTPResponseStatus(statusCode: statusCode)
            var head = HTTPResponseHead(version: .http1_1, status: status)
            for (key, value) in responseHeaders {
                head.headers.add(name: key, value: value)
            }
            if !head.headers.contains(name: "content-length") && !head.headers.contains(name: "transfer-encoding") {
                head.headers.add(name: "content-length", value: String(bodyBytes.count))
            }
            if keepAlive {
                head.headers.replaceOrAdd(name: "connection", value: "keep-alive")
            }
            headSent = true
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if !bodyBytes.isEmpty {
                var buf = channel.allocator.buffer(capacity: bodyBytes.count)
                buf.writeBytes(bodyBytes)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
            }
        } else {
            sendHead()
            if let bytes = bytes, !bytes.isEmpty {
                var buf = channel.allocator.buffer(capacity: bytes.count)
                buf.writeBytes(bytes)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
            }
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [weak self] _ in
            guard let self else { return }
            if !self.keepAlive {
                self.channel.close(promise: nil)
            }
        }
    }
}

// MARK: - HTTPBridgeHandler

/// NIO ChannelInboundHandler that bridges HTTP requests to the JS event loop.
final class HTTPBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let server: NIOHTTPServer
    private var requestHead: HTTPRequestHead?
    private var activeRequestId: Int?

    init(server: NIOHTTPServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            let reqId = server.nextRequestId()
            self.activeRequestId = reqId
            let keepAlive = head.isKeepAlive
            let channel = context.channel
            let state = HTTPRequestState(requestId: reqId, channel: channel, keepAlive: keepAlive)

            let method = head.method.rawValue
            let uri = head.uri
            let headerPairs: [(String, String)] = head.headers.map { ($0.name, $0.value) }
            let remoteAddr = context.remoteAddress?.ipAddress ?? "127.0.0.1"
            let remotePort = context.remoteAddress?.port ?? 0

            server.eventLoop.enqueueCallback { [weak self] in
                guard let self else { return }
                self.server.onRegisterRequest(state)

                guard let jsServer = self.server.jsServer, let ctx = jsServer.context else { return }
                let headersObj = JSValue(newObjectIn: ctx)!
                let rawHeadersArr = JSValue(newArrayIn: ctx)!
                var rawIdx: Int = 0
                for (name, value) in headerPairs {
                    let lname = name.lowercased()
                    if let existing = headersObj.forProperty(lname), !existing.isUndefined {
                        headersObj.setValue(existing.toString()! + ", " + value, forProperty: lname)
                    } else {
                        headersObj.setValue(value, forProperty: lname)
                    }
                    rawHeadersArr.setValue(name, at: rawIdx)
                    rawHeadersArr.setValue(value, at: rawIdx + 1)
                    rawIdx += 2
                }
                jsServer.invokeMethod("_handleRequest", withArguments: [
                    reqId, method, uri, headersObj, "1.1", NSNull(), rawHeadersArr, remoteAddr, remotePort,
                ])
            }

        case .body(var buf):
            guard let reqId = activeRequestId else { return }
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                let str = String(data: Data(bytes), encoding: .utf8)
                    ?? String(data: Data(bytes), encoding: .isoLatin1) ?? ""
                server.eventLoop.enqueueCallback { [weak self] in
                    guard let self else { return }
                    self.server.jsServer?.invokeMethod("_pushBodyChunk", withArguments: [reqId, str])
                }
            }

        case .end:
            guard let reqId = activeRequestId else { return }
            server.eventLoop.enqueueCallback { [weak self] in
                guard let self else { return }
                self.server.jsServer?.invokeMethod("_endBody", withArguments: [reqId])
            }
            requestHead = nil
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        guard context.channel.isWritable else { return }
        guard let reqId = activeRequestId else { return }
        server.eventLoop.enqueueCallback { [weak self] in
            self?.server.jsServer?.invokeMethod("_emitDrain", withArguments: [reqId])
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard let reqId = activeRequestId else { return }
        activeRequestId = nil
        server.eventLoop.enqueueCallback { [weak self] in
            guard let self else { return }
            self.server.jsServer?.invokeMethod("_notifyClose", withArguments: [reqId])
        }
    }
}
