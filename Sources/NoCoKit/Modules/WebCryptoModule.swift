import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import Security

/// Installs `globalThis.crypto` (Web Crypto API) with full `crypto.subtle` support.
/// Covers HMAC, ECDSA (P-256/P-384/P-521), Ed25519, RSA (PKCS1v1.5/PSS),
/// AES-GCM/CBC, HKDF, PBKDF2, generateKey, wrapKey/unwrapKey.
public struct WebCryptoModule {
    public static func install(in context: JSContext, runtime: NodeRuntime) {
        installBridgeFunctions(in: context)
        context.evaluateScript(webCryptoScript)
    }

    // MARK: - Bridge Installation

    private static func installBridgeFunctions(in context: JSContext) {
        installRandomAndDigest(in: context)
        installHMAC(in: context)
        installECDSA(in: context)
        installEd25519(in: context)
        installRSA(in: context)
        installAES(in: context)
        installGenerateKey(in: context)
        installKeyDerivation(in: context)
    }

    // MARK: - Random & Digest

    private static func installRandomAndDigest(in context: JSContext) {
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
        context.setObject(unsafeBitCast(getRandomValues, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoGetRandomValues" as NSString)

        let digest: @convention(block) (String, JSValue) -> JSValue = { algorithm, data in
            let ctx = JSContext.current()!
            let inputData = jsValueToData(data)
            let digestData: Data
            switch algorithm.uppercased() {
            case "SHA-256": digestData = Data(SHA256.hash(data: inputData))
            case "SHA-384": digestData = Data(SHA384.hash(data: inputData))
            case "SHA-512": digestData = Data(SHA512.hash(data: inputData))
            case "SHA-1": digestData = Data(Insecure.SHA1.hash(data: inputData))
            case "MD5": digestData = Data(Insecure.MD5.hash(data: inputData))
            default:
                ctx.exception = ctx.createError("Unsupported digest algorithm: \(algorithm)",
                                                code: "ERR_CRYPTO_HASH_UNKNOWN")
                return JSValue(undefinedIn: ctx)
            }
            return dataToJSArray(digestData, in: ctx)
        }
        context.setObject(unsafeBitCast(digest, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoDigest" as NSString)
    }

    // MARK: - HMAC

    private static func installHMAC(in context: JSContext) {
        let hmacSign: @convention(block) (String, JSValue, JSValue) -> JSValue = {
            hashName, keyData, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let inputBytes = jsValueToData(data)
            let symmetricKey = SymmetricKey(data: keyBytes)
            let signature: Data
            switch hashName.uppercased() {
            case "SHA-256":
                var h = HMAC<SHA256>(key: symmetricKey); h.update(data: inputBytes); signature = Data(h.finalize())
            case "SHA-384":
                var h = HMAC<SHA384>(key: symmetricKey); h.update(data: inputBytes); signature = Data(h.finalize())
            case "SHA-512":
                var h = HMAC<SHA512>(key: symmetricKey); h.update(data: inputBytes); signature = Data(h.finalize())
            default:
                ctx.exception = ctx.createError("Unsupported HMAC hash: \(hashName)",
                                                code: "ERR_CRYPTO_HASH_UNKNOWN")
                return JSValue(undefinedIn: ctx)
            }
            return dataToJSArray(signature, in: ctx)
        }
        context.setObject(unsafeBitCast(hmacSign, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoHmacSign" as NSString)

        let hmacVerify: @convention(block) (String, JSValue, JSValue, JSValue) -> Bool = {
            hashName, keyData, signature, data in
            let keyBytes = jsValueToData(keyData)
            let sigBytes = jsValueToData(signature)
            let inputBytes = jsValueToData(data)
            let symmetricKey = SymmetricKey(data: keyBytes)
            switch hashName.uppercased() {
            case "SHA-256":
                return HMAC<SHA256>.isValidAuthenticationCode(sigBytes, authenticating: inputBytes, using: symmetricKey)
            case "SHA-384":
                return HMAC<SHA384>.isValidAuthenticationCode(sigBytes, authenticating: inputBytes, using: symmetricKey)
            case "SHA-512":
                return HMAC<SHA512>.isValidAuthenticationCode(sigBytes, authenticating: inputBytes, using: symmetricKey)
            default: return false
            }
        }
        context.setObject(unsafeBitCast(hmacVerify, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoHmacVerify" as NSString)
    }

    // MARK: - ECDSA

    private static func installECDSA(in context: JSContext) {
        // __cryptoEcdsaSign(curve, keyData, data) -> [UInt8]
        let ecdsaSign: @convention(block) (String, JSValue, JSValue) -> JSValue = { curve, keyData, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let inputBytes = jsValueToData(data)
            do {
                let sigData: Data
                switch curve {
                case "P-256":
                    let key = try P256.Signing.PrivateKey(rawRepresentation: keyBytes)
                    sigData = try key.signature(for: inputBytes).rawRepresentation
                case "P-384":
                    let key = try P384.Signing.PrivateKey(rawRepresentation: keyBytes)
                    sigData = try key.signature(for: inputBytes).rawRepresentation
                case "P-521":
                    let key = try P521.Signing.PrivateKey(rawRepresentation: keyBytes)
                    sigData = try key.signature(for: inputBytes).rawRepresentation
                default:
                    ctx.exception = ctx.createError("Unsupported curve: \(curve)")
                    return JSValue(undefinedIn: ctx)
                }
                return dataToJSArray(sigData, in: ctx)
            } catch {
                ctx.exception = ctx.createError("ECDSA sign failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(ecdsaSign, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEcdsaSign" as NSString)

        // __cryptoEcdsaVerify(curve, pubKeyData, sig, data) -> Bool
        let ecdsaVerify: @convention(block) (String, JSValue, JSValue, JSValue) -> Bool = {
            curve, pubKeyData, sig, data in
            let pubBytes = jsValueToData(pubKeyData)
            let sigBytes = jsValueToData(sig)
            let inputBytes = jsValueToData(data)
            do {
                switch curve {
                case "P-256":
                    let pk = try P256.Signing.PublicKey(x963Representation: pubBytes)
                    let s = try P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
                    return pk.isValidSignature(s, for: inputBytes)
                case "P-384":
                    let pk = try P384.Signing.PublicKey(x963Representation: pubBytes)
                    let s = try P384.Signing.ECDSASignature(rawRepresentation: sigBytes)
                    return pk.isValidSignature(s, for: inputBytes)
                case "P-521":
                    let pk = try P521.Signing.PublicKey(x963Representation: pubBytes)
                    let s = try P521.Signing.ECDSASignature(rawRepresentation: sigBytes)
                    return pk.isValidSignature(s, for: inputBytes)
                default: return false
                }
            } catch { return false }
        }
        context.setObject(unsafeBitCast(ecdsaVerify, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEcdsaVerify" as NSString)

        // __cryptoEcImportKey(curve, keyData, format, isPrivate) -> {keyData, publicKeyData}
        let ecImportKey: @convention(block) (String, JSValue, String, Bool) -> JSValue = {
            curve, keyData, format, isPrivate in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let result = JSValue(newObjectIn: ctx)!
            do {
                switch curve {
                case "P-256":
                    if isPrivate {
                        let pk: P256.Signing.PrivateKey
                        switch format {
                        case "pkcs8": pk = try P256.Signing.PrivateKey(derRepresentation: keyBytes)
                        default: pk = try P256.Signing.PrivateKey(rawRepresentation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "keyData")
                        result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKeyData")
                    } else {
                        let pk: P256.Signing.PublicKey
                        switch format {
                        case "spki": pk = try P256.Signing.PublicKey(derRepresentation: keyBytes)
                        default: pk = try P256.Signing.PublicKey(x963Representation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.x963Representation, in: ctx), forProperty: "keyData")
                    }
                case "P-384":
                    if isPrivate {
                        let pk: P384.Signing.PrivateKey
                        switch format {
                        case "pkcs8": pk = try P384.Signing.PrivateKey(derRepresentation: keyBytes)
                        default: pk = try P384.Signing.PrivateKey(rawRepresentation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "keyData")
                        result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKeyData")
                    } else {
                        let pk: P384.Signing.PublicKey
                        switch format {
                        case "spki": pk = try P384.Signing.PublicKey(derRepresentation: keyBytes)
                        default: pk = try P384.Signing.PublicKey(x963Representation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.x963Representation, in: ctx), forProperty: "keyData")
                    }
                case "P-521":
                    if isPrivate {
                        let pk: P521.Signing.PrivateKey
                        switch format {
                        case "pkcs8": pk = try P521.Signing.PrivateKey(derRepresentation: keyBytes)
                        default: pk = try P521.Signing.PrivateKey(rawRepresentation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "keyData")
                        result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKeyData")
                    } else {
                        let pk: P521.Signing.PublicKey
                        switch format {
                        case "spki": pk = try P521.Signing.PublicKey(derRepresentation: keyBytes)
                        default: pk = try P521.Signing.PublicKey(x963Representation: keyBytes)
                        }
                        result.setValue(dataToJSArray(pk.x963Representation, in: ctx), forProperty: "keyData")
                    }
                default:
                    ctx.exception = ctx.createError("Unsupported curve: \(curve)")
                    return JSValue(undefinedIn: ctx)
                }
                return result
            } catch {
                ctx.exception = ctx.createError("EC import failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(ecImportKey, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEcImportKey" as NSString)

        // __cryptoEcExportDer(curve, keyData, isPrivate) -> [UInt8]
        let ecExportDer: @convention(block) (String, JSValue, Bool) -> JSValue = {
            curve, keyData, isPrivate in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            do {
                let derData: Data
                switch curve {
                case "P-256":
                    if isPrivate {
                        derData = try P256.Signing.PrivateKey(rawRepresentation: keyBytes).derRepresentation
                    } else {
                        derData = try P256.Signing.PublicKey(x963Representation: keyBytes).derRepresentation
                    }
                case "P-384":
                    if isPrivate {
                        derData = try P384.Signing.PrivateKey(rawRepresentation: keyBytes).derRepresentation
                    } else {
                        derData = try P384.Signing.PublicKey(x963Representation: keyBytes).derRepresentation
                    }
                case "P-521":
                    if isPrivate {
                        derData = try P521.Signing.PrivateKey(rawRepresentation: keyBytes).derRepresentation
                    } else {
                        derData = try P521.Signing.PublicKey(x963Representation: keyBytes).derRepresentation
                    }
                default:
                    ctx.exception = ctx.createError("Unsupported curve: \(curve)")
                    return JSValue(undefinedIn: ctx)
                }
                return dataToJSArray(derData, in: ctx)
            } catch {
                ctx.exception = ctx.createError("EC DER export failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(ecExportDer, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEcExportDer" as NSString)
    }

    // MARK: - Ed25519

    private static func installEd25519(in context: JSContext) {
        let ed25519Sign: @convention(block) (JSValue, JSValue) -> JSValue = { keyData, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let inputBytes = jsValueToData(data)
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
                let sig = try key.signature(for: inputBytes)
                return dataToJSArray(sig, in: ctx)
            } catch {
                ctx.exception = ctx.createError("Ed25519 sign failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(ed25519Sign, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEd25519Sign" as NSString)

        let ed25519Verify: @convention(block) (JSValue, JSValue, JSValue) -> Bool = {
            pubKeyData, sig, data in
            let pubBytes = jsValueToData(pubKeyData)
            let sigBytes = jsValueToData(sig)
            let inputBytes = jsValueToData(data)
            do {
                let pk = try Curve25519.Signing.PublicKey(rawRepresentation: pubBytes)
                return pk.isValidSignature(sigBytes, for: inputBytes)
            } catch { return false }
        }
        context.setObject(unsafeBitCast(ed25519Verify, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEd25519Verify" as NSString)

        // __cryptoEd25519ImportKey(keyData, format, isPrivate) -> {keyData, publicKeyData}
        let ed25519ImportKey: @convention(block) (JSValue, String, Bool) -> JSValue = {
            keyData, format, isPrivate in
            let ctx = JSContext.current()!
            var keyBytes = jsValueToData(keyData)
            let result = JSValue(newObjectIn: ctx)!
            do {
                if format == "pkcs8" {
                    guard let extracted = extractPrivateKeyFromPKCS8(keyBytes) else {
                        ctx.exception = ctx.createError("Invalid Ed25519 PKCS#8")
                        return JSValue(undefinedIn: ctx)
                    }
                    // Inner OCTET STRING: 04 20 [32 bytes]
                    if extracted.count > 2 && extracted[0] == 0x04 {
                        var off = 1
                        let len = readASN1Length(extracted, offset: &off)
                        keyBytes = Data(extracted[off..<(off + len)])
                    } else {
                        keyBytes = extracted
                    }
                } else if format == "spki" {
                    guard let extracted = extractPublicKeyFromSPKI(keyBytes) else {
                        ctx.exception = ctx.createError("Invalid Ed25519 SPKI")
                        return JSValue(undefinedIn: ctx)
                    }
                    keyBytes = extracted
                }

                if isPrivate {
                    let pk = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
                    result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "keyData")
                    result.setValue(dataToJSArray(pk.publicKey.rawRepresentation, in: ctx), forProperty: "publicKeyData")
                } else {
                    let pk = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
                    result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "keyData")
                }
                return result
            } catch {
                ctx.exception = ctx.createError("Ed25519 import failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(ed25519ImportKey, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoEd25519ImportKey" as NSString)
    }

    // MARK: - RSA

    private static func installRSA(in context: JSContext) {
        // __cryptoRsaSign(algoName, hash, keyData, data) -> [UInt8]
        let rsaSign: @convention(block) (String, String, JSValue, JSValue) -> JSValue = {
            algoName, hash, keyData, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let inputBytes = jsValueToData(data)
            guard let algorithm = secKeyAlgorithm(for: algoName, hash: hash) else {
                ctx.exception = ctx.createError("Unsupported RSA algorithm: \(algoName) + \(hash)")
                return JSValue(undefinedIn: ctx)
            }
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(keyBytes as CFData, attrs as CFDictionary, &error) else {
                ctx.exception = ctx.createError("RSA key creation failed")
                return JSValue(undefinedIn: ctx)
            }
            guard let sigData = SecKeyCreateSignature(secKey, algorithm, inputBytes as CFData, &error) as Data? else {
                ctx.exception = ctx.createError("RSA sign failed")
                return JSValue(undefinedIn: ctx)
            }
            return dataToJSArray(sigData, in: ctx)
        }
        context.setObject(unsafeBitCast(rsaSign, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoRsaSign" as NSString)

        // __cryptoRsaVerify(algoName, hash, pubKeyData, sig, data) -> Bool
        let rsaVerify: @convention(block) (String, String, JSValue, JSValue, JSValue) -> Bool = {
            algoName, hash, pubKeyData, sig, data in
            let pubBytes = jsValueToData(pubKeyData)
            let sigBytes = jsValueToData(sig)
            let inputBytes = jsValueToData(data)
            guard let algorithm = secKeyAlgorithm(for: algoName, hash: hash) else { return false }
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(pubBytes as CFData, attrs as CFDictionary, &error) else {
                return false
            }
            return SecKeyVerifySignature(secKey, algorithm, inputBytes as CFData, sigBytes as CFData, &error)
        }
        context.setObject(unsafeBitCast(rsaVerify, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoRsaVerify" as NSString)

        // __cryptoRsaImportKey(keyData, format, isPrivate) -> {keyData, publicKeyData}
        let rsaImportKey: @convention(block) (JSValue, String, Bool) -> JSValue = {
            keyData, format, isPrivate in
            let ctx = JSContext.current()!
            let result = JSValue(newObjectIn: ctx)!

            let pkcs1Der: Data
            switch format {
            case "pkcs8":
                let bytes = jsValueToData(keyData)
                guard let extracted = extractPrivateKeyFromPKCS8(bytes) else {
                    ctx.exception = ctx.createError("Invalid PKCS#8 data")
                    return JSValue(undefinedIn: ctx)
                }
                pkcs1Der = extracted
            case "spki":
                let bytes = jsValueToData(keyData)
                guard let extracted = extractPublicKeyFromSPKI(bytes) else {
                    ctx.exception = ctx.createError("Invalid SPKI data")
                    return JSValue(undefinedIn: ctx)
                }
                pkcs1Der = extracted
            case "jwk":
                let n = jsValueToData(keyData.forProperty("n")!)
                let e = jsValueToData(keyData.forProperty("e")!)
                if isPrivate {
                    let d = jsValueToData(keyData.forProperty("d")!)
                    let p = jsValueToData(keyData.forProperty("p")!)
                    let q = jsValueToData(keyData.forProperty("q")!)
                    let dp = jsValueToData(keyData.forProperty("dp")!)
                    let dq = jsValueToData(keyData.forProperty("dq")!)
                    let qi = jsValueToData(keyData.forProperty("qi")!)
                    pkcs1Der = buildRSAPrivateKeyDER(n: n, e: e, d: d, p: p, q: q, dp: dp, dq: dq, qi: qi)
                } else {
                    pkcs1Der = buildRSAPublicKeyDER(n: n, e: e)
                }
            default:
                ctx.exception = ctx.createError("Unsupported RSA format: \(format)")
                return JSValue(undefinedIn: ctx)
            }

            let keyClass = isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass,
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(pkcs1Der as CFData, attrs as CFDictionary, &error) else {
                ctx.exception = ctx.createError("RSA key creation failed")
                return JSValue(undefinedIn: ctx)
            }
            guard let exportedData = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
                ctx.exception = ctx.createError("RSA key export failed")
                return JSValue(undefinedIn: ctx)
            }
            result.setValue(dataToJSArray(exportedData, in: ctx), forProperty: "keyData")

            if isPrivate, let publicSecKey = SecKeyCopyPublicKey(secKey),
               let publicData = SecKeyCopyExternalRepresentation(publicSecKey, &error) as Data? {
                result.setValue(dataToJSArray(publicData, in: ctx), forProperty: "publicKeyData")
            }
            return result
        }
        context.setObject(unsafeBitCast(rsaImportKey, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoRsaImportKey" as NSString)

        // __cryptoRsaExportJwk(keyData, isPrivate) -> {n, e, d?, p?, q?, dp?, dq?, qi?}
        let rsaExportJwk: @convention(block) (JSValue, Bool) -> JSValue = { keyData, isPrivate in
            let ctx = JSContext.current()!
            let bytes = jsValueToData(keyData)
            guard let integers = parseDERIntegers(bytes) else {
                ctx.exception = ctx.createError("Invalid RSA key DER")
                return JSValue(undefinedIn: ctx)
            }
            let result = JSValue(newObjectIn: ctx)!
            if isPrivate {
                guard integers.count >= 9 else {
                    ctx.exception = ctx.createError("Invalid RSA private key structure")
                    return JSValue(undefinedIn: ctx)
                }
                result.setValue(dataToJSArray(integers[1], in: ctx), forProperty: "n")
                result.setValue(dataToJSArray(integers[2], in: ctx), forProperty: "e")
                result.setValue(dataToJSArray(integers[3], in: ctx), forProperty: "d")
                result.setValue(dataToJSArray(integers[4], in: ctx), forProperty: "p")
                result.setValue(dataToJSArray(integers[5], in: ctx), forProperty: "q")
                result.setValue(dataToJSArray(integers[6], in: ctx), forProperty: "dp")
                result.setValue(dataToJSArray(integers[7], in: ctx), forProperty: "dq")
                result.setValue(dataToJSArray(integers[8], in: ctx), forProperty: "qi")
            } else {
                guard integers.count >= 2 else {
                    ctx.exception = ctx.createError("Invalid RSA public key structure")
                    return JSValue(undefinedIn: ctx)
                }
                result.setValue(dataToJSArray(integers[0], in: ctx), forProperty: "n")
                result.setValue(dataToJSArray(integers[1], in: ctx), forProperty: "e")
            }
            return result
        }
        context.setObject(unsafeBitCast(rsaExportJwk, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoRsaExportJwk" as NSString)
    }

    // MARK: - AES

    private static func installAES(in context: JSContext) {
        // __cryptoAesGcmEncrypt(keyData, iv, data, aad, tagLength) -> [UInt8]
        let aesGcmEncrypt: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            keyData, iv, data, aad, tagLenVal in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let ivBytes = jsValueToData(iv)
            let plaintext = jsValueToData(data)
            let aadBytes = aad.isNullOrUndefined ? Data() : jsValueToData(aad)
            let tagLen = Int(tagLenVal.toInt32())
            do {
                let key = SymmetricKey(data: keyBytes)
                let nonce = try AES.GCM.Nonce(data: ivBytes)
                let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aadBytes)
                var result = Data(sealedBox.ciphertext)
                let tag = Data(sealedBox.tag)
                // Truncate tag if tagLength < 128
                let tagSize = tagLen / 8
                result.append(tag.prefix(tagSize))
                return dataToJSArray(result, in: ctx)
            } catch {
                ctx.exception = ctx.createError("AES-GCM encrypt failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(aesGcmEncrypt, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoAesGcmEncrypt" as NSString)

        // __cryptoAesGcmDecrypt(keyData, iv, data, aad, tagLength) -> [UInt8]
        let aesGcmDecrypt: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            keyData, iv, data, aad, tagLenVal in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let ivBytes = jsValueToData(iv)
            let combined = jsValueToData(data)
            let aadBytes = aad.isNullOrUndefined ? Data() : jsValueToData(aad)
            let tagSize = Int(tagLenVal.toInt32()) / 8
            guard combined.count >= tagSize else {
                ctx.exception = ctx.createError("AES-GCM decrypt: ciphertext too short")
                return JSValue(undefinedIn: ctx)
            }
            let ciphertext = combined.prefix(combined.count - tagSize)
            var tag = Data(combined.suffix(tagSize))
            // Pad tag to 16 bytes if truncated (CryptoKit requires 12-16 bytes)
            while tag.count < 16 { tag.append(0) }
            do {
                let key = SymmetricKey(data: keyBytes)
                let nonce = try AES.GCM.Nonce(data: ivBytes)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: aadBytes)
                return dataToJSArray(plaintext, in: ctx)
            } catch {
                ctx.exception = ctx.createError("AES-GCM decrypt failed: \(error)")
                return JSValue(undefinedIn: ctx)
            }
        }
        context.setObject(unsafeBitCast(aesGcmDecrypt, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoAesGcmDecrypt" as NSString)

        // __cryptoAesCbcEncrypt(keyData, iv, data) -> [UInt8]
        let aesCbcEncrypt: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = {
            keyData, iv, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let ivBytes = jsValueToData(iv)
            let plaintext = jsValueToData(data)
            let bufSize = plaintext.count + kCCBlockSizeAES128
            var outBuf = Data(count: bufSize)
            var outLen: size_t = 0
            let status = outBuf.withUnsafeMutableBytes { outPtr in
                plaintext.withUnsafeBytes { plainPtr in
                    keyBytes.withUnsafeBytes { keyPtr in
                        ivBytes.withUnsafeBytes { ivPtr in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(kCCOptionPKCS7Padding),
                                    keyPtr.baseAddress, keyBytes.count, ivPtr.baseAddress,
                                    plainPtr.baseAddress, plaintext.count,
                                    outPtr.baseAddress, bufSize, &outLen)
                        }
                    }
                }
            }
            guard status == kCCSuccess else {
                ctx.exception = ctx.createError("AES-CBC encrypt failed: \(status)")
                return JSValue(undefinedIn: ctx)
            }
            outBuf.count = outLen
            return dataToJSArray(outBuf, in: ctx)
        }
        context.setObject(unsafeBitCast(aesCbcEncrypt, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoAesCbcEncrypt" as NSString)

        // __cryptoAesCbcDecrypt(keyData, iv, data) -> [UInt8]
        let aesCbcDecrypt: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = {
            keyData, iv, data in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let ivBytes = jsValueToData(iv)
            let ciphertext = jsValueToData(data)
            let bufSize = ciphertext.count + kCCBlockSizeAES128
            var outBuf = Data(count: bufSize)
            var outLen: size_t = 0
            let status = outBuf.withUnsafeMutableBytes { outPtr in
                ciphertext.withUnsafeBytes { cipherPtr in
                    keyBytes.withUnsafeBytes { keyPtr in
                        ivBytes.withUnsafeBytes { ivPtr in
                            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(kCCOptionPKCS7Padding),
                                    keyPtr.baseAddress, keyBytes.count, ivPtr.baseAddress,
                                    cipherPtr.baseAddress, ciphertext.count,
                                    outPtr.baseAddress, bufSize, &outLen)
                        }
                    }
                }
            }
            guard status == kCCSuccess else {
                ctx.exception = ctx.createError("AES-CBC decrypt failed: \(status)")
                return JSValue(undefinedIn: ctx)
            }
            outBuf.count = outLen
            return dataToJSArray(outBuf, in: ctx)
        }
        context.setObject(unsafeBitCast(aesCbcDecrypt, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoAesCbcDecrypt" as NSString)
    }

    // MARK: - Key Generation

    private static func installGenerateKey(in context: JSContext) {
        let generateKey: @convention(block) (String, JSValue) -> JSValue = { algoName, params in
            let ctx = JSContext.current()!
            let result = JSValue(newObjectIn: ctx)!
            let upper = algoName.uppercased()

            if upper == "HMAC" {
                let hashName = params.forProperty("hash")?.toString() ?? "SHA-256"
                var keyLen: Int
                if let lv = params.forProperty("length"), !lv.isUndefined {
                    keyLen = Int(lv.toInt32()) / 8
                } else {
                    keyLen = hashName.uppercased().contains("384") ? 48 : (hashName.uppercased().contains("512") ? 64 : 32)
                }
                var bytes = [UInt8](repeating: 0, count: keyLen)
                _ = SecRandomCopyBytes(kSecRandomDefault, keyLen, &bytes)
                result.setValue("symmetric", forProperty: "type")
                result.setValue(dataToJSArray(Data(bytes), in: ctx), forProperty: "secretKey")
                return result
            }

            if upper.hasPrefix("AES") {
                let length = Int(params.forProperty("length")?.toInt32() ?? 256) / 8
                var bytes = [UInt8](repeating: 0, count: length)
                _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
                result.setValue("symmetric", forProperty: "type")
                result.setValue(dataToJSArray(Data(bytes), in: ctx), forProperty: "secretKey")
                return result
            }

            if upper == "ECDSA" || upper == "ECDH" {
                let curve = params.forProperty("namedCurve")?.toString() ?? "P-256"
                result.setValue("asymmetric", forProperty: "type")
                switch curve {
                case "P-256":
                    let pk = P256.Signing.PrivateKey()
                    result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "privateKey")
                    result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKey")
                case "P-384":
                    let pk = P384.Signing.PrivateKey()
                    result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "privateKey")
                    result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKey")
                case "P-521":
                    let pk = P521.Signing.PrivateKey()
                    result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "privateKey")
                    result.setValue(dataToJSArray(pk.publicKey.x963Representation, in: ctx), forProperty: "publicKey")
                default:
                    ctx.exception = ctx.createError("Unsupported curve: \(curve)")
                    return JSValue(undefinedIn: ctx)
                }
                return result
            }

            if upper == "ED25519" {
                let pk = Curve25519.Signing.PrivateKey()
                result.setValue("asymmetric", forProperty: "type")
                result.setValue(dataToJSArray(pk.rawRepresentation, in: ctx), forProperty: "privateKey")
                result.setValue(dataToJSArray(pk.publicKey.rawRepresentation, in: ctx), forProperty: "publicKey")
                return result
            }

            if upper.hasPrefix("RSA") {
                let modLen = Int(params.forProperty("modulusLength")?.toInt32() ?? 2048)
                let attrs: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeySizeInBits as String: modLen,
                ]
                var error: Unmanaged<CFError>?
                guard let privKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
                      let pubKey = SecKeyCopyPublicKey(privKey),
                      let privData = SecKeyCopyExternalRepresentation(privKey, &error) as Data?,
                      let pubData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
                    ctx.exception = ctx.createError("RSA key generation failed")
                    return JSValue(undefinedIn: ctx)
                }
                result.setValue("asymmetric", forProperty: "type")
                result.setValue(dataToJSArray(privData, in: ctx), forProperty: "privateKey")
                result.setValue(dataToJSArray(pubData, in: ctx), forProperty: "publicKey")
                return result
            }

            ctx.exception = ctx.createError("Unsupported generateKey algorithm: \(algoName)")
            return JSValue(undefinedIn: ctx)
        }
        context.setObject(unsafeBitCast(generateKey, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoGenerateKey" as NSString)
    }

    // MARK: - Key Derivation

    private static func installKeyDerivation(in context: JSContext) {
        // __cryptoHkdfDeriveBits(hash, keyData, salt, info, length) -> [UInt8]
        let hkdfDerive: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            hash, keyData, salt, info, length in
            let ctx = JSContext.current()!
            let keyBytes = jsValueToData(keyData)
            let saltBytes = jsValueToData(salt)
            let infoBytes = jsValueToData(info)
            let outLen = Int(length.toInt32())
            let ikm = SymmetricKey(data: keyBytes)
            let derived: SymmetricKey
            switch hash.uppercased() {
            case "SHA-256":
                derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: saltBytes,
                                                 info: infoBytes, outputByteCount: outLen)
            case "SHA-384":
                derived = HKDF<SHA384>.deriveKey(inputKeyMaterial: ikm, salt: saltBytes,
                                                 info: infoBytes, outputByteCount: outLen)
            case "SHA-512":
                derived = HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: saltBytes,
                                                 info: infoBytes, outputByteCount: outLen)
            default:
                ctx.exception = ctx.createError("Unsupported HKDF hash: \(hash)")
                return JSValue(undefinedIn: ctx)
            }
            let data = derived.withUnsafeBytes { Data($0) }
            return dataToJSArray(data, in: ctx)
        }
        context.setObject(unsafeBitCast(hkdfDerive, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoHkdfDeriveBits" as NSString)

        // __cryptoPbkdf2DeriveBits(hash, password, salt, iterations, length) -> [UInt8]
        let pbkdf2Derive: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
            hash, password, salt, iterations, length in
            let ctx = JSContext.current()!
            let passBytes = jsValueToData(password)
            let saltBytes = jsValueToData(salt)
            let iterCount = UInt32(iterations.toInt32())
            let outLen = Int(length.toInt32())
            let prf: CCPseudoRandomAlgorithm
            switch hash.uppercased() {
            case "SHA-1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case "SHA-256": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case "SHA-384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case "SHA-512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            default:
                ctx.exception = ctx.createError("Unsupported PBKDF2 hash: \(hash)")
                return JSValue(undefinedIn: ctx)
            }
            var derived = Data(count: outLen)
            let status = derived.withUnsafeMutableBytes { derivedPtr in
                passBytes.withUnsafeBytes { passPtr in
                    saltBytes.withUnsafeBytes { saltPtr in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passPtr.baseAddress?.assumingMemoryBound(to: Int8.self), passBytes.count,
                            saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                            prf, iterCount,
                            derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), outLen)
                    }
                }
            }
            guard status == kCCSuccess else {
                ctx.exception = ctx.createError("PBKDF2 failed: \(status)")
                return JSValue(undefinedIn: ctx)
            }
            return dataToJSArray(derived, in: ctx)
        }
        context.setObject(unsafeBitCast(pbkdf2Derive, to: AnyObject.self),
                          forKeyedSubscript: "__cryptoPbkdf2DeriveBits" as NSString)
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

    private static func dataToJSArray(_ data: Data, in context: JSContext) -> JSValue {
        let arr = JSValue(newArrayIn: context)!
        for (i, byte) in data.enumerated() {
            arr.setValue(Int(byte), at: i)
        }
        return arr
    }

    private static func secKeyAlgorithm(for algoName: String, hash: String) -> SecKeyAlgorithm? {
        let upper = algoName.uppercased()
        let h = hash.uppercased()
        if upper.contains("PKCS1") {
            switch h {
            case "SHA-1": return .rsaSignatureMessagePKCS1v15SHA1
            case "SHA-256": return .rsaSignatureMessagePKCS1v15SHA256
            case "SHA-384": return .rsaSignatureMessagePKCS1v15SHA384
            case "SHA-512": return .rsaSignatureMessagePKCS1v15SHA512
            default: return nil
            }
        } else if upper.contains("PSS") {
            switch h {
            case "SHA-1": return .rsaSignatureMessagePSSSHA1
            case "SHA-256": return .rsaSignatureMessagePSSSHA256
            case "SHA-384": return .rsaSignatureMessagePSSSHA384
            case "SHA-512": return .rsaSignatureMessagePSSSHA512
            default: return nil
            }
        }
        return nil
    }

    // MARK: - ASN.1 / DER Helpers

    private static func readASN1Length(_ data: Data, offset: inout Int) -> Int {
        guard offset < data.count else { return 0 }
        let first = data[offset]
        offset += 1
        if first < 0x80 { return Int(first) }
        let numBytes = Int(first & 0x7F)
        guard numBytes <= 4, offset + numBytes <= data.count else { return 0 }
        var length = 0
        for _ in 0..<numBytes {
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }

    private static func extractPrivateKeyFromPKCS8(_ data: Data) -> Data? {
        var offset = 0
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        _ = readASN1Length(data, offset: &offset)
        // Version INTEGER
        guard offset < data.count, data[offset] == 0x02 else { return nil }
        offset += 1
        let vLen = readASN1Length(data, offset: &offset)
        offset += vLen
        // AlgorithmIdentifier SEQUENCE
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        let algoLen = readASN1Length(data, offset: &offset)
        offset += algoLen
        // OCTET STRING
        guard offset < data.count, data[offset] == 0x04 else { return nil }
        offset += 1
        let octetLen = readASN1Length(data, offset: &offset)
        guard offset + octetLen <= data.count else { return nil }
        return Data(data[offset..<(offset + octetLen)])
    }

    private static func extractPublicKeyFromSPKI(_ data: Data) -> Data? {
        var offset = 0
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        _ = readASN1Length(data, offset: &offset)
        // AlgorithmIdentifier SEQUENCE
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        let algoLen = readASN1Length(data, offset: &offset)
        offset += algoLen
        // BIT STRING
        guard offset < data.count, data[offset] == 0x03 else { return nil }
        offset += 1
        let bitLen = readASN1Length(data, offset: &offset)
        guard bitLen > 1, offset < data.count else { return nil }
        offset += 1  // skip unused bits byte (0x00)
        let keyLen = bitLen - 1
        guard offset + keyLen <= data.count else { return nil }
        return Data(data[offset..<(offset + keyLen)])
    }

    private static func encodeDERLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        if length < 0x100 { return Data([0x81, UInt8(length)]) }
        return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
    }

    private static func encodeDERInteger(_ data: Data) -> Data {
        var bytes = Array(data)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if !bytes.isEmpty && bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        if bytes.isEmpty { bytes = [0] }
        var result = Data([0x02])
        result.append(encodeDERLength(bytes.count))
        result.append(contentsOf: bytes)
        return result
    }

    private static func encodeDERSequence(_ contents: Data) -> Data {
        var result = Data([0x30])
        result.append(encodeDERLength(contents.count))
        result.append(contents)
        return result
    }

    private static func buildRSAPublicKeyDER(n: Data, e: Data) -> Data {
        var content = Data()
        content.append(encodeDERInteger(n))
        content.append(encodeDERInteger(e))
        return encodeDERSequence(content)
    }

    private static func buildRSAPrivateKeyDER(n: Data, e: Data, d: Data, p: Data, q: Data,
                                               dp: Data, dq: Data, qi: Data) -> Data {
        var content = Data()
        content.append(encodeDERInteger(Data([0])))  // version
        content.append(encodeDERInteger(n))
        content.append(encodeDERInteger(e))
        content.append(encodeDERInteger(d))
        content.append(encodeDERInteger(p))
        content.append(encodeDERInteger(q))
        content.append(encodeDERInteger(dp))
        content.append(encodeDERInteger(dq))
        content.append(encodeDERInteger(qi))
        return encodeDERSequence(content)
    }

    private static func parseDERIntegers(_ data: Data) -> [Data]? {
        var offset = 0
        guard offset < data.count, data[offset] == 0x30 else { return nil }
        offset += 1
        _ = readASN1Length(data, offset: &offset)
        var integers: [Data] = []
        while offset < data.count {
            guard data[offset] == 0x02 else { break }
            offset += 1
            let intLen = readASN1Length(data, offset: &offset)
            guard offset + intLen <= data.count else { return nil }
            integers.append(Data(data[offset..<(offset + intLen)]))
            offset += intLen
        }
        return integers
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
            this._publicKeyData = null;
        }
        g.CryptoKey = CryptoKey;

        // ============================================================
        // Helpers
        // ============================================================
        function toUint8Array(data) {
            if (data instanceof Uint8Array) return data;
            if (data instanceof ArrayBuffer) return new Uint8Array(data);
            if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            return new Uint8Array(data);
        }
        function bridgeResultToArrayBuffer(arr) {
            var ab = new ArrayBuffer(arr.length);
            var u8 = new Uint8Array(ab);
            for (var i = 0; i < arr.length; i++) u8[i] = arr[i];
            return ab;
        }
        function toU8(arr) {
            var u8 = new Uint8Array(arr.length);
            for (var i = 0; i < arr.length; i++) u8[i] = arr[i];
            return u8;
        }
        function getAlgoName(algorithm) {
            return typeof algorithm === 'string' ? algorithm : algorithm.name;
        }
        function getHashName(algorithm) {
            if (!algorithm.hash) return 'SHA-256';
            return typeof algorithm.hash === 'string' ? algorithm.hash : algorithm.hash.name;
        }
        function base64urlDecode(str) {
            var b64 = str.replace(/-/g, '+').replace(/_/g, '/');
            while (b64.length % 4) b64 += '=';
            var binary = atob(b64);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return bytes;
        }
        function base64urlEncode(bytes) {
            var binary = '';
            for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
            return btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
        }
        function stripLeadingZero(arr) {
            if (arr.length > 1 && arr[0] === 0) return arr.slice(1);
            return arr;
        }

        // ============================================================
        // SubtleCrypto
        // ============================================================
        function SubtleCrypto() {}

        // ---- digest ----
        SubtleCrypto.prototype.digest = function(algorithm, data) {
            try {
                var algoName = getAlgoName(algorithm);
                var bytes = toUint8Array(data);
                var r = __cryptoDigest(algoName, bytes);
                if (r === undefined) return Promise.reject(new Error('Digest failed'));
                return Promise.resolve(bridgeResultToArrayBuffer(r));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- importKey ----
        SubtleCrypto.prototype.importKey = function(format, keyData, algorithm, extractable, usages) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var algoName = algoObj.name;
                var upper = algoName.toUpperCase();

                // HMAC
                if (upper === 'HMAC') {
                    if (format === 'raw') {
                        var kb = toUint8Array(keyData); var cp = new Uint8Array(kb.length); cp.set(kb);
                        return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, cp));
                    }
                    if (format === 'jwk' && keyData.k) {
                        var bytes = base64urlDecode(keyData.k);
                        return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, bytes));
                    }
                    return Promise.reject(new Error('Unsupported format for HMAC: ' + format));
                }

                // ECDSA / ECDH
                if (upper === 'ECDSA' || upper === 'ECDH') {
                    var crv = algoObj.namedCurve;
                    if (format === 'jwk') {
                        var isPriv = !!keyData.d;
                        if (isPriv) {
                            var d = base64urlDecode(keyData.d);
                            var imp = __cryptoEcImportKey(crv, d, 'raw', true);
                            if (!imp) return Promise.reject(new Error('EC private key import failed'));
                            var k = new CryptoKey('private', extractable, algoObj, usages, toU8(imp.keyData));
                            k._publicKeyData = toU8(imp.publicKeyData);
                            return Promise.resolve(k);
                        } else {
                            var x = base64urlDecode(keyData.x);
                            var y = base64urlDecode(keyData.y);
                            var pub = new Uint8Array(1 + x.length + y.length);
                            pub[0] = 0x04; pub.set(x, 1); pub.set(y, 1 + x.length);
                            var imp = __cryptoEcImportKey(crv, pub, 'raw', false);
                            if (!imp) return Promise.reject(new Error('EC public key import failed'));
                            return Promise.resolve(new CryptoKey('public', extractable, algoObj, usages, toU8(imp.keyData)));
                        }
                    }
                    if (format === 'raw') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEcImportKey(crv, b, 'raw', false);
                        if (!imp) return Promise.reject(new Error('EC import failed'));
                        return Promise.resolve(new CryptoKey('public', extractable, algoObj, usages, toU8(imp.keyData)));
                    }
                    if (format === 'pkcs8') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEcImportKey(crv, b, 'pkcs8', true);
                        if (!imp) return Promise.reject(new Error('EC PKCS#8 import failed'));
                        var k = new CryptoKey('private', extractable, algoObj, usages, toU8(imp.keyData));
                        k._publicKeyData = toU8(imp.publicKeyData);
                        return Promise.resolve(k);
                    }
                    if (format === 'spki') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEcImportKey(crv, b, 'spki', false);
                        if (!imp) return Promise.reject(new Error('EC SPKI import failed'));
                        return Promise.resolve(new CryptoKey('public', extractable, algoObj, usages, toU8(imp.keyData)));
                    }
                    return Promise.reject(new Error('Unsupported format for EC: ' + format));
                }

                // Ed25519
                if (upper === 'ED25519') {
                    if (format === 'jwk') {
                        if (keyData.d) {
                            var d = base64urlDecode(keyData.d);
                            var imp = __cryptoEd25519ImportKey(d, 'raw', true);
                            if (!imp) return Promise.reject(new Error('Ed25519 import failed'));
                            var k = new CryptoKey('private', extractable, {name:'Ed25519'}, usages, toU8(imp.keyData));
                            k._publicKeyData = toU8(imp.publicKeyData);
                            return Promise.resolve(k);
                        } else {
                            var x = base64urlDecode(keyData.x);
                            var imp = __cryptoEd25519ImportKey(x, 'raw', false);
                            if (!imp) return Promise.reject(new Error('Ed25519 import failed'));
                            return Promise.resolve(new CryptoKey('public', extractable, {name:'Ed25519'}, usages, toU8(imp.keyData)));
                        }
                    }
                    if (format === 'raw') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEd25519ImportKey(b, 'raw', false);
                        if (!imp) return Promise.reject(new Error('Ed25519 import failed'));
                        return Promise.resolve(new CryptoKey('public', extractable, {name:'Ed25519'}, usages, toU8(imp.keyData)));
                    }
                    if (format === 'pkcs8') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEd25519ImportKey(b, 'pkcs8', true);
                        if (!imp) return Promise.reject(new Error('Ed25519 PKCS#8 import failed'));
                        var k = new CryptoKey('private', extractable, {name:'Ed25519'}, usages, toU8(imp.keyData));
                        k._publicKeyData = toU8(imp.publicKeyData);
                        return Promise.resolve(k);
                    }
                    if (format === 'spki') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoEd25519ImportKey(b, 'spki', false);
                        if (!imp) return Promise.reject(new Error('Ed25519 SPKI import failed'));
                        return Promise.resolve(new CryptoKey('public', extractable, {name:'Ed25519'}, usages, toU8(imp.keyData)));
                    }
                    return Promise.reject(new Error('Unsupported format for Ed25519: ' + format));
                }

                // RSA
                if (upper === 'RSASSA-PKCS1-V1_5' || upper === 'RSA-PSS' || upper === 'RSA-OAEP') {
                    if (format === 'jwk') {
                        var isPriv = !!keyData.d;
                        var comp = {};
                        comp.n = base64urlDecode(keyData.n);
                        comp.e = base64urlDecode(keyData.e);
                        if (isPriv) {
                            comp.d = base64urlDecode(keyData.d);
                            comp.p = base64urlDecode(keyData.p);
                            comp.q = base64urlDecode(keyData.q);
                            comp.dp = base64urlDecode(keyData.dp);
                            comp.dq = base64urlDecode(keyData.dq);
                            comp.qi = base64urlDecode(keyData.qi);
                        }
                        var imp = __cryptoRsaImportKey(comp, 'jwk', isPriv);
                        if (!imp) return Promise.reject(new Error('RSA JWK import failed'));
                        var k = new CryptoKey(isPriv ? 'private' : 'public', extractable, algoObj, usages, toU8(imp.keyData));
                        if (isPriv && imp.publicKeyData) k._publicKeyData = toU8(imp.publicKeyData);
                        return Promise.resolve(k);
                    }
                    if (format === 'pkcs8') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoRsaImportKey(b, 'pkcs8', true);
                        if (!imp) return Promise.reject(new Error('RSA PKCS#8 import failed'));
                        var k = new CryptoKey('private', extractable, algoObj, usages, toU8(imp.keyData));
                        if (imp.publicKeyData) k._publicKeyData = toU8(imp.publicKeyData);
                        return Promise.resolve(k);
                    }
                    if (format === 'spki') {
                        var b = toUint8Array(keyData);
                        var imp = __cryptoRsaImportKey(b, 'spki', false);
                        if (!imp) return Promise.reject(new Error('RSA SPKI import failed'));
                        return Promise.resolve(new CryptoKey('public', extractable, algoObj, usages, toU8(imp.keyData)));
                    }
                    return Promise.reject(new Error('Unsupported format for RSA: ' + format));
                }

                // AES
                if (upper.indexOf('AES') === 0) {
                    if (format === 'raw') {
                        var kb = toUint8Array(keyData); var cp = new Uint8Array(kb.length); cp.set(kb);
                        return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, cp));
                    }
                    if (format === 'jwk' && keyData.k) {
                        return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, base64urlDecode(keyData.k)));
                    }
                    return Promise.reject(new Error('Unsupported format for AES: ' + format));
                }

                // HKDF / PBKDF2
                if (upper === 'HKDF' || upper === 'PBKDF2') {
                    if (format === 'raw') {
                        var kb = toUint8Array(keyData); var cp = new Uint8Array(kb.length); cp.set(kb);
                        return Promise.resolve(new CryptoKey('secret', false, algoObj, usages, cp));
                    }
                    return Promise.reject(new Error('Unsupported format for ' + algoName + ': ' + format));
                }

                return Promise.reject(new Error('Unsupported algorithm: ' + algoName));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- exportKey ----
        SubtleCrypto.prototype.exportKey = function(format, key) {
            try {
                if (!key.extractable) return Promise.reject(new Error('key is not extractable'));
                var algoName = key.algorithm.name;
                var upper = algoName.toUpperCase();

                if (format === 'raw') {
                    if (key.type === 'private') return Promise.reject(new Error('Cannot export private key as raw'));
                    var ab = new ArrayBuffer(key._keyData.length);
                    new Uint8Array(ab).set(key._keyData);
                    return Promise.resolve(ab);
                }

                if (format === 'jwk') {
                    // HMAC
                    if (upper === 'HMAC') {
                        var hashName = getHashName(key.algorithm);
                        return Promise.resolve({
                            kty: 'oct', k: base64urlEncode(key._keyData),
                            alg: 'HS' + hashName.replace('SHA-', ''),
                            key_ops: key.usages, ext: key.extractable
                        });
                    }
                    // ECDSA / ECDH
                    if (upper === 'ECDSA' || upper === 'ECDH') {
                        var crv = key.algorithm.namedCurve;
                        var cs = crv === 'P-256' ? 32 : (crv === 'P-384' ? 48 : 66);
                        var pub = key.type === 'private' ? key._publicKeyData : key._keyData;
                        var jwk = {
                            kty: 'EC', crv: crv,
                            x: base64urlEncode(pub.slice(1, 1 + cs)),
                            y: base64urlEncode(pub.slice(1 + cs, 1 + 2 * cs)),
                            key_ops: key.usages, ext: key.extractable
                        };
                        if (key.type === 'private') jwk.d = base64urlEncode(key._keyData);
                        return Promise.resolve(jwk);
                    }
                    // Ed25519
                    if (upper === 'ED25519') {
                        var pub = key.type === 'private' ? key._publicKeyData : key._keyData;
                        var jwk = {
                            kty: 'OKP', crv: 'Ed25519',
                            x: base64urlEncode(pub),
                            key_ops: key.usages, ext: key.extractable
                        };
                        if (key.type === 'private') jwk.d = base64urlEncode(key._keyData);
                        return Promise.resolve(jwk);
                    }
                    // RSA
                    if (upper === 'RSASSA-PKCS1-V1_5' || upper === 'RSA-PSS' || upper === 'RSA-OAEP') {
                        var isPriv = key.type === 'private';
                        var comp = __cryptoRsaExportJwk(key._keyData, isPriv);
                        if (!comp) return Promise.reject(new Error('RSA JWK export failed'));
                        var hashName = getHashName(key.algorithm);
                        var prefix = upper.indexOf('PKCS1') >= 0 ? 'RS' : (upper.indexOf('PSS') >= 0 ? 'PS' : 'RSA-OAEP');
                        var jwk = {
                            kty: 'RSA',
                            n: base64urlEncode(stripLeadingZero(toU8(comp.n))),
                            e: base64urlEncode(stripLeadingZero(toU8(comp.e))),
                            alg: prefix + hashName.replace('SHA-', ''),
                            key_ops: key.usages, ext: key.extractable
                        };
                        if (isPriv) {
                            jwk.d = base64urlEncode(stripLeadingZero(toU8(comp.d)));
                            jwk.p = base64urlEncode(stripLeadingZero(toU8(comp.p)));
                            jwk.q = base64urlEncode(stripLeadingZero(toU8(comp.q)));
                            jwk.dp = base64urlEncode(stripLeadingZero(toU8(comp.dp)));
                            jwk.dq = base64urlEncode(stripLeadingZero(toU8(comp.dq)));
                            jwk.qi = base64urlEncode(stripLeadingZero(toU8(comp.qi)));
                        }
                        return Promise.resolve(jwk);
                    }
                    // AES
                    if (upper.indexOf('AES') === 0) {
                        return Promise.resolve({
                            kty: 'oct', k: base64urlEncode(key._keyData),
                            alg: 'A' + (key._keyData.length * 8) + upper.replace('AES-', ''),
                            key_ops: key.usages, ext: key.extractable
                        });
                    }
                    return Promise.reject(new Error('JWK export not supported for ' + algoName));
                }

                if (format === 'pkcs8') {
                    if (key.type !== 'private') return Promise.reject(new Error('pkcs8 requires private key'));
                    if (upper === 'ECDSA' || upper === 'ECDH') {
                        var r = __cryptoEcExportDer(key.algorithm.namedCurve, key._keyData, true);
                        if (!r) return Promise.reject(new Error('EC pkcs8 export failed'));
                        return Promise.resolve(bridgeResultToArrayBuffer(r));
                    }
                    return Promise.reject(new Error('pkcs8 export not supported for ' + algoName));
                }

                if (format === 'spki') {
                    if (upper === 'ECDSA' || upper === 'ECDH') {
                        var pubData = key.type === 'private' ? key._publicKeyData : key._keyData;
                        var r = __cryptoEcExportDer(key.algorithm.namedCurve, pubData, false);
                        if (!r) return Promise.reject(new Error('EC spki export failed'));
                        return Promise.resolve(bridgeResultToArrayBuffer(r));
                    }
                    return Promise.reject(new Error('spki export not supported for ' + algoName));
                }

                return Promise.reject(new Error('Unsupported export format: ' + format));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- sign ----
        SubtleCrypto.prototype.sign = function(algorithm, key, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var bytes = toUint8Array(data);
                if (upper === 'HMAC') {
                    var h = getHashName(key.algorithm || algoObj);
                    var r = __cryptoHmacSign(h, key._keyData, bytes);
                    if (r === undefined) return Promise.reject(new Error('HMAC sign failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'ECDSA') {
                    var crv = key.algorithm.namedCurve;
                    var r = __cryptoEcdsaSign(crv, key._keyData, bytes);
                    if (r === undefined) return Promise.reject(new Error('ECDSA sign failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'ED25519') {
                    var r = __cryptoEd25519Sign(key._keyData, bytes);
                    if (r === undefined) return Promise.reject(new Error('Ed25519 sign failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'RSASSA-PKCS1-V1_5' || upper === 'RSA-PSS') {
                    var h = getHashName(key.algorithm || algoObj);
                    var r = __cryptoRsaSign(algoObj.name, h, key._keyData, bytes);
                    if (r === undefined) return Promise.reject(new Error('RSA sign failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                return Promise.reject(new Error('Unsupported sign algorithm: ' + algoObj.name));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- verify ----
        SubtleCrypto.prototype.verify = function(algorithm, key, signature, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var sigBytes = toUint8Array(signature);
                var dataBytes = toUint8Array(data);
                if (upper === 'HMAC') {
                    var h = getHashName(key.algorithm || algoObj);
                    return Promise.resolve(__cryptoHmacVerify(h, key._keyData, sigBytes, dataBytes));
                }
                if (upper === 'ECDSA') {
                    var crv = key.algorithm.namedCurve;
                    var pub = key.type === 'public' ? key._keyData : key._publicKeyData;
                    return Promise.resolve(__cryptoEcdsaVerify(crv, pub, sigBytes, dataBytes));
                }
                if (upper === 'ED25519') {
                    var pub = key.type === 'public' ? key._keyData : key._publicKeyData;
                    return Promise.resolve(__cryptoEd25519Verify(pub, sigBytes, dataBytes));
                }
                if (upper === 'RSASSA-PKCS1-V1_5' || upper === 'RSA-PSS') {
                    var h = getHashName(key.algorithm || algoObj);
                    var pub = key.type === 'public' ? key._keyData : key._publicKeyData;
                    return Promise.resolve(__cryptoRsaVerify(algoObj.name, h, pub, sigBytes, dataBytes));
                }
                return Promise.reject(new Error('Unsupported verify algorithm: ' + algoObj.name));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- encrypt ----
        SubtleCrypto.prototype.encrypt = function(algorithm, key, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var bytes = toUint8Array(data);
                if (upper === 'AES-GCM') {
                    var iv = toUint8Array(algoObj.iv);
                    var aad = algoObj.additionalData ? toUint8Array(algoObj.additionalData) : null;
                    var tagLen = algoObj.tagLength || 128;
                    var r = __cryptoAesGcmEncrypt(key._keyData, iv, bytes, aad, tagLen);
                    if (r === undefined) return Promise.reject(new Error('AES-GCM encrypt failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'AES-CBC') {
                    var iv = toUint8Array(algoObj.iv);
                    var r = __cryptoAesCbcEncrypt(key._keyData, iv, bytes);
                    if (r === undefined) return Promise.reject(new Error('AES-CBC encrypt failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                return Promise.reject(new Error('Unsupported encrypt algorithm: ' + algoObj.name));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- decrypt ----
        SubtleCrypto.prototype.decrypt = function(algorithm, key, data) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var bytes = toUint8Array(data);
                if (upper === 'AES-GCM') {
                    var iv = toUint8Array(algoObj.iv);
                    var aad = algoObj.additionalData ? toUint8Array(algoObj.additionalData) : null;
                    var tagLen = algoObj.tagLength || 128;
                    var r = __cryptoAesGcmDecrypt(key._keyData, iv, bytes, aad, tagLen);
                    if (r === undefined) return Promise.reject(new Error('AES-GCM decrypt failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'AES-CBC') {
                    var iv = toUint8Array(algoObj.iv);
                    var r = __cryptoAesCbcDecrypt(key._keyData, iv, bytes);
                    if (r === undefined) return Promise.reject(new Error('AES-CBC decrypt failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                return Promise.reject(new Error('Unsupported decrypt algorithm: ' + algoObj.name));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- generateKey ----
        SubtleCrypto.prototype.generateKey = function(algorithm, extractable, usages) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var params = {};
                if (algoObj.namedCurve) params.namedCurve = algoObj.namedCurve;
                if (algoObj.modulusLength) params.modulusLength = algoObj.modulusLength;
                if (algoObj.publicExponent) params.publicExponent = toUint8Array(algoObj.publicExponent);
                if (algoObj.hash) params.hash = typeof algoObj.hash === 'string' ? algoObj.hash : algoObj.hash.name;
                if (algoObj.length) params.length = algoObj.length;

                var r = __cryptoGenerateKey(upper, params);
                if (!r || r === undefined) return Promise.reject(new Error('generateKey failed'));

                if (r.type === 'symmetric') {
                    return Promise.resolve(new CryptoKey('secret', extractable, algoObj, usages, toU8(r.secretKey)));
                }

                var privUsages = [], pubUsages = [];
                for (var i = 0; i < usages.length; i++) {
                    var u = usages[i];
                    if (u === 'sign' || u === 'decrypt' || u === 'unwrapKey' || u === 'deriveKey' || u === 'deriveBits')
                        privUsages.push(u);
                    else pubUsages.push(u);
                }
                var priv = new CryptoKey('private', extractable, algoObj, privUsages, toU8(r.privateKey));
                var pub = new CryptoKey('public', true, algoObj, pubUsages, toU8(r.publicKey));
                priv._publicKeyData = pub._keyData;
                return Promise.resolve({ privateKey: priv, publicKey: pub });
            } catch(e) { return Promise.reject(e); }
        };

        // ---- deriveBits ----
        SubtleCrypto.prototype.deriveBits = function(algorithm, baseKey, length) {
            try {
                var algoObj = typeof algorithm === 'string' ? { name: algorithm } : algorithm;
                var upper = algoObj.name.toUpperCase();
                var byteLen = length / 8;
                if (upper === 'HKDF') {
                    var h = typeof algoObj.hash === 'string' ? algoObj.hash : algoObj.hash.name;
                    var salt = algoObj.salt ? toUint8Array(algoObj.salt) : new Uint8Array(0);
                    var info = algoObj.info ? toUint8Array(algoObj.info) : new Uint8Array(0);
                    var r = __cryptoHkdfDeriveBits(h, baseKey._keyData, salt, info, byteLen);
                    if (r === undefined) return Promise.reject(new Error('HKDF deriveBits failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                if (upper === 'PBKDF2') {
                    var h = typeof algoObj.hash === 'string' ? algoObj.hash : algoObj.hash.name;
                    var salt = toUint8Array(algoObj.salt);
                    var r = __cryptoPbkdf2DeriveBits(h, baseKey._keyData, salt, algoObj.iterations, byteLen);
                    if (r === undefined) return Promise.reject(new Error('PBKDF2 deriveBits failed'));
                    return Promise.resolve(bridgeResultToArrayBuffer(r));
                }
                return Promise.reject(new Error('Unsupported deriveBits algorithm: ' + algoObj.name));
            } catch(e) { return Promise.reject(e); }
        };

        // ---- deriveKey ----
        SubtleCrypto.prototype.deriveKey = function(algorithm, baseKey, derivedKeyAlgo, extractable, keyUsages) {
            var self = this;
            try {
                var dka = typeof derivedKeyAlgo === 'string' ? { name: derivedKeyAlgo } : derivedKeyAlgo;
                var length;
                if (dka.length) length = dka.length;
                else if (dka.name === 'HMAC') {
                    var h = getHashName(dka);
                    length = h === 'SHA-384' ? 384 : (h === 'SHA-512' ? 512 : 256);
                } else length = 256;
                return self.deriveBits(algorithm, baseKey, length).then(function(bits) {
                    return self.importKey('raw', bits, derivedKeyAlgo, extractable, keyUsages);
                });
            } catch(e) { return Promise.reject(e); }
        };

        // ---- wrapKey ----
        SubtleCrypto.prototype.wrapKey = function(format, key, wrappingKey, wrapAlgorithm) {
            var self = this;
            return self.exportKey(format, key).then(function(exported) {
                var data = format === 'jwk' ? new TextEncoder().encode(JSON.stringify(exported)) : exported;
                return self.encrypt(wrapAlgorithm, wrappingKey, data);
            });
        };

        // ---- unwrapKey ----
        SubtleCrypto.prototype.unwrapKey = function(format, wrappedKey, unwrappingKey, unwrapAlgo, unwrappedKeyAlgo, extractable, keyUsages) {
            var self = this;
            return self.decrypt(unwrapAlgo, unwrappingKey, wrappedKey).then(function(unwrapped) {
                var kd = format === 'jwk' ? JSON.parse(new TextDecoder().decode(new Uint8Array(unwrapped))) : unwrapped;
                return self.importKey(format, kd, unwrappedKeyAlgo, extractable, keyUsages);
            });
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
            buf[6] = (buf[6] & 0x0f) | 0x40;
            buf[8] = (buf[8] & 0x3f) | 0x80;
            var hex = '';
            for (var i = 0; i < 16; i++) hex += ('00' + buf[i].toString(16)).slice(-2);
            return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20);
        };
        g.crypto = cryptoObj;
    })(this);
    """
}
