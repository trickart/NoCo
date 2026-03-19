import Foundation
@preconcurrency import JavaScriptCore
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOTransportServices

/// Implements Node.js `http2` module. Server uses SwiftNIO with NIOHTTP2.
public struct HTTP2Module: NodeModule {
    public static let moduleName = "http2"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let http2 = JSValue(newObjectIn: context)!

        // Per-runtime server storage
        final class HTTP2Storage {
            var servers: [Int: NIOHTTP2Server] = [:]
            var nextServerId: Int = 1
            var pendingRequests: [Int: HTTP2RequestState] = [:]
        }
        let storage = HTTP2Storage()

        // --- Server bridge functions ---

        // __http2CreateServer() -> serverId
        let createServerBlock: @convention(block) () -> Int = {
            let id = storage.nextServerId
            storage.nextServerId += 1
            let server = NIOHTTP2Server(eventLoop: runtime.eventLoop) { reqState in
                storage.pendingRequests[reqState.requestId] = reqState
            }
            storage.servers[id] = server
            return id
        }
        context.setObject(createServerBlock, forKeyedSubscript: "__http2CreateServer" as NSString)

        // __http2ServerListen(serverId, port, host, jsServer)
        let serverListenBlock: @convention(block) (Int, Int, String, JSValue) -> Void = { id, port, host, jsServer in
            guard let server = storage.servers[id] else { return }
            server.jsServer = jsServer
            runtime.eventLoop.retainHandle()
            server.bind(host: host, port: port)
        }
        context.setObject(serverListenBlock, forKeyedSubscript: "__http2ServerListen" as NSString)

        // __http2ServerClose(serverId)
        let serverCloseBlock: @convention(block) (Int) -> Void = { id in
            guard let server = storage.servers[id] else { return }
            server.close()
            storage.servers.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(serverCloseBlock, forKeyedSubscript: "__http2ServerClose" as NSString)

        // __http2ServerAddress(serverId)
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
        context.setObject(serverAddressBlock, forKeyedSubscript: "__http2ServerAddress" as NSString)

        // __http2WriteHead(requestId, statusCode, headersArray)
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
        context.setObject(writeHeadBlock, forKeyedSubscript: "__http2WriteHead" as NSString)

        // __http2WriteBody(requestId, data)
        let writeBodyBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            if dataVal.isString, let str = dataVal.toString() {
                state.responseBody.append(contentsOf: str.utf8)
            } else {
                let len = Int(dataVal.forProperty("length")?.toInt32() ?? 0)
                for i in 0..<len {
                    state.responseBody.append(UInt8(dataVal.atIndex(i).toInt32() & 0xFF))
                }
            }
        }
        context.setObject(writeBodyBlock, forKeyedSubscript: "__http2WriteBody" as NSString)

        // __http2End(requestId, data?)
        let endBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            if !dataVal.isNull && !dataVal.isUndefined {
                if dataVal.isString, let str = dataVal.toString() {
                    state.responseBody.append(contentsOf: str.utf8)
                } else {
                    let len = Int(dataVal.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<len {
                        state.responseBody.append(UInt8(dataVal.atIndex(i).toInt32() & 0xFF))
                    }
                }
            }
            state.sendResponse()
            storage.pendingRequests.removeValue(forKey: reqId)
        }
        context.setObject(endBlock, forKeyedSubscript: "__http2End" as NSString)

        // --- JS-side http2 API ---
        let setupJS = """
        (function(http2) {
            var EventEmitter = this.__NoCo_EventEmitter;

            // --- Http2ServerRequest (compatibility API) ---
            function Http2ServerRequest(reqId, method, url, headers, httpVersion, rawHeaders, remoteAddr, remotePort) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._reqId = reqId;
                this.method = method;
                this.url = url;
                this.headers = headers;
                this.httpVersion = httpVersion;
                var _vparts = httpVersion.split('.');
                this.httpVersionMajor = parseInt(_vparts[0], 10) || 1;
                this.httpVersionMinor = parseInt(_vparts[1], 10) || 0;
                this.readable = true;
                this._encoding = null;
                this._body = [];
                this._ended = false;
                this.complete = false;
                this.aborted = false;
                this.upgrade = false;
                this.errored = null;
                this.stream = { id: reqId };
                this.rawHeaders = rawHeaders || [];
                this.authority = headers[':authority'] || headers['host'] || '';
                this.scheme = headers[':scheme'] || 'https';
                var addr = remoteAddr || '127.0.0.1';
                var port = remotePort || 0;
                this.socket = {
                    encrypted: false,
                    remoteAddress: addr,
                    remotePort: port,
                    remoteFamily: addr.indexOf(':') !== -1 ? 'IPv6' : 'IPv4'
                };
            }
            Http2ServerRequest.prototype = Object.create(EventEmitter.prototype);
            Http2ServerRequest.prototype.constructor = Http2ServerRequest;
            Http2ServerRequest.prototype.setEncoding = function(enc) { this._encoding = enc; return this; };
            Http2ServerRequest.prototype.destroy = function(err) {
                this._ended = true;
                if (err) this.errored = err;
                this.emit('close');
                return this;
            };

            // --- Http2ServerResponse (compatibility API) ---
            function Http2ServerResponse(reqId) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._reqId = reqId;
                this.statusCode = 200;
                this._headers = {};
                this._headersSent = false;
                this.finished = false;
                this.writable = true;
                this.writableFinished = false;
                this.stream = { id: reqId };
            }
            Http2ServerResponse.prototype = Object.create(EventEmitter.prototype);
            Http2ServerResponse.prototype.constructor = Http2ServerResponse;
            Object.defineProperty(Http2ServerResponse.prototype, 'headersSent', {
                get: function() { return this._headersSent; }
            });
            Http2ServerResponse.prototype.flushHeaders = function() {
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
            };
            Http2ServerResponse.prototype.destroy = function(err) {
                this.finished = true;
                this.writable = false;
                if (err) this.emit('error', err);
                this.emit('close');
                return this;
            };

            Http2ServerResponse.prototype.setHeader = function(name, value) {
                this._headers[name.toLowerCase()] = value;
            };
            Http2ServerResponse.prototype.getHeader = function(name) {
                return this._headers[name.toLowerCase()];
            };
            Http2ServerResponse.prototype.removeHeader = function(name) {
                delete this._headers[name.toLowerCase()];
            };
            Http2ServerResponse.prototype.writeHead = function(statusCode, reasonOrHeaders, headers) {
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
                __http2WriteHead(this._reqId, this.statusCode, flat);
                return this;
            };
            Http2ServerResponse.prototype.write = function(data, encoding) {
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
                if (data) __http2WriteBody(this._reqId, data);
                return true;
            };
            Http2ServerResponse.prototype.end = function(data, encoding, callback) {
                if (typeof data === 'function') { callback = data; data = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
                this.finished = true;
                __http2End(this._reqId, data || null);
                this.emit('finish');
                if (callback) callback();
            };

            // --- Http2Stream (core API) ---
            function Http2Stream(reqId) {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this.id = reqId;
                this._reqId = reqId;
                this.destroyed = false;
                this.closed = false;
                this.sentHeaders = null;
                this.sentInfoHeaders = [];
                this.sentTrailers = null;
            }
            Http2Stream.prototype = Object.create(EventEmitter.prototype);
            Http2Stream.prototype.constructor = Http2Stream;

            Http2Stream.prototype.respond = function(headers, options) {
                var statusCode = headers && headers[':status'] ? headers[':status'] : 200;
                var flat = [];
                if (headers) {
                    var keys = Object.keys(headers);
                    for (var i = 0; i < keys.length; i++) {
                        if (keys[i].charAt(0) !== ':') {
                            flat.push(keys[i]);
                            flat.push(String(headers[keys[i]]));
                        }
                    }
                }
                this.sentHeaders = headers || {};
                __http2WriteHead(this._reqId, statusCode, flat);
            };

            Http2Stream.prototype.write = function(data) {
                if (data) __http2WriteBody(this._reqId, data);
                return true;
            };

            Http2Stream.prototype.end = function(data, encoding, callback) {
                if (typeof data === 'function') { callback = data; data = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                this.closed = true;
                __http2End(this._reqId, data || null);
                this.emit('close');
                if (callback) callback();
            };

            Http2Stream.prototype.close = function(code) {
                this.closed = true;
                this.destroyed = true;
                this.emit('close');
            };

            // --- Http2Session ---
            function Http2Session() {
                this._events = Object.create(null);
                this._maxListeners = 10;
                this.destroyed = false;
                this.closed = false;
                this.socket = null;
                this.state = {};
                this.localSettings = http2.getDefaultSettings();
                this.remoteSettings = http2.getDefaultSettings();
            }
            Http2Session.prototype = Object.create(EventEmitter.prototype);
            Http2Session.prototype.constructor = Http2Session;
            Http2Session.prototype.destroy = function() { this.destroyed = true; this.emit('close'); };
            Http2Session.prototype.close = function(cb) { this.closed = true; if (cb) cb(); this.emit('close'); };
            Http2Session.prototype.settings = function(settings, cb) { if (cb) cb(); };

            // --- Http2Server ---
            function Http2Server(options, requestListener) {
                if (!(this instanceof Http2Server)) return new Http2Server(options, requestListener);
                if (typeof options === 'function') {
                    requestListener = options;
                    options = {};
                }
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._options = options || {};
                this._serverId = __http2CreateServer();
                this.listening = false;
                if (requestListener) this.on('request', requestListener);
            }
            Http2Server.prototype = Object.create(EventEmitter.prototype);
            Http2Server.prototype.constructor = Http2Server;

            Http2Server.prototype.listen = function(port, host, backlog, callback) {
                if (typeof host === 'function') { callback = host; host = '0.0.0.0'; }
                if (typeof backlog === 'function') { callback = backlog; backlog = undefined; }
                if (!host) host = '0.0.0.0';
                if (callback) this.once('listening', callback);
                this.listening = true;
                __http2ServerListen(this._serverId, port || 0, host, this);
                return this;
            };

            Http2Server.prototype.close = function(callback) {
                if (callback) this.once('close', callback);
                this.listening = false;
                __http2ServerClose(this._serverId);
                this.emit('close');
                return this;
            };

            Http2Server.prototype.address = function() {
                return __http2ServerAddress(this._serverId);
            };

            Http2Server.prototype.setTimeout = function() { return this; };
            Http2Server.prototype.ref = function() { return this; };
            Http2Server.prototype.unref = function() { return this; };

            Http2Server.prototype._handleRequest = function(reqId, method, url, headersObj, httpVersion, bodyStr, rawHeaders, remoteAddr, remotePort) {
                var req = new Http2ServerRequest(reqId, method, url, headersObj, httpVersion, rawHeaders || [], remoteAddr, remotePort);
                var res = new Http2ServerResponse(reqId);
                res.on('finish', function() {
                    res.writableFinished = true;
                    res.writable = false;
                });
                if (bodyStr && bodyStr.length > 0) {
                    req._body.push(bodyStr);
                    req.rawBody = Buffer.from(bodyStr, 'utf8');
                }
                this.emit('request', req, res);
                for (var i = 0; i < req._body.length; i++) {
                    req.emit('data', req._body[i]);
                }
                req._ended = true;
                req.complete = true;
                req.emit('end');
            };

            // --- Public API ---

            http2.createServer = function(options, requestListener) {
                if (typeof options === 'function') {
                    requestListener = options;
                    options = {};
                }
                return new Http2Server(options, requestListener);
            };

            http2.createSecureServer = function(options, requestListener) {
                if (typeof options === 'function') {
                    requestListener = options;
                    options = {};
                }
                return new Http2Server(options, requestListener);
            };

            http2.connect = function(authority, options, listener) {
                if (typeof options === 'function') { listener = options; options = {}; }
                var session = new Http2Session();
                session.request = function(headers) {
                    var stream = new Http2Stream(0);
                    return stream;
                };
                if (listener) {
                    setTimeout(function() { listener(session); }, 0);
                }
                return session;
            };

            http2.getDefaultSettings = function() {
                return {
                    headerTableSize: 4096,
                    enablePush: true,
                    initialWindowSize: 65535,
                    maxFrameSize: 16384,
                    maxConcurrentStreams: 4294967295,
                    maxHeaderListSize: 65535,
                    enableConnectProtocol: false
                };
            };

            http2.getPackedSettings = function(settings) {
                return Buffer.alloc(0);
            };

            http2.getUnpackedSettings = function(buf) {
                return http2.getDefaultSettings();
            };

            http2.sensitiveHeaders = Symbol('nodejs.http2.sensitiveHeaders');

            // --- Constants ---
            http2.constants = {
                NGHTTP2_SESSION_SERVER: 0,
                NGHTTP2_SESSION_CLIENT: 1,
                NGHTTP2_ERR_FRAME_SIZE_ERROR: -522,
                NGHTTP2_NO_ERROR: 0,
                NGHTTP2_PROTOCOL_ERROR: 1,
                NGHTTP2_INTERNAL_ERROR: 2,
                NGHTTP2_FLOW_CONTROL_ERROR: 3,
                NGHTTP2_SETTINGS_TIMEOUT: 4,
                NGHTTP2_STREAM_CLOSED: 5,
                NGHTTP2_FRAME_SIZE_ERROR: 6,
                NGHTTP2_REFUSED_STREAM: 7,
                NGHTTP2_CANCEL: 8,
                NGHTTP2_COMPRESSION_ERROR: 9,
                NGHTTP2_CONNECT_ERROR: 10,
                NGHTTP2_ENHANCE_YOUR_CALM: 11,
                NGHTTP2_INADEQUATE_SECURITY: 12,
                NGHTTP2_HTTP_1_1_REQUIRED: 13,
                NGHTTP2_DEFAULT_WEIGHT: 16,
                HTTP2_HEADER_STATUS: ':status',
                HTTP2_HEADER_METHOD: ':method',
                HTTP2_HEADER_AUTHORITY: ':authority',
                HTTP2_HEADER_SCHEME: ':scheme',
                HTTP2_HEADER_PATH: ':path',
                HTTP2_HEADER_PROTOCOL: ':protocol',
                HTTP2_HEADER_ACCEPT_ENCODING: 'accept-encoding',
                HTTP2_HEADER_ACCEPT_LANGUAGE: 'accept-language',
                HTTP2_HEADER_ACCEPT_RANGES: 'accept-ranges',
                HTTP2_HEADER_ACCEPT: 'accept',
                HTTP2_HEADER_ACCESS_CONTROL_ALLOW_ORIGIN: 'access-control-allow-origin',
                HTTP2_HEADER_AGE: 'age',
                HTTP2_HEADER_AUTHORIZATION: 'authorization',
                HTTP2_HEADER_CACHE_CONTROL: 'cache-control',
                HTTP2_HEADER_CONNECTION: 'connection',
                HTTP2_HEADER_CONTENT_DISPOSITION: 'content-disposition',
                HTTP2_HEADER_CONTENT_ENCODING: 'content-encoding',
                HTTP2_HEADER_CONTENT_LENGTH: 'content-length',
                HTTP2_HEADER_CONTENT_TYPE: 'content-type',
                HTTP2_HEADER_COOKIE: 'cookie',
                HTTP2_HEADER_DATE: 'date',
                HTTP2_HEADER_ETAG: 'etag',
                HTTP2_HEADER_HOST: 'host',
                HTTP2_HEADER_IF_MODIFIED_SINCE: 'if-modified-since',
                HTTP2_HEADER_IF_NONE_MATCH: 'if-none-match',
                HTTP2_HEADER_LAST_MODIFIED: 'last-modified',
                HTTP2_HEADER_LINK: 'link',
                HTTP2_HEADER_LOCATION: 'location',
                HTTP2_HEADER_RANGE: 'range',
                HTTP2_HEADER_REFERER: 'referer',
                HTTP2_HEADER_SERVER: 'server',
                HTTP2_HEADER_SET_COOKIE: 'set-cookie',
                HTTP2_HEADER_TRANSFER_ENCODING: 'transfer-encoding',
                HTTP2_HEADER_VARY: 'vary',
                HTTP2_HEADER_VIA: 'via',
                HTTP2_METHOD_ACL: 'ACL',
                HTTP2_METHOD_BASELINE_CONTROL: 'BASELINE-CONTROL',
                HTTP2_METHOD_BIND: 'BIND',
                HTTP2_METHOD_CHECKIN: 'CHECKIN',
                HTTP2_METHOD_CHECKOUT: 'CHECKOUT',
                HTTP2_METHOD_CONNECT: 'CONNECT',
                HTTP2_METHOD_COPY: 'COPY',
                HTTP2_METHOD_DELETE: 'DELETE',
                HTTP2_METHOD_GET: 'GET',
                HTTP2_METHOD_HEAD: 'HEAD',
                HTTP2_METHOD_LABEL: 'LABEL',
                HTTP2_METHOD_LINK: 'LINK',
                HTTP2_METHOD_LOCK: 'LOCK',
                HTTP2_METHOD_MERGE: 'MERGE',
                HTTP2_METHOD_MKACTIVITY: 'MKACTIVITY',
                HTTP2_METHOD_MKCALENDAR: 'MKCALENDAR',
                HTTP2_METHOD_MKCOL: 'MKCOL',
                HTTP2_METHOD_MKREDIRECTREF: 'MKREDIRECTREF',
                HTTP2_METHOD_MKWORKSPACE: 'MKWORKSPACE',
                HTTP2_METHOD_MOVE: 'MOVE',
                HTTP2_METHOD_OPTIONS: 'OPTIONS',
                HTTP2_METHOD_ORDERPATCH: 'ORDERPATCH',
                HTTP2_METHOD_PATCH: 'PATCH',
                HTTP2_METHOD_POST: 'POST',
                HTTP2_METHOD_PRI: 'PRI',
                HTTP2_METHOD_PROPFIND: 'PROPFIND',
                HTTP2_METHOD_PROPPATCH: 'PROPPATCH',
                HTTP2_METHOD_PUT: 'PUT',
                HTTP2_METHOD_REBIND: 'REBIND',
                HTTP2_METHOD_REPORT: 'REPORT',
                HTTP2_METHOD_SEARCH: 'SEARCH',
                HTTP2_METHOD_TRACE: 'TRACE',
                HTTP2_METHOD_UNBIND: 'UNBIND',
                HTTP2_METHOD_UNCHECKOUT: 'UNCHECKOUT',
                HTTP2_METHOD_UNLINK: 'UNLINK',
                HTTP2_METHOD_UNLOCK: 'UNLOCK',
                HTTP2_METHOD_UPDATE: 'UPDATE',
                HTTP2_METHOD_UPDATEREDIRECTREF: 'UPDATEREDIRECTREF',
                HTTP2_METHOD_VERSION_CONTROL: 'VERSION-CONTROL',
                HTTP_STATUS_CONTINUE: 100,
                HTTP_STATUS_SWITCHING_PROTOCOLS: 101,
                HTTP_STATUS_PROCESSING: 102,
                HTTP_STATUS_EARLY_HINTS: 103,
                HTTP_STATUS_OK: 200,
                HTTP_STATUS_CREATED: 201,
                HTTP_STATUS_ACCEPTED: 202,
                HTTP_STATUS_NON_AUTHORITATIVE_INFORMATION: 203,
                HTTP_STATUS_NO_CONTENT: 204,
                HTTP_STATUS_RESET_CONTENT: 205,
                HTTP_STATUS_PARTIAL_CONTENT: 206,
                HTTP_STATUS_MULTI_STATUS: 207,
                HTTP_STATUS_ALREADY_REPORTED: 208,
                HTTP_STATUS_IM_USED: 226,
                HTTP_STATUS_MULTIPLE_CHOICES: 300,
                HTTP_STATUS_MOVED_PERMANENTLY: 301,
                HTTP_STATUS_FOUND: 302,
                HTTP_STATUS_SEE_OTHER: 303,
                HTTP_STATUS_NOT_MODIFIED: 304,
                HTTP_STATUS_USE_PROXY: 305,
                HTTP_STATUS_TEMPORARY_REDIRECT: 307,
                HTTP_STATUS_PERMANENT_REDIRECT: 308,
                HTTP_STATUS_BAD_REQUEST: 400,
                HTTP_STATUS_UNAUTHORIZED: 401,
                HTTP_STATUS_PAYMENT_REQUIRED: 402,
                HTTP_STATUS_FORBIDDEN: 403,
                HTTP_STATUS_NOT_FOUND: 404,
                HTTP_STATUS_METHOD_NOT_ALLOWED: 405,
                HTTP_STATUS_NOT_ACCEPTABLE: 406,
                HTTP_STATUS_PROXY_AUTHENTICATION_REQUIRED: 407,
                HTTP_STATUS_REQUEST_TIMEOUT: 408,
                HTTP_STATUS_CONFLICT: 409,
                HTTP_STATUS_GONE: 410,
                HTTP_STATUS_LENGTH_REQUIRED: 411,
                HTTP_STATUS_PRECONDITION_FAILED: 412,
                HTTP_STATUS_PAYLOAD_TOO_LARGE: 413,
                HTTP_STATUS_URI_TOO_LONG: 414,
                HTTP_STATUS_UNSUPPORTED_MEDIA_TYPE: 415,
                HTTP_STATUS_RANGE_NOT_SATISFIABLE: 416,
                HTTP_STATUS_EXPECTATION_FAILED: 417,
                HTTP_STATUS_TEAPOT: 418,
                HTTP_STATUS_MISDIRECTED_REQUEST: 421,
                HTTP_STATUS_UNPROCESSABLE_ENTITY: 422,
                HTTP_STATUS_LOCKED: 423,
                HTTP_STATUS_FAILED_DEPENDENCY: 424,
                HTTP_STATUS_TOO_EARLY: 425,
                HTTP_STATUS_UPGRADE_REQUIRED: 426,
                HTTP_STATUS_PRECONDITION_REQUIRED: 428,
                HTTP_STATUS_TOO_MANY_REQUESTS: 429,
                HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE: 431,
                HTTP_STATUS_UNAVAILABLE_FOR_LEGAL_REASONS: 451,
                HTTP_STATUS_INTERNAL_SERVER_ERROR: 500,
                HTTP_STATUS_NOT_IMPLEMENTED: 501,
                HTTP_STATUS_BAD_GATEWAY: 502,
                HTTP_STATUS_SERVICE_UNAVAILABLE: 503,
                HTTP_STATUS_GATEWAY_TIMEOUT: 504,
                HTTP_STATUS_HTTP_VERSION_NOT_SUPPORTED: 505,
                HTTP_STATUS_VARIANT_ALSO_NEGOTIATES: 506,
                HTTP_STATUS_INSUFFICIENT_STORAGE: 507,
                HTTP_STATUS_LOOP_DETECTED: 508,
                HTTP_STATUS_BANDWIDTH_LIMIT_EXCEEDED: 509,
                HTTP_STATUS_NOT_EXTENDED: 510,
                HTTP_STATUS_NETWORK_AUTHENTICATION_REQUIRED: 511
            };

            // Export classes
            http2.Http2ServerRequest = Http2ServerRequest;
            http2.Http2ServerResponse = Http2ServerResponse;
            http2.Http2Stream = Http2Stream;
            http2.Http2Session = Http2Session;
            http2.Http2Server = Http2Server;
        })
        """
        let setupFn = context.evaluateScript(setupJS)!
        setupFn.call(withArguments: [http2])

        return http2
    }
}

// MARK: - NIOHTTP2Server

/// HTTP/2 server using NIOTransportServices + NIOHTTP2.
final class NIOHTTP2Server: @unchecked Sendable {
    let eventLoop: EventLoop
    let onRegisterRequest: (HTTP2RequestState) -> Void
    var jsServer: JSValue?
    var boundPort: Int = 0
    var boundHost: String = ""
    private var group: NIOTSEventLoopGroup?
    private var channel: Channel?
    private let requestIdCounter = AtomicCounter(initial: 1)

    init(eventLoop: EventLoop, onRegisterRequest: @escaping (HTTP2RequestState) -> Void) {
        self.eventLoop = eventLoop
        self.onRegisterRequest = onRegisterRequest
    }

    func bind(host: String, port: Int) {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        self.group = group
        let serverRef = self

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                    streamChannel.pipeline.addHandlers([
                        HTTP2FramePayloadToHTTP1ServerCodec(),
                        HTTP2BridgeHandler(server: serverRef),
                    ])
                }.map { _ in () }
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

// MARK: - HTTP2RequestState

/// Manages per-stream response state for HTTP/2.
final class HTTP2RequestState: @unchecked Sendable {
    let requestId: Int
    let channel: Channel
    var statusCode: Int = 200
    var responseHeaders: [(String, String)] = []
    var responseBody: [UInt8] = []

    init(requestId: Int, channel: Channel) {
        self.requestId = requestId
        self.channel = channel
    }

    func sendResponse() {
        let status = HTTPResponseStatus(statusCode: statusCode)
        var head = HTTPResponseHead(version: .http2, status: status)
        for (key, value) in responseHeaders {
            head.headers.add(name: key, value: value)
        }
        if !head.headers.contains(name: "content-length") && !head.headers.contains(name: "transfer-encoding") {
            head.headers.add(name: "content-length", value: String(responseBody.count))
        }

        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        var buf = channel.allocator.buffer(capacity: responseBody.count)
        buf.writeBytes(responseBody)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}

// MARK: - HTTP2BridgeHandler

/// NIO ChannelInboundHandler that bridges HTTP/2 stream requests to the JS event loop.
/// Each HTTP/2 stream gets its own handler instance via the stream multiplexer.
final class HTTP2BridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let server: NIOHTTP2Server
    private var requestHead: HTTPRequestHead?
    private var activeRequestId: Int?

    init(server: NIOHTTP2Server) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            let reqId = server.nextRequestId()
            self.activeRequestId = reqId
            let channel = context.channel
            let state = HTTP2RequestState(requestId: reqId, channel: channel)

            let method = head.method.rawValue
            let uri = head.uri
            let headerPairs: [(String, String)] = head.headers.map { ($0.name, $0.value) }
            let parentAddr = context.channel.parent?.remoteAddress
            let remoteAddr = parentAddr?.ipAddress ?? "127.0.0.1"
            let remotePort = parentAddr?.port ?? 0

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
                    reqId, method, uri, headersObj, "2.0", NSNull(), rawHeadersArr, remoteAddr, remotePort,
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
}
