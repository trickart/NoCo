import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Web Crypto API Tests

@Test func cryptoGlobalExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        typeof crypto === 'object' &&
        typeof crypto.subtle === 'object' &&
        typeof crypto.getRandomValues === 'function' &&
        typeof crypto.randomUUID === 'function' &&
        typeof CryptoKey === 'function'
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoGetRandomValues() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var arr = new Uint8Array(16);
        var result = crypto.getRandomValues(arr);
        (result === arr) + ':' + (arr.length === 16) + ':' + arr.some(function(v) { return v !== 0; });
    """)
    #expect(result?.toString() == "true:true:true")
}

@Test func webCryptoRandomUUID() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("crypto.randomUUID()")
    let uuid = result?.toString() ?? ""
    #expect(uuid.count == 36)
    // UUID v4 format check: 8-4-4-4-12, version nibble is '4'
    let parts = uuid.split(separator: "-")
    #expect(parts.count == 5)
    #expect(parts[2].hasPrefix("4"))
}

@Test func webCryptoRandomUUIDUnique() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        crypto.randomUUID() !== crypto.randomUUID()
    """)
    #expect(result?.toBool() == true)
}

// MARK: - subtle.digest

@Test func subtleDigestSHA256() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var data = new TextEncoder().encode('hello');
        crypto.subtle.digest('SHA-256', data).then(function(buf) {
            var arr = new Uint8Array(buf);
            var hex = Array.prototype.map.call(arr, function(b) {
                return ('00' + b.toString(16)).slice(-2);
            }).join('');
            console.log(hex);
        });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
}

@Test func subtleDigestSHA1() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.digest({ name: 'SHA-1' }, new TextEncoder().encode('hello')).then(function(buf) {
            var arr = new Uint8Array(buf);
            var hex = Array.prototype.map.call(arr, function(b) {
                return ('00' + b.toString(16)).slice(-2);
            }).join('');
            console.log(hex);
        });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d"))
}

@Test func subtleDigestReturnsArrayBuffer() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.digest('SHA-256', new TextEncoder().encode('test')).then(function(buf) {
            console.log('isArrayBuffer:' + (buf instanceof ArrayBuffer));
            console.log('byteLength:' + buf.byteLength);
        });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("isArrayBuffer:true"))
    #expect(messages.contains("byteLength:32"))
}

// MARK: - subtle.importKey + sign + verify (HMAC)

@Test func subtleHmacSignVerify() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        var keyData = enc.encode('secret');
        var data = enc.encode('hello');
        crypto.subtle.importKey('raw', keyData, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
            .then(function(key) {
                return crypto.subtle.sign({ name: 'HMAC', hash: { name: 'SHA-256' } }, key, data)
                    .then(function(sig) {
                        return crypto.subtle.verify({ name: 'HMAC', hash: { name: 'SHA-256' } }, key, sig, data);
                    });
            })
            .then(function(valid) {
                console.log('valid:' + valid);
            })
            .catch(function(e) {
                console.log('error:' + e.message);
            });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("valid:true"))
}

@Test func subtleHmacVerifyRejectsTamperedData() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('secret'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
            .then(function(key) {
                return crypto.subtle.sign('HMAC', key, enc.encode('hello'))
                    .then(function(sig) {
                        return crypto.subtle.verify('HMAC', key, sig, enc.encode('tampered'));
                    });
            })
            .then(function(valid) {
                console.log('tampered:' + valid);
            });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("tampered:false"))
}

@Test func subtleHmacSignDeterministic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('key'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
            .then(function(key) {
                return Promise.all([
                    crypto.subtle.sign('HMAC', key, enc.encode('data')),
                    crypto.subtle.sign('HMAC', key, enc.encode('data'))
                ]);
            })
            .then(function(sigs) {
                var a = new Uint8Array(sigs[0]);
                var b = new Uint8Array(sigs[1]);
                var same = a.length === b.length && a.every(function(v, i) { return v === b[i]; });
                console.log('deterministic:' + same);
            });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("deterministic:true"))
}

// MARK: - CryptoKey

@Test func cryptoKeyInstanceOf() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('key'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
            .then(function(key) {
                console.log('isCryptoKey:' + (key instanceof CryptoKey));
                console.log('type:' + key.type);
                console.log('extractable:' + key.extractable);
                console.log('algoName:' + key.algorithm.name);
            });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("isCryptoKey:true"))
    #expect(messages.contains("type:secret"))
    #expect(messages.contains("extractable:false"))
    #expect(messages.contains("algoName:HMAC"))
}

// MARK: - subtle.exportKey

@Test func subtleExportKeyRaw() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        var originalKey = enc.encode('mysecretkey');
        crypto.subtle.importKey('raw', originalKey, { name: 'HMAC', hash: 'SHA-256' }, true, ['sign'])
            .then(function(key) {
                return crypto.subtle.exportKey('raw', key);
            })
            .then(function(exported) {
                var arr = new Uint8Array(exported);
                var str = new TextDecoder().decode(arr);
                console.log('exported:' + str);
            });
    """)
    runtime.runEventLoop(timeout: 2)
    #expect(messages.contains("exported:mysecretkey"))
}

// MARK: - Phase 1: ECDSA P-256 sign/verify

@Test func ecdsaP256SignVerify() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
            .then(function(keyPair) {
                var data = new TextEncoder().encode('hello ecdsa');
                return crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, keyPair.privateKey, data)
                    .then(function(sig) {
                        return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, keyPair.publicKey, sig, data);
                    });
            })
            .then(function(v) { console.log('ecdsa-verify:' + v); })
            .catch(function(e) { console.log('ecdsa-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("ecdsa-verify:true"))
}

@Test func ecdsaP256RejectsTampered() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
            .then(function(kp) {
                return crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, kp.privateKey, new TextEncoder().encode('original'))
                    .then(function(sig) {
                        return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, kp.publicKey, sig, new TextEncoder().encode('tampered'));
                    });
            })
            .then(function(v) { console.log('tampered:' + v); })
            .catch(function(e) { console.log('error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("tampered:false"))
}

@Test func ecdsaJwkImportExport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
            .then(function(kp) {
                return crypto.subtle.exportKey('jwk', kp.privateKey).then(function(jwk) {
                    console.log('kty:' + jwk.kty);
                    console.log('crv:' + jwk.crv);
                    console.log('hasX:' + !!jwk.x);
                    console.log('hasY:' + !!jwk.y);
                    console.log('hasD:' + !!jwk.d);
                    // Re-import as private key and sign
                    return crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
                        .then(function(reimported) {
                            return crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, reimported, new TextEncoder().encode('test'));
                        })
                        .then(function(sig) {
                            console.log('reimport-sign:' + (sig.byteLength > 0));
                        });
                });
            })
            .catch(function(e) { console.log('jwk-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("kty:EC"))
    #expect(messages.contains("crv:P-256"))
    #expect(messages.contains("hasX:true"))
    #expect(messages.contains("hasY:true"))
    #expect(messages.contains("hasD:true"))
    #expect(messages.contains("reimport-sign:true"))
}

@Test func ecdsaExportPublicJwkFromPrivate() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
            .then(function(kp) {
                // Export private key as JWK, remove d to get public JWK
                return crypto.subtle.exportKey('jwk', kp.privateKey).then(function(jwk) {
                    var pubJwk = { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y };
                    return crypto.subtle.importKey('jwk', pubJwk, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify'])
                        .then(function(pubKey) {
                            console.log('pubKeyType:' + pubKey.type);
                            // Sign with private, verify with re-imported public
                            return crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, kp.privateKey, new TextEncoder().encode('data'))
                                .then(function(sig) {
                                    return crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pubKey, sig, new TextEncoder().encode('data'));
                                });
                        });
                });
            })
            .then(function(v) { console.log('cross-verify:' + v); })
            .catch(function(e) { console.log('error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("pubKeyType:public"))
    #expect(messages.contains("cross-verify:true"))
}

// MARK: - Phase 2: Ed25519 sign/verify

@Test func ed25519SignVerify() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])
            .then(function(kp) {
                var data = new TextEncoder().encode('hello ed25519');
                return crypto.subtle.sign({ name: 'Ed25519' }, kp.privateKey, data)
                    .then(function(sig) {
                        console.log('sigLen:' + sig.byteLength);
                        return crypto.subtle.verify({ name: 'Ed25519' }, kp.publicKey, sig, data);
                    });
            })
            .then(function(v) { console.log('ed25519-verify:' + v); })
            .catch(function(e) { console.log('ed25519-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("sigLen:64"))
    #expect(messages.contains("ed25519-verify:true"))
}

@Test func ed25519JwkImportExport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])
            .then(function(kp) {
                return crypto.subtle.exportKey('jwk', kp.privateKey).then(function(jwk) {
                    console.log('kty:' + jwk.kty);
                    console.log('crv:' + jwk.crv);
                    console.log('hasX:' + !!jwk.x);
                    console.log('hasD:' + !!jwk.d);
                    // Re-import and verify
                    return crypto.subtle.importKey('jwk', jwk, { name: 'Ed25519' }, true, ['sign'])
                        .then(function(k) {
                            return crypto.subtle.sign('Ed25519', k, new TextEncoder().encode('test'));
                        })
                        .then(function(sig) {
                            console.log('reimport-ok:' + (sig.byteLength === 64));
                        });
                });
            })
            .catch(function(e) { console.log('ed-jwk-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("kty:OKP"))
    #expect(messages.contains("crv:Ed25519"))
    #expect(messages.contains("hasX:true"))
    #expect(messages.contains("hasD:true"))
    #expect(messages.contains("reimport-ok:true"))
}

// MARK: - Phase 3: RSA sign/verify

@Test func rsaPkcs1SignVerify() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey(
            { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' },
            true, ['sign', 'verify']
        ).then(function(kp) {
            var data = new TextEncoder().encode('hello rsa');
            return crypto.subtle.sign('RSASSA-PKCS1-v1_5', kp.privateKey, data)
                .then(function(sig) {
                    console.log('sigLen:' + sig.byteLength);
                    return crypto.subtle.verify('RSASSA-PKCS1-v1_5', kp.publicKey, sig, data);
                });
        })
        .then(function(v) { console.log('rsa-verify:' + v); })
        .catch(function(e) { console.log('rsa-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 10)
    #expect(messages.contains("rsa-verify:true"))
}

@Test func rsaPssSignVerify() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey(
            { name: 'RSA-PSS', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' },
            true, ['sign', 'verify']
        ).then(function(kp) {
            var data = new TextEncoder().encode('hello pss');
            return crypto.subtle.sign({ name: 'RSA-PSS', saltLength: 32 }, kp.privateKey, data)
                .then(function(sig) {
                    return crypto.subtle.verify({ name: 'RSA-PSS', saltLength: 32 }, kp.publicKey, sig, data);
                });
        })
        .then(function(v) { console.log('pss-verify:' + v); })
        .catch(function(e) { console.log('pss-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 10)
    #expect(messages.contains("pss-verify:true"))
}

// MARK: - Phase 4: generateKey

@Test func generateKeyAllAlgorithms() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        Promise.all([
            crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, true, ['sign']),
            crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']),
            crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']),
            crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']),
        ]).then(function(results) {
            console.log('hmac:' + results[0].type + ':' + (results[0]._keyData.length === 32));
            console.log('aes:' + results[1].type + ':' + (results[1]._keyData.length === 32));
            console.log('ecdsa-priv:' + results[2].privateKey.type);
            console.log('ecdsa-pub:' + results[2].publicKey.type);
            console.log('ed-priv:' + results[3].privateKey.type);
            console.log('ed-pub:' + results[3].publicKey.type);
        }).catch(function(e) { console.log('gen-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("hmac:secret:true"))
    #expect(messages.contains("aes:secret:true"))
    #expect(messages.contains("ecdsa-priv:private"))
    #expect(messages.contains("ecdsa-pub:public"))
    #expect(messages.contains("ed-priv:private"))
    #expect(messages.contains("ed-pub:public"))
}

// MARK: - Phase 5: AES-GCM / AES-CBC encrypt/decrypt

@Test func aesGcmEncryptDecrypt() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt'])
            .then(function(key) {
                var iv = crypto.getRandomValues(new Uint8Array(12));
                var data = new TextEncoder().encode('secret message');
                return crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv }, key, data)
                    .then(function(ct) {
                        console.log('ct-len:' + ct.byteLength);
                        return crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv }, key, ct);
                    })
                    .then(function(pt) {
                        console.log('decrypted:' + new TextDecoder().decode(new Uint8Array(pt)));
                    });
            })
            .catch(function(e) { console.log('gcm-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("decrypted:secret message"))
}

@Test func aesGcmTamperedFails() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt'])
            .then(function(key) {
                var iv = crypto.getRandomValues(new Uint8Array(12));
                return crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv }, key, new TextEncoder().encode('data'))
                    .then(function(ct) {
                        var arr = new Uint8Array(ct);
                        arr[0] ^= 0xFF; // tamper
                        return crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv }, key, arr.buffer);
                    });
            })
            .then(function() { console.log('should-not-reach'); })
            .catch(function(e) { console.log('tamper-detected:true'); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("tamper-detected:true"))
}

@Test func aesCbcEncryptDecrypt() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        crypto.subtle.generateKey({ name: 'AES-CBC', length: 256 }, true, ['encrypt', 'decrypt'])
            .then(function(key) {
                var iv = crypto.getRandomValues(new Uint8Array(16));
                var data = new TextEncoder().encode('cbc secret message');
                return crypto.subtle.encrypt({ name: 'AES-CBC', iv: iv }, key, data)
                    .then(function(ct) {
                        return crypto.subtle.decrypt({ name: 'AES-CBC', iv: iv }, key, ct);
                    })
                    .then(function(pt) {
                        console.log('cbc-decrypted:' + new TextDecoder().decode(new Uint8Array(pt)));
                    });
            })
            .catch(function(e) { console.log('cbc-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("cbc-decrypted:cbc secret message"))
}

// MARK: - Phase 6: HKDF / PBKDF2

@Test func hkdfDeriveBits() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('input key material'), 'HKDF', false, ['deriveBits'])
            .then(function(baseKey) {
                return crypto.subtle.deriveBits({
                    name: 'HKDF', hash: 'SHA-256',
                    salt: enc.encode('salt'), info: enc.encode('info')
                }, baseKey, 256);
            })
            .then(function(bits) {
                console.log('hkdf-len:' + bits.byteLength);
                console.log('hkdf-ok:' + (bits.byteLength === 32));
            })
            .catch(function(e) { console.log('hkdf-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("hkdf-ok:true"))
}

@Test func hkdfDeterministic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        var ikm = enc.encode('key');
        Promise.all([
            crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']).then(function(k) {
                return crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: enc.encode('s'), info: enc.encode('i') }, k, 128);
            }),
            crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']).then(function(k) {
                return crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: enc.encode('s'), info: enc.encode('i') }, k, 128);
            })
        ]).then(function(results) {
            var a = new Uint8Array(results[0]);
            var b = new Uint8Array(results[1]);
            var same = a.length === b.length && a.every(function(v,i) { return v === b[i]; });
            console.log('hkdf-deterministic:' + same);
        });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("hkdf-deterministic:true"))
}

@Test func pbkdf2DeriveBits() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('password'), 'PBKDF2', false, ['deriveBits'])
            .then(function(baseKey) {
                return crypto.subtle.deriveBits({
                    name: 'PBKDF2', hash: 'SHA-256',
                    salt: enc.encode('salt'), iterations: 100000
                }, baseKey, 256);
            })
            .then(function(bits) {
                console.log('pbkdf2-len:' + bits.byteLength);
                // Known test vector: PBKDF2-HMAC-SHA256("password", "salt", 100000, 32)
                var arr = new Uint8Array(bits);
                var hex = Array.prototype.map.call(arr, function(b) { return ('00' + b.toString(16)).slice(-2); }).join('');
                console.log('pbkdf2-hex:' + hex);
            })
            .catch(function(e) { console.log('pbkdf2-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 10)
    #expect(messages.contains("pbkdf2-len:32"))
    // Known test vector
    #expect(messages.contains("pbkdf2-hex:0394a2ede332c9a13eb82e9b24631604c31df978b4e2f0fbd2c549944f9d79a5"))
}

@Test func deriveKey() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        var enc = new TextEncoder();
        crypto.subtle.importKey('raw', enc.encode('password'), 'PBKDF2', false, ['deriveKey'])
            .then(function(baseKey) {
                return crypto.subtle.deriveKey(
                    { name: 'PBKDF2', hash: 'SHA-256', salt: enc.encode('salt'), iterations: 1000 },
                    baseKey,
                    { name: 'AES-GCM', length: 256 },
                    true, ['encrypt']
                );
            })
            .then(function(derivedKey) {
                console.log('derived-type:' + derivedKey.type);
                console.log('derived-algo:' + derivedKey.algorithm.name);
                console.log('derived-len:' + derivedKey._keyData.length);
            })
            .catch(function(e) { console.log('dk-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("derived-type:secret"))
    #expect(messages.contains("derived-algo:AES-GCM"))
    #expect(messages.contains("derived-len:32"))
}

// MARK: - Phase 7: wrapKey / unwrapKey

@Test func wrapUnwrapKey() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }
    runtime.evaluate("""
        Promise.all([
            crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['wrapKey', 'unwrapKey', 'encrypt', 'decrypt']),
            crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, true, ['sign'])
        ]).then(function(keys) {
            var wrappingKey = keys[0];
            var keyToWrap = keys[1];
            var iv = crypto.getRandomValues(new Uint8Array(12));
            return crypto.subtle.wrapKey('raw', keyToWrap, wrappingKey, { name: 'AES-GCM', iv: iv })
                .then(function(wrapped) {
                    console.log('wrapped-ok:' + (wrapped.byteLength > 0));
                    return crypto.subtle.unwrapKey('raw', wrapped, wrappingKey, { name: 'AES-GCM', iv: iv },
                        { name: 'HMAC', hash: 'SHA-256' }, true, ['sign']);
                })
                .then(function(unwrapped) {
                    console.log('unwrap-type:' + unwrapped.type);
                    console.log('unwrap-algo:' + unwrapped.algorithm.name);
                    // Verify the unwrapped key works for signing
                    return crypto.subtle.sign('HMAC', unwrapped, new TextEncoder().encode('test'));
                })
                .then(function(sig) {
                    console.log('unwrap-sign-ok:' + (sig.byteLength > 0));
                });
        })
        .catch(function(e) { console.log('wrap-error:' + e.message); });
    """)
    runtime.runEventLoop(timeout: 5)
    #expect(messages.contains("wrapped-ok:true"))
    #expect(messages.contains("unwrap-type:secret"))
    #expect(messages.contains("unwrap-algo:HMAC"))
    #expect(messages.contains("unwrap-sign-ok:true"))
}
