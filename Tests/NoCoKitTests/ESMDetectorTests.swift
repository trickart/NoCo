import Foundation
import Testing
@testable import NoCoKit

@Test func detectMjsAsESM() async throws {
    let detector = ESMDetector.shared
    #expect(detector.isESM(path: "/some/file.mjs") == true)
}

@Test func detectCjsAsCJS() async throws {
    let detector = ESMDetector.shared
    #expect(detector.isESM(path: "/some/file.cjs") == false)
}

@Test func detectJsDefaultAsCJS() async throws {
    let detector = ESMDetector.shared
    // .js without package.json type → CJS
    #expect(detector.isESM(path: "/tmp/no-pkg/test.js") == false)
}

@Test func detectJsWithTypeModule() async throws {
    let fm = FileManager.default
    let tmpDir = NSTemporaryDirectory() + "esm-test-\(UUID().uuidString)"
    try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmpDir) }

    let pkgJson = """
    {"type": "module"}
    """
    try pkgJson.write(toFile: tmpDir + "/package.json", atomically: true, encoding: .utf8)

    let detector = ESMDetector.shared
    detector.clearCache()
    #expect(detector.isESM(path: tmpDir + "/test.js") == true)
}

@Test func detectJsWithTypeCommonJS() async throws {
    let fm = FileManager.default
    let tmpDir = NSTemporaryDirectory() + "esm-test-\(UUID().uuidString)"
    try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmpDir) }

    let pkgJson = """
    {"type": "commonjs"}
    """
    try pkgJson.write(toFile: tmpDir + "/package.json", atomically: true, encoding: .utf8)

    let detector = ESMDetector.shared
    detector.clearCache()
    #expect(detector.isESM(path: tmpDir + "/test.js") == false)
}

@Test func findNearestPackageTypeWalksUp() async throws {
    let fm = FileManager.default
    let tmpDir = NSTemporaryDirectory() + "esm-test-\(UUID().uuidString)"
    let subDir = tmpDir + "/src/lib"
    try fm.createDirectory(atPath: subDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmpDir) }

    let pkgJson = """
    {"type": "module"}
    """
    try pkgJson.write(toFile: tmpDir + "/package.json", atomically: true, encoding: .utf8)

    let detector = ESMDetector.shared
    detector.clearCache()
    #expect(detector.isESM(path: subDir + "/test.js") == true)
}
