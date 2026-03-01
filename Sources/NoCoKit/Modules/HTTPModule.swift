import Foundation
@preconcurrency import JavaScriptCore

/// Implements a basic Node.js `http` module using URLSession.
public struct HTTPModule: NodeModule {
    public static let moduleName = "http"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let http = JSValue(newObjectIn: context)!

        // http.request(options, callback)
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

            // Create a simple req object (EventEmitter-like)
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

            // On _send, perform the actual HTTP request
            let onSend: @convention(block) () -> Void = {
                guard let url = URL(string: urlString) else {
                    let err = ctx.createError("Invalid URL: \(urlString)")
                    req.invokeMethod("emit", withArguments: ["error", err])
                    return
                }

                var urlReq = URLRequest(url: url)
                urlReq.httpMethod = method

                // Set headers
                if let headers = headers, !headers.isUndefined {
                    let keys = ctx.evaluateScript("Object.keys")?.call(withArguments: [headers])
                    let keyCount = Int(keys?.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<keyCount {
                        let key = keys?.atIndex(i)?.toString() ?? ""
                        let value = headers.forProperty(key)?.toString() ?? ""
                        urlReq.setValue(value, forHTTPHeaderField: key)
                    }
                }

                // Set body
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
                    runtime.perform { ctx in
                        if let error = error {
                            let jsErr = ctx.createError(error.localizedDescription)
                            req.invokeMethod("emit", withArguments: ["error", jsErr])
                            return
                        }

                        guard let httpResp = response as? HTTPURLResponse else { return }

                        // Create response object (Readable-like)
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

                        // Push data
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

            // Auto-end for GET
            if method == "GET" || method == "HEAD" {
                req.invokeMethod("end", withArguments: [])
            }

            return req
        }
        http.setValue(unsafeBitCast(request, to: AnyObject.self), forProperty: "request")

        // http.get(url, options?, callback)
        let get: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []

            // Delegate to http.request then auto-end
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
