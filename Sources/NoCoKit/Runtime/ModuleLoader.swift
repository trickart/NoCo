import Foundation
import JavaScriptCore

/// Implements CommonJS `require()` resolution and loading.
/// Resolution order: builtin modules → cache → file system.
public final class ModuleLoader {
    private weak var runtime: NodeRuntime?
    private var moduleCache: [String: JSValue] = [:]
    private var loadingModules: [String: JSValue] = [:]

    init(runtime: NodeRuntime) {
        self.runtime = runtime
        installRequire()
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

        // 1b. Handle builtin subpath modules (e.g., 'fs/promises')
        if resolvedName.contains("/") {
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

        // 3. Resolve file path
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

        // Check cache by absolute path
        if let cached = moduleCache[path] {
            return cached
        }

        // 循環 require: module.exports の現在値を返す
        if let loadingModule = loadingModules[path] {
            return loadingModule.forProperty("exports")
        }

        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            let error = runtime.context.createError(
                "Cannot read module '\(path)'", code: "MODULE_NOT_FOUND")
            runtime.context.exception = error
            return JSValue(undefinedIn: runtime.context)
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

        // Wrap in CommonJS function (no leading newline to preserve line numbers)
        let wrapped = "(function(exports, require, module, __filename, __dirname) {\(transformedSource)\n})"

        guard let fn = context.evaluateScript(wrapped, withSourceURL: URL(fileURLWithPath: path))
        else {
            loadingModules.removeValue(forKey: path)
            return JSValue(undefinedIn: context)
        }

        // Create a local require that resolves relative to this module's directory
        let localRequire: @convention(block) (String) -> JSValue = { [weak self] name in
            guard let self = self else { return JSValue(undefinedIn: JSContext.current()) }
            if name.hasPrefix(".") || name.hasPrefix("/") {
                let resolved = self.resolveRelativePath(name, from: dirname)
                if let resolved = resolved {
                    return self.loadFile(at: resolved)
                }
            }
            // Try node_modules resolution from this module's directory
            if !name.hasPrefix(".") && !name.hasPrefix("/") {
                if let resolved = self.resolveNodeModules(name, from: dirname) {
                    return self.loadFile(at: resolved)
                }
            }
            return self.require(name)
        }

        // Attach resolve/resolve.paths to local require
        let localResolveBlock: @convention(block) (String) -> JSValue = { [weak self] moduleName in
            guard let self = self, let runtime = self.runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let ctx = JSContext.current()!
            let reqName = moduleName.hasPrefix("node:") ? String(moduleName.dropFirst(5)) : moduleName

            if runtime.registeredModules[reqName] != nil || ["process", "console"].contains(reqName) {
                return JSValue(object: reqName, in: ctx)
            }

            // Resolve relative to this module's directory
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

        fn.call(withArguments: [
            exports,
            localRequireObj,
            module,
            path,
            dirname,
        ])

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

        // Try with extensions: .js, .mjs, .cjs, .ts, .mts, .cts, .json
        for ext in [".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".json"] {
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
    private func resolvePackageExports(at dir: String, subpath: String) -> String? {
        let packageJsonPath = (dir as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exports = json["exports"] as? [String: Any]
        else { return nil }

        // 完全一致
        if let entry = exports[subpath] {
            return extractExportPath(entry)
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
                if let template = extractExportPath(entry) {
                    return template.replacingOccurrences(of: "*", with: matched)
                }
            }
        }

        return nil
    }

    /// Resolve a bare module name by walking up the directory tree looking for node_modules.
    func resolveNodeModules(_ name: String, from startDir: String) -> String? {
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
                    if let exportedPath = resolvePackageExports(at: moduleDir, subpath: exportSubpath) {
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
                           'copyFile', 'access', 'chmod', 'chown'];
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
