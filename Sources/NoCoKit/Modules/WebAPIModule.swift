import Foundation
import JavaScriptCore
import Compression

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
                    // If we have a pull function and queue is getting low, call it
                    if (stream._pull && !stream._pulling && !stream._closed) {
                        stream._pulling = true;
                        Promise.resolve(stream._pull(stream._controller)).then(function() {
                            stream._pulling = false;
                        })['catch'](function(e) {
                            stream._pulling = false;
                            stream._controller.error(e);
                        });
                    }
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
                // Need to wait for data - also trigger pull if available
                if (stream._pull && !stream._pulling) {
                    stream._pulling = true;
                    Promise.resolve(stream._pull(stream._controller)).then(function() {
                        stream._pulling = false;
                    })['catch'](function(e) {
                        stream._pulling = false;
                        stream._controller.error(e);
                    });
                }
                return new Promise(function(resolve, reject) {
                    self._resolve = resolve;
                    self._reject = reject;
                });
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
                            controller.enqueue(typeof src === 'string' ? src : String(src));
                            controller.close();
                        }
                    });
                    return this._bodyStream;
                },
                configurable: true
            });
            Request.prototype.clone = function() {
                return new Request(this.url, {
                    method: this.method,
                    headers: new Headers(this.headers),
                    body: this._bodySource,
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
                return this.text().then(function(t) {
                    var enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
                    if (enc) return enc.encode(t).buffer;
                    return new ArrayBuffer(0);
                });
            };
            Request.prototype.blob = function() {
                return this.text().then(function(t) { return new Blob([t]); });
            };
            Request.prototype.formData = function() {
                return Promise.reject(new TypeError('formData() is not supported'));
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
                            controller.enqueue(typeof src === 'string' ? src : String(src));
                            controller.close();
                        }
                    });
                    return this._bodyStream;
                },
                configurable: true
            });
            Response.prototype.clone = function() {
                return new Response(this._bodySource, {
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
                return this.text().then(function(t) {
                    var enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
                    if (enc) return enc.encode(t).buffer;
                    return new ArrayBuffer(0);
                });
            };
            Response.prototype.blob = function() {
                return this.text().then(function(t) { return new Blob([t]); });
            };
            Response.prototype.formData = function() {
                return Promise.reject(new TypeError('formData() is not supported'));
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
