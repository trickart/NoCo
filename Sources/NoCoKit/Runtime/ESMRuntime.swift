import Foundation
import JavaScriptCore

/// Installs ESM runtime functions (`__esm_import`, `__esm_export`, etc.) into the JS context.
public enum ESMRuntime {
    public static func install(in context: JSContext, runtime: NodeRuntime) {
        // __esm_import(specifier, basedir) — resolve and load a module for ESM
        let esmImportBlock: @convention(block) (String, String) -> JSValue = {
            [weak runtime] specifier, basedir in
            guard let runtime = runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }

            let loader = runtime.moduleLoader!

            // Convert file:// URLs to filesystem paths
            let resolved: String
            if specifier.hasPrefix("file://") {
                if let url = URL(string: specifier), url.scheme == "file" {
                    resolved = url.path
                } else {
                    resolved = String(specifier.dropFirst(7))
                }
            } else if specifier.hasPrefix("node:") {
                // Strip node: prefix
                resolved = String(specifier.dropFirst(5))
            } else {
                resolved = specifier
            }

            // Use require for builtin/absolute/relative resolution
            let moduleValue: JSValue
            if resolved.hasPrefix("#") {
                // Private import — resolve via package.json "imports" field
                if let path = loader.resolvePrivateImport(resolved, from: basedir) {
                    moduleValue = loader.loadFile(at: path)
                } else {
                    let error = runtime.context.createError(
                        "Cannot find module '\(specifier)'", code: "MODULE_NOT_FOUND")
                    runtime.context.exception = error
                    return JSValue(undefinedIn: runtime.context)
                }
            } else if resolved.hasPrefix(".") || resolved.hasPrefix("/") {
                // Resolve relative to basedir
                if let path = loader.resolveRelativePath(resolved, from: basedir) {
                    moduleValue = loader.loadFile(at: path)
                } else {
                    let error = runtime.context.createError(
                        "Cannot find module '\(specifier)'", code: "MODULE_NOT_FOUND")
                    runtime.context.exception = error
                    return JSValue(undefinedIn: runtime.context)
                }
            } else if runtime.registeredModules[resolved] != nil
                        || resolved == "process" || resolved == "console"
                        || resolved.contains("/") && runtime.registeredModules[String(resolved.split(separator: "/")[0])] != nil {
                moduleValue = loader.require(resolved)
            } else {
                // Try node_modules resolution from basedir
                if let path = loader.resolveNodeModules(resolved, from: basedir, esmContext: true) {
                    moduleValue = loader.loadFile(at: path)
                } else {
                    moduleValue = loader.require(resolved)
                }
            }

            if runtime.context.exception != nil {
                return JSValue(undefinedIn: runtime.context)
            }

            // loadFile の結果が thenable (ネストされた TLA の Promise) かチェック
            // 事前ロードで解決済みの場合はキャッシュヒットし、ここには到達しない
            // 動的 import 等で未解決の Promise が返った場合はチェインする
            if moduleValue.isObject,
               let thenFn = moduleValue.forProperty("then"),
               thenFn.isObject, !thenFn.isUndefined {
                let ctx = runtime.context
                let wrapBlock: @convention(block) (JSValue) -> JSValue = { resolved in
                    return wrapAsNamespace(resolved, in: ctx)
                }
                return moduleValue.invokeMethod("then", withArguments: [
                    unsafeBitCast(wrapBlock, to: AnyObject.self),
                ])!
            }

            // Wrap CJS module result as ESM namespace:
            // If the module already has __esModule marker, return as-is
            // Otherwise, create namespace with named exports + default
            return wrapAsNamespace(moduleValue, in: runtime.context)
        }

        context.setObject(
            unsafeBitCast(esmImportBlock, to: AnyObject.self),
            forKeyedSubscript: "__esm_import" as NSString
        )

        // __esm_export(module, name, getter) — register a live binding export
        context.evaluateScript("""
            function __esm_export(mod, name, getter) {
                Object.defineProperty(mod.exports, name, {
                    enumerable: true,
                    configurable: true,
                    get: getter
                });
            }
            """)

        // __esm_export_default(module, value) — register default export
        context.evaluateScript("""
            function __esm_export_default(mod, value) {
                mod.exports.default = value;
            }
            """)

        // __esm_export_star(module, source) — re-export all from source
        context.evaluateScript("""
            function __esm_export_star(mod, source) {
                if (source && typeof source === 'object') {
                    Object.keys(source).forEach(function(k) {
                        if (k !== 'default' && k !== '__esModule') {
                            Object.defineProperty(mod.exports, k, {
                                enumerable: true,
                                configurable: true,
                                get: function() { return source[k]; }
                            });
                        }
                    });
                }
            }
            """)

        // __importDynamic(specifier, basedir) — dynamic import()
        let dynamicImportBlock: @convention(block) (String, String) -> JSValue = {
            [weak runtime] specifier, basedir in
            guard let runtime = runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let ctx = runtime.context
            // Create a resolved promise wrapping __esm_import
            let esmImport = ctx.objectForKeyedSubscript("__esm_import" as NSString)!
            let result = esmImport.call(withArguments: [specifier, basedir])!

            if ctx.exception != nil {
                // Convert exception to rejected promise
                let err = ctx.exception!
                ctx.exception = nil
                let promise = ctx.evaluateScript("(function(e) { return Promise.reject(e); })")!
                return promise.call(withArguments: [err])!
            }

            let promise = ctx.evaluateScript("(function(v) { return Promise.resolve(v); })")!
            return promise.call(withArguments: [result])!
        }

        context.setObject(
            unsafeBitCast(dynamicImportBlock, to: AnyObject.self),
            forKeyedSubscript: "__importDynamic" as NSString
        )
    }

    /// Wrap a CJS module value as an ESM namespace object.
    /// If it already has `__esModule`, return as-is.
    /// Otherwise, spread own properties + add `default` pointing to the whole module.
    private static func wrapAsNamespace(_ value: JSValue, in context: JSContext) -> JSValue {
        // If the module has __esModule marker, it was already set up by ESM transformer
        if let esModule = value.forProperty("__esModule"), esModule.toBool() {
            return value
        }

        // For non-object values (string, number, function), just wrap with default
        if !value.isObject {
            let ns = JSValue(newObjectIn: context)!
            ns.setValue(value, forProperty: "default")
            return ns
        }

        // Create namespace: copy all own enumerable properties + add default
        let wrapScript = context.evaluateScript("""
            (function(mod) {
                var ns = Object.create(null);
                if (mod && (typeof mod === 'object' || typeof mod === 'function')) {
                    var keys = Object.keys(mod);
                    for (var i = 0; i < keys.length; i++) {
                        (function(k) {
                            Object.defineProperty(ns, k, {
                                enumerable: true,
                                get: function() { return mod[k]; }
                            });
                        })(keys[i]);
                    }
                }
                ns.default = mod;
                return ns;
            })
            """)!
        return wrapScript.call(withArguments: [value])!
    }
}
