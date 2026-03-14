import JavaScriptCore

/// Implements the Node.js `module` built-in module (minimal stub for compatibility).
public struct ModuleModule: NodeModule {
    public static let moduleName = "module"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var mod = {};

            // createRequire returns the global require function
            mod.createRequire = function(filename) {
                return require;
            };

            mod.createRequireFromPath = function(filename) {
                return require;
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
                // Minimal stub: evaluate the content
                var fn = new Function('exports', 'require', 'module', '__filename', '__dirname', content);
                fn(this.exports, require, this, this.filename, this.filename.replace(/\\/[^/]*$/, ''));
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

            return mod;
        })();
        """

        return context.evaluateScript(script)!
    }
}
