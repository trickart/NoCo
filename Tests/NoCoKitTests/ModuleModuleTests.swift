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

// MARK: - wrap / wrapper

@Test func moduleWrap() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        m.wrap('x = 1');
    """)
    #expect(result?.toString() == "(function (exports, require, module, __filename, __dirname) { x = 1\n});")
}

@Test func moduleWrapper() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            isArray: Array.isArray(m.wrapper),
            len: m.wrapper.length,
            hasPrefix: m.wrapper[0].indexOf('(function') >= 0
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isArray\":true"))
    #expect(json.contains("\"len\":2"))
    #expect(json.contains("\"hasPrefix\":true"))
}

@Test func moduleWrapOnModuleConstructor() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        m.Module.wrap('x') === m.wrap('x');
    """)
    #expect(result?.toBool() == true)
}

// MARK: - _findPath

@Test func moduleFindPathExistingFile() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var fs = require('fs');
        var path = require('path');
        var tmpDir = '/tmp/noco_findpath_test_' + Date.now();
        fs.mkdirSync(tmpDir, { recursive: true });
        fs.writeFileSync(path.join(tmpDir, 'hello.js'), 'module.exports = 1;');
        var found = m.Module._findPath(path.join(tmpDir, 'hello'), []);
        fs.unlinkSync(path.join(tmpDir, 'hello.js'));
        fs.rmdirSync(tmpDir);
        found;
    """)
    let r = result?.toString() ?? ""
    #expect(r.contains("hello.js"))
}

@Test func moduleFindPathNotFound() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        m.Module._findPath('/nonexistent/path/xyz', []);
    """)
    #expect(result?.toBool() == false)
}

@Test func moduleFindPathWithPaths() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var fs = require('fs');
        var path = require('path');
        var tmpDir = '/tmp/noco_findpath_paths_' + Date.now();
        fs.mkdirSync(tmpDir, { recursive: true });
        fs.writeFileSync(path.join(tmpDir, 'mylib.js'), '1');
        var found = m.Module._findPath('mylib', [tmpDir]);
        fs.unlinkSync(path.join(tmpDir, 'mylib.js'));
        fs.rmdirSync(tmpDir);
        found;
    """)
    let r = result?.toString() ?? ""
    #expect(r.contains("mylib.js"))
}

// MARK: - _resolveLookupPaths

@Test func moduleResolveLookupPathsRelative() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var paths = m.Module._resolveLookupPaths('./foo', { filename: '/usr/local/test.js' });
        JSON.stringify(paths);
    """)
    #expect(result?.toString() == "[\"/usr/local\"]")
}

@Test func moduleResolveLookupPathsPackage() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var paths = m.Module._resolveLookupPaths('lodash', { filename: '/usr/local/test.js' });
        Array.isArray(paths) && paths.length > 0 && paths[0].indexOf('node_modules') >= 0;
    """)
    #expect(result?.toBool() == true)
}

@Test func moduleResolveLookupPathsBuiltin() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        m.Module._resolveLookupPaths('fs', null);
    """)
    #expect(result?.isNull == true)
}

// MARK: - findPackageJSON

@Test func moduleFindPackageJSON() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var fs = require('fs');
        var path = require('path');
        var tmpDir = '/tmp/noco_findpkg_' + Date.now();
        var subDir = path.join(tmpDir, 'a', 'b');
        fs.mkdirSync(subDir, { recursive: true });
        fs.writeFileSync(path.join(tmpDir, 'package.json'), '{"name":"test"}');
        var found = m.Module.findPackageJSON(subDir);
        fs.unlinkSync(path.join(tmpDir, 'package.json'));
        fs.rmdirSync(path.join(tmpDir, 'a', 'b'));
        fs.rmdirSync(path.join(tmpDir, 'a'));
        fs.rmdirSync(tmpDir);
        found;
    """)
    let r = result?.toString() ?? ""
    #expect(r.contains("package.json"))
}

@Test func moduleFindPackageJSONNotFound() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var r = m.Module.findPackageJSON('/nonexistent/deep/path');
        r === undefined;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - globalPaths

@Test func moduleGlobalPaths() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            isArray: Array.isArray(m.Module.globalPaths),
            topLevel: Array.isArray(m.globalPaths),
            hasNodeModules: m.Module.globalPaths.some(function(p) { return p.indexOf('.node_modules') >= 0; })
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isArray\":true"))
    #expect(json.contains("\"topLevel\":true"))
    #expect(json.contains("\"hasNodeModules\":true"))
}

// MARK: - stripTypeScriptTypes

@Test func moduleStripTypeScriptTypes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        m.Module.stripTypeScriptTypes('const x: number = 1');
    """)
    let r = result?.toString() ?? ""
    #expect(r.contains("const x"))
    #expect(r.contains("= 1"))
    #expect(!r.contains(": number"))
}

// MARK: - constants

@Test func moduleConstants() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            val: m.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER,
            moduleVal: m.Module.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"val\":0"))
    #expect(json.contains("\"moduleVal\":0"))
}

// MARK: - Stub APIs

@Test func moduleStubAPIs() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            syncBuiltinESMExports: typeof m.Module.syncBuiltinESMExports,
            enableCompileCache: typeof m.Module.enableCompileCache,
            getCompileCacheDir: typeof m.Module.getCompileCacheDir,
            flushCompileCache: typeof m.Module.flushCompileCache,
            findSourceMap: typeof m.Module.findSourceMap,
            SourceMap: typeof m.Module.SourceMap,
            _initPaths: typeof m.Module._initPaths,
            _preloadModules: typeof m.Module._preloadModules
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"syncBuiltinESMExports\":\"function\""))
    #expect(json.contains("\"enableCompileCache\":\"function\""))
    #expect(json.contains("\"getCompileCacheDir\":\"function\""))
    #expect(json.contains("\"flushCompileCache\":\"function\""))
    #expect(json.contains("\"findSourceMap\":\"function\""))
    #expect(json.contains("\"SourceMap\":\"function\""))
    #expect(json.contains("\"_initPaths\":\"function\""))
    #expect(json.contains("\"_preloadModules\":\"function\""))
}

// MARK: - registerHooks / register

@Test func moduleRegisterHooksIsFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        JSON.stringify({
            registerHooks: typeof m.registerHooks,
            moduleRegisterHooks: typeof m.Module.registerHooks,
            register: typeof m.register,
            moduleRegister: typeof m.Module.register,
            setSourceMapsSupport: typeof m.setSourceMapsSupport
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"registerHooks\":\"function\""))
    #expect(json.contains("\"moduleRegisterHooks\":\"function\""))
    #expect(json.contains("\"register\":\"function\""))
    #expect(json.contains("\"moduleRegister\":\"function\""))
    #expect(json.contains("\"setSourceMapsSupport\":\"function\""))
}

@Test func moduleRegisterHooksAcceptsHooks() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var resolvedSpecs = [];
        m.registerHooks({
            resolve: function(specifier, context, nextResolve) {
                resolvedSpecs.push(specifier);
                return nextResolve(specifier, context);
            }
        });
        require('path');
        // ビルトインは Swift 側で直接処理されるため、ファイルモジュール解決のみフックが呼ばれる
        // registerHooks がクラッシュしないことを確認
        true;
    """)
    #expect(result?.toBool() == true)
}

@Test func moduleEnableCompileCacheReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var m = require('module');
        var r = m.Module.enableCompileCache();
        JSON.stringify({ status: r.status, hasDir: typeof r.directory === 'string' });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"status\":2"))
    #expect(json.contains("\"hasDir\":true"))
}
