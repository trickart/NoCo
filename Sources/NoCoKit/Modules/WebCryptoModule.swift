import CryptoKit
import Foundation
import JavaScriptCore

/// Installs `globalThis.crypto` (Web Crypto API) with `crypto.subtle`,
/// `crypto.getRandomValues()`, and `crypto.randomUUID()`.
/// Required by frameworks like Hono for authentication middleware.
public struct WebCryptoModule {
    public static func install(in context: JSContext, runtime: NodeRuntime) {
        installBridgeFunctions(in: context)
        context.evaluateScript(webCryptoScript)
    }

    // MARK: - Swift Bridge Functions

    private static func installBridgeFunctions(in context: JSContext) {
        // __cryptoGetRandomValues(typedArray) -> typedArray
        let getRandomValues: @convention(block) (JSValue) -> JSValue = { typedArray in
            let length = Int(typedArray.forProperty("length")?.toInt32() ?? 0)
            guard length > 0 else { return typedArray }
            var bytes = [UInt8](repeating: 0, count: length)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            for i in 0..<length {
                typedArray.setValue(Int(bytes[i]), at: i)
            }
            return typedArray
        }
        context.setObject(
            unsafeBitCast(getRandomValues, to: AnyObject.self),
            forKeyedSubscript: "__cryptoGetRandomValues" as NSString
        )

        // __cryptoDigest(algorithmName, dataArray) -> [UInt8] array
        let digest: @convention(block) (String, JSValue) -> JSValue = { algorithm, data in
            let ctx = JSContext.current()!
            let inputData = jsValueToData(data)

            let digestData: Data
            switch algorithm.uppercased() {
            case "SHA-256":
                digestData = Data(SHA256.hash(data: inputData))
            case "SHA-384":
                digestData = Data(SHA384.hash(data: inputData))
            case "SHA-512":
                digestData = Data(SHA512.hash(data: inputData))
            case "SHA-1":
                digestData = Data(Insecure.SHA1.hash(data: inputData))
            case "MD5":
                digestData = Data(Insecure.MD5.hash(data: inputData))
            default:
                ctx.exception = ctx.createError(
                    "Unsupported digest algorithm: \(algorithm)",
                    code: "ERR_CRYPTO_HASH_UNKNOWN")
                return JSValue(undefinedIn: ctx)
            }

            let arr = JSValue(newArrayIn: ctx)!
            for (i, byte) in digestData.enumerated() {
                arr.setValue(Int(byte), at: i)
            }
            return arr
        }
        context.setObject(
            unsafeBitCast(digest, to: AnyObject.self),
            forKeyedSubscript: "__cryptoDigest" as NSString
        )

        // __cryptoHmacSign(hashName, keyDataArray, dataArray) -> [UInt8] array
        let hmacSign: @convention(block) (String, JSValue, JSValue) -> JSValue = {
            hashName, keyData, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let inputBytes = jsValueToData(data)
            let symmetricKey = SymmetricKey(data: keyBytes)

            let signature: Data
            switch hashName.uppercased() {
            case "SHA-256":
                var h = HMAC<SHA256>(key: symmetricKey)
                h.update(data: inputBytes)
                signature = Data(h.finalize())
            case "SHA-384":
                var h = HMAC<SHA384>(key: symmetricKey)
                h.update(data: inputBytes)
                signature = Data(h.finalize())
            case "SHA-512":
                var h = HMAC<SHA512>(key: symmetricKey)
                h.update(data: inputBytes)
                signature = Data(h.finalize())
            default:
                ctx.exception = ctx.createError(
                    "Unsupported HMAC hash: \(hashName)",
                    code: "ERR_CRYPTO_HASH_UNKNOWN")
                return JSValue(undefinedIn: ctx)
            }

            let arr = JSValue(newArrayIn: ctx)!
            for (i, byte) in signature.enumerated() {
                arr.setValue(Int(byte), at: i)
            }
            return arr
        }
        context.setObject(
            unsafeBitCast(hmacSign, to: AnyObject.self),
            forKeyedSubscript: "__cryptoHmacSign" as NSString
        )

        // __cryptoHmacVerify(hashName, keyDataArray, signatureArray, dataArray) -> Bool
        let hmacVerify: @convention(block) (String, JSValue, JSValue, JSValue) -> Bool = {
            hashName, keyData, signature, data in
            let keyBytes = jsValueToData(keyData)
            let sigBytes = jsValueToData(signature)
            let inputBytes = jsValueToData(data)
            let symmetricKey = SymmetricKey(data: keyBytes)

            switch hashName.uppercased() {
            case "SHA-256":
                return HMAC<SHA256>.isValidAuthenticationCode(
                    sigBytes, authenticating: inputBytes, using: symmetricKey)
            case "SHA-384":
                return HMAC<SHA384>.isValidAuthenticationCode(
                    sigBytes, authenticating: inputBytes, using: symmetricKey)
            case "SHA-512":
                return HMAC<SHA512>.isValidAuthenticationCode(
                    sigBytes, authenticating: inputBytes, using: symmetricKey)
            default:
                return false
            }
        }
        context.setObject(
            unsafeBitCast(hmacVerify, to: AnyObject.self),
            forKeyedSubscript: "__cryptoHmacVerify" as NSString
        )
    }

    // MARK: - Helpers

    private static func jsValueToData(_ value: JSValue) -> Data {
        let length = Int(value.forProperty("length")?.toInt32() ?? 0)
        var data = Data(capacity: length)
        for i in 0..<length {
            data.append(UInt8(value.atIndex(i).toInt32() & 0xFF))
        }
        return data
    }

    // MARK: - JS Wrapper Script

    private static let webCryptoScript = """
    (function(g) {
        // ============================================================
        // CryptoKey
        // ============================================================
        function CryptoKey(type, extractable, algorithm, usages, keyData) {
            this.type = type;
            this.extractable = extractable;
            this.algorithm = algorithm;
            this.usages = usages;
            this._keyData = keyData;
        }
        g.CryptoKey = CryptoKey;

        // ============================================================
        // Helper: normalize data to Uint8Array
        // ============================================================
        function toUint8Array(data) {
            if (data instanceof Uint8Array) return data;
            if (data instanceof ArrayBuffer) return new Uint8Array(data);
            if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            return new Uint8Array(data);
        }

        // Helper: byte array from bridge result to ArrayBuffer
        function bridgeResultToArrayBuffer(arr) {
            var ab = new ArrayBuffer(arr.length);
            var u8 = new Uint8Array(ab);
            for (var i = 0; i < arr.length; i++) {
                u8[i] = arr[i];
            }
            return ab;
        }

        // Helper: parse algorithm object
        function getAlgoName(algorithm) {
            return typeof algorithm === 'string' ? algorithm : algorithm.name;
        }

        function getHashName(algorithm) {
            if (!algorithm.hash) return 'SHA-256';
            return typeof algorithm.hash === 'string' ? algorithm.hash : algorithm.hash.name;
        }

        // ============================================================
        // SubtleCrypto
        // ============================================================
        function SubtleCrypto() {}

        SubtleCrypto.prototype.digest = function(algorithm, data) {
            try {
                var algoName = getAlgoName(algorithm);
                var bytes = toUint8Array(data);
                var resultArr = __cryptoDigest(algoName, bytes);
                if (resultArr === undefined) return Promise.reject(new Error('Digest failed'));
                return Promise.resolve(bridgeResultToArrayBuffer(resultArr));
            } catch(e) {
                return Promise.reject(e);
            }
        };

        SubtleCrypto.prototype.importKey = function(format, keyData, algorithm, extractable, usages) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var algoName = algoObj.name;

                if (format === 'raw') {
                    var keyBytes = toUint8Array(keyData);
                    // Copy the key data so it's independent of the input buffer
                    var copy = new Uint8Array(keyBytes.length);
                    copy.set(keyBytes);
                    var type = (algoName === 'HMAC') ? 'secret' : 'secret';
                    return Promise.resolve(new CryptoKey(type, extractable, algoObj, usages, copy));
                }

                if (format === 'jwk') {
                    if (algoName === 'HMAC' && keyData.k) {
                        // base64url decode
                        var b64 = keyData.k.replace(/-/g, '+').replace(/_/g, '/');
                        while (b64.length % 4) b64 += '=';
                        var binary = atob(b64);
                        var bytes = new Uint8Array(binary.length);
                        for (var i = 0; i < binary.length; i++) {
                            bytes[i] = binary.charCodeAt(i);
                        }
                        return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, bytes));
                    }
                    return Promise.reject(new Error('JWK import not supported for ' + algoName));
                }

                return Promise.reject(new Error('Unsupported key format: ' + format));
            } catch(e) {
                return Promise.reject(e);
            }
        };

        SubtleCrypto.prototype.sign = function(algorithm, key, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var algoName = algoObj.name;
                var bytes = toUint8Array(data);

                if (algoName === 'HMAC') {
                    var hashName = getHashName(key.algorithm || algoObj);
                    var resultArr = __cryptoHmacSign(hashName, key._keyData, bytes);
                    if (resultArr === undefined) return Promise.reject(new Error('HMAC sign failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(resultArr));
                }

                return Promise.reject(new Error('Unsupported sign algorithm: ' + algoName));
            } catch(e) {
                return Promise.reject(e);
            }
        };

        SubtleCrypto.prototype.verify = function(algorithm, key, signature, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var algoName = algoObj.name;
                var sigBytes = toUint8Array(signature);
                var dataBytes = toUint8Array(data);

                if (algoName === 'HMAC') {
                    var hashName = getHashName(key.algorithm || algoObj);
                    var result = __cryptoHmacVerify(hashName, key._keyData, sigBytes, dataBytes);
                    return Promise.resolve(result);
                }

                return Promise.reject(new Error('Unsupported verify algorithm: ' + algoName));
            } catch(e) {
                return Promise.reject(e);
            }
        };

        SubtleCrypto.prototype.exportKey = function(format, key) {
            try {
                if (!key.extractable) {
                    return Promise.reject(new Error('key is not extractable'));
                }
                if (format === 'raw') {
                    var ab = new ArrayBuffer(key._keyData.length);
                    var u8 = new Uint8Array(ab);
                    u8.set(key._keyData);
                    return Promise.resolve(ab);
                }
                if (format === 'jwk') {
                    if (key.algorithm.name === 'HMAC') {
                        var binary = '';
                        for (var i = 0; i < key._keyData.length; i++) {
                            binary += String.fromCharCode(key._keyData[i]);
                        }
                        var b64 = btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
                        var hashName = getHashName(key.algorithm);
                        var jwk = {
                            kty: 'oct',
                            k: b64,
                            alg: 'HS' + hashName.replace('SHA-', ''),
                            key_ops: key.usages
                        };
                        return Promise.resolve(jwk);
                    }
                    return Promise.reject(new Error('JWK export not supported for ' + key.algorithm.name));
                }
                return Promise.reject(new Error('Unsupported export format: ' + format));
            } catch(e) {
                return Promise.reject(e);
            }
        };

        SubtleCrypto.prototype.generateKey = function() {
            return Promise.reject(new Error('generateKey is not yet supported'));
        };

        SubtleCrypto.prototype.deriveKey = function() {
            return Promise.reject(new Error('deriveKey is not yet supported'));
        };

        SubtleCrypto.prototype.deriveBits = function() {
            return Promise.reject(new Error('deriveBits is not yet supported'));
        };

        SubtleCrypto.prototype.wrapKey = function() {
            return Promise.reject(new Error('wrapKey is not yet supported'));
        };

        SubtleCrypto.prototype.unwrapKey = function() {
            return Promise.reject(new Error('unwrapKey is not yet supported'));
        };

        // ============================================================
        // crypto global object
        // ============================================================
        var cryptoObj = {};
        cryptoObj.subtle = new SubtleCrypto();

        cryptoObj.getRandomValues = function(typedArray) {
            return __cryptoGetRandomValues(typedArray);
        };

        cryptoObj.randomUUID = function() {
            var buf = new Uint8Array(16);
            __cryptoGetRandomValues(buf);
            // Set version (4) and variant (10xx)
            buf[6] = (buf[6] & 0x0f) | 0x40;
            buf[8] = (buf[8] & 0x3f) | 0x80;
            var hex = '';
            for (var i = 0; i < 16; i++) {
                hex += ('00' + buf[i].toString(16)).slice(-2);
            }
            return hex.slice(0,8) + '-' + hex.slice(8,12) + '-' + hex.slice(12,16) + '-' + hex.slice(16,20) + '-' + hex.slice(20);
        };

        g.crypto = cryptoObj;
    })(this);
    """
}
