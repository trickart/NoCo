import Testing
import JavaScriptCore
@testable import NoCoKit

@Test func moduleRequireReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('module')")
    #expect(result?.toString() == "object")
}

@Test func moduleNodePrefixRequire() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('node:module')")
    #expect(result?.toString() == "object")
}

@Test func moduleCreateRequireReturnsFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        typeof m.createRequire;
    """)
    #expect(result?.toString() == "function")
}

@Test func moduleCreateRequireReturnsRequire() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var req = m.createRequire('/tmp/test.js');
        req === require;
    """)
    #expect(result?.toBool() == true)
}

@Test func moduleCreateRequireFromPathReturnsRequire() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var req = m.createRequireFromPath('/tmp/test.js');
        req === require;
    """)
    #expect(result?.toBool() == true)
}

@Test func moduleBuiltinModulesIsArray() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        Array.isArray(m.builtinModules);
    """)
    #expect(result?.toBool() == true)
}

@Test func moduleBuiltinModulesContainsExpectedEntries() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var b = m.builtinModules;
        JSON.stringify([
            b.indexOf('fs') >= 0,
            b.indexOf('path') >= 0,
            b.indexOf('http') >= 0,
            b.indexOf('events') >= 0
        ]);
    """)
    #expect(result?.toString() == "[true,true,true,true]")
}

@Test func moduleModuleConstructor() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var mod = new m.Module('/tmp/test.js');
        JSON.stringify({
            id: mod.id,
            loaded: mod.loaded,
            hasExports: typeof mod.exports === 'object'
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"id\":\"/tmp/test.js\""))
    #expect(json.contains("\"loaded\":false"))
    #expect(json.contains("\"hasExports\":true"))
}

@Test func moduleNodeModulePaths() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var paths = m.Module._nodeModulePaths('/usr/local/lib');
        JSON.stringify(paths);
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("/usr/local/lib/node_modules"))
    #expect(json.contains("/usr/local/node_modules"))
    #expect(json.contains("/usr/node_modules"))
}

@Test func moduleNodeModulePathsSkipsNodeModulesSegment() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var paths = m.Module._nodeModulePaths('/foo/node_modules/bar');
        var hasDoubleNodeModules = paths.some(function(p) {
            return p.indexOf('node_modules/node_modules') >= 0;
        });
        hasDoubleNodeModules;
    """)
    #expect(result?.toBool() == false)
}

@Test func moduleCacheAndPathCacheExist() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            hasCache: typeof m._cache === 'object',
            hasPathCache: typeof m._pathCache === 'object'
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"hasCache\":true"))
    #expect(json.contains("\"hasPathCache\":true"))
}

@Test func modulePrototypeCompileExists() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        typeof m.Module.prototype._compile;
    """)
    #expect(result?.toString() == "function")
}
