import JavaScriptCore

/// Implements the Node.js `module` built-in module.
public struct ModuleModule: NodeModule {
    public static let moduleName = "module"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // Swift helper for TypeScript type stripping
        let stripTSBlock: @convention(block) (String) -> String = { code in
            return TypeScriptStripper.strip(code)
        }
        context.setObject(
            unsafeBitCast(stripTSBlock, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_stripTypeScriptTypes" as NSString
        )

        // Swift helper for module.registerHooks()
        let registerHooksBlock: @convention(block) (JSValue, JSValue) -> Void = { resolve, load in
            runtime.moduleLoader.registerModuleHooks(
                resolve: resolve.isNull ? nil : resolve,
                load: load.isNull ? nil : load
            )
        }
        context.setObject(
            unsafeBitCast(registerHooksBlock, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_registerModuleHooks" as NSString
        )

        let script = #"""
        (function() {
            var mod = {};

            // createRequire returns a require function scoped to the given filename
            mod.createRequire = function(filename) {
                var path = require('path');
                var url = filename;
                // Support file:// URLs (Node.js compatible)
                if (typeof url === 'string' && url.startsWith('file://')) {
                    url = url.slice(7);
                }
                // Support URL objects
                if (typeof url === 'object' && url !== null) {
                    if (url.protocol === 'file:') {
                        url = url.pathname;
                    } else if (url.href) {
                        url = url.href.replace(/^file:\/\//, '');
                    }
                }
                var baseDir = path.dirname(path.resolve(url));
                var scopedRequire = function(request) {
                    if (request.startsWith('.') || request.startsWith('/')) {
                        return require(path.resolve(baseDir, request));
                    }
                    return require(request);
                };
                scopedRequire.resolve = function(request) {
                    if (request.startsWith('.') || request.startsWith('/')) {
                        var resolved = path.resolve(baseDir, request);
                        if (require.resolve) {
                            return require.resolve(resolved);
                        }
                        return resolved;
                    }
                    if (require.resolve) {
                        return require.resolve(request);
                    }
                    return request;
                };
                scopedRequire.resolve.paths = function(request) {
                    if (require.resolve && require.resolve.paths) {
                        return require.resolve.paths(request);
                    }
                    return null;
                };
                scopedRequire.cache = require.cache || {};
                scopedRequire.main = require.main;
                return scopedRequire;
            };

            mod.createRequireFromPath = function(filename) {
                return mod.createRequire(filename);
            };

            // Module constructor stub
            mod.Module = function Module(id, parent) {
                this.id = id || '';
                this.filename = id || '';
                this.loaded = false;
                this.parent = parent || null;
                this.children = [];
                this.paths = [];
                this.exports = {};
            };

            mod.Module._nodeModulePaths = function(dir) {
                var parts = dir.split('/');
                var paths = [];
                for (var i = parts.length; i > 0; i--) {
                    var part = parts[i - 1];
                    if (part === 'node_modules') continue;
                    var p = parts.slice(0, i).join('/') + '/node_modules';
                    paths.push(p);
                }
                return paths;
            };

            mod.Module.prototype._compile = function(content, filename) {
                var fn = new Function('exports', 'require', 'module', '__filename', '__dirname', content);
                fn(this.exports, require, this, this.filename, this.filename.replace(/\/[^/]*$/, ''));
            };

            mod.builtinModules = [
                'assert', 'async_hooks', 'buffer', 'child_process', 'constants',
                'crypto', 'events', 'fs', 'http', 'http2', 'https', 'module',
                'net', 'os', 'path', 'perf_hooks', 'process', 'querystring',
                'readline', 'stream', 'string_decoder', 'test', 'timers',
                'tty', 'url', 'util', 'v8', 'vm', 'worker_threads', 'zlib'
            ];

            mod.isBuiltin = function(name) {
                var n = name;
                if (n.startsWith('node:')) n = n.slice(5);
                return mod.builtinModules.indexOf(n) !== -1;
            };

            mod.Module.builtinModules = mod.builtinModules;
            mod.Module.isBuiltin = mod.isBuiltin;

            mod._cache = {};
            mod._pathCache = {};

            // Expose Module internals at top level too (pirates/jest use require('module')._extensions)
            mod._extensions = {};
            mod._extensions['.js'] = function(module, filename) {
                var fs = require('fs');
                var content = fs.readFileSync(filename, 'utf8');
                module._compile(content, filename);
            };
            mod._extensions['.json'] = function(module, filename) {
                var fs = require('fs');
                var content = fs.readFileSync(filename, 'utf8');
                module.exports = JSON.parse(content);
            };
            mod._extensions['.node'] = function(module, filename) {
                throw new Error('.node native addons are not supported');
            };

            mod._resolveFilename = function(request, parent) {
                if (require.resolve) {
                    return require.resolve(request);
                }
                return request;
            };

            // Module._extensions — loader hooks (used by pirates/jest transform)
            mod.Module._extensions = {};
            mod.Module._extensions['.js'] = function(module, filename) {
                var fs = require('fs');
                var content = fs.readFileSync(filename, 'utf8');
                module._compile(content, filename);
            };
            mod.Module._extensions['.json'] = function(module, filename) {
                var fs = require('fs');
                var content = fs.readFileSync(filename, 'utf8');
                module.exports = JSON.parse(content);
            };
            mod.Module._extensions['.node'] = function(module, filename) {
                throw new Error('.node native addons are not supported');
            };

            // Module._resolveFilename
            mod.Module._resolveFilename = function(request, parent) {
                if (require.resolve) {
                    return require.resolve(request);
                }
                return request;
            };

            // Module._cache
            mod.Module._cache = mod._cache;

            // --- wrap / wrapper ---
            mod.wrapper = ['(function (exports, require, module, __filename, __dirname) { ', '\n});'];
            mod.wrap = function(code) { return mod.wrapper[0] + code + mod.wrapper[1]; };
            mod.Module.wrap = mod.wrap;
            mod.Module.wrapper = mod.wrapper;

            // --- _findPath ---
            mod.Module._findPath = function(request, paths, isMain) {
                var fs = require('fs');
                var path = require('path');
                var exts = ['.js', '.json', '.node', '.mjs', '.cjs'];

                function tryFile(p) {
                    try {
                        var stat = fs.statSync(p);
                        if (stat.isFile()) return p;
                    } catch(e) {}
                    return false;
                }

                function tryExtensions(p) {
                    for (var e = 0; e < exts.length; e++) {
                        var f = tryFile(p + exts[e]);
                        if (f) return f;
                    }
                    return false;
                }

                function tryDirectory(dir) {
                    var pkgPath = path.join(dir, 'package.json');
                    try {
                        if (fs.existsSync(pkgPath)) {
                            var pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
                            if (pkg.main) {
                                var mainPath = path.resolve(dir, pkg.main);
                                var f = tryFile(mainPath) || tryExtensions(mainPath);
                                if (f) return f;
                            }
                        }
                    } catch(e) {}
                    return tryExtensions(path.join(dir, 'index'));
                }

                function resolve(basePath) {
                    var f = tryFile(basePath);
                    if (f) return f;
                    f = tryExtensions(basePath);
                    if (f) return f;
                    try {
                        var stat = fs.statSync(basePath);
                        if (stat.isDirectory()) return tryDirectory(basePath);
                    } catch(e) {}
                    return false;
                }

                if (path.isAbsolute(request) || request.startsWith('./') || request.startsWith('../')) {
                    return resolve(request);
                }

                if (!paths) return false;
                for (var i = 0; i < paths.length; i++) {
                    var basePath = path.join(paths[i], request);
                    var r = resolve(basePath);
                    if (r) return r;
                }
                return false;
            };
            mod._findPath = mod.Module._findPath;

            // --- _resolveLookupPaths ---
            mod.Module._resolveLookupPaths = function(request, parent) {
                if (mod.isBuiltin(request)) return null;
                if (request.startsWith('./') || request.startsWith('../') || request.startsWith('/')) {
                    var parentDir = parent && parent.filename ? require('path').dirname(parent.filename) : process.cwd();
                    return [parentDir];
                }
                var from = parent && parent.filename ? require('path').dirname(parent.filename) : process.cwd();
                return mod.Module._nodeModulePaths(from);
            };
            mod._resolveLookupPaths = mod.Module._resolveLookupPaths;

            // --- globalPaths ---
            mod.Module.globalPaths = (function() {
                var paths = [];
                var home = process.env.HOME || process.env.USERPROFILE || '';
                if (home) {
                    paths.push(require('path').join(home, '.node_modules'));
                    paths.push(require('path').join(home, '.node_libraries'));
                }
                var nodePath = process.env.NODE_PATH;
                if (nodePath) {
                    nodePath.split(':').forEach(function(p) { if (p) paths.push(p); });
                }
                return paths;
            })();
            mod.globalPaths = mod.Module.globalPaths;

            // --- findPackageJSON ---
            mod.Module.findPackageJSON = function(startPath) {
                var fs = require('fs');
                var path = require('path');
                var dir = startPath;
                try { if (fs.statSync(dir).isFile()) dir = path.dirname(dir); } catch(e) { dir = path.dirname(dir); }
                while (true) {
                    var pkgPath = path.join(dir, 'package.json');
                    if (fs.existsSync(pkgPath)) return pkgPath;
                    var parent = path.dirname(dir);
                    if (parent === dir) break;
                    dir = parent;
                }
                return undefined;
            };
            mod.findPackageJSON = mod.Module.findPackageJSON;

            // --- stripTypeScriptTypes ---
            mod.Module.stripTypeScriptTypes = function(code) {
                return __NoCo_stripTypeScriptTypes(code);
            };
            mod.stripTypeScriptTypes = mod.Module.stripTypeScriptTypes;

            // --- constants ---
            mod.constants = { USE_MAIN_CONTEXT_DEFAULT_LOADER: 0 };
            mod.Module.constants = mod.constants;

            // --- V8 compile cache stubs (JSC has no equivalent) ---
            mod.Module.enableCompileCache = function() { return { status: 2, directory: '' }; };
            mod.Module.getCompileCacheDir = function() { return undefined; };
            mod.Module.flushCompileCache = function() {};

            // --- V8 SourceMap stubs (JSC has no equivalent) ---
            mod.Module.findSourceMap = function(filename) { return undefined; };
            mod.Module.SourceMap = function SourceMap(payload) { this.payload = payload; };

            // --- syncBuiltinESMExports (no-op) ---
            mod.Module.syncBuiltinESMExports = function() {};
            mod.syncBuiltinESMExports = mod.Module.syncBuiltinESMExports;

            // --- _initPaths / _preloadModules (no-op) ---
            mod.Module._initPaths = function() {};
            mod.Module._preloadModules = function(requests) {};

            // --- registerHooks (Node.js 22.15+) ---
            mod.registerHooks = function(hooks) {
                if (hooks) {
                    __NoCo_registerModuleHooks(
                        typeof hooks.resolve === 'function' ? hooks.resolve : null,
                        typeof hooks.load === 'function' ? hooks.load : null
                    );
                }
            };
            mod.Module.registerHooks = mod.registerHooks;

            // --- register (Node.js 18.19+ no-op stub) ---
            mod.register = function(specifier, options) {};
            mod.Module.register = mod.register;

            // --- setSourceMapsSupport (Node.js 22+ no-op stub) ---
            mod.setSourceMapsSupport = function(enable) {};
            mod.Module.setSourceMapsSupport = mod.setSourceMapsSupport;

            return mod;
        })();
        """#

        return context.evaluateScript(script)!
    }
}
