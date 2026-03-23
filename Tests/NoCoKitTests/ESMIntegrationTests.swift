import Foundation
import Testing
@testable import NoCoKit

private func fixtureDir() -> String {
    // Locate the Fixtures/esm directory relative to the test file
    let thisFile = #filePath
    let testsDir = (thisFile as NSString).deletingLastPathComponent
    return (testsDir as NSString).appendingPathComponent("Fixtures/esm")
}

// MARK: - Basic ESM Loading

@Test func loadMjsBasic() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/basic.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0.contains("basic:hello:a/b") }))
}

@Test func loadMjsDefaultExport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/import-default.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0.contains("Hello, World") }))
}

// MARK: - Live Bindings

@Test func liveBindingViaNamespace() async throws {
    // Live bindings work when accessed through the namespace object (getter)
    // Note: destructured imports (var { count } = ...) copy the value at import time
    let runtime = NodeRuntime()
    let path = fixtureDir() + "/live-binding.mjs"
    let ns = runtime.moduleLoader.loadFile(at: path)

    let before = ns.forProperty("count")?.toInt32()
    #expect(before == 0)

    ns.forProperty("increment")?.call(withArguments: [])

    let after = ns.forProperty("count")?.toInt32()
    #expect(after == 1)
}

// MARK: - Namespace Import

@Test func namespaceImportBuiltin() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/namespace.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0 == "function" }))
}

// MARK: - import.meta

@Test func importMetaUrl() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/import-meta.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0.hasPrefix("url:file://") }))
    #expect(messages.contains(where: { $0.hasPrefix("dirname:") }))
    #expect(messages.contains(where: { $0.hasPrefix("filename:") && $0.hasSuffix("import-meta.mjs") }))
}

// MARK: - ESM → CJS Interop

@Test func esmImportCjs() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/import-cjs.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0 == "default:42" }))
    #expect(messages.contains(where: { $0 == "named:42" }))
}

// MARK: - Re-exports

@Test func reExportNamed() async throws {
    let runtime = NodeRuntime()
    let path = fixtureDir() + "/re-export.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    let greeting = exports.forProperty("greeting")?.toString()
    let sum = exports.forProperty("sum")
    #expect(greeting == "hello")
    #expect(sum?.call(withArguments: [2, 3])?.toInt32() == 5)
}

@Test func reExportStar() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/re-export-star.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    let greeting = exports.forProperty("greeting")?.toString()
    #expect(greeting == "hello")
}

// MARK: - Export Class

@Test func exportClass() async throws {
    let runtime = NodeRuntime()
    let path = fixtureDir() + "/export-class.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    let result = runtime.evaluate("""
        var MyClass = require('\(path)').MyClass;
        var obj = new MyClass('Test');
        obj.greet();
    """)
    #expect(result?.toString() == "Hello, Test")
}

// MARK: - CJS require ESM

@Test func cjsRequireEsm() async throws {
    let runtime = NodeRuntime()
    let esmPath = fixtureDir() + "/basic.mjs"

    let result = runtime.evaluate("""
        var mod = require('\(esmPath)');
        mod.greeting;
    """)
    #expect(result?.toString() == "hello")
}

// MARK: - Dynamic import()

@Test func dynamicImportFromCjs() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/dynamic-import.cjs"
    runtime.moduleLoader.loadFile(at: path)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains(where: { $0 == "dynamic:hello" }))
}

// MARK: - Builtin ESM Imports

@Test func esmImportBuiltinFs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        (function() {
            var m = __esm_import('fs', '/tmp');
            return typeof m.readFileSync;
        })()
    """)
    #expect(result?.toString() == "function")
}

@Test func esmImportBuiltinWithNodePrefix() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        (function() {
            var m = __esm_import('node:path', '/tmp');
            return typeof m.join;
        })()
    """)
    #expect(result?.toString() == "function")
}

// MARK: - file:// URL Import

@Test func esmImportFileUrl() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "noco_test_esm_fileurl_\(UUID().uuidString).mjs"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    try "exports.answer = 42;".write(toFile: tmpPath, atomically: true, encoding: .utf8)

    let fileUrl = "file://\(tmpPath)"
    let result = runtime.evaluate("""
        (function() {
            var m = __esm_import('\(fileUrl)', '/tmp');
            return m.answer;
        })()
    """)
    #expect(result?.toInt32() == 42)
}

@Test func esmImportFileUrlWithSpaces() async throws {
    let runtime = NodeRuntime()
    let dir = NSTemporaryDirectory() + "noco test spaces \(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmpPath = dir + "/mod.js"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    try "exports.val = 'ok';".write(toFile: tmpPath, atomically: true, encoding: .utf8)

    // file:// URLs encode spaces as %20
    let fileUrl = URL(fileURLWithPath: tmpPath).absoluteString
    let result = runtime.evaluate("""
        (function() {
            var m = __esm_import('\(fileUrl)', '/tmp');
            return m.val;
        })()
    """)
    #expect(result?.toString() == "ok")
}

@Test func dynamicImportFileUrl() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let tmpPath = NSTemporaryDirectory() + "noco_test_dyn_fileurl_\(UUID().uuidString).mjs"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }

    try "exports.x = 99;".write(toFile: tmpPath, atomically: true, encoding: .utf8)

    let fileUrl = URL(fileURLWithPath: tmpPath).absoluteString
    runtime.evaluate("""
        __importDynamic('\(fileUrl)', '/tmp').then(function(m) {
            console.log('val:' + m.x);
        });
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("val:99"))
}

// MARK: - Top-Level Await

@Test func topLevelAwaitDynamicImport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/tla-basic.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains(where: { $0 == "tla:hello" }))
}

@Test func topLevelAwaitValue() async throws {
    let runtime = NodeRuntime()
    let path = fixtureDir() + "/tla-value.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    let value = exports.forProperty("value")?.toInt32()
    #expect(value == 42)
}

@Test func topLevelAwaitStaticImport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/tla-import-chain.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains("chain:99"))
    let value = exports.forProperty("value")?.toInt32()
    #expect(value == 99)
}

@Test func topLevelAwaitMultiImport() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/tla-multi-chain.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains("multi:99:hello"))
}

@Test func topLevelAwaitReexport() async throws {
    let runtime = NodeRuntime()
    let path = fixtureDir() + "/tla-reexport.mjs"
    let exports = runtime.moduleLoader.loadFile(at: path)

    let value = exports.forProperty("value")?.toInt32()
    #expect(value == 99)
}

// MARK: - Many Named Imports (excluded ranges regression)

@Test func manyNamedImportsThenDefault() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/many-imports-then-default.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains("many-imports:v1:v16:function"))
}

// MARK: - const require redefinition in ESM

@Test func esmConstRequireRedefinition() async throws {
    // Bundlers like esbuild emit `const require = createRequire(import.meta.url)` in ESM files.
    // The CJS wrapper must not shadow `require` as a parameter for ESM files,
    // otherwise `const require` causes a SyntaxError (duplicate lexical declaration).
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/const-require.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains("const-require:a/b"))
}

@Test func esmConstRequireSameLine() async throws {
    // Same pattern but import and const on the same line (common in minified output)
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let path = fixtureDir() + "/const-require-sameline.mjs"
    runtime.moduleLoader.loadFile(at: path)

    #expect(messages.contains("sameline:function"))
}
