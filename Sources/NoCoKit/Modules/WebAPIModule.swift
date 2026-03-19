import Foundation
@preconcurrency import JavaScriptCore
import Compression
import Synchronization

/// Installs Web Platform APIs as globals: Headers, Request, Response,
/// AbortController, AbortSignal, ReadableStream.
/// These are required by frameworks like Hono that bridge between
/// Node.js HTTP and the Fetch API.
public struct WebAPIModule {
    public static func install(in context: JSContext, runtime: NodeRuntime) {
        // ── Compression bridge functions ──
        let compressBlock: @convention(block) (JSValue, String) -> JSValue = { dataValue, format in
            let ctx = JSContext.current()!
            guard let bytes = extractUint8Array(dataValue),
                  let compressed = performCompress(bytes, format: format) else {
                return JSValue(nullIn: ctx)
            }
            return makeUint8Array(compressed, in: ctx)
        }
        context.setObject(compressBlock, forKeyedSubscript: "__compress" as NSString)

        let decompressBlock: @convention(block) (JSValue, String) -> JSValue = { dataValue, format in
            let ctx = JSContext.current()!
            guard let bytes = extractUint8Array(dataValue),
                  let decompressed = performDecompress(bytes, format: format) else {
                return JSValue(nullIn: ctx)
            }
            return makeUint8Array(decompressed, in: ctx)
        }
        context.setObject(decompressBlock, forKeyedSubscript: "__decompress" as NSString)

        // ── Fetch bridge functions ──
        final class FetchStorage: Sendable {
            private struct State {
                var activeTasks: [Int: URLSessionDataTask] = [:]
                var nextTaskId: Int = 1
            }
            private let state = Mutex(State())

            func allocateTaskId() -> Int {
                state.withLock { s in
                    let id = s.nextTaskId
                    s.nextTaskId += 1
                    return id
                }
            }

            func storeTask(_ taskId: Int, _ task: URLSessionDataTask) {
                state.withLock { $0.activeTasks[taskId] = task }
            }

            func removeTask(_ taskId: Int) {
                state.withLock { _ = $0.activeTasks.removeValue(forKey: taskId) }
            }

            func cancelTask(_ taskId: Int) {
                let task = state.withLock { $0.activeTasks[taskId] }
                task?.cancel()
            }
        }
        let fetchStorage = FetchStorage()
        let noRedirectSession = URLSession(
            configuration: .default,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )

        // __fetchBridge(url, method, headerPairs, body, redirect, resolve, reject) -> taskId
        let fetchBridgeBlock: @convention(block) (String, String, JSValue, JSValue, String, JSValue, JSValue) -> Int = { urlStr, method, headerPairsVal, bodyVal, redirectMode, resolve, reject in
            guard let url = URL(string: urlStr) else {
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let err = JSValue(newErrorFromMessage: "Invalid URL: \(urlStr)", in: ctx)
                    reject.call(withArguments: [err as Any])
                }
                return 0
            }

            var request = URLRequest(url: url)
            request.httpMethod = method

            // Set headers from flat array [key, value, key, value, ...]
            if !headerPairsVal.isUndefined && !headerPairsVal.isNull {
                let len = Int(headerPairsVal.forProperty("length")?.toInt32() ?? 0)
                var i = 0
                while i < len - 1 {
                    let key = headerPairsVal.atIndex(i).toString() ?? ""
                    let value = headerPairsVal.atIndex(i + 1).toString() ?? ""
                    request.addValue(value, forHTTPHeaderField: key)
                    i += 2
                }
            }

            // Set body
            if !bodyVal.isUndefined && !bodyVal.isNull {
                if let bytes = extractUint8Array(bodyVal) {
                    request.httpBody = Data(bytes)
                } else if let str = bodyVal.toString() {
                    request.httpBody = str.data(using: .utf8)
                }
            }

            let taskId = fetchStorage.allocateTaskId()

            runtime.eventLoop.retainHandle()

            let session = (redirectMode == "follow") ? URLSession.shared : noRedirectSession

            let task = session.dataTask(with: request) { data, response, error in
                runtime.eventLoop.enqueueCallback {
                    runtime.eventLoop.releaseHandle()
                    fetchStorage.removeTask(taskId)

                    let ctx = runtime.context

                    if let error = error {
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                            // AbortError
                            let domExCtor = ctx.objectForKeyedSubscript("DOMException" as NSString)
                            let abortErr = domExCtor?.construct(withArguments: ["The operation was aborted.", "AbortError"])
                            reject.call(withArguments: [abortErr as Any])
                        } else {
                            let err = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                            reject.call(withArguments: [err as Any])
                        }
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        let err = JSValue(newErrorFromMessage: "Network error", in: ctx)
                        reject.call(withArguments: [err as Any])
                        return
                    }

                    // redirect: 'error' mode - reject on 3xx
                    if redirectMode == "error" && (300...399).contains(httpResponse.statusCode) {
                        let err = JSValue(newErrorFromMessage: "redirect mode is set to error", in: ctx)
                        reject.call(withArguments: [err as Any])
                        return
                    }

                    let result = JSValue(newObjectIn: ctx)!
                    result.setValue(httpResponse.statusCode, forProperty: "status")
                    result.setValue(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode), forProperty: "statusText")
                    result.setValue(httpResponse.url?.absoluteString ?? urlStr, forProperty: "url")
                    result.setValue(httpResponse.url?.absoluteString != urlStr, forProperty: "redirected")

                    // Headers as flat array
                    let headerArray = JSValue(newArrayIn: ctx)!
                    var headerIdx = 0
                    for (key, value) in httpResponse.allHeaderFields {
                        headerArray.setValue("\(key)", at: headerIdx)
                        headerIdx += 1
                        headerArray.setValue("\(value)", at: headerIdx)
                        headerIdx += 1
                    }
                    result.setValue(headerArray, forProperty: "headers")

                    // Body
                    if let data = data, !data.isEmpty {
                        if let str = String(data: data, encoding: .utf8) {
                            result.setValue(str, forProperty: "bodyStr")
                        } else {
                            let uint8 = makeUint8Array(Array(data), in: ctx)
                            result.setValue(uint8, forProperty: "bodyBytes")
                        }
                    }

                    resolve.call(withArguments: [result])
                }
            }

            fetchStorage.storeTask(taskId, task)
            task.resume()

            return taskId
        }
        context.setObject(fetchBridgeBlock, forKeyedSubscript: "__fetchBridge" as NSString)

        // __fetchCancel(taskId)
        let fetchCancelBlock: @convention(block) (Int) -> Void = { taskId in
            fetchStorage.cancelTask(taskId)
        }
        context.setObject(fetchCancelBlock, forKeyedSubscript: "__fetchCancel" as NSString)

        let script = """
        (function(g) {
            // ============================================================
            // Headers
            // ============================================================
            function Headers(init) {
                this._map = Object.create(null);
                this._keys = [];
                if (init) {
                    if (init instanceof Headers) {
                        var it = init.entries();
                        var next;
                        while (!(next = it.next()).done) {
                            this.append(next.value[0], next.value[1]);
                        }
                    } else if (Array.isArray(init)) {
                        for (var i = 0; i < init.length; i++) {
                            this.append(init[i][0], init[i][1]);
                        }
                    } else if (typeof init === 'object') {
                        var keys = Object.keys(init);
                        for (var j = 0; j < keys.length; j++) {
                            this.append(keys[j], init[keys[j]]);
                        }
                    }
                }
            }
            Headers.prototype.append = function(name, value) {
                var lc = name.toLowerCase();
                if (!(lc in this._map)) {
                    this._keys.push(lc);
                    this._map[lc] = [];
                }
                this._map[lc].push(String(value));
            };
            Headers.prototype.set = function(name, value) {
                var lc = name.toLowerCase();
                if (!(lc in this._map)) {
                    this._keys.push(lc);
                }
                this._map[lc] = [String(value)];
            };
            Headers.prototype.get = function(name) {
                var lc = name.toLowerCase();
                var arr = this._map[lc];
                return arr ? arr.join(', ') : null;
            };
            Headers.prototype.has = function(name) {
                return name.toLowerCase() in this._map;
            };
            Headers.prototype['delete'] = function(name) {
                var lc = name.toLowerCase();
                if (lc in this._map) {
                    delete this._map[lc];
                    var idx = this._keys.indexOf(lc);
                    if (idx !== -1) this._keys.splice(idx, 1);
                }
            };
            Headers.prototype.forEach = function(callback, thisArg) {
                for (var i = 0; i < this._keys.length; i++) {
                    var k = this._keys[i];
                    callback.call(thisArg, this._map[k].join(', '), k, this);
                }
            };
            Headers.prototype.entries = function() {
                var keys = this._keys;
                var map = this._map;
                var index = 0;
                return {
                    next: function() {
                        if (index < keys.length) {
                            var k = keys[index++];
                            return { value: [k, map[k].join(', ')], done: false };
                        }
                        return { value: undefined, done: true };
                    },
                    [Symbol.iterator]: function() { return this; }
                };
            };
            Headers.prototype.keys = function() {
                var keys = this._keys;
                var index = 0;
                return {
                    next: function() {
                        if (index < keys.length) {
                            return { value: keys[index++], done: false };
                        }
                        return { value: undefined, done: true };
                    },
                    [Symbol.iterator]: function() { return this; }
                };
            };
            Headers.prototype.values = function() {
                var keys = this._keys;
                var map = this._map;
                var index = 0;
                return {
                    next: function() {
                        if (index < keys.length) {
                            var k = keys[index++];
                            return { value: map[k].join(', '), done: false };
                        }
                        return { value: undefined, done: true };
                    },
                    [Symbol.iterator]: function() { return this; }
                };
            };
            Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
            g.Headers = Headers;

            // ============================================================
            // AbortSignal / AbortController
            // ============================================================
            function AbortSignal() {
                this.aborted = false;
                this.reason = undefined;
                this._listeners = [];
            }
            AbortSignal.prototype.addEventListener = function(type, listener) {
                if (type === 'abort') this._listeners.push(listener);
            };
            AbortSignal.prototype.removeEventListener = function(type, listener) {
                if (type === 'abort') {
                    var idx = this._listeners.indexOf(listener);
                    if (idx !== -1) this._listeners.splice(idx, 1);
                }
            };
            AbortSignal.prototype.throwIfAborted = function() {
                if (this.aborted) throw this.reason;
            };
            AbortSignal.abort = function(reason) {
                var signal = new AbortSignal();
                signal.aborted = true;
                signal.reason = reason !== undefined ? reason : new DOMException('The operation was aborted.', 'AbortError');
                return signal;
            };
            AbortSignal.timeout = function(ms) {
                var signal = new AbortSignal();
                setTimeout(function() {
                    signal.aborted = true;
                    signal.reason = new DOMException('The operation timed out.', 'TimeoutError');
                    for (var i = 0; i < signal._listeners.length; i++) {
                        signal._listeners[i]({ type: 'abort', target: signal });
                    }
                }, ms);
                return signal;
            };
            g.AbortSignal = AbortSignal;

            function AbortController() {
                this.signal = new AbortSignal();
            }
            AbortController.prototype.abort = function(reason) {
                if (this.signal.aborted) return;
                this.signal.aborted = true;
                this.signal.reason = reason !== undefined ? reason : new DOMException('The operation was aborted.', 'AbortError');
                var listeners = this.signal._listeners.slice();
                for (var i = 0; i < listeners.length; i++) {
                    listeners[i]({ type: 'abort', target: this.signal });
                }
            };
            g.AbortController = AbortController;

            // DOMException polyfill (minimal)
            if (typeof g.DOMException === 'undefined') {
                function DOMException(message, name) {
                    this.message = message || '';
                    this.name = name || 'Error';
                }
                DOMException.prototype = Object.create(Error.prototype);
                DOMException.prototype.constructor = DOMException;
                g.DOMException = DOMException;
            }

            // ============================================================
            // ReadableStream
            // ============================================================
            function ReadableStreamDefaultController(stream) {
                this._stream = stream;
                this._closeRequested = false;
            }
            ReadableStreamDefaultController.prototype.enqueue = function(chunk) {
                this._stream._queue.push(chunk);
                if (this._stream._reader && this._stream._reader._resolve) {
                    var resolve = this._stream._reader._resolve;
                    this._stream._reader._resolve = null;
                    this._stream._reader._reject = null;
                    resolve({ value: this._stream._queue.shift(), done: false });
                }
            };
            ReadableStreamDefaultController.prototype.close = function() {
                this._closeRequested = true;
                this._stream._closed = true;
                if (this._stream._reader) {
                    if (this._stream._queue.length === 0 && this._stream._reader._resolve) {
                        var resolve = this._stream._reader._resolve;
                        this._stream._reader._resolve = null;
                        this._stream._reader._reject = null;
                        resolve({ value: undefined, done: true });
                    }
                    if (this._stream._reader._closedResolve) {
                        this._stream._reader._closedResolve();
                        this._stream._reader._closedResolve = null;
                    }
                }
            };
            ReadableStreamDefaultController.prototype.error = function(e) {
                this._stream._errored = true;
                this._stream._storedError = e;
                if (this._stream._reader && this._stream._reader._reject) {
                    var reject = this._stream._reader._reject;
                    this._stream._reader._reject = null;
                    this._stream._reader._resolve = null;
                    reject(e);
                }
                if (this._stream._reader && this._stream._reader._closedReject) {
                    this._stream._reader._closedReject(e);
                    this._stream._reader._closedReject = null;
                }
            };

            function ReadableStreamDefaultReader(stream) {
                this._stream = stream;
                this._resolve = null;
                this._reject = null;
                this._closedResolve = null;
                this._closedReject = null;
                var self = this;
                this.closed = new Promise(function(resolve, reject) {
                    if (stream._closed) {
                        resolve();
                    } else if (stream._errored) {
                        reject(stream._storedError);
                    } else {
                        self._closedResolve = resolve;
                        self._closedReject = reject;
                    }
                });
            }
            function readableStreamCallPull(stream) {
                if (!stream._pull || stream._closed) return;
                if (stream._pulling) {
                    stream._pullAgain = true;
                    return;
                }
                stream._pulling = true;
                Promise.resolve(stream._pull(stream._controller)).then(function() {
                    stream._pulling = false;
                    if (stream._pullAgain) {
                        stream._pullAgain = false;
                        readableStreamCallPull(stream);
                    }
                })['catch'](function(e) {
                    stream._pulling = false;
                    stream._pullAgain = false;
                    stream._controller.error(e);
                });
            }
            ReadableStreamDefaultReader.prototype.read = function() {
                var self = this;
                var stream = this._stream;
                if (stream._queue.length > 0) {
                    var chunk = stream._queue.shift();
                    if (stream._closed && stream._queue.length === 0) {
                        if (self._closedResolve) {
                            self._closedResolve();
                            self._closedResolve = null;
                        }
                    }
                    readableStreamCallPull(stream);
                    return Promise.resolve({ value: chunk, done: false });
                }
                if (stream._closed) {
                    if (self._closedResolve) {
                        self._closedResolve();
                        self._closedResolve = null;
                    }
                    return Promise.resolve({ value: undefined, done: true });
                }
                if (stream._errored) {
                    return Promise.reject(stream._storedError);
                }
                // Create pending Promise first so pull can resolve it synchronously
                var promise = new Promise(function(resolve, reject) {
                    self._resolve = resolve;
                    self._reject = reject;
                });
                readableStreamCallPull(stream);
                return promise;
            };
            ReadableStreamDefaultReader.prototype.cancel = function(reason) {
                this._stream._closed = true;
                this._stream._queue = [];
                if (this._closedResolve) {
                    this._closedResolve();
                    this._closedResolve = null;
                }
                return Promise.resolve();
            };
            ReadableStreamDefaultReader.prototype.releaseLock = function() {
                this._stream._reader = null;
            };

            function ReadableStream(underlyingSource) {
                this._queue = [];
                this._closed = false;
                this._errored = false;
                this._storedError = null;
                this._reader = null;
                this._pull = null;
                this._pulling = false;
                this._pullAgain = false;
                this._controller = new ReadableStreamDefaultController(this);
                if (underlyingSource) {
                    if (typeof underlyingSource.pull === 'function') {
                        this._pull = underlyingSource.pull;
                    }
                    if (typeof underlyingSource.start === 'function') {
                        underlyingSource.start(this._controller);
                    }
                }
            }
            ReadableStream.prototype.getReader = function() {
                if (this._reader) {
                    throw new TypeError('ReadableStream is already locked');
                }
                var reader = new ReadableStreamDefaultReader(this);
                this._reader = reader;
                return reader;
            };
            Object.defineProperty(ReadableStream.prototype, 'locked', {
                get: function() { return this._reader !== null; }
            });
            ReadableStream.prototype.cancel = function(reason) {
                this._closed = true;
                this._queue = [];
                return Promise.resolve();
            };
            ReadableStream.prototype[Symbol.asyncIterator] = function() {
                var reader = this.getReader();
                return {
                    next: function() {
                        return reader.read();
                    },
                    'return': function() {
                        reader.releaseLock();
                        return Promise.resolve({ value: undefined, done: true });
                    }
                };
            };
            ReadableStream.prototype.pipeTo = function(destination, options) {
                var reader = this.getReader();
                var writer = destination.getWriter();
                var preventClose = options && options.preventClose;
                var preventAbort = options && options.preventAbort;
                var preventCancel = options && options.preventCancel;
                function pump() {
                    return reader.read().then(function(result) {
                        if (result.done) {
                            reader.releaseLock();
                            if (!preventClose) {
                                return writer.close().then(function() {
                                    writer.releaseLock();
                                });
                            }
                            writer.releaseLock();
                            return;
                        }
                        return writer.write(result.value).then(pump);
                    });
                }
                return pump();
            };

            ReadableStream.prototype.pipeThrough = function(transform, options) {
                this.pipeTo(transform.writable, options);
                return transform.readable;
            };
            ReadableStream.prototype.tee = function() {
                var reader = this.getReader();
                var branch1Controller, branch2Controller;
                var cancelled1 = false, cancelled2 = false;
                var branch1 = new ReadableStream({
                    start: function(c) { branch1Controller = c; },
                    cancel: function() { cancelled1 = true; if (cancelled2) reader.cancel(); }
                });
                var branch2 = new ReadableStream({
                    start: function(c) { branch2Controller = c; },
                    cancel: function() { cancelled2 = true; if (cancelled1) reader.cancel(); }
                });
                function pump() {
                    return reader.read().then(function(result) {
                        if (result.done) {
                            if (!cancelled1) branch1Controller.close();
                            if (!cancelled2) branch2Controller.close();
                            return;
                        }
                        if (!cancelled1) branch1Controller.enqueue(result.value);
                        if (!cancelled2) branch2Controller.enqueue(result.value);
                        return pump();
                    });
                }
                pump();
                return [branch1, branch2];
            };

            g.ReadableStream = ReadableStream;

            // ============================================================
            // WritableStream
            // ============================================================
            function WritableStreamDefaultWriter(stream) {
                this._stream = stream;
                stream._writer = this;
                var self = this;
                this.closed = new Promise(function(resolve, reject) {
                    self._closedResolve = resolve;
                    self._closedReject = reject;
                });
                this.ready = Promise.resolve();
            }
            WritableStreamDefaultWriter.prototype.write = function(chunk) {
                var stream = this._stream;
                if (stream._closed) return Promise.reject(new TypeError('Cannot write to a closed WritableStream'));
                if (stream._writeHandler) {
                    try {
                        var result = stream._writeHandler(chunk);
                        if (result && typeof result.then === 'function') return result;
                    } catch(e) {
                        return Promise.reject(e);
                    }
                }
                if (stream._underlyingSink && typeof stream._underlyingSink.write === 'function') {
                    try {
                        var result = stream._underlyingSink.write(chunk, stream._controller);
                        if (result && typeof result.then === 'function') return result;
                    } catch(e) {
                        return Promise.reject(e);
                    }
                }
                return Promise.resolve();
            };
            WritableStreamDefaultWriter.prototype.close = function() {
                var stream = this._stream;
                if (stream._closed) return Promise.reject(new TypeError('Cannot close a closed WritableStream'));
                stream._closed = true;
                if (stream._closeHandler) {
                    try {
                        stream._closeHandler();
                    } catch(e) {
                        if (this._closedReject) this._closedReject(e);
                        return Promise.reject(e);
                    }
                }
                if (stream._underlyingSink && typeof stream._underlyingSink.close === 'function') {
                    try {
                        stream._underlyingSink.close();
                    } catch(e) {
                        if (this._closedReject) this._closedReject(e);
                        return Promise.reject(e);
                    }
                }
                if (this._closedResolve) {
                    this._closedResolve();
                    this._closedResolve = null;
                }
                return Promise.resolve();
            };
            WritableStreamDefaultWriter.prototype.abort = function(reason) {
                this._stream._closed = true;
                if (this._closedReject) {
                    this._closedReject(reason);
                    this._closedReject = null;
                }
                return Promise.resolve();
            };
            WritableStreamDefaultWriter.prototype.releaseLock = function() {
                this._stream._writer = null;
            };

            function WritableStream(underlyingSink) {
                this._closed = false;
                this._writer = null;
                this._underlyingSink = underlyingSink || null;
                this._writeHandler = null;
                this._closeHandler = null;
                this._controller = {};
                if (underlyingSink && typeof underlyingSink.start === 'function') {
                    underlyingSink.start(this._controller);
                }
            }
            WritableStream.prototype.getWriter = function() {
                if (this._writer) {
                    throw new TypeError('WritableStream is already locked');
                }
                return new WritableStreamDefaultWriter(this);
            };
            Object.defineProperty(WritableStream.prototype, 'locked', {
                get: function() { return this._writer !== null; }
            });
            WritableStream.prototype.close = function() {
                if (this._writer) {
                    return this._writer.close();
                }
                this._closed = true;
                return Promise.resolve();
            };
            WritableStream.prototype.abort = function(reason) {
                this._closed = true;
                return Promise.resolve();
            };
            g.WritableStream = WritableStream;

            // ============================================================
            // TransformStream
            // ============================================================
            function TransformStream(transformer) {
                var readableController;
                this.readable = new ReadableStream({
                    start: function(controller) {
                        readableController = controller;
                    }
                });
                this.writable = new WritableStream();
                this.writable._writeHandler = function(chunk) {
                    if (transformer && typeof transformer.transform === 'function') {
                        transformer.transform(chunk, {
                            enqueue: function(c) { readableController.enqueue(c); }
                        });
                    } else {
                        readableController.enqueue(chunk);
                    }
                };
                this.writable._closeHandler = function() {
                    if (transformer && typeof transformer.flush === 'function') {
                        transformer.flush({
                            enqueue: function(c) { readableController.enqueue(c); }
                        });
                    }
                    readableController.close();
                };
            }
            g.TransformStream = TransformStream;

            // ============================================================
            // CompressionStream / DecompressionStream
            // ============================================================
            function CompressionStream(format) {
                if (format !== 'gzip' && format !== 'deflate' && format !== 'deflate-raw') {
                    throw new TypeError("Unsupported compression format: '" + format + "'");
                }
                var chunks = [];
                var totalLength = 0;
                TransformStream.call(this, {
                    transform: function(chunk, controller) {
                        var bytes = (chunk instanceof Uint8Array) ? chunk
                                  : new TextEncoder().encode(String(chunk));
                        chunks.push(bytes);
                        totalLength += bytes.length;
                    },
                    flush: function(controller) {
                        var combined = new Uint8Array(totalLength);
                        var offset = 0;
                        for (var i = 0; i < chunks.length; i++) {
                            combined.set(chunks[i], offset);
                            offset += chunks[i].length;
                        }
                        var compressed = __compress(combined, format);
                        if (compressed) controller.enqueue(compressed);
                    }
                });
            }
            CompressionStream.prototype = Object.create(TransformStream.prototype);
            CompressionStream.prototype.constructor = CompressionStream;
            g.CompressionStream = CompressionStream;

            function DecompressionStream(format) {
                if (format !== 'gzip' && format !== 'deflate' && format !== 'deflate-raw') {
                    throw new TypeError("Unsupported compression format: '" + format + "'");
                }
                var chunks = [];
                var totalLength = 0;
                TransformStream.call(this, {
                    transform: function(chunk, controller) {
                        var bytes = (chunk instanceof Uint8Array) ? chunk
                                  : new Uint8Array(chunk);
                        chunks.push(bytes);
                        totalLength += bytes.length;
                    },
                    flush: function(controller) {
                        var combined = new Uint8Array(totalLength);
                        var offset = 0;
                        for (var i = 0; i < chunks.length; i++) {
                            combined.set(chunks[i], offset);
                            offset += chunks[i].length;
                        }
                        var decompressed = __decompress(combined, format);
                        if (decompressed) controller.enqueue(decompressed);
                    }
                });
            }
            DecompressionStream.prototype = Object.create(TransformStream.prototype);
            DecompressionStream.prototype.constructor = DecompressionStream;
            g.DecompressionStream = DecompressionStream;

            // ============================================================
            // File (extends Blob)
            // ============================================================
            function File(parts, name, options) {
                Blob.call(this, parts, options);
                this._name = String(name);
                options = options || {};
                this._lastModified = options.lastModified !== undefined
                    ? Number(options.lastModified) : Date.now();
            }
            File.prototype = Object.create(Blob.prototype);
            File.prototype.constructor = File;
            Object.defineProperty(File.prototype, 'name', {
                get: function() { return this._name; },
                enumerable: true, configurable: true
            });
            Object.defineProperty(File.prototype, 'lastModified', {
                get: function() { return this._lastModified; },
                enumerable: true, configurable: true
            });
            g.File = File;

            // ============================================================
            // FormData
            // ============================================================
            function FormData() {
                this._entries = [];
            }
            FormData.prototype.append = function(name, value, filename) {
                name = String(name);
                if (value instanceof Blob) {
                    if (!(value instanceof File)) {
                        value = new File([value], filename !== undefined ? String(filename) : 'blob', { type: value.type });
                    } else if (filename !== undefined) {
                        value = new File([value], String(filename), { type: value.type, lastModified: value.lastModified });
                    }
                } else {
                    value = String(value);
                }
                this._entries.push([name, value]);
            };
            FormData.prototype.set = function(name, value, filename) {
                name = String(name);
                if (value instanceof Blob) {
                    if (!(value instanceof File)) {
                        value = new File([value], filename !== undefined ? String(filename) : 'blob', { type: value.type });
                    } else if (filename !== undefined) {
                        value = new File([value], String(filename), { type: value.type, lastModified: value.lastModified });
                    }
                } else {
                    value = String(value);
                }
                var found = false;
                var newEntries = [];
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] === name) {
                        if (!found) {
                            newEntries.push([name, value]);
                            found = true;
                        }
                    } else {
                        newEntries.push(this._entries[i]);
                    }
                }
                if (!found) newEntries.push([name, value]);
                this._entries = newEntries;
            };
            FormData.prototype.get = function(name) {
                name = String(name);
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] === name) return this._entries[i][1];
                }
                return null;
            };
            FormData.prototype.getAll = function(name) {
                name = String(name);
                var result = [];
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] === name) result.push(this._entries[i][1]);
                }
                return result;
            };
            FormData.prototype.has = function(name) {
                name = String(name);
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] === name) return true;
                }
                return false;
            };
            FormData.prototype['delete'] = function(name) {
                name = String(name);
                var newEntries = [];
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] !== name) newEntries.push(this._entries[i]);
                }
                this._entries = newEntries;
            };
            FormData.prototype.forEach = function(callback, thisArg) {
                for (var i = 0; i < this._entries.length; i++) {
                    callback.call(thisArg, this._entries[i][1], this._entries[i][0], this);
                }
            };
            FormData.prototype.entries = function() {
                var entries = this._entries;
                var index = 0;
                return {
                    next: function() {
                        if (index < entries.length) {
                            var entry = entries[index++];
                            return { value: [entry[0], entry[1]], done: false };
                        }
                        return { value: undefined, done: true };
                    }
                };
            };
            FormData.prototype.entries.prototype = undefined;
            FormData.prototype.keys = function() {
                var entries = this._entries;
                var index = 0;
                return {
                    next: function() {
                        if (index < entries.length) {
                            return { value: entries[index++][0], done: false };
                        }
                        return { value: undefined, done: true };
                    }
                };
            };
            FormData.prototype.values = function() {
                var entries = this._entries;
                var index = 0;
                return {
                    next: function() {
                        if (index < entries.length) {
                            return { value: entries[index++][1], done: false };
                        }
                        return { value: undefined, done: true };
                    }
                };
            };
            if (typeof Symbol !== 'undefined' && Symbol.iterator) {
                FormData.prototype[Symbol.iterator] = FormData.prototype.entries;
            }
            g.FormData = FormData;

            // ── multipart/form-data parser ──
            function __parseMultipart(bodyText, boundary) {
                var fd = new FormData();
                var delimiter = '--' + boundary;
                var parts = bodyText.split(delimiter);
                // skip first (preamble) and last (epilogue with --)
                for (var i = 1; i < parts.length; i++) {
                    var part = parts[i];
                    if (part.indexOf('--') === 0) break; // closing delimiter
                    // split headers from body at first CRLF CRLF
                    var headerEnd = part.indexOf('\\r\\n\\r\\n');
                    if (headerEnd === -1) continue;
                    var headerSection = part.substring(0, headerEnd);
                    var body = part.substring(headerEnd + 4);
                    // remove trailing \r\n
                    if (body.length >= 2 && body.substring(body.length - 2) === '\\r\\n') {
                        body = body.substring(0, body.length - 2);
                    }
                    // parse headers
                    var headers = {};
                    var headerLines = headerSection.split('\\r\\n');
                    for (var h = 0; h < headerLines.length; h++) {
                        var line = headerLines[h];
                        var colonIdx = line.indexOf(':');
                        if (colonIdx !== -1) {
                            var key = line.substring(0, colonIdx).trim().toLowerCase();
                            var val = line.substring(colonIdx + 1).trim();
                            headers[key] = val;
                        }
                    }
                    var disposition = headers['content-disposition'] || '';
                    var nameMatch = disposition.match(/name="([^"]*)"/);
                    if (!nameMatch) continue;
                    var fieldName = nameMatch[1];
                    var filenameMatch = disposition.match(/filename="([^"]*)"/);
                    if (filenameMatch) {
                        var contentType = headers['content-type'] || 'application/octet-stream';
                        var file = new File([body], filenameMatch[1], { type: contentType });
                        fd.append(fieldName, file);
                    } else {
                        fd.append(fieldName, body);
                    }
                }
                return fd;
            }

            // ============================================================
            // Request
            // ============================================================
            function Request(input, init) {
                if (typeof input === 'string' || input instanceof URL) {
                    this.url = String(input);
                } else if (input && typeof input === 'object') {
                    this.url = input.url || '';
                    if (!init) init = input;
                }
                init = init || {};
                this.method = (init.method || 'GET').toUpperCase();
                if (init.headers) {
                    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
                } else {
                    this.headers = new Headers();
                }
                this._bodySource = init.body !== undefined ? init.body : null;
                this._bodyStream = undefined;
                this.bodyUsed = false;
                this.signal = init.signal || new AbortSignal();
                this.mode = init.mode || 'cors';
                this.credentials = init.credentials || 'same-origin';
                this.cache = init.cache || 'default';
                this.redirect = init.redirect || 'follow';
                this.referrer = init.referrer || 'about:client';
                this.referrerPolicy = init.referrerPolicy || '';
                this.integrity = init.integrity || '';
                this.keepalive = init.keepalive || false;
                this.destination = init.destination || '';
                this.duplex = init.duplex || undefined;
            }
            Object.defineProperty(Request.prototype, 'body', {
                get: function() {
                    if (this._bodySource === null || this._bodySource === undefined) return null;
                    if (this._bodySource instanceof ReadableStream) return this._bodySource;
                    if (this._bodyStream !== undefined) return this._bodyStream;
                    var src = this._bodySource;
                    this._bodyStream = new ReadableStream({
                        start: function(controller) {
                            if (src instanceof Uint8Array) {
                                controller.enqueue(src);
                            } else {
                                controller.enqueue(new TextEncoder().encode(typeof src === 'string' ? src : String(src)));
                            }
                            controller.close();
                        }
                    });
                    return this._bodyStream;
                },
                configurable: true
            });
            Request.prototype.clone = function() {
                var body = this._bodySource;
                if (body instanceof ReadableStream) {
                    var teed = body.tee();
                    this._bodySource = teed[0];
                    this._bodyStream = undefined;
                    body = teed[1];
                }
                return new Request(this.url, {
                    method: this.method,
                    headers: new Headers(this.headers),
                    body: body,
                    signal: this.signal,
                    mode: this.mode,
                    credentials: this.credentials,
                    cache: this.cache,
                    redirect: this.redirect,
                    referrer: this.referrer,
                    referrerPolicy: this.referrerPolicy,
                    integrity: this.integrity,
                    keepalive: this.keepalive
                });
            };
            Request.prototype.text = function() {
                this.bodyUsed = true;
                var body = this._bodySource;
                if (body === null || body === undefined) return Promise.resolve('');
                if (typeof body === 'string') return Promise.resolve(body);
                if (body instanceof Uint8Array) return Promise.resolve(new TextDecoder().decode(body));
                if (body instanceof ReadableStream) {
                    var reader = body.getReader();
                    var chunks = [];
                    function pump() {
                        return reader.read().then(function(result) {
                            if (result.done) return chunks.join('');
                            chunks.push(typeof result.value === 'string' ? result.value : new TextDecoder().decode(result.value));
                            return pump();
                        });
                    }
                    return pump();
                }
                return Promise.resolve(String(body));
            };
            Request.prototype.json = function() {
                return this.text().then(function(t) { return JSON.parse(t); });
            };
            Request.prototype.arrayBuffer = function() {
                var body = this._bodySource;
                if (body instanceof Uint8Array) {
                    this.bodyUsed = true;
                    return Promise.resolve(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
                }
                return this.text().then(function(t) {
                    var enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
                    if (enc) return enc.encode(t).buffer;
                    return new ArrayBuffer(0);
                });
            };
            Request.prototype.blob = function() {
                var body = this._bodySource;
                if (body instanceof Uint8Array) {
                    this.bodyUsed = true;
                    return Promise.resolve(new Blob([body]));
                }
                return this.text().then(function(t) { return new Blob([t]); });
            };
            Request.prototype.formData = function() {
                var self = this;
                return this.text().then(function(bodyText) {
                    var ct = self.headers.get('content-type') || '';
                    if (ct.indexOf('application/x-www-form-urlencoded') !== -1) {
                        var params = new URLSearchParams(bodyText.replace(/\\+/g, '%20'));
                        var fd = new FormData();
                        params.forEach(function(value, key) { fd.append(key, value); });
                        return fd;
                    }
                    if (ct.indexOf('multipart/form-data') !== -1) {
                        var m = ct.match(/boundary="?([^\\s";]+)"?/);
                        if (!m) throw new TypeError('multipart/form-data missing boundary');
                        return __parseMultipart(bodyText, m[1]);
                    }
                    throw new TypeError('Could not parse content as FormData');
                });
            };
            g.Request = Request;

            // ============================================================
            // Response
            // ============================================================
            function Response(body, init) {
                init = init || {};
                this.status = init.status !== undefined ? init.status : 200;
                this.statusText = init.statusText || '';
                this.ok = this.status >= 200 && this.status < 300;
                if (init.headers) {
                    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
                } else {
                    this.headers = new Headers();
                }
                this._bodySource = body !== undefined && body !== null ? body : null;
                this._bodyStream = undefined;
                this.bodyUsed = false;
                this.type = 'default';
                this.url = init.url || '';
                this.redirected = false;
            }
            Object.defineProperty(Response.prototype, 'body', {
                get: function() {
                    if (this._bodySource === null || this._bodySource === undefined) return null;
                    if (this._bodySource instanceof ReadableStream) return this._bodySource;
                    if (this._bodyStream !== undefined) return this._bodyStream;
                    var src = this._bodySource;
                    this._bodyStream = new ReadableStream({
                        start: function(controller) {
                            if (src instanceof Uint8Array) {
                                controller.enqueue(src);
                            } else {
                                controller.enqueue(new TextEncoder().encode(typeof src === 'string' ? src : String(src)));
                            }
                            controller.close();
                        }
                    });
                    return this._bodyStream;
                },
                configurable: true
            });
            Response.prototype.clone = function() {
                var body = this._bodySource;
                if (body instanceof ReadableStream) {
                    var teed = body.tee();
                    this._bodySource = teed[0];
                    this._bodyStream = undefined;
                    body = teed[1];
                }
                return new Response(body, {
                    status: this.status,
                    statusText: this.statusText,
                    headers: new Headers(this.headers)
                });
            };
            Response.prototype.text = function() {
                this.bodyUsed = true;
                var body = this._bodySource;
                if (body === null || body === undefined) return Promise.resolve('');
                if (typeof body === 'string') return Promise.resolve(body);
                if (body instanceof Uint8Array) return Promise.resolve(new TextDecoder().decode(body));
                if (body instanceof ReadableStream) {
                    var reader = body.getReader();
                    var chunks = [];
                    function pump() {
                        return reader.read().then(function(result) {
                            if (result.done) return chunks.join('');
                            chunks.push(typeof result.value === 'string' ? result.value : new TextDecoder().decode(result.value));
                            return pump();
                        });
                    }
                    return pump();
                }
                return Promise.resolve(String(body));
            };
            Response.prototype.json = function() {
                return this.text().then(function(t) { return JSON.parse(t); });
            };
            Response.prototype.arrayBuffer = function() {
                var body = this._bodySource;
                if (body instanceof Uint8Array) {
                    this.bodyUsed = true;
                    return Promise.resolve(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
                }
                return this.text().then(function(t) {
                    var enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
                    if (enc) return enc.encode(t).buffer;
                    return new ArrayBuffer(0);
                });
            };
            Response.prototype.blob = function() {
                var body = this._bodySource;
                if (body instanceof Uint8Array) {
                    this.bodyUsed = true;
                    return Promise.resolve(new Blob([body]));
                }
                return this.text().then(function(t) { return new Blob([t]); });
            };
            Response.prototype.formData = function() {
                var self = this;
                return this.text().then(function(bodyText) {
                    var ct = self.headers.get('content-type') || '';
                    if (ct.indexOf('application/x-www-form-urlencoded') !== -1) {
                        var params = new URLSearchParams(bodyText.replace(/\\+/g, '%20'));
                        var fd = new FormData();
                        params.forEach(function(value, key) { fd.append(key, value); });
                        return fd;
                    }
                    if (ct.indexOf('multipart/form-data') !== -1) {
                        var m = ct.match(/boundary="?([^\\s";]+)"?/);
                        if (!m) throw new TypeError('multipart/form-data missing boundary');
                        return __parseMultipart(bodyText, m[1]);
                    }
                    throw new TypeError('Could not parse content as FormData');
                });
            };
            Response.redirect = function(url, status) {
                return new Response(null, {
                    status: status || 302,
                    headers: new Headers({ Location: url })
                });
            };
            Response.error = function() {
                var r = new Response(null, { status: 0 });
                r.type = 'error';
                return r;
            };
            Response.json = function(data, init) {
                init = init || {};
                var headers = init.headers ? (init.headers instanceof Headers ? init.headers : new Headers(init.headers)) : new Headers();
                if (!headers.has('content-type')) {
                    headers.set('content-type', 'application/json');
                }
                return new Response(JSON.stringify(data), {
                    status: init.status || 200,
                    statusText: init.statusText || '',
                    headers: headers
                });
            };
            g.Response = Response;

            // ============================================================
            // fetch
            // ============================================================
            g.fetch = function fetch(input, init) {
                init = init || {};
                var url, method, headers, body, signal, redirect;

                if (input instanceof Request) {
                    url = input.url;
                    method = init.method || input.method;
                    headers = new Headers(init.headers || input.headers);
                    body = init.body !== undefined ? init.body : input._bodySource;
                    signal = init.signal || input.signal;
                    redirect = init.redirect || input.redirect || 'follow';
                } else {
                    url = String(input instanceof URL ? input.href : input);
                    method = (init.method || 'GET').toUpperCase();
                    headers = new Headers(init.headers || {});
                    body = init.body !== undefined ? init.body : null;
                    signal = init.signal || null;
                    redirect = init.redirect || 'follow';
                }

                // AbortSignal pre-check
                if (signal && signal.aborted) {
                    return Promise.reject(signal.reason);
                }

                // Serialize body to Uint8Array
                var bodyBytes = null;
                if (body !== null && body !== undefined) {
                    if (typeof body === 'string') {
                        bodyBytes = new TextEncoder().encode(body);
                        if (!headers.has('content-type')) {
                            headers.set('content-type', 'text/plain;charset=UTF-8');
                        }
                    } else if (body instanceof Uint8Array) {
                        bodyBytes = body;
                    } else if (body instanceof ArrayBuffer) {
                        bodyBytes = new Uint8Array(body);
                    } else if (typeof Buffer !== 'undefined' && body instanceof Buffer) {
                        bodyBytes = body;
                    } else if (typeof Blob !== 'undefined' && body instanceof Blob) {
                        bodyBytes = body._data || new Uint8Array(0);
                    }
                }

                // Serialize headers to flat array
                var headerPairs = [];
                var hIt = headers.entries();
                var hNext;
                while (!(hNext = hIt.next()).done) {
                    headerPairs.push(hNext.value[0]);
                    headerPairs.push(hNext.value[1]);
                }

                return new Promise(function(resolve, reject) {
                    var taskId = __fetchBridge(url, method, headerPairs, bodyBytes, redirect,
                        function onResolve(result) {
                            var resHeaders = new Headers();
                            var rh = result.headers;
                            if (rh) {
                                var rhLen = rh.length;
                                for (var i = 0; i < rhLen; i += 2) {
                                    resHeaders.append(rh[i], rh[i + 1]);
                                }
                            }

                            var resBody = null;
                            if (result.bodyStr !== undefined) resBody = result.bodyStr;
                            else if (result.bodyBytes) resBody = result.bodyBytes;

                            var res = new Response(resBody, {
                                status: result.status,
                                statusText: result.statusText,
                                headers: resHeaders
                            });
                            // Override read-only-like properties
                            Object.defineProperty(res, 'url', { value: result.url, writable: false });
                            res.redirected = !!result.redirected;
                            res.type = 'basic';
                            resolve(res);
                        },
                        function onReject(err) { reject(err); }
                    );

                    if (signal && taskId > 0) {
                        signal.addEventListener('abort', function() {
                            __fetchCancel(taskId);
                        });
                    }
                });
            };

            // ============================================================
            // queueMicrotask
            // ============================================================
            if (typeof g.queueMicrotask === 'undefined') {
                g.queueMicrotask = function(callback) {
                    Promise.resolve().then(callback);
                };
            }

            // ============================================================
            // structuredClone (minimal)
            // ============================================================
            if (typeof g.structuredClone === 'undefined') {
                g.structuredClone = function(value) {
                    return JSON.parse(JSON.stringify(value));
                };
            }

            // ============================================================
            // Cache API (Web Cache API — in-memory implementation)
            // ============================================================
            function Cache() {
                this._entries = {};
            }

            Cache.prototype._resolveKey = function(request) {
                if (typeof request === 'string') return request;
                if (request instanceof URL) return request.href;
                if (request && typeof request === 'object' && request.url) return request.url;
                return String(request);
            };

            Cache.prototype._consumeBody = function(response) {
                var src = response._bodySource;
                if (src === null || src === undefined) {
                    return Promise.resolve(null);
                }
                if (typeof src === 'string') {
                    return Promise.resolve(src);
                }
                if (src instanceof Uint8Array) {
                    return Promise.resolve(new Uint8Array(src));
                }
                if (src instanceof ReadableStream) {
                    var reader = src.getReader();
                    var chunks = [];
                    function pump() {
                        return reader.read().then(function(result) {
                            if (result.done) {
                                if (chunks.length === 0) return null;
                                if (chunks.length === 1) return chunks[0];
                                var total = 0;
                                for (var i = 0; i < chunks.length; i++) total += chunks[i].length;
                                var merged = new Uint8Array(total);
                                var offset = 0;
                                for (var j = 0; j < chunks.length; j++) {
                                    merged.set(chunks[j], offset);
                                    offset += chunks[j].length;
                                }
                                return merged;
                            }
                            var chunk = result.value;
                            if (typeof chunk === 'string') {
                                chunks.push(new TextEncoder().encode(chunk));
                            } else if (chunk instanceof Uint8Array) {
                                chunks.push(chunk);
                            } else {
                                chunks.push(new TextEncoder().encode(String(chunk)));
                            }
                            return pump();
                        });
                    }
                    return pump();
                }
                return Promise.resolve(String(src));
            };

            Cache.prototype.match = function(request) {
                var key = this._resolveKey(request);
                var entry = this._entries[key];
                if (!entry) return Promise.resolve(undefined);
                var body = entry.body;
                if (body !== null && body instanceof Uint8Array) {
                    body = new Uint8Array(body);
                }
                var resp = new Response(body, {
                    status: entry.status,
                    statusText: entry.statusText,
                    headers: new Headers(entry.headers)
                });
                return Promise.resolve(resp);
            };

            Cache.prototype.put = function(request, response) {
                var key = this._resolveKey(request);
                var entries = this._entries;
                var status = response.status;
                var statusText = response.statusText;
                var headers = [];
                response.headers.forEach(function(value, name) {
                    headers.push([name, value]);
                });
                return this._consumeBody(response).then(function(body) {
                    entries[key] = {
                        body: body,
                        status: status,
                        statusText: statusText,
                        headers: headers
                    };
                });
            };

            Cache.prototype.delete = function(request) {
                var key = this._resolveKey(request);
                var had = key in this._entries;
                delete this._entries[key];
                return Promise.resolve(had);
            };

            Cache.prototype.keys = function() {
                var self = this;
                var reqs = Object.keys(this._entries).map(function(url) {
                    return new Request(url);
                });
                return Promise.resolve(reqs);
            };

            function CacheStorage() {
                this._caches = {};
            }

            CacheStorage.prototype.open = function(name) {
                if (!this._caches[name]) {
                    this._caches[name] = new Cache();
                }
                return Promise.resolve(this._caches[name]);
            };

            CacheStorage.prototype.has = function(name) {
                return Promise.resolve(name in this._caches);
            };

            CacheStorage.prototype.delete = function(name) {
                var had = name in this._caches;
                delete this._caches[name];
                return Promise.resolve(had);
            };

            CacheStorage.prototype.keys = function() {
                return Promise.resolve(Object.keys(this._caches));
            };

            g.caches = new CacheStorage();
        })(this);
        """
        context.evaluateScript(script)
    }

    // MARK: - Compression Helpers

    private static func extractUint8Array(_ value: JSValue) -> [UInt8]? {
        guard let length = value.forProperty("length")?.toInt32(), length >= 0 else {
            return nil
        }
        if length == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        for i in 0..<Int(length) {
            bytes[i] = UInt8(value.atIndex(i).toInt32() & 0xFF)
        }
        return bytes
    }

    private static func makeUint8Array(_ bytes: [UInt8], in ctx: JSContext) -> JSValue {
        let ctor = ctx.objectForKeyedSubscript("Uint8Array" as NSString)!
        let jsArray = JSValue(newArrayIn: ctx)!
        for (i, b) in bytes.enumerated() {
            jsArray.setValue(b, at: i)
        }
        return ctor.construct(withArguments: [jsArray])!
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func performCompress(_ input: [UInt8], format: String) -> [UInt8]? {
        if input.isEmpty {
            // Empty data: return empty compressed result appropriate for format
            if format == "gzip" {
                // Minimal valid gzip for empty content
                let compressed = performCompress([UInt8](), format: "deflate")
                guard let raw = compressed else { return nil }
                var result: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]
                result.append(contentsOf: raw)
                let crc = crc32([])
                result.append(UInt8(crc & 0xFF))
                result.append(UInt8((crc >> 8) & 0xFF))
                result.append(UInt8((crc >> 16) & 0xFF))
                result.append(UInt8((crc >> 24) & 0xFF))
                result.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // size = 0
                return result
            }
            // For deflate/deflate-raw, return minimal raw deflate for empty
            let data = Data([UInt8]())
            guard let c = try? (data as NSData).compressed(using: .zlib) as Data else {
                return [0x03, 0x00] // minimal empty deflate block
            }
            return Array(c)
        }

        let data = Data(input)
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        let rawDeflate = Array(compressed)

        if format == "gzip" {
            var result: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]
            result.append(contentsOf: rawDeflate)
            let crc = crc32(input)
            result.append(UInt8(crc & 0xFF))
            result.append(UInt8((crc >> 8) & 0xFF))
            result.append(UInt8((crc >> 16) & 0xFF))
            result.append(UInt8((crc >> 24) & 0xFF))
            let size = UInt32(truncatingIfNeeded: input.count)
            result.append(UInt8(size & 0xFF))
            result.append(UInt8((size >> 8) & 0xFF))
            result.append(UInt8((size >> 16) & 0xFF))
            result.append(UInt8((size >> 24) & 0xFF))
            return result
        }

        // deflate / deflate-raw: raw deflate
        return rawDeflate
    }

    private static func performDecompress(_ input: [UInt8], format: String) -> [UInt8]? {
        var rawDeflate: [UInt8]

        if format == "gzip" {
            guard input.count >= 18 else { return nil }
            guard input[0] == 0x1f && input[1] == 0x8b else { return nil }
            let flg = input[3]
            var offset = 10

            // FEXTRA
            if flg & 0x04 != 0 {
                guard offset + 2 <= input.count else { return nil }
                let xlen = Int(input[offset]) | (Int(input[offset + 1]) << 8)
                offset += 2 + xlen
            }
            // FNAME
            if flg & 0x08 != 0 {
                while offset < input.count && input[offset] != 0 { offset += 1 }
                offset += 1
            }
            // FCOMMENT
            if flg & 0x10 != 0 {
                while offset < input.count && input[offset] != 0 { offset += 1 }
                offset += 1
            }
            // FHCRC
            if flg & 0x02 != 0 {
                offset += 2
            }

            guard offset <= input.count - 8 else { return nil }
            rawDeflate = Array(input[offset..<(input.count - 8)])
        } else {
            rawDeflate = input
        }

        if rawDeflate.isEmpty {
            return []
        }

        let data = Data(rawDeflate)
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return Array(decompressed)
    }
}

// MARK: - NoRedirectDelegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
