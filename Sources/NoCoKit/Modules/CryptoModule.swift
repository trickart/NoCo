import CryptoKit
import Foundation
import JavaScriptCore

/// Implements the Node.js `crypto` module using Apple CryptoKit.
public struct CryptoModule: NodeModule {
    public static let moduleName = "crypto"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let crypto = JSValue(newObjectIn: context)!

        // crypto.createHash(algorithm)
        let createHash: @convention(block) (String) -> JSValue = { algorithm in
            let ctx = JSContext.current()!
            let hash = JSValue(newObjectIn: ctx)!
            var inputData = Data()
            let algo = algorithm.lowercased()

            let update: @convention(block) (JSValue, JSValue) -> JSValue = { data, encoding in
                if data.isString {
                    let enc = encoding.isUndefined ? "utf8" : encoding.toString()!
                    if enc == "hex" {
                        // Parse hex string
                        let hexStr = data.toString()!
                        var bytes = [UInt8]()
                        var idx = hexStr.startIndex
                        while idx < hexStr.endIndex {
                            let nextIdx = hexStr.index(idx, offsetBy: 2, limitedBy: hexStr.endIndex) ?? hexStr.endIndex
                            if let byte = UInt8(hexStr[idx..<nextIdx], radix: 16) {
                                bytes.append(byte)
                            }
                            idx = nextIdx
                        }
                        inputData.append(contentsOf: bytes)
                    } else {
                        inputData.append(data.toString()!.data(using: .utf8)!)
                    }
                } else {
                    // Buffer/Uint8Array
                    let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<length {
                        inputData.append(UInt8(data.atIndex(i).toInt32()))
                    }
                }
                return hash
            }
            hash.setValue(unsafeBitCast(update, to: AnyObject.self), forProperty: "update")

            let digest: @convention(block) (JSValue) -> JSValue = { encoding in
                let enc = encoding.isUndefined ? "hex" : encoding.toString()!
                let digestData: Data

                switch algo {
                case "sha256", "sha-256":
                    digestData = Data(SHA256.hash(data: inputData))
                case "sha384", "sha-384":
                    digestData = Data(SHA384.hash(data: inputData))
                case "sha512", "sha-512":
                    digestData = Data(SHA512.hash(data: inputData))
                case "md5":
                    digestData = Data(Insecure.MD5.hash(data: inputData))
                case "sha1", "sha-1":
                    digestData = Data(Insecure.SHA1.hash(data: inputData))
                default:
                    JSContext.current()!.exception = JSContext.current()!.createError(
                        "Unsupported hash algorithm: \(algo)", code: "ERR_CRYPTO_HASH_UNKNOWN")
                    return JSValue(undefinedIn: JSContext.current())
                }

                if enc == "hex" {
                    let hex = digestData.map { String(format: "%02x", $0) }.joined()
                    return JSValue(object: hex, in: JSContext.current())
                } else if enc == "base64" {
                    return JSValue(object: digestData.base64EncodedString(), in: JSContext.current())
                } else if enc == "buffer" {
                    let bufferCtor = JSContext.current()!.objectForKeyedSubscript("Buffer")!
                    let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                    let arr = [UInt8](digestData).map { Int($0) }
                    return fromFn.call(withArguments: [arr])
                }
                // Return as hex by default
                let hex = digestData.map { String(format: "%02x", $0) }.joined()
                return JSValue(object: hex, in: JSContext.current())
            }
            hash.setValue(unsafeBitCast(digest, to: AnyObject.self), forProperty: "digest")

            return hash
        }
        crypto.setValue(unsafeBitCast(createHash, to: AnyObject.self), forProperty: "createHash")

        // crypto.createHmac(algorithm, key)
        let createHmac: @convention(block) (String, JSValue) -> JSValue = { algorithm, key in
            let ctx = JSContext.current()!
            let hmac = JSValue(newObjectIn: ctx)!
            var inputData = Data()
            let algo = algorithm.lowercased()

            let keyData: Data
            if key.isString {
                keyData = key.toString()!.data(using: .utf8)!
            } else {
                let length = Int(key.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(key.atIndex(i).toInt32()))
                }
                keyData = Data(bytes)
            }

            let update: @convention(block) (JSValue, JSValue) -> JSValue = { data, encoding in
                if data.isString {
                    inputData.append(data.toString()!.data(using: .utf8)!)
                } else {
                    let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                    for i in 0..<length {
                        inputData.append(UInt8(data.atIndex(i).toInt32()))
                    }
                }
                return hmac
            }
            hmac.setValue(unsafeBitCast(update, to: AnyObject.self), forProperty: "update")

            let digest: @convention(block) (JSValue) -> JSValue = { encoding in
                let enc = encoding.isUndefined ? "hex" : encoding.toString()!
                let symmetricKey = SymmetricKey(data: keyData)
                let digestData: Data

                switch algo {
                case "sha256", "sha-256":
                    var h = HMAC<SHA256>(key: symmetricKey)
                    h.update(data: inputData)
                    digestData = Data(h.finalize())
                case "sha384", "sha-384":
                    var h = HMAC<SHA384>(key: symmetricKey)
                    h.update(data: inputData)
                    digestData = Data(h.finalize())
                case "sha512", "sha-512":
                    var h = HMAC<SHA512>(key: symmetricKey)
                    h.update(data: inputData)
                    digestData = Data(h.finalize())
                case "sha1", "sha-1":
                    var h = HMAC<Insecure.SHA1>(key: symmetricKey)
                    h.update(data: inputData)
                    digestData = Data(h.finalize())
                case "md5":
                    var h = HMAC<Insecure.MD5>(key: symmetricKey)
                    h.update(data: inputData)
                    digestData = Data(h.finalize())
                default:
                    JSContext.current()!.exception = JSContext.current()!.createError(
                        "Unsupported HMAC algorithm: \(algo)", code: "ERR_CRYPTO_HASH_UNKNOWN")
                    return JSValue(undefinedIn: JSContext.current())
                }

                if enc == "hex" {
                    let hex = digestData.map { String(format: "%02x", $0) }.joined()
                    return JSValue(object: hex, in: JSContext.current())
                } else if enc == "base64" {
                    return JSValue(object: digestData.base64EncodedString(), in: JSContext.current())
                }
                let hex = digestData.map { String(format: "%02x", $0) }.joined()
                return JSValue(object: hex, in: JSContext.current())
            }
            hmac.setValue(unsafeBitCast(digest, to: AnyObject.self), forProperty: "digest")

            return hmac
        }
        crypto.setValue(unsafeBitCast(createHmac, to: AnyObject.self), forProperty: "createHmac")

        // crypto.randomBytes(size, callback?)
        let randomBytes: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            let size = args.first?.toInt32() ?? 0
            let callback = args.count > 1 ? args[1] : nil
            let ctx = JSContext.current()!

            var bytes = [UInt8](repeating: 0, count: Int(size))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

            let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
            let buf = fromFn.call(withArguments: [bytes.map { Int($0) }])!

            if let cb = callback, !cb.isUndefined {
                cb.call(withArguments: [JSValue(nullIn: ctx)!, buf])
                return JSValue(undefinedIn: ctx)
            }
            return buf
        }
        crypto.setValue(unsafeBitCast(randomBytes, to: AnyObject.self), forProperty: "randomBytes")

        // crypto.randomUUID()
        let randomUUID: @convention(block) () -> String = {
            UUID().uuidString.lowercased()
        }
        crypto.setValue(unsafeBitCast(randomUUID, to: AnyObject.self), forProperty: "randomUUID")

        return crypto
    }
}
