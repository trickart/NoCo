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

        // __httpWriteBody(requestId, data)
        let writeBodyBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            if dataVal.isString, let str = dataVal.toString() {
                state.responseBody.append(contentsOf: str.utf8)
            } else if let bufData = dataVal.forProperty("_data") {
                let len = Int(bufData.forProperty("length")?.toInt32() ?? 0)
                for i in 0..<len {
                    state.responseBody.append(UInt8(bufData.atIndex(i).toInt32() & 0xFF))
                }
            }
        }
        context.setObject(writeBodyBlock, forKeyedSubscript: "__httpWriteBody" as NSString)

        // __httpEnd(requestId, data?)
        let endBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            if !dataVal.isNull && !dataVal.isUndefined {
                if dataVal.isString, let str = dataVal.toString() {
                    state.responseBody.append(contentsOf: str.utf8)
                } else if let bufData = dataVal.forProperty("_data") {
                    let len = Int(bufData.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<len {
                        state.responseBody.append(UInt8(bufData.atIndex(i).toInt32() & 0xFF))
                    }
                }
            }
            state.sendResponse()
            storage.pendingRequests.removeValue(forKey: reqId)
        }
        context.setObject(endBlock, forKeyedSubscript: "__httpEnd" as NSString)

        // --- JS-side http.createServer ---
        let createServerJS = """
        (function(http) {
            var EventEmitter = this.__NoCo_EventEmitter;

            function IncomingMessage(reqId, method, url, headers, httpVersion) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._reqId = reqId;
                this.method = method;
                this.url = url;
                this.headers = headers;
                this.httpVersion = httpVersion;
                this.readable = true;
                this._encoding = null;
                this._body = [];
                this._ended = false;
            }
            IncomingMessage.prototype = Object.create(EventEmitter.prototype);
            IncomingMessage.prototype.constructor = IncomingMessage;
            IncomingMessage.prototype.setEncoding = function(enc) { this._encoding = enc; return this; };

            function ServerResponse(reqId) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._reqId = reqId;
                this.statusCode = 200;
                this._headers = {};
                this._headersSent = false;
                this.finished = false;
            }
            ServerResponse.prototype = Object.create(EventEmitter.prototype);
            ServerResponse.prototype.constructor = ServerResponse;

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
                if (data) __httpWriteBody(this._reqId, data);
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
            };

            function Server(requestListener) {
                if (!(this instanceof Server)) return new Server(requestListener);
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._serverId = __httpCreateServer();
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

            Server.prototype._handleRequest = function(reqId, method, url, headersObj, httpVersion, bodyStr) {
                var req = new IncomingMessage(reqId, method, url, headersObj, httpVersion);
                var res = new ServerResponse(reqId);
                if (bodyStr && bodyStr.length > 0) {
                    req._body.push(bodyStr);
                }
                this.emit('request', req, res);
                for (var i = 0; i < req._body.length; i++) {
                    req.emit('data', req._body[i]);
                }
                req._ended = true;
                req.emit('end');
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
                let proto = options?.forProperty("protocol")?.toString() ?? "http:"
                let hostname = options?.forProperty("hostname")?.toString()
                    ?? options?.forProperty("host")?.toString() ?? "localhost"
                let port = options?.forProperty("port")?.toString()
                let path = options?.forProperty("path")?.toString() ?? "/"
                let portStr = port != nil ? ":\(port!)" : ""
                urlString = "\(proto)//\(hostname)\(portStr)\(path)"
            }

            let method = options?.forProperty("method")?.toString()?.uppercased() ?? "GET"
            let headers = options?.forProperty("headers")
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

// MARK: - HTTPRequestState

/// Accumulates request data and sends the HTTP response via NIO channel.
final class HTTPRequestState: @unchecked Sendable {
    let requestId: Int
    let channel: Channel
    let keepAlive: Bool
    var statusCode: Int = 200
    var responseHeaders: [(String, String)] = []
    var responseBody: [UInt8] = []

    init(requestId: Int, channel: Channel, keepAlive: Bool) {
        self.requestId = requestId
        self.channel = channel
        self.keepAlive = keepAlive
    }

    func sendResponse() {
        let status = HTTPResponseStatus(statusCode: statusCode)
        var head = HTTPResponseHead(version: .http1_1, status: status)
        for (key, value) in responseHeaders {
            head.headers.add(name: key, value: value)
        }
        if !head.headers.contains(name: "content-length") {
            head.headers.add(name: "content-length", value: String(responseBody.count))
        }
        if keepAlive {
            head.headers.replaceOrAdd(name: "connection", value: "keep-alive")
        }

        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        var buf = channel.allocator.buffer(capacity: responseBody.count)
        buf.writeBytes(responseBody)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
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
    private var bodyBuffer: Data = Data()

    init(server: NIOHTTPServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = Data()
        case .body(var buf):
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                bodyBuffer.append(contentsOf: bytes)
            }
        case .end:
            guard let head = requestHead else { return }
            let reqId = server.nextRequestId()
            let keepAlive = head.isKeepAlive
            let channel = context.channel
            let state = HTTPRequestState(requestId: reqId, channel: channel, keepAlive: keepAlive)

            let method = head.method.rawValue
            let uri = head.uri
            let headerPairs: [(String, String)] = head.headers.map { ($0.name, $0.value) }
            let bodyStr = String(data: bodyBuffer, encoding: .utf8) ?? ""

            server.eventLoop.enqueueCallback { [weak self] in
                guard let self else { return }
                self.server.onRegisterRequest(state)

                guard let jsServer = self.server.jsServer, let ctx = jsServer.context else { return }
                let headersObj = JSValue(newObjectIn: ctx)!
                for (name, value) in headerPairs {
                    let lname = name.lowercased()
                    if let existing = headersObj.forProperty(lname), !existing.isUndefined {
                        headersObj.setValue(existing.toString()! + ", " + value, forProperty: lname)
                    } else {
                        headersObj.setValue(value, forProperty: lname)
                    }
                }
                jsServer.invokeMethod("_handleRequest", withArguments: [
                    reqId, method, uri, headersObj, "1.1", bodyStr,
                ])
            }

            requestHead = nil
            bodyBuffer = Data()
        }
    }
}
