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

@Test func cryptoHashChaining() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha256').update('hello').update(' world').digest('hex')
    """)
    // SHA-256 of "hello world"
    #expect(result?.toString() == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
}
