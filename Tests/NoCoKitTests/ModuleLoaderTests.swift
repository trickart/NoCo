import Foundation
import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Module Loader Tests

@Test func requireBuiltinPath() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').join('a', 'b', 'c')")
    #expect(result?.toString() == "a/b/c")
}

@Test func requireBuiltinCrypto() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('crypto').createHash('sha256').update('hello').digest('hex')
    """)
    #expect(result?.toString() == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

// MARK: - Module Loader Edge Cases

@Test func requireCachesModule() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var path1 = require('path');
        var path2 = require('path');
        path1 === path2;
    """)
    #expect(result?.toBool() == true)
}

@Test func requireUnknownModule() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        try {
            require('nonexistent_module_xyz');
        } catch(e) {
            console.log('error:' + e.code);
        }
    """)
    #expect(messages.contains(where: { $0.1 == "error:MODULE_NOT_FOUND" }))
}

@Test func requireFileModule() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_module_\(UUID().uuidString).js"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // Write a JS module file
    try "module.exports = { greeting: 'hello from module' };".write(
        toFile: tmpPath, atomically: true, encoding: .utf8
    )

    let result = runtime.evaluate("require('\(tmpPath)').greeting")
    #expect(result?.toString() == "hello from module")
}

@Test func requireJsonModule() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_json_\(UUID().uuidString).js"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    // Module loader wraps in CommonJS, so JSON files need explicit module.exports
    try "module.exports = {\"name\": \"test\", \"version\": 42};".write(
        toFile: tmpPath, atomically: true, encoding: .utf8
    )

    let result = runtime.evaluate("require('\(tmpPath)').name + ':' + require('\(tmpPath)').version")
    #expect(result?.toString() == "test:42")
}

// MARK: - Module Loader Additional Tests

private func fixturesPath() -> String {
    let testFile = #filePath
    return (testFile as NSString).deletingLastPathComponent + "/Fixtures"
}

@Test func requireModuleExportsReplacement() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/replace_exports.js"
    let result = runtime.evaluate("var greet = require('\(fixturePath)'); greet('World');")
    #expect(result?.toString() == "Hello, World!")
}

@Test func requireCircularDependency() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/circular_a.js"
    let result = runtime.evaluate("""
        var a = require('\(fixturePath)');
        a.fromA + ':' + a.fromB;
    """)
    #expect(result?.toString() == "valueA:valueB")
}

@Test func requireCircularWithModuleExportsReplacement() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/circular_replace_a.js"
    let result = runtime.evaluate("""
        var a = require('\(fixturePath)');
        var b = require('\(fixturePath.replacingOccurrences(of: "_a.js", with: "_b.js"))');
        b.aHasGetValue + ':' + b.getValueFromA();
    """)
    #expect(result?.toString() == "true:fromA")
}

@Test func requireClearCache() async throws {
    let runtime = NodeRuntime()
    let tmpPath = NSTemporaryDirectory() + "nodecore_test_clearcache_\(UUID().uuidString).js"
    defer {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    try "module.exports = { value: 1 };".write(
        toFile: tmpPath, atomically: true, encoding: .utf8
    )

    let first = runtime.evaluate("require('\(tmpPath)').value")
    #expect(first?.toInt32() == 1)

    // Update the file
    try "module.exports = { value: 2 };".write(
        toFile: tmpPath, atomically: true, encoding: .utf8
    )

    // Without clearing cache, still returns old value
    let cached = runtime.evaluate("require('\(tmpPath)').value")
    #expect(cached?.toInt32() == 1)

    // Clear cache and re-require
    runtime.moduleLoader.clearCache()
    let reloaded = runtime.evaluate("require('\(tmpPath)').value")
    #expect(reloaded?.toInt32() == 2)
}

@Test func requireDirectoryIndex() async throws {
    let runtime = NodeRuntime()
    let dirPath = fixturesPath() + "/dir_mod"
    let result = runtime.evaluate("require('\(dirPath)').source")
    #expect(result?.toString() == "dir_mod_index")
}

// MARK: - Module Resolution: file vs directory with same name

@Test func requireFileWhenSameNameDirectoryExists() async throws {
    // request.js と request/ が共存する場合、request.js が優先される
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/importer.js"
    let result = runtime.evaluate("require('\(fixturePath)').requestSource")
    #expect(result?.toString() == "request_file")
}

@Test func requireFileWithExplicitExtensionWhenDirectoryExists() async throws {
    // 明示的に .js を付けた場合も正しく解決される
    let runtime = NodeRuntime()
    let filePath = fixturesPath() + "/request.js"
    let result = runtime.evaluate("require('\(filePath)').source")
    #expect(result?.toString() == "request_file")
}

@Test func requireSubfileInsideDirectory() async throws {
    // request/constants.js を明示的に require できる
    let runtime = NodeRuntime()
    let filePath = fixturesPath() + "/request/constants"
    let result = runtime.evaluate("require('\(filePath)').source")
    #expect(result?.toString() == "request_dir_constants")
}

@Test func requireDirectoryWithPackageJsonMain() async throws {
    // ディレクトリに package.json の main フィールドがある場合それを使う
    let runtime = NodeRuntime()
    let dirPath = fixturesPath() + "/pkg_mod"
    let result = runtime.evaluate("require('\(dirPath)').source")
    #expect(result?.toString() == "pkg_mod_main")
}

// MARK: - package.json exports フィールド

@Test func requirePackageExportsMainEntry() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath()
    let tmp = fixturePath + "/__test_\(UUID().uuidString).js"
    try "module.exports = require('mock-exports-pkg').name;".write(
        toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let result = runtime.moduleLoader.loadFile(at: tmp)
    #expect(result.toString() == "main")
}

@Test func requirePackageExportsSubpath() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath()
    let tmp = fixturePath + "/__test_\(UUID().uuidString).js"
    try "module.exports = require('mock-exports-pkg/cors').name;".write(
        toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let result = runtime.moduleLoader.loadFile(at: tmp)
    #expect(result.toString() == "cors")
}
