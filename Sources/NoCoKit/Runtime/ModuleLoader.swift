import Foundation
import JavaScriptCore

/// Implements CommonJS `require()` resolution and loading.
/// Resolution order: builtin modules → cache → file system.
public final class ModuleLoader {
    private weak var runtime: NodeRuntime?
    private var moduleCache: [String: JSValue] = [:]
    private var loadingModules: [String: JSValue] = [:]
    private var loadFileDepth: Int = 0
    private var resolveHooks: [JSValue] = []
    private var loadHooks: [JSValue] = []

    init(runtime: NodeRuntime) {
        self.runtime = runtime
        installRequire()
    }

    /// module.registerHooks() から呼ばれる。resolve/load フックを登録する。
    func registerModuleHooks(resolve: JSValue?, load: JSValue?) {
        if let resolve = resolve, !resolve.isUndefined {
            resolveHooks.append(resolve)
        }
        if let load = load, !load.isUndefined {
            loadHooks.append(load)
        }
    }

    private func installRequire() {
        guard let runtime = runtime else { return }
        let context = runtime.context

        let requireBlock: @convention(block) (String) -> JSValue = { [weak self] moduleName in
            guard let self = self else {
                return JSValue(undefinedIn: JSContext.current())
            }
            return self.require(moduleName)
        }

        context.setObject(
            unsafeBitCast(requireBlock, to: AnyObject.self),
            forKeyedSubscript: "require" as NSString
        )

        // require.resolve(id) — resolve module path without loading
        let resolveBlock: @convention(block) (String) -> JSValue = { [weak self] moduleName in
            guard let self = self, let runtime = self.runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let ctx = JSContext.current()!

            let name = moduleName.hasPrefix("node:") ? String(moduleName.dropFirst(5)) : moduleName

            // Builtin modules resolve to their name
            if runtime.registeredModules[name] != nil || ["process", "console"].contains(name) {
                return JSValue(object: name, in: ctx)
            }

            if let path = self.resolveFilePath(name) {
                return JSValue(object: path, in: ctx)
            }

            ctx.exception = ctx.evaluateScript(
                "new Error('Cannot find module \\'" + name.replacingOccurrences(of: "'", with: "\\'") + "\\'')"
            )
            return JSValue(undefinedIn: ctx)
        }

        // require.resolve.paths(request) — return search paths
        let resolvePathsBlock: @convention(block) (String) -> JSValue = { _ in
            let ctx = JSContext.current()!
            let cwd = FileManager.default.currentDirectoryPath
            let result = JSValue(newArrayIn: ctx)!
            var paths: [String] = []
            var dir = cwd
            while true {
                let nmDir = (dir as NSString).appendingPathComponent("node_modules")
                paths.append(nmDir)
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
            for (i, p) in paths.enumerated() {
                result.setValue(p, at: i)
            }
            return result
        }

        // Build require as a callable with .resolve and .resolve.paths
        context.evaluateScript("""
            (function(req, resolve, resolvePaths) {
                req.resolve = resolve;
                req.resolve.paths = resolvePaths;
                req.cache = {};
                req.main = undefined;
            })
        """)!.call(withArguments: [
            context.objectForKeyedSubscript("require" as NSString)!,
            unsafeBitCast(resolveBlock, to: AnyObject.self),
            unsafeBitCast(resolvePathsBlock, to: AnyObject.self),
        ])
    }

    /// Resolve and load a module by name.
    func require(_ moduleName: String) -> JSValue {
        guard let runtime = runtime else {
            return JSValue(undefinedIn: JSContext.current())
        }

        // Strip "node:" prefix (e.g. require('node:path') → require('path'))
        let resolvedName: String
        if moduleName.hasPrefix("node:") {
            resolvedName = String(moduleName.dropFirst(5))
        } else {
            resolvedName = moduleName
        }

        // 0. Global modules accessible via require (process, console, etc.)
        let globalModules = ["process", "console"]
        if globalModules.contains(resolvedName) {
            if let cached = moduleCache[resolvedName] {
                return cached
            }
            let value = runtime.context.objectForKeyedSubscript(resolvedName as NSString)!
            moduleCache[resolvedName] = value
            return value
        }

        // 1. Check builtin modules (including subpath like 'fs/promises')
        if let moduleType = runtime.registeredModules[resolvedName] {
            if let cached = moduleCache[resolvedName] {
                return cached
            }
            let exports = moduleType.install(in: runtime.context, runtime: runtime)
            moduleCache[resolvedName] = exports

            // Attach fs.promises property for Node.js compatibility
            if resolvedName == "fs" {
                let promises = createPromisifiedFS(exports, context: runtime.context)
                exports.setValue(promises, forProperty: "promises")
                moduleCache["fs/promises"] = promises
            }

            return exports
        }

        // 1b. Handle builtin subpath modules (e.g., 'fs/promises', 'timers/promises')
        if resolvedName.contains("/") {
            // Check if the full subpath is registered as its own module
            if let subpathModule = runtime.registeredModules[resolvedName] {
                if let cached = moduleCache[resolvedName] {
                    return cached
                }
                let exports = subpathModule.install(in: runtime.context, runtime: runtime)
                moduleCache[resolvedName] = exports
                return exports
            }

            let parts = resolvedName.split(separator: "/", maxSplits: 1)
            let baseName = String(parts[0])
            let subPath = String(parts[1])
            if let moduleType = runtime.registeredModules[baseName] {
                let cacheKey = resolvedName
                if let cached = moduleCache[cacheKey] {
                    return cached
                }
                // Install the base module first
                let base = moduleType.install(in: runtime.context, runtime: runtime)
                // Try to get the subpath property
                if subPath == "promises" {
                    // Create promisified version
                    let promises = createPromisifiedFS(base, context: runtime.context)
                    moduleCache[cacheKey] = promises
                    return promises
                }
                if let sub = base.forProperty(subPath), !sub.isUndefined {
                    moduleCache[cacheKey] = sub
                    return sub
                }
                // Fallback: return base module
                moduleCache[cacheKey] = base
                return base
            }
        }

        // 2. Check cache
        if let cached = moduleCache[resolvedName] {
            return cached
        }

        // 3. Resolve via hooks or file path
        let cwd = FileManager.default.currentDirectoryPath
        if let hookResult = callResolveHooks(specifier: resolvedName, parentURL: "file://\(cwd)/", fromDir: cwd) {
            switch hookResult {
            case .filePath(let path):
                return loadFile(at: path)
            case .builtin(let name):
                return self.require(name)
            }
        }

        let resolvedPath = resolveFilePath(resolvedName)

        guard let path = resolvedPath else {
            let error = runtime.context.createError(
                "Cannot find module '\(moduleName)'", code: "MODULE_NOT_FOUND")
            runtime.context.exception = error
            return JSValue(undefinedIn: runtime.context)
        }

        return loadFile(at: path)
    }

    /// Load a JS file (or JSON file) as a CommonJS module.
    @discardableResult
    public func loadFile(at path: String) -> JSValue {
        // シンボリックリンクを実体パスに解決（Node.js互換: __dirname/__filenameは実体基準）
        let path = (path as NSString).resolvingSymlinksInPath

        guard let runtime = runtime else {
            return JSValue(undefinedIn: JSContext.current())
        }

        loadFileDepth += 1
        defer { loadFileDepth -= 1 }

        // Check cache by absolute path
        if let cached = moduleCache[path] {
            return cached
        }

        // 循環 require: module.exports の現在値を返す
        if let loadingModule = loadingModules[path] {
            return loadingModule.forProperty("exports")
        }

        // Handle .node native addons
        if path.hasSuffix(".node") {
            if let exports = NAPIModule.load(path: path, context: runtime.context, runtime: runtime) {
                loadingModules.removeValue(forKey: path)
                moduleCache[path] = exports
                return exports
            }
            loadingModules.removeValue(forKey: path)
            return JSValue(undefinedIn: runtime.context)
        }

        // load フック実行
        let source: String
        let fileURL = "file://\(path)"
        if let hookResult = callLoadHooks(url: fileURL, path: path) {
            source = hookResult.source
        } else {
            guard let fileSource = try? String(contentsOfFile: path, encoding: .utf8) else {
                let error = runtime.context.createError(
                    "Cannot read module '\(path)'", code: "MODULE_NOT_FOUND")
                runtime.context.exception = error
                return JSValue(undefinedIn: runtime.context)
            }
            source = fileSource
        }

        // Handle JSON files natively
        if path.hasSuffix(".json") {
            let context = runtime.context
            let result = context.evaluateScript("(\(source))")!
            moduleCache[path] = result
            return result
        }

        let context = runtime.context
        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setValue(exports, forProperty: "exports")
        module.setValue(path, forProperty: "filename")
        module.setValue((path as NSString).deletingLastPathComponent, forProperty: "path")

        // Register as loading (handle circular requires via module.exports)
        loadingModules[path] = module

        let dirname = (path as NSString).deletingLastPathComponent

        // Shebang行をJSコメントに変換（行番号を維持）
        let strippedSource = Self.stripShebang(source)

        // TypeScriptファイルの場合、型注釈を削除
        let tsExtensions = ["ts", "mts", "cts"]
        let fileExt = (path as NSString).pathExtension.lowercased()
        let jsSource: String
        if tsExtensions.contains(fileExt) {
            jsSource = TypeScriptStripper.strip(strippedSource)
        } else {
            jsSource = strippedSource
        }

        // Transform source based on module type
        let transformedSource: String
        if ESMDetector.shared.isESM(path: path) {
            transformedSource = ESMTransformer.transform(jsSource)
        } else {
            transformedSource = ESMTransformer.transformDynamicImport(jsSource)
        }

        // ESM 静的インポートの事前ロード: モジュール実行前に TLA 依存を解決
        // evaluateScript("void 0") による microtask drain は JS コールバック内では動作しないため、
        // 純粋な Swift コンテキストでインポート先を事前にロード・drain しておく
        // TLA 事前ロード: ESM 静的インポート先のうち TLA を持つモジュールを事前に解決
        // depth 1（Swift コンテキスト）でのみ実行。depth > 1 では JS コールバック内のため drain 不可
        let isESM = ESMDetector.shared.isESM(path: path)
        if isESM && loadFileDepth == 1 {
            preloadStaticImports(source: jsSource, basedir: dirname, context: context)
        }

        // Wrap in CommonJS function (no leading newline to preserve line numbers)
        // ESM files may declare their own const __dirname/__filename (e.g. from import.meta.url),
        // which conflicts with wrapper parameters. Use unique names for ESM files.
        let wrapped: String
        let hasTLA = isESM && ESMTransformer.containsTopLevelAwait(jsSource)
        if isESM {
            if hasTLA {
                wrapped = "(async function(exports, __noco_require__, module, __noco_filename__, __noco_dirname__) {\(transformedSource)\n})"
            } else {
                wrapped = "(function(exports, __noco_require__, module, __noco_filename__, __noco_dirname__) {\(transformedSource)\n})"
            }
        } else {
            wrapped = "(function(exports, require, module, __filename, __dirname) {\(transformedSource)\n})"
        }

        guard let fn = context.evaluateScript(wrapped, withSourceURL: URL(fileURLWithPath: path))
        else {
            loadingModules.removeValue(forKey: path)
            return JSValue(undefinedIn: context)
        }

        let localRequireObj = makeLocalRequire(dirname: dirname, parentPath: path, context: context)

        let result = fn.call(withArguments: [
            exports,
            localRequireObj,
            module,
            path,
            dirname,
        ])

        // For top-level await modules, synchronously drain microtasks to resolve the Promise
        if hasTLA, let promise = result, !promise.isUndefined {
            if loadFileDepth == 1 {
                // トップレベル: microtask drain が動作する
                var settled = false
                var rejected = false
                var rejectionError: JSValue?

                let thenBlock: @convention(block) (JSValue) -> Void = { _ in
                    settled = true
                }
                let catchBlock: @convention(block) (JSValue) -> Void = { err in
                    settled = true
                    rejected = true
                    rejectionError = err
                }

                promise.invokeMethod("then", withArguments: [
                    unsafeBitCast(thenBlock, to: AnyObject.self),
                ])
                promise.invokeMethod("catch", withArguments: [
                    unsafeBitCast(catchBlock, to: AnyObject.self),
                ])

                // Drain microtasks (evaluateScript("void 0") flushes the JSC microtask queue)
                for _ in 0..<10 {
                    context.evaluateScript("void 0")
                    if settled { break }
                }

                if rejected, let err = rejectionError {
                    context.exception = err
                }
            } else {
                // ネストされた呼び出し: evaluateScript("void 0") による drain は
                // 外部の pending microtask を消費してしまうため使用しない。
                // module.exports の内容で TLA false positive を判定し、
                // 真の TLA は Promise をそのまま返す（__esm_import の thenable チェックが処理）。
                let currentExports = module.forProperty("exports")
                let hasContent: Bool
                if let exp = currentExports, exp.isObject {
                    let keys = context.objectForKeyedSubscript("Object" as NSString)!
                        .invokeMethod("keys", withArguments: [exp])!
                    hasContent = keys.forProperty("length")!.toInt32() > 1
                } else {
                    hasContent = false
                }

                if !hasContent {
                    // 真の TLA: Promise を返す（caller が chain する）
                    let exportsThenBlock: @convention(block) (JSValue) -> JSValue = { _ in
                        return module.forProperty("exports") ?? exports
                    }
                    let exportsPromise = promise.invokeMethod("then", withArguments: [
                        unsafeBitCast(exportsThenBlock, to: AnyObject.self),
                    ])!
                    loadingModules.removeValue(forKey: path)
                    moduleCache[path] = exportsPromise
                    return exportsPromise
                }
                // module.exports に内容があるなら TLA false positive — exports を使用
            }
        }

        // If an exception occurred during module loading, remove from loading
        // and let it propagate (don't log here — the top-level caller will).
        if context.exception != nil {
            loadingModules.removeValue(forKey: path)
            return JSValue(undefinedIn: context)
        }

        // Module might have replaced module.exports
        let finalExports = module.forProperty("exports") ?? exports
        loadingModules.removeValue(forKey: path)
        moduleCache[path] = finalExports
        return finalExports
    }

    /// Create a local `require` function that resolves relative to the given directory.
    /// Returns the require object (as AnyObject) with `.resolve` and `.resolve.paths` attached.
    private func makeLocalRequire(dirname: String, parentPath: String, context: JSContext) -> AnyObject {
        let parentURL = "file://\(parentPath)"
        let localRequire: @convention(block) (String) -> JSValue = { [weak self] name in
            guard let self = self else { return JSValue(undefinedIn: JSContext.current()) }

            // resolve フック実行
            if let hookResult = self.callResolveHooks(specifier: name, parentURL: parentURL, fromDir: dirname) {
                switch hookResult {
                case .filePath(let path):
                    return self.loadFile(at: path)
                case .builtin(let builtinName):
                    return self.require(builtinName)
                }
            }

            if name.hasPrefix("#") {
                if let resolved = self.resolvePrivateImport(name, from: dirname) {
                    return self.loadFile(at: resolved)
                }
            }
            if name.hasPrefix(".") || name.hasPrefix("/") {
                let resolved = self.resolveRelativePath(name, from: dirname)
                if let resolved = resolved {
                    return self.loadFile(at: resolved)
                }
            }
            if !name.hasPrefix(".") && !name.hasPrefix("/") {
                if let resolved = self.resolveNodeModules(name, from: dirname) {
                    return self.loadFile(at: resolved)
                }
            }
            return self.require(name)
        }

        let localResolveBlock: @convention(block) (String) -> JSValue = { [weak self] moduleName in
            guard let self = self, let runtime = self.runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let ctx = JSContext.current()!
            let reqName = moduleName.hasPrefix("node:") ? String(moduleName.dropFirst(5)) : moduleName

            if runtime.registeredModules[reqName] != nil || ["process", "console"].contains(reqName) {
                return JSValue(object: reqName, in: ctx)
            }

            if reqName.hasPrefix(".") || reqName.hasPrefix("/") {
                if let resolved = self.resolveRelativePath(reqName, from: dirname) {
                    return JSValue(object: resolved, in: ctx)
                }
            } else {
                if let resolved = self.resolveNodeModules(reqName, from: dirname) {
                    return JSValue(object: resolved, in: ctx)
                }
            }
            if let resolved = self.resolveFilePath(reqName) {
                return JSValue(object: resolved, in: ctx)
            }

            ctx.exception = ctx.evaluateScript(
                "new Error('Cannot find module \\'" + reqName.replacingOccurrences(of: "'", with: "\\'") + "\\'')"
            )
            return JSValue(undefinedIn: ctx)
        }

        let localResolvePathsBlock: @convention(block) (String) -> JSValue = { _ in
            let ctx = JSContext.current()!
            let result = JSValue(newArrayIn: ctx)!
            var paths: [String] = []
            var d = dirname
            while true {
                paths.append((d as NSString).appendingPathComponent("node_modules"))
                let parent = (d as NSString).deletingLastPathComponent
                if parent == d { break }
                d = parent
            }
            for (i, p) in paths.enumerated() {
                result.setValue(p, at: i)
            }
            return result
        }

        let localRequireObj = unsafeBitCast(localRequire, to: AnyObject.self)
        context.evaluateScript("""
            (function(req, resolve, resolvePaths) {
                req.resolve = resolve;
                req.resolve.paths = resolvePaths;
                req.cache = {};
                req.main = undefined;
            })
        """)!.call(withArguments: [
            localRequireObj,
            unsafeBitCast(localResolveBlock, to: AnyObject.self),
            unsafeBitCast(localResolvePathsBlock, to: AnyObject.self),
        ])

        return localRequireObj
    }

    /// Evaluate code in a CommonJS module context (for `node -e` equivalent).
    /// Provides `__dirname` (= cwd), `__filename` (= "[eval]"), `module`, `exports`, and local `require`.
    @discardableResult
    public func evaluateCode(_ code: String) -> JSValue? {
        guard let runtime = runtime else {
            return JSValue(undefinedIn: JSContext.current())
        }

        let context = runtime.context
        let dirname = FileManager.default.currentDirectoryPath
        let filename = "[eval]"

        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setValue(exports, forProperty: "exports")
        module.setValue(filename, forProperty: "filename")
        module.setValue(dirname, forProperty: "path")
        module.setValue(filename, forProperty: "id")

        let transformedCode = ESMTransformer.transformDynamicImport(code)

        let wrapped = "(function(exports, require, module, __filename, __dirname) {\(transformedCode)\n})"

        guard let fn = context.evaluateScript(wrapped, withSourceURL: URL(string: "eval")) else {
            return JSValue(undefinedIn: context)
        }

        let localRequireObj = makeLocalRequire(dirname: dirname, parentPath: (dirname as NSString).appendingPathComponent(filename), context: context)

        return fn.call(withArguments: [
            exports,
            localRequireObj,
            module,
            filename,
            dirname,
        ])
    }

    /// Resolve a `#` private import (package.json "imports" field).
    func resolvePrivateImport(_ name: String, from dir: String) -> String? {
        guard name.hasPrefix("#") else { return nil }
        let fm = FileManager.default
        var searchDir = dir
        while true {
            let packageJsonPath = (searchDir as NSString).appendingPathComponent("package.json")
            if fm.fileExists(atPath: packageJsonPath),
               let data = fm.contents(atPath: packageJsonPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let imports = json["imports"] as? [String: Any] {
                if let entry = imports[name] {
                    if let resolved = extractExportPath(entry) {
                        return resolveRelativePath(resolved, from: searchDir)
                    }
                }
            }
            let parent = (searchDir as NSString).deletingLastPathComponent
            if parent == searchDir { break }
            searchDir = parent
        }
        return nil
    }

    // MARK: - Module Hooks (registerHooks)

    /// resolve フックチェーンを実行する。
    /// フックが結果を返した場合はファイルパスを返す。フック未登録なら nil。
    private func callResolveHooks(specifier: String, parentURL: String, fromDir: String) -> ResolveHookResult? {
        guard !resolveHooks.isEmpty, let runtime = runtime else { return nil }
        let context = runtime.context

        // デフォルト解決（チェーン最深部）
        let defaultResolveBlock: @convention(block) (String, JSValue) -> JSValue = { [weak self] spec, _ in
            guard let self = self else { return JSValue(undefinedIn: JSContext.current()) }
            let jsCtx = JSContext.current()!
            let result = JSValue(newObjectIn: jsCtx)!

            // file:// URL を通常パスに変換
            let cleanSpec: String
            if spec.hasPrefix("file://") {
                cleanSpec = String(spec.dropFirst(7)).removingPercentEncoding ?? String(spec.dropFirst(7))
            } else {
                cleanSpec = spec
            }

            // builtin チェック
            let bareName = cleanSpec.hasPrefix("node:") ? String(cleanSpec.dropFirst(5)) : cleanSpec
            if let rt = self.runtime, rt.registeredModules[bareName] != nil ||
                ["process", "console"].contains(bareName) {
                result.setValue("node:\(bareName)", forProperty: "url")
                result.setValue("builtin", forProperty: "format")
                return result
            }

            // ファイル解決
            var resolved: String?
            if cleanSpec.hasPrefix(".") || cleanSpec.hasPrefix("/") {
                resolved = self.resolveRelativePath(cleanSpec, from: fromDir)
            } else {
                resolved = self.resolveNodeModules(cleanSpec, from: fromDir)
            }

            if let resolved = resolved {
                result.setValue("file://\(resolved)", forProperty: "url")
            } else {
                // 解決できなくてもエラーにしない — フックが別処理するかもしれない
                result.setValue(cleanSpec, forProperty: "url")
            }
            return result
        }
        let defaultResolveObj = unsafeBitCast(defaultResolveBlock, to: AnyObject.self)

        // フックチェーンを構築: hooks を逆順にラップ
        // 最後に登録されたフックが最初に実行される
        var nextResolve: AnyObject = defaultResolveObj
        for i in 0..<(resolveHooks.count - 1) {
            let hook = resolveHooks[i]
            let currentNext = nextResolve
            let chainBlock: @convention(block) (String, JSValue) -> JSValue = { spec, ctx in
                return hook.call(withArguments: [spec, ctx, currentNext]) ?? JSValue(undefinedIn: JSContext.current())
            }
            nextResolve = unsafeBitCast(chainBlock, to: AnyObject.self)
        }

        // コンテキストオブジェクト
        let hookContext = JSValue(newObjectIn: context)!
        hookContext.setValue(parentURL, forProperty: "parentURL")
        let conditions = JSValue(newArrayIn: context)!
        conditions.setValue("node", at: 0)
        conditions.setValue("require", at: 1)
        hookContext.setValue(conditions, forProperty: "conditions")

        // 最後のフック（= 最初に実行されるフック）を呼び出し
        let lastHook = resolveHooks.last!
        let result = lastHook.call(withArguments: [specifier, hookContext, nextResolve])

        guard let result = result, !result.isUndefined else { return nil }

        if let url = result.forProperty("url")?.toString() {
            if url.hasPrefix("file://") {
                let path = String(url.dropFirst(7)).removingPercentEncoding ?? String(url.dropFirst(7))
                // クエリパラメータ除去 (Vitest が ?vitest=xxx を付加する)
                let cleanPath = path.components(separatedBy: "?").first ?? path
                return .filePath(cleanPath)
            }
            if url.hasPrefix("node:") {
                let bareName = String(url.dropFirst(5))
                return .builtin(bareName)
            }
        }

        let shortCircuit = result.forProperty("shortCircuit")?.toBool() ?? false
        if shortCircuit {
            return nil
        }

        return nil
    }

    /// load フックチェーンを実行する。
    /// フックが結果を返した場合は (source, format) を返す。フック未登録なら nil。
    private func callLoadHooks(url: String, path: String) -> (source: String, format: String?)? {
        guard !loadHooks.isEmpty, let runtime = runtime else { return nil }
        let context = runtime.context

        // デフォルトの読み込み
        let defaultLoadBlock: @convention(block) (String, JSValue) -> JSValue = { urlStr, _ in
            let jsCtx = JSContext.current()!
            let filePath: String
            if urlStr.hasPrefix("file://") {
                filePath = String(urlStr.dropFirst(7)).removingPercentEncoding ?? String(urlStr.dropFirst(7))
            } else {
                filePath = urlStr
            }
            // クエリパラメータ除去
            let cleanPath = filePath.components(separatedBy: "?").first ?? filePath

            let result = JSValue(newObjectIn: jsCtx)!
            if let source = try? String(contentsOfFile: cleanPath, encoding: .utf8) {
                result.setValue(source, forProperty: "source")
                let format = ESMDetector.shared.isESM(path: cleanPath) ? "module" : "commonjs"
                result.setValue(format, forProperty: "format")
            }
            return result
        }
        let defaultLoadObj = unsafeBitCast(defaultLoadBlock, to: AnyObject.self)

        // フックチェーンを構築
        var nextLoad: AnyObject = defaultLoadObj
        for i in 0..<(loadHooks.count - 1) {
            let hook = loadHooks[i]
            let currentNext = nextLoad
            let chainBlock: @convention(block) (String, JSValue) -> JSValue = { url, ctx in
                return hook.call(withArguments: [url, ctx, currentNext]) ?? JSValue(undefinedIn: JSContext.current())
            }
            nextLoad = unsafeBitCast(chainBlock, to: AnyObject.self)
        }

        let hookContext = JSValue(newObjectIn: context)!
        let format = ESMDetector.shared.isESM(path: path) ? "module" : "commonjs"
        hookContext.setValue(format, forProperty: "format")
        let conditions = JSValue(newArrayIn: context)!
        conditions.setValue("node", at: 0)
        conditions.setValue("require", at: 1)
        hookContext.setValue(conditions, forProperty: "conditions")

        let lastHook = loadHooks.last!
        let result = lastHook.call(withArguments: [url, hookContext, nextLoad])

        guard let result = result, !result.isUndefined else { return nil }

        if let source = result.forProperty("source")?.toString(), source != "undefined" {
            let fmt = result.forProperty("format")?.toString()
            return (source, fmt)
        }

        return nil
    }

    enum ResolveHookResult {
        case filePath(String)
        case builtin(String)
    }

    /// Resolve a file path from a module name.
    private func resolveFilePath(_ name: String) -> String? {
        if name.hasPrefix(".") || name.hasPrefix("/") {
            return resolveRelativePath(name, from: FileManager.default.currentDirectoryPath)
        }
        // Try node_modules resolution from cwd
        return resolveNodeModules(name, from: FileManager.default.currentDirectoryPath)
    }

    /// Resolve a relative path from a base directory.
    func resolveRelativePath(_ name: String, from baseDir: String) -> String? {
        let fm = FileManager.default

        var candidate: String
        if name.hasPrefix("/") {
            candidate = name
        } else {
            candidate = (baseDir as NSString).appendingPathComponent(name)
        }
        candidate = (candidate as NSString).standardizingPath

        // Try exact path (file, not directory)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: candidate, isDirectory: &isDir) && !isDir.boolValue {
            return candidate
        }

        // Try with extensions: .js, .mjs, .cjs, .ts, .mts, .cts, .json, .node
        for ext in [".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".json", ".node"] {
            let withExt = candidate + ext
            if fm.fileExists(atPath: withExt) {
                return withExt
            }
        }

        // Try as directory with index.js (or package.json main)
        if isDir.boolValue {
            if let main = readPackageJsonMain(at: candidate) {
                if let resolved = resolveRelativePath("./" + main, from: candidate) {
                    return resolved
                }
            }
            let indexPath = (candidate as NSString).appendingPathComponent("index.js")
            if fm.fileExists(atPath: indexPath) {
                return indexPath
            }
        }

        // Try candidate/index.js even if the directory wasn't detected above
        let dirIndex = (candidate as NSString).appendingPathComponent("index.js")
        if fm.fileExists(atPath: dirIndex) {
            return dirIndex
        }

        return nil
    }

    /// Read the "main" field from a package.json file.
    private func readPackageJsonMain(at dir: String) -> String? {
        let packageJsonPath = (dir as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = json["main"] as? String
        else {
            return nil
        }
        return main
    }

    /// Extract a resolved path string from an exports entry (string or conditional object).
    /// When `esmContext` is true, prefer "import" condition; otherwise prefer "require".
    private func extractExportPath(_ entry: Any, esmContext: Bool = false) -> String? {
        if let str = entry as? String { return str }
        if let obj = entry as? [String: Any] {
            if esmContext {
                if let imp = obj["import"] { if let p = extractExportPath(imp, esmContext: true) { return p } }
            }
            if let node = obj["node"] { if let p = extractExportPath(node, esmContext: esmContext) { return p } }
            if !esmContext {
                if let req = obj["require"] { if let p = extractExportPath(req, esmContext: false) { return p } }
            }
            if let def = obj["default"] { if let p = extractExportPath(def, esmContext: esmContext) { return p } }
        }
        return nil
    }

    /// Resolve a subpath using the "exports" field in package.json.
    private func resolvePackageExports(at dir: String, subpath: String, esmContext: Bool = false) -> String? {
        let packageJsonPath = (dir as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exports = json["exports"] as? [String: Any]
        else { return nil }

        // サブパスが "." の場合、exports 自体が条件マップかもしれない
        if subpath == "." {
            let hasSubpathKeys = exports.keys.contains { $0.hasPrefix(".") }
            if !hasSubpathKeys {
                return extractExportPath(exports, esmContext: esmContext)
            }
        }

        // 完全一致
        if let entry = exports[subpath] {
            return extractExportPath(entry, esmContext: esmContext)
        }

        // ワイルドカードパターン: "./utils/*" → "./dist/cjs/utils/*.js"
        for (pattern, entry) in exports {
            guard pattern.contains("*") else { continue }
            let parts = pattern.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let prefix = String(parts[0])
            let suffix = String(parts[1])
            if subpath.hasPrefix(prefix) && subpath.hasSuffix(suffix) {
                let matched = String(subpath.dropFirst(prefix.count).dropLast(suffix.count))
                if let template = extractExportPath(entry, esmContext: esmContext) {
                    return template.replacingOccurrences(of: "*", with: matched)
                }
            }
        }

        return nil
    }

    /// Resolve a bare module name by walking up the directory tree looking for node_modules.
    func resolveNodeModules(_ name: String, from startDir: String, esmContext: Bool = false) -> String? {
        let fm = FileManager.default
        var dir = (startDir as NSString).standardizingPath

        // パッケージ名とサブパスを分離
        let packageName: String
        let exportSubpath: String  // "." or "./cors" 形式
        if name.hasPrefix("@") {
            // スコープパッケージ: "@scope/pkg/sub" → "@scope/pkg" + "./sub"
            let parts = name.split(separator: "/", maxSplits: 2)
            if parts.count > 2 {
                packageName = "\(parts[0])/\(parts[1])"
                exportSubpath = "./\(parts[2])"
            } else {
                packageName = name
                exportSubpath = "."
            }
        } else if let slashIdx = name.firstIndex(of: "/") {
            // 通常パッケージ: "hono/cors" → "hono" + "./cors"
            packageName = String(name[..<slashIdx])
            exportSubpath = "." + String(name[slashIdx...])
        } else {
            packageName = name
            exportSubpath = "."
        }

        while true {
            // Skip if this directory is itself named "node_modules"
            if (dir as NSString).lastPathComponent != "node_modules" {
                let moduleDir = (dir as NSString).appendingPathComponent("node_modules/\(packageName)")
                if fm.fileExists(atPath: moduleDir) {
                    // 1. exports フィールドを試みる
                    if let exportedPath = resolvePackageExports(at: moduleDir, subpath: exportSubpath, esmContext: esmContext) {
                        if let resolved = resolveRelativePath(
                            exportedPath.hasPrefix("./") ? exportedPath : "./" + exportedPath,
                            from: moduleDir
                        ) {
                            return resolved
                        }
                    }

                    if exportSubpath == "." {
                        // 2. メインエントリ: main フィールド → index.js フォールバック
                        if let main = readPackageJsonMain(at: moduleDir) {
                            if let resolved = resolveRelativePath("./" + main, from: moduleDir) {
                                return resolved
                            }
                        }
                        let indexPath = (moduleDir as NSString).appendingPathComponent("index.js")
                        if fm.fileExists(atPath: indexPath) {
                            return indexPath
                        }
                    } else {
                        // 3. サブパス: 直接ファイルパスとしてフォールバック
                        if let resolved = resolveRelativePath(exportSubpath, from: moduleDir) {
                            return resolved
                        }
                    }
                }
            }

            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }  // reached root
            dir = parent
        }

        return nil
    }

    /// Create a promisified version of the fs module.
    private func createPromisifiedFS(_ fsModule: JSValue, context: JSContext) -> JSValue {
        let script = """
        (function(fs) {
            var promises = {};
            // Wrap common fs methods as promise-returning versions
            var methods = ['readFile', 'writeFile', 'appendFile', 'readdir',
                           'stat', 'unlink', 'mkdir', 'rmdir', 'rename',
                           'copyFile', 'access', 'chmod', 'chown', 'rm'];
            methods.forEach(function(name) {
                var syncName = name + 'Sync';
                promises[name] = function() {
                    var args = Array.prototype.slice.call(arguments);
                    return new Promise(function(resolve, reject) {
                        try {
                            if (typeof fs[syncName] === 'function') {
                                var result = fs[syncName].apply(fs, args);
                                resolve(result);
                            } else if (typeof fs[name] === 'function') {
                                args.push(function(err, data) {
                                    if (err) reject(err);
                                    else resolve(data);
                                });
                                fs[name].apply(fs, args);
                            } else {
                                reject(new Error(name + ' is not supported'));
                            }
                        } catch(e) {
                            reject(e);
                        }
                    });
                };
            });
            // fs.promises.open — minimal stub
            promises.open = function(path, flags) {
                return new Promise(function(resolve, reject) {
                    reject(new Error('fs.promises.open is not supported'));
                });
            };
            return promises;
        })
        """
        let factory = context.evaluateScript(script)!
        return factory.call(withArguments: [fsModule])!
    }

    /// ESM 静的インポートの事前ロード
    /// モジュール実行前に依存モジュールをロードし、TLA Promise を drain する。
    /// JS コールバック外の純粋な Swift コンテキストで呼ばれるため、drain が動作する。
    private func preloadStaticImports(source: String, basedir: String, context: JSContext) {
        let specifiers = Self.extractStaticImportSpecifiers(source)
        for spec in specifiers {
            // ビルトインモジュールはスキップ（同期的にロードされる）
            if spec.hasPrefix("node:") || (!spec.hasPrefix(".") && !spec.hasPrefix("/") && !spec.hasPrefix("#")) {
                if let runtime = runtime, runtime.registeredModules[spec] != nil {
                    continue
                }
                if spec == "process" || spec == "console" {
                    continue
                }
            }

            // パスを解決
            let resolvedPath: String?
            let cleanSpec = spec.hasPrefix("node:") ? String(spec.dropFirst(5)) : spec
            if cleanSpec.hasPrefix("#") {
                resolvedPath = resolvePrivateImport(cleanSpec, from: basedir)
            } else if cleanSpec.hasPrefix(".") || cleanSpec.hasPrefix("/") {
                resolvedPath = resolveRelativePath(cleanSpec, from: basedir)
            } else {
                // ビルトインチェック
                if let runtime = runtime, runtime.registeredModules[cleanSpec] != nil {
                    continue
                }
                resolvedPath = resolveNodeModules(cleanSpec, from: basedir, esmContext: true)
            }

            guard let path = resolvedPath else { continue }

            // すでにキャッシュ済み（かつ Promise でない）ならスキップ
            if let cached = moduleCache[path] {
                if !Self.isThenable(cached) { continue }
            }

            // ロード
            let result = loadFile(at: path)

            // TLA Promise の drain
            if Self.isThenable(result) {
                var settled = false
                var resolvedExports: JSValue?
                let onResolve: @convention(block) (JSValue) -> Void = { val in
                    settled = true
                    resolvedExports = val
                }
                let onReject: @convention(block) (JSValue) -> Void = { _ in
                    settled = true
                }
                result.invokeMethod("then", withArguments: [
                    unsafeBitCast(onResolve, to: AnyObject.self),
                    unsafeBitCast(onReject, to: AnyObject.self),
                ])
                for _ in 0..<30 {
                    context.evaluateScript("void 0")
                    if settled { break }
                }
                // 解決済みなら exports でキャッシュを更新（Promise から解決値へ）
                if settled, let exports = resolvedExports {
                    moduleCache[path] = exports
                }
            }
        }
    }

    /// JSValue が thenable (Promise) かチェック
    private static func isThenable(_ value: JSValue) -> Bool {
        guard value.isObject else { return false }
        guard let thenFn = value.forProperty("then") else { return false }
        return thenFn.isObject && !thenFn.isUndefined
    }

    /// ESM ソースから静的インポートの specifier を抽出
    static func extractStaticImportSpecifiers(_ source: String) -> [String] {
        var specifiers: [String] = []
        // import ... from 'specifier'
        let importFromPattern = /import\s+(?:[\s\S]*?)\s+from\s*['"]([\s\S]*?)['"]/
        for match in source.matches(of: importFromPattern) {
            specifiers.append(String(match.output.1))
        }
        // import 'specifier' (side-effect only)
        let importOnlyPattern = /(?:^|\n|;)\s*import\s*['"]([^'"]+)['"]/
        for match in source.matches(of: importOnlyPattern) {
            specifiers.append(String(match.output.1))
        }
        // export { ... } from 'specifier'
        let reexportPattern = /export\s*\{[^}]*\}\s*from\s*['"]([^'"]+)['"]/
        for match in source.matches(of: reexportPattern) {
            specifiers.append(String(match.output.1))
        }
        // export * from 'specifier'
        let starReexportPattern = /export\s*\*\s*from\s*['"]([^'"]+)['"]/
        for match in source.matches(of: starReexportPattern) {
            specifiers.append(String(match.output.1))
        }
        // 重複排除
        return Array(Set(specifiers))
    }

    /// Clear the module cache.
    func clearCache() {
        moduleCache.removeAll()
        loadingModules.removeAll()
    }

    /// Shebang行(`#!`)をJSコメント(`//`)に変換（行番号を維持）
    static func stripShebang(_ source: String) -> String {
        guard source.hasPrefix("#!") else { return source }
        if let newlineIndex = source.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return "//" + source[source.index(source.startIndex, offsetBy: 2)..<newlineIndex] + source[newlineIndex...]
        }
        // 改行なし（shebangのみのファイル）
        return "//" + source.dropFirst(2)
    }
}
