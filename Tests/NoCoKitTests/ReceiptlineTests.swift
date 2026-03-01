import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - receiptline npm Package Compatibility Tests

private func fixturesPath() -> String {
    let testFile = #filePath
    return (testFile as NSString).deletingLastPathComponent + "/Fixtures"
}

private func evaluateInFixtures(_ runtime: NodeRuntime, script: String) -> JSValue {
    let dir = fixturesPath()
    let tmp = dir + "/__test_\(UUID().uuidString).js"
    try! script.write(toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    return runtime.moduleLoader.loadFile(at: tmp)
}

// MARK: - require

@Test func receiptlineRequire() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var receiptline = require('receiptline');
        module.exports = typeof receiptline.transform;
    """)
    #expect(result.toString() == "function")
}

// MARK: - SVG output

@Test func receiptlineTransformSvg() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var receiptline = require('receiptline');
        var doc = 'Asparagus | 0.99\\nBroccoli | 1.99\\n---\\nTOTAL | $2.98';
        module.exports = receiptline.transform(doc, { command: 'svg' });
    """)
    let svg = result.toString()!
    #expect(svg.contains("<svg"))
    // receiptline renders each character in separate <tspan> elements
    #expect(svg.contains(">A<"))
}

// MARK: - Text output

@Test func receiptlineTransformText() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var receiptline = require('receiptline');
        var doc = 'Hello World';
        module.exports = receiptline.transform(doc, { command: 'text' });
    """)
    let text = result.toString()!
    #expect(text.contains("Hello World"))
}

// MARK: - Barcode

@Test func receiptlineBarcode() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var receiptline = require('receiptline');
        var doc = '{code:12345678; option:code128}';
        module.exports = receiptline.transform(doc, { command: 'svg' });
    """)
    let svg = result.toString()!
    #expect(svg.contains("<svg"))
}

// MARK: - QR code

@Test func receiptlineQrcode() async throws {
    let runtime = NodeRuntime()
    let result = evaluateInFixtures(runtime, script: """
        var receiptline = require('receiptline');
        var doc = '{code:https://example.com; option:qrcode}';
        module.exports = receiptline.transform(doc, { command: 'svg' });
    """)
    let svg = result.toString()!
    #expect(svg.contains("<svg"))
}
