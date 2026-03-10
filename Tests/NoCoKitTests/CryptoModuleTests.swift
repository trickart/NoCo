import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Crypto Module Tests

@Test func cryptoSHA256() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha256').update('hello').digest('hex')
    """)
    #expect(result?.toString() == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test func cryptoMD5() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('md5').update('hello').digest('hex')
    """)
    #expect(result?.toString() == "5d41402abc4b2a76b9719d911017c592")
}

@Test func cryptoHMAC() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHmac('sha256', 'secret').update('hello').digest('hex')
    """)
    // Verify it returns a hex string of correct length (64 chars for SHA-256)
    let hex = result?.toString() ?? ""
    #expect(hex.count == 64)
}

@Test func cryptoRandomBytes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').randomBytes(16).length
    """)
    #expect(result?.toInt32() == 16)
}

@Test func cryptoRandomUUID() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('crypto').randomUUID()")
    let uuid = result?.toString() ?? ""
    #expect(uuid.count == 36) // UUID format: 8-4-4-4-12
}

// MARK: - Crypto Module Edge Cases

@Test func cryptoSHA512() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha512').update('hello').digest('hex')
    """)
    let hex = result?.toString() ?? ""
    // SHA-512 produces 128 hex chars
    #expect(hex.count == 128)
    #expect(hex.hasPrefix("9b71d224bd62"))
}

@Test func cryptoSHA1() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha1').update('hello').digest('hex')
    """)
    let hex = result?.toString() ?? ""
    // SHA-1 produces 40 hex chars
    #expect(hex.count == 40)
    #expect(hex == "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
}

@Test func cryptoDigestBase64() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha256').update('hello').digest('base64')
    """)
    let b64 = result?.toString() ?? ""
    #expect(!b64.isEmpty)
    // Base64 of SHA-256 should be 44 chars (with padding)
    #expect(b64.count == 44)
}

@Test func cryptoHmacSHA512() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHmac('sha512', 'secret').update('hello').digest('hex')
    """)
    let hex = result?.toString() ?? ""
    // SHA-512 HMAC produces 128 hex chars
    #expect(hex.count == 128)
}

@Test func cryptoUnsupportedAlgorithm() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        try {
            require('crypto').createHash('fakealgo').update('hello').digest('hex');
        } catch(e) {
            console.log('error:' + e.message);
        }
    """)
    #expect(messages.contains(where: { $0.1.contains("Unsupported") || $0.1.contains("fakealgo") }))
}

// MARK: - digest() returns Buffer when no encoding specified

@Test func cryptoHashDigestReturnsBufferWithoutEncoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var d = require('crypto').createHash('sha256').update('hello').digest();
        JSON.stringify({ isBuffer: Buffer.isBuffer(d), length: d.length });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isBuffer\":true"))
    #expect(json.contains("\"length\":32"))
}

@Test func cryptoHashDigestBufferContentMatchesHex() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var buf = crypto.createHash('sha256').update('hello').digest();
        var hex = crypto.createHash('sha256').update('hello').digest('hex');
        buf.toString('hex') === hex;
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoHmacDigestReturnsBufferWithoutEncoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var d = require('crypto').createHmac('sha256', 'key').update('data').digest();
        JSON.stringify({ isBuffer: Buffer.isBuffer(d), length: d.length });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isBuffer\":true"))
    #expect(json.contains("\"length\":32"))
}

// MARK: - crypto.randomFillSync

@Test func cryptoRandomFillSyncUint8Array() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var buf = new Uint8Array(16);
        var ret = crypto.randomFillSync(buf);
        JSON.stringify({ same: ret === buf, length: buf.length, nonZero: buf.some(function(b) { return b !== 0; }) });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"same\":true"))
    #expect(json.contains("\"length\":16"))
    #expect(json.contains("\"nonZero\":true"))
}

@Test func cryptoRandomFillSyncWithOffset() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var buf = new Uint8Array(10);
        crypto.randomFillSync(buf, 5, 5);
        var firstFiveZero = buf[0] === 0 && buf[1] === 0 && buf[2] === 0 && buf[3] === 0 && buf[4] === 0;
        var lastFiveSet = buf.slice(5).some(function(b) { return b !== 0; });
        JSON.stringify({ firstFiveZero: firstFiveZero, lastFiveSet: lastFiveSet });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"firstFiveZero\":true"))
}

@Test func cryptoRandomFillSyncBuffer() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var buf = Buffer.alloc(32);
        crypto.randomFillSync(buf);
        var hasNonZero = false;
        for (var i = 0; i < buf.length; i++) { if (buf[i] !== 0) { hasNonZero = true; break; } }
        JSON.stringify({ isBuffer: Buffer.isBuffer(buf), nonZero: hasNonZero, length: buf.length });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"nonZero\":true"))
    #expect(json.contains("\"length\":32"))
}

// MARK: - crypto.KeyObject / createSecretKey / createPrivateKey / createPublicKey

@Test func cryptoCreateSecretKey() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var key = crypto.createSecretKey(Buffer.from('my-secret'));
        JSON.stringify({ type: key.type, size: key.symmetricKeySize, isKeyObject: key instanceof crypto.KeyObject });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"type\":\"secret\""))
    #expect(json.contains("\"isKeyObject\":true"))
}

@Test func cryptoCreateSecretKeyFromString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var key = crypto.createSecretKey('my-secret');
        key.type === 'secret' && key instanceof crypto.KeyObject;
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoCreatePrivateKeyRejectsBareString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var threw = false;
        try { crypto.createPrivateKey('not-a-pem'); } catch(e) { threw = true; }
        threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoCreatePrivateKeyAcceptsPEM() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var key = crypto.createPrivateKey('-----BEGIN PRIVATE KEY-----\\nfake\\n-----END PRIVATE KEY-----');
        key.type === 'private';
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoCreatePublicKeyRejectsBareString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var threw = false;
        try { crypto.createPublicKey('not-a-pem'); } catch(e) { threw = true; }
        threw;
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoKeyObjectExport() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var key = crypto.createSecretKey(Buffer.from('test-key'));
        key.export().toString() === 'test-key';
    """)
    #expect(result?.toBool() == true)
}

// MARK: - createHmac with KeyObject

@Test func cryptoHmacWithKeyObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var crypto = require('crypto');
        var key = crypto.createSecretKey(Buffer.from('secret'));
        var hmac1 = crypto.createHmac('sha256', key).update('hello').digest('hex');
        var hmac2 = crypto.createHmac('sha256', 'secret').update('hello').digest('hex');
        hmac1 === hmac2;
    """)
    #expect(result?.toBool() == true)
}

@Test func cryptoHashChaining() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha256').update('hello').update(' world').digest('hex')
    """)
    // SHA-256 of "hello world"
    #expect(result?.toString() == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
}
