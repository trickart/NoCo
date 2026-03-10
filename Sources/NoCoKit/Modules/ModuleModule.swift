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
                'assert', 'buffer', 'child_process', 'constants', 'crypto',
                'events', 'fs', 'http', 'http2', 'module', 'net', 'os',
                'path', 'process', 'querystring', 'readline', 'stream',
                'string_decoder', 'timers', 'tty', 'url', 'util', 'zlib'
            ];

            mod._cache = {};
            mod._pathCache = {};

            return mod;
        })();
        """

        return context.evaluateScript(script)!
    }
}
