import Foundation
import JavaScriptCore

/// Implements the Node.js `Buffer` class (Uint8Array-based).
public struct BufferModule: NodeModule {
    public static let moduleName = "buffer"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Polyfill TextEncoder/TextDecoder if not available
        context.evaluateScript("""
        if (typeof TextEncoder === 'undefined') {
            var TextEncoder = function() {};
            TextEncoder.prototype.encode = function(str) {
                var bytes = [];
                for (var i = 0; i < str.length; i++) {
                    var c = str.charCodeAt(i);
                    if (c < 0x80) {
                        bytes.push(c);
                    } else if (c < 0x800) {
                        bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
                    } else if (c >= 0xD800 && c < 0xDC00) {
                        var next = str.charCodeAt(++i);
                        var cp = 0x10000 + ((c - 0xD800) << 10) + (next - 0xDC00);
                        bytes.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                                   0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
                    } else {
                        bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
                    }
                }
                return new Uint8Array(bytes);
            };
        }
        if (typeof TextDecoder === 'undefined') {
            var TextDecoder = function(enc) { this.encoding = enc || 'utf-8'; };
            TextDecoder.prototype.decode = function(bytes) {
                if (!bytes || bytes.length === 0) return '';
                var str = '';
                var i = 0;
                while (i < bytes.length) {
                    var b = bytes[i];
                    if (b < 0x80) {
                        str += String.fromCharCode(b); i++;
                    } else if (b < 0xE0) {
                        str += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i+1] & 0x3F)); i += 2;
                    } else if (b < 0xF0) {
                        str += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i+1] & 0x3F) << 6) | (bytes[i+2] & 0x3F)); i += 3;
                    } else {
                        var cp = ((b & 0x07) << 18) | ((bytes[i+1] & 0x3F) << 12) | ((bytes[i+2] & 0x3F) << 6) | (bytes[i+3] & 0x3F);
                        cp -= 0x10000;
                        str += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
                        i += 4;
                    }
                }
                return str;
            };
        }
        if (typeof atob === 'undefined') {
            var _b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            var atob = function(input) {
                input = input.replace(/=+$/, '');
                var output = '';
                for (var i = 0, len = input.length; i < len; ) {
                    var a = _b64chars.indexOf(input.charAt(i++));
                    var b = i < len ? _b64chars.indexOf(input.charAt(i++)) : -1;
                    var c = i < len ? _b64chars.indexOf(input.charAt(i++)) : -1;
                    var d = i < len ? _b64chars.indexOf(input.charAt(i++)) : -1;
                    var bits = (a << 18) | ((b > 0 ? b : 0) << 12) | ((c > 0 ? c : 0) << 6) | (d > 0 ? d : 0);
                    output += String.fromCharCode((bits >> 16) & 0xFF);
                    if (c !== -1) output += String.fromCharCode((bits >> 8) & 0xFF);
                    if (d !== -1) output += String.fromCharCode(bits & 0xFF);
                }
                return output;
            };
            var btoa = function(input) {
                var output = '';
                for (var i = 0; i < input.length; ) {
                    var a = input.charCodeAt(i++);
                    var b = i < input.length ? input.charCodeAt(i++) : NaN;
                    var c = i < input.length ? input.charCodeAt(i++) : NaN;
                    var d1 = a >> 2;
                    var d2 = ((a & 3) << 4) | (b >> 4);
                    var d3 = ((b & 15) << 2) | (c >> 6);
                    var d4 = c & 63;
                    if (isNaN(b)) { d3 = d4 = 64; }
                    else if (isNaN(c)) { d4 = 64; }
                    output += _b64chars.charAt(d1) + _b64chars.charAt(d2) + _b64chars.charAt(d3) + (d4 === 64 ? '=' : _b64chars.charAt(d4));
                }
                return output;
            };
        }
        """)

        let bufferScript = """
        (function(global) {
            function Buffer(sizeOrArray) {
                if (!(this instanceof Buffer)) {
                    return new Buffer(sizeOrArray);
                }
                if (typeof sizeOrArray === 'number') {
                    this._data = new Uint8Array(sizeOrArray);
                } else if (sizeOrArray instanceof Uint8Array) {
                    this._data = new Uint8Array(sizeOrArray);
                } else if (Array.isArray(sizeOrArray)) {
                    this._data = new Uint8Array(sizeOrArray);
                } else {
                    this._data = new Uint8Array(0);
                }
                this.length = this._data.length;
                // Index access
                for (var i = 0; i < this.length; i++) {
                    Object.defineProperty(this, i, {
                        get: (function(idx) { return function() { return this._data[idx]; }; })(i),
                        set: (function(idx) { return function(v) { this._data[idx] = v; }; })(i),
                        enumerable: true,
                        configurable: true
                    });
                }
            }

            Buffer.from = function(value, encodingOrOffset, length) {
                if (typeof value === 'string') {
                    var encoding = encodingOrOffset || 'utf8';
                    return Buffer._fromString(value, encoding);
                }
                if (value instanceof ArrayBuffer) {
                    var offset = encodingOrOffset || 0;
                    var len = length !== undefined ? length : value.byteLength - offset;
                    return new Buffer(new Uint8Array(value, offset, len));
                }
                if (value instanceof Buffer) {
                    return new Buffer(value._data);
                }
                if (Array.isArray(value) || value instanceof Uint8Array) {
                    return new Buffer(value);
                }
                if (value && value.type === 'Buffer' && Array.isArray(value.data)) {
                    return Buffer.from(value.data);
                }
                throw new TypeError('The first argument must be a string, Buffer, ArrayBuffer, Array, or array-like object.');
            };

            Buffer._fromString = function(str, encoding) {
                encoding = encoding.toLowerCase().replace('-', '');
                if (encoding === 'utf8') {
                    var encoder = new TextEncoder();
                    var bytes = encoder.encode(str);
                    return new Buffer(bytes);
                }
                if (encoding === 'hex') {
                    var arr = [];
                    for (var i = 0; i < str.length; i += 2) {
                        arr.push(parseInt(str.substr(i, 2), 16));
                    }
                    return new Buffer(arr);
                }
                if (encoding === 'base64') {
                    var binary = atob(str);
                    var buf = new Buffer(binary.length);
                    for (var i = 0; i < binary.length; i++) {
                        buf._data[i] = binary.charCodeAt(i);
                    }
                    buf.length = binary.length;
                    return buf;
                }
                if (encoding === 'ascii' || encoding === 'latin1' || encoding === 'binary') {
                    var buf = new Buffer(str.length);
                    for (var i = 0; i < str.length; i++) {
                        buf._data[i] = str.charCodeAt(i) & 0xFF;
                    }
                    return buf;
                }
                // default to utf8
                var encoder = new TextEncoder();
                return new Buffer(encoder.encode(str));
            };

            Buffer.alloc = function(size, fill, encoding) {
                var buf = new Buffer(size);
                if (fill !== undefined) {
                    if (typeof fill === 'number') {
                        for (var i = 0; i < size; i++) buf._data[i] = fill & 0xFF;
                    } else if (typeof fill === 'string') {
                        var fillBuf = Buffer.from(fill, encoding || 'utf8');
                        for (var i = 0; i < size; i++) {
                            buf._data[i] = fillBuf._data[i % fillBuf.length];
                        }
                    }
                }
                return buf;
            };

            Buffer.allocUnsafe = function(size) {
                return new Buffer(size);
            };

            Buffer.allocUnsafeSlow = function(size) {
                return new Buffer(size);
            };

            Buffer.concat = function(list, totalLength) {
                if (list.length === 0) return Buffer.alloc(0);
                if (totalLength === undefined) {
                    totalLength = 0;
                    for (var i = 0; i < list.length; i++) totalLength += list[i].length;
                }
                var result = Buffer.alloc(totalLength);
                var offset = 0;
                for (var j = 0; j < list.length; j++) {
                    var buf = list[j];
                    for (var i = 0; i < buf.length && offset < totalLength; i++, offset++) {
                        result._data[offset] = buf._data ? buf._data[i] : buf[i];
                    }
                }
                return result;
            };

            Buffer.isBuffer = function(obj) {
                return obj instanceof Buffer;
            };

            Buffer.isEncoding = function(encoding) {
                return ['utf8', 'utf-8', 'hex', 'base64', 'ascii', 'latin1', 'binary'].indexOf(
                    (encoding || '').toLowerCase()
                ) !== -1;
            };

            Buffer.byteLength = function(string, encoding) {
                if (typeof string !== 'string') return string.length || 0;
                return Buffer.from(string, encoding || 'utf8').length;
            };

            Buffer.prototype.toString = function(encoding, start, end) {
                encoding = (encoding || 'utf8').toLowerCase().replace('-', '');
                start = start || 0;
                end = end !== undefined ? end : this.length;
                var data = this._data.subarray(start, end);

                if (encoding === 'utf8') {
                    var decoder = new TextDecoder('utf-8');
                    return decoder.decode(data);
                }
                if (encoding === 'hex') {
                    var hex = '';
                    for (var i = 0; i < data.length; i++) {
                        hex += (data[i] < 16 ? '0' : '') + data[i].toString(16);
                    }
                    return hex;
                }
                if (encoding === 'base64') {
                    var binary = '';
                    for (var i = 0; i < data.length; i++) {
                        binary += String.fromCharCode(data[i]);
                    }
                    return btoa(binary);
                }
                if (encoding === 'ascii' || encoding === 'latin1' || encoding === 'binary') {
                    var str = '';
                    for (var i = 0; i < data.length; i++) {
                        str += String.fromCharCode(data[i]);
                    }
                    return str;
                }
                // default utf8
                var decoder = new TextDecoder('utf-8');
                return decoder.decode(data);
            };

            Buffer.prototype.toJSON = function() {
                var arr = [];
                for (var i = 0; i < this.length; i++) arr.push(this._data[i]);
                return { type: 'Buffer', data: arr };
            };

            Buffer.prototype.slice = function(start, end) {
                var sliced = this._data.subarray(start, end);
                return new Buffer(sliced);
            };

            Buffer.prototype.subarray = Buffer.prototype.slice;

            Buffer.prototype.reduce = function(callback, initialValue) {
                var acc = arguments.length >= 2 ? initialValue : this._data[0];
                var start = arguments.length >= 2 ? 0 : 1;
                for (var i = start; i < this.length; i++) {
                    acc = callback(acc, this._data[i], i, this);
                }
                return acc;
            };

            Buffer.prototype.copy = function(target, targetStart, sourceStart, sourceEnd) {
                targetStart = targetStart || 0;
                sourceStart = sourceStart || 0;
                sourceEnd = sourceEnd !== undefined ? sourceEnd : this.length;
                var len = Math.min(sourceEnd - sourceStart, target.length - targetStart);
                for (var i = 0; i < len; i++) {
                    target._data[targetStart + i] = this._data[sourceStart + i];
                }
                return len;
            };

            Buffer.prototype.equals = function(other) {
                if (this.length !== other.length) return false;
                for (var i = 0; i < this.length; i++) {
                    if (this._data[i] !== other._data[i]) return false;
                }
                return true;
            };

            Buffer.prototype.compare = function(target, tStart, tEnd, sStart, sEnd) {
                sStart = sStart || 0;
                sEnd = sEnd || this.length;
                tStart = tStart || 0;
                tEnd = tEnd || target.length;
                var len = Math.min(sEnd - sStart, tEnd - tStart);
                for (var i = 0; i < len; i++) {
                    if (this._data[sStart + i] < target._data[tStart + i]) return -1;
                    if (this._data[sStart + i] > target._data[tStart + i]) return 1;
                }
                if ((sEnd - sStart) < (tEnd - tStart)) return -1;
                if ((sEnd - sStart) > (tEnd - tStart)) return 1;
                return 0;
            };

            Buffer.prototype.write = function(string, offset, length, encoding) {
                if (typeof offset === 'string') { encoding = offset; offset = 0; }
                offset = offset || 0;
                encoding = encoding || 'utf8';
                var src = Buffer.from(string, encoding);
                var maxLen = Math.min(src.length, this.length - offset, length || Infinity);
                for (var i = 0; i < maxLen; i++) {
                    this._data[offset + i] = src._data[i];
                }
                return maxLen;
            };

            Buffer.prototype.fill = function(value, offset, end) {
                offset = offset || 0;
                end = end || this.length;
                var fillVal = typeof value === 'number' ? value & 0xFF : 0;
                for (var i = offset; i < end; i++) {
                    this._data[i] = fillVal;
                }
                return this;
            };

            Buffer.prototype.indexOf = function(value, byteOffset) {
                byteOffset = byteOffset || 0;
                if (typeof value === 'number') {
                    for (var i = byteOffset; i < this.length; i++) {
                        if (this._data[i] === value) return i;
                    }
                    return -1;
                }
                if (typeof value === 'string') value = Buffer.from(value);
                for (var i = byteOffset; i <= this.length - value.length; i++) {
                    var found = true;
                    for (var j = 0; j < value.length; j++) {
                        if (this._data[i + j] !== value._data[j]) { found = false; break; }
                    }
                    if (found) return i;
                }
                return -1;
            };

            Buffer.prototype.includes = function(value, byteOffset) {
                return this.indexOf(value, byteOffset) !== -1;
            };

            Buffer.prototype.readUInt8 = function(offset) { return this._data[offset || 0]; };
            Buffer.prototype.readUInt16BE = function(offset) { offset = offset || 0; return (this._data[offset] << 8) | this._data[offset+1]; };
            Buffer.prototype.readUInt16LE = function(offset) { offset = offset || 0; return this._data[offset] | (this._data[offset+1] << 8); };
            Buffer.prototype.readUInt32BE = function(offset) {
                offset = offset || 0;
                return ((this._data[offset] << 24) | (this._data[offset+1] << 16) | (this._data[offset+2] << 8) | this._data[offset+3]) >>> 0;
            };
            Buffer.prototype.readUInt32LE = function(offset) {
                offset = offset || 0;
                return (this._data[offset] | (this._data[offset+1] << 8) | (this._data[offset+2] << 16) | (this._data[offset+3] << 24)) >>> 0;
            };

            Buffer.prototype.writeUInt8 = function(value, offset) { this._data[offset || 0] = value & 0xFF; return (offset || 0) + 1; };
            Buffer.prototype.writeUInt16BE = function(value, offset) {
                offset = offset || 0; this._data[offset] = (value >> 8) & 0xFF; this._data[offset+1] = value & 0xFF; return offset + 2;
            };
            Buffer.prototype.writeUInt16LE = function(value, offset) {
                offset = offset || 0; this._data[offset] = value & 0xFF; this._data[offset+1] = (value >> 8) & 0xFF; return offset + 2;
            };

            Buffer.prototype.writeUInt32BE = function(value, offset) {
                offset = offset || 0;
                this._data[offset]     = (value >>> 24) & 0xFF;
                this._data[offset + 1] = (value >>> 16) & 0xFF;
                this._data[offset + 2] = (value >>> 8)  & 0xFF;
                this._data[offset + 3] = value & 0xFF;
                return offset + 4;
            };
            Buffer.prototype.writeUInt32LE = function(value, offset) {
                offset = offset || 0;
                this._data[offset]     = value & 0xFF;
                this._data[offset + 1] = (value >>> 8)  & 0xFF;
                this._data[offset + 2] = (value >>> 16) & 0xFF;
                this._data[offset + 3] = (value >>> 24) & 0xFF;
                return offset + 4;
            };

            // Signed integer read methods
            Buffer.prototype.readInt8 = function(offset) {
                offset = offset || 0;
                var val = this._data[offset];
                return val >= 0x80 ? val - 0x100 : val;
            };
            Buffer.prototype.readInt16BE = function(offset) {
                offset = offset || 0;
                var val = (this._data[offset] << 8) | this._data[offset+1];
                return val >= 0x8000 ? val - 0x10000 : val;
            };
            Buffer.prototype.readInt16LE = function(offset) {
                offset = offset || 0;
                var val = this._data[offset] | (this._data[offset+1] << 8);
                return val >= 0x8000 ? val - 0x10000 : val;
            };
            Buffer.prototype.readInt32BE = function(offset) {
                offset = offset || 0;
                return (this._data[offset] << 24) | (this._data[offset+1] << 16) | (this._data[offset+2] << 8) | this._data[offset+3];
            };
            Buffer.prototype.readInt32LE = function(offset) {
                offset = offset || 0;
                return this._data[offset] | (this._data[offset+1] << 8) | (this._data[offset+2] << 16) | (this._data[offset+3] << 24);
            };

            // Signed integer write methods
            Buffer.prototype.writeInt8 = function(value, offset) {
                offset = offset || 0;
                this._data[offset] = value < 0 ? value + 0x100 : value;
                return offset + 1;
            };
            Buffer.prototype.writeInt16BE = function(value, offset) {
                offset = offset || 0;
                if (value < 0) value = value + 0x10000;
                this._data[offset] = (value >> 8) & 0xFF;
                this._data[offset+1] = value & 0xFF;
                return offset + 2;
            };
            Buffer.prototype.writeInt16LE = function(value, offset) {
                offset = offset || 0;
                if (value < 0) value = value + 0x10000;
                this._data[offset] = value & 0xFF;
                this._data[offset+1] = (value >> 8) & 0xFF;
                return offset + 2;
            };
            Buffer.prototype.writeInt32BE = function(value, offset) {
                offset = offset || 0;
                this._data[offset]     = (value >>> 24) & 0xFF;
                this._data[offset + 1] = (value >>> 16) & 0xFF;
                this._data[offset + 2] = (value >>> 8)  & 0xFF;
                this._data[offset + 3] = value & 0xFF;
                return offset + 4;
            };
            Buffer.prototype.writeInt32LE = function(value, offset) {
                offset = offset || 0;
                this._data[offset]     = value & 0xFF;
                this._data[offset + 1] = (value >>> 8)  & 0xFF;
                this._data[offset + 2] = (value >>> 16) & 0xFF;
                this._data[offset + 3] = (value >>> 24) & 0xFF;
                return offset + 4;
            };

            // Float read/write methods
            Buffer.prototype.readFloatBE = function(offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(4);
                var view = new DataView(buf);
                for (var i = 0; i < 4; i++) view.setUint8(i, this._data[offset + i]);
                return view.getFloat32(0, false);
            };
            Buffer.prototype.readFloatLE = function(offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(4);
                var view = new DataView(buf);
                for (var i = 0; i < 4; i++) view.setUint8(i, this._data[offset + i]);
                return view.getFloat32(0, true);
            };
            Buffer.prototype.readDoubleBE = function(offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(8);
                var view = new DataView(buf);
                for (var i = 0; i < 8; i++) view.setUint8(i, this._data[offset + i]);
                return view.getFloat64(0, false);
            };
            Buffer.prototype.readDoubleLE = function(offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(8);
                var view = new DataView(buf);
                for (var i = 0; i < 8; i++) view.setUint8(i, this._data[offset + i]);
                return view.getFloat64(0, true);
            };
            Buffer.prototype.writeFloatBE = function(value, offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(4);
                var view = new DataView(buf);
                view.setFloat32(0, value, false);
                for (var i = 0; i < 4; i++) this._data[offset + i] = view.getUint8(i);
                return offset + 4;
            };
            Buffer.prototype.writeFloatLE = function(value, offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(4);
                var view = new DataView(buf);
                view.setFloat32(0, value, true);
                for (var i = 0; i < 4; i++) this._data[offset + i] = view.getUint8(i);
                return offset + 4;
            };
            Buffer.prototype.writeDoubleBE = function(value, offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(8);
                var view = new DataView(buf);
                view.setFloat64(0, value, false);
                for (var i = 0; i < 8; i++) this._data[offset + i] = view.getUint8(i);
                return offset + 8;
            };
            Buffer.prototype.writeDoubleLE = function(value, offset) {
                offset = offset || 0;
                var buf = new ArrayBuffer(8);
                var view = new DataView(buf);
                view.setFloat64(0, value, true);
                for (var i = 0; i < 8; i++) this._data[offset + i] = view.getUint8(i);
                return offset + 8;
            };

            // Patch ArrayBuffer.isView to recognize Buffer instances
            var _origIsView = ArrayBuffer.isView;
            ArrayBuffer.isView = function(obj) {
                return _origIsView(obj) || (obj instanceof Buffer);
            };

            global.Buffer = Buffer;
            return { Buffer: Buffer, SlowBuffer: Buffer, kMaxLength: 0x7fffffff, INSPECT_MAX_BYTES: 50 };
        })(this);
        """

        let exports = context.evaluateScript(bufferScript)!
        return exports
    }
}
