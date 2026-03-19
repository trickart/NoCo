import Foundation
import JavaScriptCore
import Compression

/// Implements the Node.js `zlib` module using Apple's Compression framework.
public struct ZlibModule: NodeModule {
    public static let moduleName = "zlib"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let exports = JSValue(newObjectIn: context)!

        // Per-runtime stream storage (captured by closures below)
        final class StreamStorage {
            var streams: [Int: InflateStream] = [:]
            var nextStreamId: Int = 1
        }
        let storage = StreamStorage()

        // ── Constants ──
        exports.setValue(0, forProperty: "Z_NO_FLUSH")
        exports.setValue(1, forProperty: "Z_PARTIAL_FLUSH")
        exports.setValue(2, forProperty: "Z_SYNC_FLUSH")
        exports.setValue(3, forProperty: "Z_FULL_FLUSH")
        exports.setValue(4, forProperty: "Z_FINISH")
        exports.setValue(5, forProperty: "Z_BLOCK")
        exports.setValue(6, forProperty: "Z_TREES")

        exports.setValue(0, forProperty: "Z_OK")
        exports.setValue(1, forProperty: "Z_STREAM_END")
        exports.setValue(2, forProperty: "Z_NEED_DICT")
        exports.setValue(-1, forProperty: "Z_ERRNO")
        exports.setValue(-2, forProperty: "Z_STREAM_ERROR")
        exports.setValue(-3, forProperty: "Z_DATA_ERROR")
        exports.setValue(-4, forProperty: "Z_MEM_ERROR")
        exports.setValue(-5, forProperty: "Z_BUF_ERROR")
        exports.setValue(-6, forProperty: "Z_VERSION_ERROR")

        exports.setValue(0, forProperty: "Z_NO_COMPRESSION")
        exports.setValue(1, forProperty: "Z_BEST_SPEED")
        exports.setValue(9, forProperty: "Z_BEST_COMPRESSION")
        exports.setValue(-1, forProperty: "Z_DEFAULT_COMPRESSION")

        exports.setValue(1, forProperty: "Z_FILTERED")
        exports.setValue(2, forProperty: "Z_HUFFMAN_ONLY")
        exports.setValue(3, forProperty: "Z_RLE")
        exports.setValue(4, forProperty: "Z_FIXED")
        exports.setValue(0, forProperty: "Z_DEFAULT_STRATEGY")

        exports.setValue(64, forProperty: "Z_MIN_CHUNK")
        exports.setValue(16384, forProperty: "Z_DEFAULT_CHUNK")
        exports.setValue(15, forProperty: "Z_MIN_WINDOWBITS")
        exports.setValue(15, forProperty: "Z_MAX_WINDOWBITS")
        exports.setValue(15, forProperty: "Z_DEFAULT_WINDOWBITS")
        exports.setValue(1, forProperty: "Z_MIN_LEVEL")
        exports.setValue(9, forProperty: "Z_MAX_LEVEL")
        exports.setValue(1, forProperty: "Z_MIN_MEMLEVEL")
        exports.setValue(9, forProperty: "Z_MAX_MEMLEVEL")
        exports.setValue(8, forProperty: "Z_DEFAULT_MEMLEVEL")

        // ── Swift-backed deflateSync ──
        let deflateSync: @convention(block) (JSValue, JSValue) -> JSValue = { bufVal, optsVal in
            let ctx = JSContext.current()!
            let bufferCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)!

            guard let inputBytes = extractUint8Array(bufVal, in: ctx),
                  !inputBytes.isEmpty else {
                ctx.exception = JSValue(newErrorFromMessage: "deflateSync: invalid input", in: ctx)
                return JSValue(undefinedIn: ctx)
            }

            guard let compressed = performDeflate(inputBytes) else {
                ctx.exception = JSValue(newErrorFromMessage: "deflateSync: compression failed", in: ctx)
                return JSValue(undefinedIn: ctx)
            }

            let jsArray = JSValue(newArrayIn: ctx)!
            for (i, byte) in compressed.enumerated() {
                jsArray.setValue(byte, at: i)
            }
            return bufferCtor.invokeMethod("from", withArguments: [jsArray])!
        }
        exports.setValue(unsafeBitCast(deflateSync, to: AnyObject.self), forProperty: "deflateSync")

        // ── Swift-backed inflateSync ──
        let inflateSync: @convention(block) (JSValue) -> JSValue = { bufVal in
            let ctx = JSContext.current()!
            let bufferCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)!

            guard let inputBytes = extractUint8Array(bufVal, in: ctx),
                  !inputBytes.isEmpty else {
                ctx.exception = JSValue(newErrorFromMessage: "inflateSync: invalid input", in: ctx)
                return JSValue(undefinedIn: ctx)
            }

            guard let decompressed = performInflate(inputBytes) else {
                ctx.exception = JSValue(newErrorFromMessage: "inflateSync: decompression failed", in: ctx)
                return JSValue(undefinedIn: ctx)
            }

            let jsArray = JSValue(newArrayIn: ctx)!
            for (i, byte) in decompressed.enumerated() {
                jsArray.setValue(byte, at: i)
            }
            return bufferCtor.invokeMethod("from", withArguments: [jsArray])!
        }
        exports.setValue(unsafeBitCast(inflateSync, to: AnyObject.self), forProperty: "inflateSync")

        // ── Inflate constructor + streaming APIs (JavaScript) ──
        // We install a JS-side Inflate constructor that creates a _handle with a
        // Swift-backed writeSync, plus createDeflate/createInflate that return
        // Transform streams.
        // __zlib_writeSync — per-runtime via storage capture
        let nativeWriteSync: @convention(block) (Int, JSValue, Int, Int) -> JSValue = { streamId, inputVal, outLen, flushFlag in
            let ctx = JSContext.current()!
            let result = JSValue(newObjectIn: ctx)!

            guard let stream = storage.streams[streamId] else {
                result.setValue(true, forProperty: "error")
                result.setValue(JSValue(newArrayIn: ctx), forProperty: "data")
                result.setValue(0, forProperty: "availIn")
                return result
            }

            // Collect input bytes
            let length = inputVal.forProperty("length")?.toInt32() ?? 0
            var inputBytes = [UInt8](repeating: 0, count: Int(length))
            for i in 0..<Int(length) {
                inputBytes[i] = UInt8(inputVal.atIndex(i).toInt32() & 0xFF)
            }

            stream.accumulatedInput.append(contentsOf: inputBytes)

            // If Z_FINISH or we have data, try to decompress
            let isFinish = (flushFlag == 4)

            if isFinish || !stream.accumulatedInput.isEmpty {
                let inputData = Data(stream.accumulatedInput)
                if let decompressed = try? (inputData as NSData).decompressed(using: .zlib) as Data {
                    let outBytes = Array(decompressed)
                    let jsArr = JSValue(newArrayIn: ctx)!
                    for (i, b) in outBytes.enumerated() {
                        jsArr.setValue(b, at: i)
                    }
                    result.setValue(false, forProperty: "error")
                    result.setValue(jsArr, forProperty: "data")
                    result.setValue(0, forProperty: "availIn")

                    stream.accumulatedInput.removeAll()
                } else if isFinish {
                    result.setValue(true, forProperty: "error")
                    result.setValue(JSValue(newArrayIn: ctx), forProperty: "data")
                    result.setValue(0, forProperty: "availIn")
                } else {
                    result.setValue(false, forProperty: "error")
                    result.setValue(JSValue(newArrayIn: ctx), forProperty: "data")
                    result.setValue(0, forProperty: "availIn")
                }
            } else {
                result.setValue(false, forProperty: "error")
                result.setValue(JSValue(newArrayIn: ctx), forProperty: "data")
                result.setValue(0, forProperty: "availIn")
            }

            return result
        }
        context.setObject(unsafeBitCast(nativeWriteSync, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_writeSync" as NSString)

        let nativeDeflateAll = createDeflateAllBlock()
        context.setObject(unsafeBitCast(nativeDeflateAll, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_deflateAll" as NSString)

        let nativeInflateAll = createInflateAllBlock()
        context.setObject(unsafeBitCast(nativeInflateAll, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_inflateAll" as NSString)

        // __zlib_streamInit — per-runtime via storage capture
        let nativeStreamInit: @convention(block) (Bool) -> Int = { isDeflate in
            let id = storage.nextStreamId
            storage.nextStreamId += 1
            storage.streams[id] = InflateStream(isDeflate: isDeflate)
            return id
        }
        context.setObject(unsafeBitCast(nativeStreamInit, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_streamInit" as NSString)

        // __zlib_streamWrite — per-runtime via storage capture
        let nativeStreamWrite: @convention(block) (Int, JSValue) -> Void = { streamId, chunkVal in
            guard let stream = storage.streams[streamId] else {
                return
            }
            let length = chunkVal.forProperty("length")?.toInt32() ?? 0
            for i in 0..<Int(length) {
                let b = UInt8(chunkVal.atIndex(i).toInt32() & 0xFF)
                stream.accumulatedInput.append(b)
            }
        }
        context.setObject(unsafeBitCast(nativeStreamWrite, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_streamWrite" as NSString)

        // __zlib_streamEnd — per-runtime via storage capture
        let nativeStreamEnd: @convention(block) (Int, Bool) -> JSValue = { streamId, isDeflate in
            let ctx = JSContext.current()!
            let bufferCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)!

            guard let stream = storage.streams[streamId] else {
                return JSValue(nullIn: ctx)
            }
            let inputData = Data(stream.accumulatedInput)
            storage.streams.removeValue(forKey: streamId)

            let resultData: Data?
            if isDeflate {
                resultData = try? (inputData as NSData).compressed(using: .zlib) as Data
            } else {
                resultData = try? (inputData as NSData).decompressed(using: .zlib) as Data
            }

            guard let outputBytes = resultData else {
                return JSValue(nullIn: ctx)
            }

            let jsArray = JSValue(newArrayIn: ctx)!
            for (i, byte) in outputBytes.enumerated() {
                jsArray.setValue(byte, at: i)
            }
            return bufferCtor.invokeMethod("from", withArguments: [jsArray])!
        }
        context.setObject(unsafeBitCast(nativeStreamEnd, to: AnyObject.self),
                          forKeyedSubscript: "__zlib_streamEnd" as NSString)

        let script = """
        (function(exports) {
            var EventEmitter = this.__NoCo_EventEmitter;
            var Stream = (typeof require !== 'undefined') ? null : null;
            function getStream() {
                if (!Stream) {
                    try { Stream = require('stream'); } catch(e) {}
                }
                return Stream;
            }

            // zlib.Inflate constructor — compatible with sync-inflate.js
            function Inflate(opts) {
                if (!(this instanceof Inflate)) {
                    return new Inflate(opts);
                }
                // Initialize EventEmitter properties
                this._events = Object.create(null);
                this._maxListeners = 10;
                opts = opts || {};
                var chunkSize = opts.chunkSize || 16384;
                if (chunkSize < 64) chunkSize = 64;
                this._chunkSize = chunkSize;
                this._buffer = Buffer.allocUnsafe(chunkSize);
                this._offset = 0;
                this._level = opts.level !== undefined ? opts.level : -1;
                this._strategy = opts.strategy !== undefined ? opts.strategy : 0;
                this._hadError = false;
                this._writeState = null;
                this._finishFlushFlag = 4; // Z_FINISH
                this._streamId = __zlib_streamInit(false);

                var self = this;
                this._handle = {
                    writeSync: function(flushFlag, chunk, inOff, inLen, outBuf, outOff, outLen) {
                        var inData;
                        if (chunk) {
                            inData = [];
                            for (var i = inOff; i < inOff + inLen; i++) {
                                inData.push(chunk[i] || 0);
                            }
                        } else {
                            inData = [];
                        }
                        var result = __zlib_writeSync(self._streamId, inData, outLen, flushFlag);
                        if (result.error) {
                            self._hadError = true;
                            return [0, outLen];
                        }
                        // Write decompressed bytes into output buffer
                        var outBytes = result.data;
                        var have = outBytes.length;
                        if (have > outLen) have = outLen;
                        for (var i = 0; i < have; i++) {
                            outBuf[outOff + i] = outBytes[i];
                        }
                        var availInAfter = result.availIn;
                        var availOutAfter = outLen - have;
                        return [availInAfter, availOutAfter];
                    },
                    close: function() {},
                    onerror: function() {}
                };
            }
            // Set up prototype chain: Inflate -> EventEmitter
            if (EventEmitter) {
                Inflate.prototype = Object.create(EventEmitter.prototype);
                Inflate.prototype.constructor = Inflate;
            }
            Inflate.prototype.close = function() {
                if (this._handle) this._handle.close();
            };
            exports.Inflate = Inflate;

            // zlib.Deflate constructor
            function Deflate(opts) {
                if (!(this instanceof Deflate)) {
                    return new Deflate(opts);
                }
                opts = opts || {};
                this._chunkSize = opts.chunkSize || 16384;
                this._level = opts.level !== undefined ? opts.level : -1;
                this._strategy = opts.strategy !== undefined ? opts.strategy : 0;
            }
            exports.Deflate = Deflate;

            // createDeflate — returns a Transform stream
            exports.createDeflate = function(opts) {
                opts = opts || {};
                var s = getStream();
                var chunks = [];
                var transform;
                if (s && s.Transform) {
                    transform = new s.Transform();
                } else {
                    // Fallback minimal transform
                    transform = { _events: {}, _chunks: [] };
                    transform.on = function(e, f) { (this._events[e] = this._events[e] || []).push(f); return this; };
                    transform.emit = function(e) {
                        var a = Array.prototype.slice.call(arguments, 1);
                        (this._events[e] || []).forEach(function(f) { f.apply(null, a); });
                    };
                    transform.write = function(chunk) { this._chunks.push(chunk); return true; };
                    transform.end = function() {
                        var input = Buffer.concat(this._chunks);
                        try {
                            var result = exports.deflateSync(input, opts);
                            this.emit('data', result);
                        } catch(e) {
                            this.emit('error', e);
                        }
                        this.emit('end');
                    };
                    transform.once = transform.on;
                    transform.removeListener = function() { return this; };
                    transform.pipe = function(dest) {
                        this.on('data', function(d) { dest.write(d); });
                        this.on('end', function() { dest.end(); });
                        return dest;
                    };
                    return transform;
                }
                transform._chunks = [];
                var origWrite = transform.write;
                transform.write = function(chunk, encoding, cb) {
                    if (typeof encoding === 'function') { cb = encoding; encoding = null; }
                    transform._chunks.push(chunk);
                    if (cb) cb();
                    return true;
                };
                transform.end = function(chunk, encoding, cb) {
                    if (typeof chunk === 'function') { cb = chunk; chunk = null; }
                    if (typeof encoding === 'function') { cb = encoding; encoding = null; }
                    if (chunk) transform._chunks.push(chunk);
                    var input = Buffer.concat(transform._chunks);
                    try {
                        var result = exports.deflateSync(input, opts);
                        transform.push(result);
                    } catch(e) {
                        transform.emit('error', e);
                    }
                    transform._writableState = transform._writableState || {};
                    transform._writableState.ended = true;
                    transform._writableState.finished = true;
                    transform.emit('finish');
                    transform.emit('end');
                    if (cb) cb();
                    return transform;
                };
                return transform;
            };

            // createInflate — returns a Transform stream
            exports.createInflate = function(opts) {
                opts = opts || {};
                var s = getStream();
                var transform;
                if (s && s.Transform) {
                    transform = new s.Transform();
                } else {
                    transform = { _events: {}, _chunks: [] };
                    transform.on = function(e, f) { (this._events[e] = this._events[e] || []).push(f); return this; };
                    transform.emit = function(e) {
                        var a = Array.prototype.slice.call(arguments, 1);
                        (this._events[e] || []).forEach(function(f) { f.apply(null, a); });
                    };
                    transform.write = function(chunk) { this._chunks.push(chunk); return true; };
                    transform.end = function() {
                        var input = Buffer.concat(this._chunks);
                        try {
                            var result = exports.inflateSync(input);
                            this.emit('data', result);
                        } catch(e) {
                            this.emit('error', e);
                        }
                        this.emit('end');
                    };
                    transform.once = transform.on;
                    transform.removeListener = function() { return this; };
                    transform.pipe = function(dest) {
                        this.on('data', function(d) { dest.write(d); });
                        this.on('end', function() { dest.end(); });
                        return dest;
                    };
                    return transform;
                }
                transform._chunks = [];
                var origWrite = transform.write;
                transform.write = function(chunk, encoding, cb) {
                    if (typeof encoding === 'function') { cb = encoding; encoding = null; }
                    transform._chunks.push(chunk);
                    if (cb) cb();
                    return true;
                };
                transform.end = function(chunk, encoding, cb) {
                    if (typeof chunk === 'function') { cb = chunk; chunk = null; }
                    if (typeof encoding === 'function') { cb = encoding; encoding = null; }
                    if (chunk) transform._chunks.push(chunk);
                    var input = Buffer.concat(transform._chunks);
                    try {
                        var result = exports.inflateSync(input);
                        transform.push(result);
                    } catch(e) {
                        transform.emit('error', e);
                    }
                    transform._writableState = transform._writableState || {};
                    transform._writableState.ended = true;
                    transform._writableState.finished = true;
                    transform.emit('finish');
                    transform.emit('end');
                    if (cb) cb();
                    return transform;
                };
                return transform;
            };

            return exports;
        })
        """
        let factory = context.evaluateScript(script)!
        factory.call(withArguments: [exports])

        // Clean up temporary globals
        context.evaluateScript("delete this.__zlib_deflateAll; delete this.__zlib_inflateAll;")

        return exports
    }

    // MARK: - Swift Compression Helpers

    /// Extract bytes from a JSValue representing a Uint8Array.
    private static func extractUint8Array(_ value: JSValue, in context: JSContext) -> [UInt8]? {
        guard let length = value.forProperty("length")?.toInt32(), length > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        for i in 0..<Int(length) {
            bytes[i] = UInt8(value.atIndex(i).toInt32() & 0xFF)
        }
        return bytes
    }

    /// Deflate (compress) data using raw deflate (zlib format).
    private static func performDeflate(_ input: [UInt8]) -> [UInt8]? {
        let data = Data(input)
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        return Array(compressed)
    }

    /// Inflate (decompress) data using raw deflate (zlib format).
    private static func performInflate(_ input: [UInt8]) -> [UInt8]? {
        let data = Data(input)
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return Array(decompressed)
    }

    // MARK: - Stateful Streaming Inflate (for sync-inflate.js _handle.writeSync)

    private class InflateStream {
        var accumulatedInput: [UInt8] = []
        var isDeflate: Bool  // true = deflate, false = inflate
        var consumed: Int = 0

        init(isDeflate: Bool) {
            self.isDeflate = isDeflate
        }
    }

    /// Dummy block for deflateAll
    private static func createDeflateAllBlock() -> @convention(block) (JSValue) -> JSValue {
        return { bufVal in
            let ctx = JSContext.current()!
            let bufferCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)!
            guard let inputBytes = extractUint8Array(bufVal, in: ctx),
                  let compressed = performDeflate(inputBytes) else {
                return JSValue(nullIn: ctx)
            }
            let jsArray = JSValue(newArrayIn: ctx)!
            for (i, byte) in compressed.enumerated() {
                jsArray.setValue(byte, at: i)
            }
            return bufferCtor.invokeMethod("from", withArguments: [jsArray])!
        }
    }

    /// Dummy block for inflateAll
    private static func createInflateAllBlock() -> @convention(block) (JSValue) -> JSValue {
        return { bufVal in
            let ctx = JSContext.current()!
            let bufferCtor = ctx.objectForKeyedSubscript("Buffer" as NSString)!
            guard let inputBytes = extractUint8Array(bufVal, in: ctx),
                  let decompressed = performInflate(inputBytes) else {
                return JSValue(nullIn: ctx)
            }
            let jsArray = JSValue(newArrayIn: ctx)!
            for (i, byte) in decompressed.enumerated() {
                jsArray.setValue(byte, at: i)
            }
            return bufferCtor.invokeMethod("from", withArguments: [jsArray])!
        }
    }
}
