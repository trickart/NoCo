import Foundation
@preconcurrency import JavaScriptCore
import Network
import Security
import Synchronization

/// Implements Node.js `https` module with TLS support.
/// Server uses Network.framework TLS via NIOTransportServices.
/// Client uses URLSession (already supports HTTPS) with `rejectUnauthorized` option.
public struct HTTPSModule: NodeModule {
    public static let moduleName = "https"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Get the http module for reuse
        let http = HTTPModule.install(in: context, runtime: runtime)
        let https = JSValue(newObjectIn: context)!

        // Copy shared properties from http (STATUS_CODES, METHODS, etc.)
        let copyScript = """
        (function(src, dst) {
            ['STATUS_CODES', 'METHODS', 'IncomingMessage', 'ServerResponse'].forEach(function(key) {
                if (src[key]) dst[key] = src[key];
            });
        })
        """
        context.evaluateScript(copyScript)!.call(withArguments: [http, https])

        https.setValue(JSValue(newObjectIn: context)!, forProperty: "globalAgent")
        https.forProperty("globalAgent")?.setValue(443, forProperty: "defaultPort")
        https.forProperty("globalAgent")?.setValue("https:", forProperty: "protocol")

        // --- Per-runtime HTTPS server storage ---
        final class HTTPSStorage {
            var servers: [Int: NIOHTTPServer] = [:]
            var nextServerId: Int = 1
            var pendingRequests: [Int: HTTPRequestState] = [:]
        }
        let storage = HTTPSStorage()

        // __httpsCreateServer(certPEM, keyPEM, passphrase?) -> serverId or -1 on error
        let createServerBlock: @convention(block) (String, String, JSValue) -> JSValue = { certPEM, keyPEM, passphraseVal in
            let ctx = JSContext.current()!
            let passphrase = passphraseVal.isUndefined || passphraseVal.isNull ? nil : passphraseVal.toString()

            guard let tlsOpts = PEMHelper.createTLSOptions(certPEM: certPEM, keyPEM: keyPEM, passphrase: passphrase) else {
                let err = ctx.evaluateScript("new Error('Failed to parse TLS certificate/key')")!
                return err
            }

            let id = storage.nextServerId
            storage.nextServerId += 1
            let server = NIOHTTPServer(eventLoop: runtime.eventLoop) { reqState in
                storage.pendingRequests[reqState.requestId] = reqState
            }
            server.tlsOptions = tlsOpts
            storage.servers[id] = server
            return JSValue(int32: Int32(id), in: ctx)
        }
        context.setObject(createServerBlock, forKeyedSubscript: "__httpsCreateServer" as NSString)

        // __httpsServerListen(serverId, port, host, jsServer)
        let serverListenBlock: @convention(block) (Int, Int, String, JSValue) -> Void = { id, port, host, jsServer in
            guard let server = storage.servers[id] else { return }
            server.jsServer = jsServer
            runtime.eventLoop.retainHandle()
            server.bind(host: host, port: port)
        }
        context.setObject(serverListenBlock, forKeyedSubscript: "__httpsServerListen" as NSString)

        // __httpsServerClose(serverId)
        let serverCloseBlock: @convention(block) (Int) -> Void = { id in
            guard let server = storage.servers[id] else { return }
            server.close()
            storage.servers.removeValue(forKey: id)
            runtime.eventLoop.releaseHandle()
        }
        context.setObject(serverCloseBlock, forKeyedSubscript: "__httpsServerClose" as NSString)

        // __httpsServerAddress(serverId)
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
        context.setObject(serverAddressBlock, forKeyedSubscript: "__httpsServerAddress" as NSString)

        // __httpsWriteHead / __httpsWriteBody / __httpsEnd (reuse HTTP bridge via storage)
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
        context.setObject(writeHeadBlock, forKeyedSubscript: "__httpsWriteHead" as NSString)

        let writeBodyBlock: @convention(block) (Int, JSValue) -> Bool = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return true }
            return state.writeChunk(httpExtractBytes(from: dataVal))
        }
        context.setObject(writeBodyBlock, forKeyedSubscript: "__httpsWriteBody" as NSString)

        let endBlock: @convention(block) (Int, JSValue) -> Void = { reqId, dataVal in
            guard let state = storage.pendingRequests[reqId] else { return }
            let finalBytes: [UInt8]? = (!dataVal.isNull && !dataVal.isUndefined)
                ? httpExtractBytes(from: dataVal) : nil
            state.sendEnd(withFinalBody: finalBytes)
            storage.pendingRequests.removeValue(forKey: reqId)
        }
        context.setObject(endBlock, forKeyedSubscript: "__httpsEnd" as NSString)

        // --- JS-side https.createServer ---
        let createServerJS = """
        (function(https) {
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
                var _vparts = httpVersion.split('.');
                this.httpVersionMajor = parseInt(_vparts[0], 10) || 1;
                this.httpVersionMinor = _vparts.length > 1 ? (parseInt(_vparts[1], 10) || 0) : 1;
                this._encoding = null;
                this._body = [];
                this._ended = false;
                this.complete = false;
                this.upgrade = false;
                this.errored = null;
                this.rawHeaders = rawHeaders || [];
                var addr = remoteAddr || '127.0.0.1';
                var port = remotePort || 0;
                this.socket = {
                    encrypted: true,
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
                this.statusMessage = 'OK';
                this._headers = {};
                this._headersSent = false;
                this.finished = false;
                this.writable = true;
                this.writableFinished = false;
                this._closed = false;
                this._writableNeedDrain = false;
                this.writableHighWaterMark = 16384;
                this.socket = null;
                this.connection = null;
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
                if (typeof reasonOrHeaders === 'string') {
                    this.statusMessage = reasonOrHeaders;
                }
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
                __httpsWriteHead(this._reqId, this.statusCode, flat);
                return this;
            };
            ServerResponse.prototype.write = function(data, encoding) {
                if (!this._headersSent) {
                    this.writeHead(this.statusCode);
                }
                if (data) {
                    var ok = __httpsWriteBody(this._reqId, data);
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
                __httpsEnd(this._reqId, data || null);
                this.emit('finish');
                if (callback) callback();
                this._emitClose();
            };

            function Server(options, requestListener) {
                if (!(this instanceof Server)) return new Server(options, requestListener);
                this._events = Object.create(null);
                this._maxListeners = 10;
                this._responses = {};
                this._requests = {};
                this.listening = false;

                if (typeof options === 'function') {
                    requestListener = options;
                    options = {};
                }
                options = options || {};

                var certPEM = options.cert ? String(options.cert) : '';
                var keyPEM = options.key ? String(options.key) : '';
                var passphrase = options.passphrase;

                if (certPEM && keyPEM) {
                    var result = __httpsCreateServer(certPEM, keyPEM, passphrase);
                    if (typeof result === 'object' && result instanceof Error) {
                        throw result;
                    }
                    this._serverId = result;
                } else {
                    throw new Error('https.createServer requires options.cert and options.key');
                }

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
                __httpsServerListen(this._serverId, port || 0, host, this);
                return this;
            };

            Server.prototype.close = function(callback) {
                if (callback) this.once('close', callback);
                this.listening = false;
                __httpsServerClose(this._serverId);
                this.emit('close');
                return this;
            };

            Server.prototype.address = function() {
                return __httpsServerAddress(this._serverId);
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
                res.socket = req.socket;
                res.connection = req.socket;
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

            https.createServer = function(options, requestListener) {
                return new Server(options, requestListener);
            };

            https.Server = Server;
        })
        """
        context.evaluateScript(createServerJS)!.call(withArguments: [https])

        // --- Client-side https.request (URLSession-based with TLS options) ---
        let request: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard !args.isEmpty else { return JSValue(undefinedIn: JSContext.current()) }
            let ctx = JSContext.current()!

            var urlString: String
            var options: JSValue?
            var callback: JSValue?

            if args[0].isString {
                urlString = args[0].toString()
                let isFunction = args.count > 1
                    ? ctx.evaluateScript("(function(v){return typeof v==='function'})")!.call(withArguments: [args[1]]).toBool()
                    : false
                if args.count > 1 && !isFunction {
                    options = args[1]
                    callback = args.count > 2 ? args[2] : nil
                } else {
                    callback = args.count > 1 ? args[1] : nil
                }
            } else {
                options = args[0]
                callback = args.count > 1 ? args[1] : nil
                let proto = options?.property("protocol")?.toString() ?? "https:"
                let hostname = options?.property("hostname")?.toString()
                    ?? options?.property("host")?.toString() ?? "localhost"
                let port = options?.property("port")?.toString()
                let path = options?.property("path")?.toString() ?? "/"
                let defaultPort = proto == "https:" ? "443" : "80"
                let portStr = (port != nil && port != defaultPort) ? ":\(port!)" : ""
                urlString = "\(proto)//\(hostname)\(portStr)\(path)"
            }

            // Ensure https:// protocol if URL doesn't have a scheme
            if !urlString.contains("://") {
                urlString = "https://" + urlString
            } else if urlString.hasPrefix("http://") {
                // If explicitly http://, keep it (allows mixed usage)
            }

            let method = options?.property("method")?.toString()?.uppercased() ?? "GET"
            let headers = options?.property("headers")
            let rejectUnauthorized = options?.property("rejectUnauthorized")
            let shouldRejectUnauthorized = rejectUnauthorized?.isUndefined != false || rejectUnauthorized?.toBool() != false
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

                // Use custom session if rejectUnauthorized is false
                let session: URLSession
                if !shouldRejectUnauthorized {
                    let delegate = InsecureURLSessionDelegate()
                    session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                } else {
                    session = URLSession.shared
                }

                runtime.eventLoop.retainHandle()
                let task = session.dataTask(with: urlReq) { data, response, error in
                    runtime.eventLoop.enqueueCallback {
                        defer { runtime.eventLoop.releaseHandle() }
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
        https.setValue(unsafeBitCast(request, to: AnyObject.self), forProperty: "request")

        // https.get
        let get: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            // Ensure method is GET
            if !args.isEmpty && args[0].isObject && !args[0].isString {
                args[0].setValue("GET", forProperty: "method")
            }
            let req = https.invokeMethod("request", withArguments: args)!
            return req
        }
        https.setValue(unsafeBitCast(get, to: AnyObject.self), forProperty: "get")

        return https
    }
}

// MARK: - InsecureURLSessionDelegate

/// URLSession delegate that skips certificate validation (for rejectUnauthorized: false).
private final class InsecureURLSessionDelegate: NSObject, URLSessionDelegate {
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

// MARK: - PEM Helper

/// Parses PEM-encoded certificates and keys, creates NWProtocolTLS.Options.
/// Retains temporary keychain references so SecIdentity stays valid for the server lifetime.
final class PEMHelper {
    /// Retained keychain paths to keep SecIdentity alive.
    /// Cleaned up when PEMHelper (and thus the containing server) is deallocated.
    private static let activeKeychainPaths = Mutex<[String]>([])

    /// Create NWProtocolTLS.Options from PEM cert and key strings.
    static func createTLSOptions(certPEM: String, keyPEM: String, passphrase: String?) -> NWProtocolTLS.Options? {
        guard let certDER = parsePEM(certPEM, type: "CERTIFICATE"),
              let keyDER = parsePEM(keyPEM, type: "PRIVATE KEY") ?? parsePEM(keyPEM, type: "RSA PRIVATE KEY") ?? parsePEM(keyPEM, type: "EC PRIVATE KEY")
        else {
            return nil
        }

        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            return nil
        }

        guard let identity = createIdentity(certificate: certificate, keyDER: keyDER) else {
            return nil
        }

        let options = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            return nil
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)

        return options
    }

    /// Parse a PEM block and return the DER-encoded data.
    static func parsePEM(_ pem: String, type: String) -> Data? {
        let beginMarker = "-----BEGIN \(type)-----"
        let endMarker = "-----END \(type)-----"

        guard let beginRange = pem.range(of: beginMarker),
              let endRange = pem.range(of: endMarker)
        else {
            return nil
        }

        let base64String = pem[beginRange.upperBound..<endRange.lowerBound]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        return Data(base64Encoded: base64String)
    }

    /// Remove a retained keychain path and delete the keychain file.
    static func cleanupKeychain(path: String) {
        activeKeychainPaths.withLock { $0.removeAll { $0 == path } }
        try? FileManager.default.removeItem(atPath: path)
        // Also remove -db and -shm files created by newer keychain format
        try? FileManager.default.removeItem(atPath: path + "-db")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    /// Create a SecIdentity from a certificate and private key DER data.
    /// Uses a temporary keychain that stays alive until explicitly cleaned up.
    private static func createIdentity(certificate: SecCertificate, keyDER: Data) -> SecIdentity? {
        #if os(macOS)
        var tempKeychain: SecKeychain?
        let keychainPath = NSTemporaryDirectory() + "noco-tls-\(UUID().uuidString).keychain"
        let password = UUID().uuidString

        var status = SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &tempKeychain)
        guard status == errSecSuccess, let keychain = tempKeychain else {
            return nil
        }

        // Retain the keychain path so the identity stays valid
        activeKeychainPaths.withLock { $0.append(keychainPath) }

        // Import the private key into the temporary keychain
        var importItems: CFArray?
        let keyData = keyDER as CFData
        var keyParams = SecItemImportExportKeyParameters()
        keyParams.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)

        status = SecItemImport(
            keyData,
            nil,
            nil,
            nil,
            [],
            &keyParams,
            keychain,
            &importItems
        )
        guard status == errSecSuccess else {
            cleanupKeychain(path: keychainPath)
            return nil
        }

        // Import the certificate into the temporary keychain
        let certData = SecCertificateCopyData(certificate) as Data
        var certImportItems: CFArray?
        status = SecItemImport(
            certData as CFData,
            nil,
            nil,
            nil,
            [],
            nil,
            keychain,
            &certImportItems
        )
        guard status == errSecSuccess else {
            cleanupKeychain(path: keychainPath)
            return nil
        }

        // Create identity from the temporary keychain
        var identity: SecIdentity?
        status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess else {
            cleanupKeychain(path: keychainPath)
            return nil
        }

        return identity
        #else
        return nil
        #endif
    }
}

