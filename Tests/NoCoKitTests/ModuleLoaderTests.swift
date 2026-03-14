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

// MARK: - package.json exports "node" condition

@Test func requirePackageExportsNodeConditionMain() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath()
    let tmp = fixturePath + "/__test_\(UUID().uuidString).js"
    try "module.exports = require('mock-node-exports-pkg').name;".write(
        toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let result = runtime.moduleLoader.loadFile(at: tmp)
    // Should resolve via "node" condition, not "default"
    #expect(result.toString() == "node-main")
}

@Test func requirePackageExportsNodeConditionSubpath() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath()
    let tmp = fixturePath + "/__test_\(UUID().uuidString).js"
    try "module.exports = require('mock-node-exports-pkg/utils').name;".write(
        toFile: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let result = runtime.moduleLoader.loadFile(at: tmp)
    #expect(result.toString() == "node-utils")
}

// MARK: - node: prefix support

@Test func requireNodePrefixPath() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('node:path').join('a', 'b')")
    #expect(result?.toString() == "a/b")
}

@Test func requireNodePrefixCrypto() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('node:crypto').createHash('sha256').update('test').digest('hex')
    """)
    #expect(result?.toString() == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
}

@Test func requireNodePrefixSameAsWithout() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var p1 = require('path');
        var p2 = require('node:path');
        p1 === p2;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Shebang handling

@Test func requireShebangModule() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/shebang_module.js"
    let result = runtime.evaluate("require('\(fixturePath)').value")
    #expect(result?.toString() == "shebang_works")
}

@Test func evaluateFileWithShebang() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    let tmpPath = NSTemporaryDirectory() + "noco_shebang_test_\(UUID().uuidString).js"
    defer { try? FileManager.default.removeItem(atPath: tmpPath) }
    try "#!/usr/bin/env node\nconsole.log('shebang_exec');".write(
        toFile: tmpPath, atomically: true, encoding: .utf8)

    try runtime.evaluateFile(at: tmpPath)
    #expect(messages.contains(where: { $0.1 == "shebang_exec" }))
}

@Test func shebangPreservesLineNumbers() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/shebang_error.js"

    let result = runtime.evaluate("""
        try {
            require('\(fixturePath)');
        } catch(e) {
            e.line;
        }
    """)
    // CommonJSラッパーで1行追加されるため、ファイル上の3行目 → e.line は4
    #expect(result?.toInt32() == 4)
}

@Test func requireShebangCRLF() async throws {
    let runtime = NodeRuntime()
    let fixturePath = fixturesPath() + "/shebang_crlf.js"
    let result = runtime.evaluate("require('\(fixturePath)').value")
    #expect(result?.toString() == "crlf_works")
}

@Test func stripShebangUnit() async throws {
    // shebangなし → そのまま返す
    #expect(ModuleLoader.stripShebang("console.log('hi')") == "console.log('hi')")

    // shebang付き → コメント化
    let result = ModuleLoader.stripShebang("#!/usr/bin/env node\nconsole.log('hi')")
    #expect(result == "///usr/bin/env node\nconsole.log('hi')")

    // CRLF
    let crlf = ModuleLoader.stripShebang("#!/usr/bin/env node\r\nconsole.log('hi')")
    #expect(crlf == "///usr/bin/env node\r\nconsole.log('hi')")

    // shebangのみ（改行なし）
    let only = ModuleLoader.stripShebang("#!/usr/bin/env node")
    #expect(only == "///usr/bin/env node")
}

// MARK: - Symlink realpath resolution

@Test func requireViaSymlinkResolvesDirname() async throws {
    let fm = FileManager.default
    let tmpBase = NSTemporaryDirectory() + "noco_symlink_test_\(UUID().uuidString)"
    let realDir = tmpBase + "/real"
    let linkDir = tmpBase + "/links"
    defer { try? fm.removeItem(atPath: tmpBase) }

    // real/lib.js — require('../lib.js') からの相対パスが実体基準で解決されることを確認
    try fm.createDirectory(atPath: realDir, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: linkDir, withIntermediateDirectories: true)

    // real/helper.js
    try "module.exports = { value: 'from_helper' };".write(
        toFile: realDir + "/helper.js", atomically: true, encoding: .utf8)

    // real/main.js — 相対パスで helper.js を require
    try "module.exports = require('./helper').value;".write(
        toFile: realDir + "/main.js", atomically: true, encoding: .utf8)

    // links/main.js → real/main.js へのシンボリックリンク
    try fm.createSymbolicLink(
        atPath: linkDir + "/main.js",
        withDestinationPath: realDir + "/main.js")

    let runtime = NodeRuntime()
    // シンボリックリンク経由でrequire — __dirnameがrealDirになり、./helperが正しく解決される
    let result = runtime.moduleLoader.loadFile(at: linkDir + "/main.js")
    #expect(result.toString() == "from_helper")
}

@Test func requireViaSymlinkDirnameIsRealPath() async throws {
    let fm = FileManager.default
    let tmpBase = NSTemporaryDirectory() + "noco_symlink_dirname_\(UUID().uuidString)"
    let realDir = tmpBase + "/real"
    let linkDir = tmpBase + "/links"
    defer { try? fm.removeItem(atPath: tmpBase) }

    try fm.createDirectory(atPath: realDir, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: linkDir, withIntermediateDirectories: true)

    // real/check.js — __dirname を返す
    try "module.exports = __dirname;".write(
        toFile: realDir + "/check.js", atomically: true, encoding: .utf8)

    // links/check.js → real/check.js
    try fm.createSymbolicLink(
        atPath: linkDir + "/check.js",
        withDestinationPath: realDir + "/check.js")

    let runtime = NodeRuntime()
    let result = runtime.moduleLoader.loadFile(at: linkDir + "/check.js")
    let resolvedRealDir = (realDir as NSString).resolvingSymlinksInPath
    #expect(result.toString() == resolvedRealDir)
}
