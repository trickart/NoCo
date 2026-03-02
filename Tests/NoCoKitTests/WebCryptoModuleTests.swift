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
