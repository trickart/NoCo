import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

/// Implements the Node.js `vm` module for sandboxed code execution.
/// Uses separate JSContext instances (on the same JSVirtualMachine) for true scope isolation.
public struct VmModule: NodeModule {
    public static let moduleName = "vm"

    /// Maps context IDs to their dedicated JSContext instances.
    private struct State {
        var contextStore: [Int: JSContext] = [:]
        var nextContextId: Int = 1
    }
    private static let state = Mutex(State())

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let vm = context.virtualMachine!

        // Swift helper: create a new JSContext for the sandbox
        let createContextBlock: @convention(block) (JSValue) -> JSValue = { [weak runtime] sandbox in
            guard let runtime = runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let ctx = JSContext.current()!

            let newContext = JSContext(virtualMachine: vm)!

            // Copy sandbox's own enumerable properties to new context's global
            let keys = ctx.evaluateScript("(function(o) { return Object.keys(o); })")!
                .call(withArguments: [sandbox])!
            let count = keys.forProperty("length")?.toInt32() ?? 0
            for i in 0..<count {
                let key = keys.atIndex(Int(i))!.toString()!
                let val = sandbox.forProperty(key)!
                newContext.setObject(val, forKeyedSubscript: key as NSString)
            }

            // Install essential globals in the new context
            installGlobals(in: newContext, from: runtime)

            // Assign a unique ID and store the mapping
            let contextId = state.withLock { s in
                let id = s.nextContextId
                s.nextContextId += 1
                s.contextStore[id] = newContext
                return id
            }

            // Mark sandbox as a context with hidden properties
            ctx.evaluateScript("""
                (function(obj, id) {
                    Object.defineProperty(obj, '__isVmContext__', {
                        value: true,
                        writable: false,
                        enumerable: false,
                        configurable: false
                    });
                    Object.defineProperty(obj, '__vmContextId__', {
                        value: id,
                        writable: false,
                        enumerable: false,
                        configurable: false
                    });
                })
            """)!.call(withArguments: [sandbox, contextId])

            return sandbox
        }

        context.setObject(
            unsafeBitCast(createContextBlock, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_vm_createContext" as NSString
        )

        // Swift helper: run code in a sandbox's JSContext
        let runInContextBlock: @convention(block) (String, JSValue, String) -> JSValue = { code, sandbox, sourceURL in
            let callerCtx = JSContext.current()!

            let contextId = sandbox.forProperty("__vmContextId__")?.toInt32() ?? 0
            guard contextId > 0, let targetCtx = state.withLock({ $0.contextStore[Int(contextId)] }) else {
                callerCtx.exception = callerCtx.evaluateScript(
                    "new TypeError('argument is not a context')"
                )
                return JSValue(undefinedIn: callerCtx)
            }

            // Sync sandbox's own properties to the target context before execution
            // Use Object.keys to get only own enumerable properties (not builtins)
            let keysArr = callerCtx.evaluateScript("(function(o) { return Object.keys(o); })")!
                .call(withArguments: [sandbox])!
            let keyCount = keysArr.forProperty("length")?.toInt32() ?? 0
            for i in 0..<keyCount {
                let key = keysArr.atIndex(Int(i))!.toString()!
                if key != "__isVmContext__" && key != "__vmContextId__" {
                    let val = sandbox.forProperty(key)!
                    targetCtx.setObject(val, forKeyedSubscript: key as NSString)
                }
            }

            let url = sourceURL.isEmpty ? nil : URL(string: sourceURL)
            let result = targetCtx.evaluateScript(code, withSourceURL: url)

            // Propagate exception from target context back to caller
            if let exception = targetCtx.exception {
                targetCtx.exception = nil
                callerCtx.exception = exception
                return JSValue(undefinedIn: callerCtx)
            }

            // Sync user-defined properties back from target context to sandbox
            // Only sync properties that were defined by user code, not JS builtins
            let userKeysScript = """
                (function() {
                    var builtins = ['Object', 'Array', 'Function', 'String', 'Number',
                        'Boolean', 'Symbol', 'Error', 'TypeError', 'RangeError',
                        'ReferenceError', 'SyntaxError', 'URIError', 'EvalError',
                        'Math', 'JSON', 'Date', 'RegExp', 'Map', 'Set', 'WeakMap',
                        'WeakSet', 'Promise', 'Proxy', 'Reflect', 'ArrayBuffer',
                        'DataView', 'Int8Array', 'Uint8Array', 'Uint8ClampedArray',
                        'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array',
                        'Float32Array', 'Float64Array', 'BigInt64Array', 'BigUint64Array',
                        'NaN', 'Infinity', 'undefined', 'isNaN', 'isFinite',
                        'parseInt', 'parseFloat', 'encodeURI', 'decodeURI',
                        'encodeURIComponent', 'decodeURIComponent', 'eval',
                        'console', 'process', 'Buffer', 'setTimeout', 'setInterval',
                        'setImmediate', 'clearTimeout', 'clearInterval', 'clearImmediate',
                        'require', 'global', 'globalThis', 'queueMicrotask',
                        '__NoCo_EventEmitter', '__isVmContext__', '__vmContextId__',
                        'TextEncoder', 'TextDecoder', 'URL', 'URLSearchParams',
                        'BigInt', 'AggregateError', 'FinalizationRegistry', 'WeakRef'];
                    var keys = Object.getOwnPropertyNames(this);
                    var result = [];
                    for (var i = 0; i < keys.length; i++) {
                        if (builtins.indexOf(keys[i]) === -1) {
                            result.push(keys[i]);
                        }
                    }
                    return result;
                })()
            """
            if let userKeys = targetCtx.evaluateScript(userKeysScript) {
                let keyCount = userKeys.forProperty("length")?.toInt32() ?? 0
                for i in 0..<keyCount {
                    let key = userKeys.atIndex(Int(i))!.toString()!
                    let val = targetCtx.globalObject.forProperty(key)!
                    sandbox.setValue(val, forProperty: key)
                }
            }

            return result ?? JSValue(undefinedIn: callerCtx)
        }

        context.setObject(
            unsafeBitCast(runInContextBlock, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_vm_runInContext" as NSString
        )

        // Swift helper: compile function in a specific context
        let compileFunctionBlock: @convention(block) (String, JSValue, JSValue, String) -> JSValue = { [weak runtime] code, paramsArray, sandbox, sourceURL in
            guard let runtime = runtime else {
                return JSValue(undefinedIn: JSContext.current())
            }
            let callerCtx = JSContext.current()!

            var params: [String] = []
            if !paramsArray.isUndefined && !paramsArray.isNull {
                let length = paramsArray.forProperty("length")?.toInt32() ?? 0
                for i in 0..<length {
                    if let p = paramsArray.atIndex(Int(i))?.toString() {
                        params.append(p)
                    }
                }
            }

            let paramList = params.joined(separator: ", ")
            let wrappedCode = "(function(\(paramList)) {\n\(code)\n})"

            // Determine target context
            let targetCtx: JSContext
            if !sandbox.isUndefined && !sandbox.isNull {
                let contextId = sandbox.forProperty("__vmContextId__")?.toInt32() ?? 0
                if contextId > 0, let mapped = state.withLock({ $0.contextStore[Int(contextId)] }) {
                    targetCtx = mapped
                } else {
                    targetCtx = runtime.context
                }
            } else {
                targetCtx = runtime.context
            }

            let url = sourceURL.isEmpty ? nil : URL(string: sourceURL)
            let result = targetCtx.evaluateScript(wrappedCode, withSourceURL: url)

            if let exception = targetCtx.exception {
                targetCtx.exception = nil
                if targetCtx !== callerCtx {
                    callerCtx.exception = exception
                }
                return JSValue(undefinedIn: callerCtx)
            }

            return result ?? JSValue(undefinedIn: callerCtx)
        }

        context.setObject(
            unsafeBitCast(compileFunctionBlock, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_vm_compileFunction" as NSString
        )

        // Main vm module implemented in JS, delegating to Swift helpers
        let script = """
        (function() {
            var vm = {};

            // --- createContext / isContext ---

            vm.createContext = function createContext(sandbox, options) {
                if (sandbox === undefined || sandbox === null) {
                    sandbox = {};
                }
                if (typeof sandbox !== 'object') {
                    throw new TypeError('sandbox must be an object');
                }
                if (sandbox.__isVmContext__) {
                    return sandbox;
                }
                return __NoCo_vm_createContext(sandbox);
            };

            vm.isContext = function isContext(obj) {
                return obj != null && typeof obj === 'object' && obj.__isVmContext__ === true;
            };

            // --- runInContext ---

            vm.runInContext = function runInContext(code, context, options) {
                if (!vm.isContext(context)) {
                    throw new TypeError('argument is not a context');
                }
                var filename = '';
                if (options) {
                    if (typeof options === 'string') {
                        filename = options;
                    } else if (options.filename) {
                        filename = options.filename;
                    }
                }
                return __NoCo_vm_runInContext(code, context, filename);
            };

            // --- runInNewContext ---

            vm.runInNewContext = function runInNewContext(code, sandbox, options) {
                if (sandbox === undefined || sandbox === null) {
                    sandbox = {};
                }
                var ctx = vm.createContext(sandbox);
                return vm.runInContext(code, ctx, options);
            };

            // --- runInThisContext ---

            vm.runInThisContext = function runInThisContext(code, options) {
                var filename = '';
                if (options) {
                    if (typeof options === 'string') {
                        filename = options;
                    } else if (options.filename) {
                        filename = options.filename;
                    }
                }
                return (0, eval)(code);
            };

            // --- compileFunction ---

            vm.compileFunction = function compileFunction(code, params, options) {
                params = params || [];
                options = options || {};
                var parsingContext = options.parsingContext || null;
                var filename = options.filename || '';

                if (parsingContext && !vm.isContext(parsingContext)) {
                    throw new TypeError('parsingContext must be a vm.Context');
                }

                return __NoCo_vm_compileFunction(code, params, parsingContext, filename);
            };

            // --- Script class ---

            function Script(code, options) {
                if (!(this instanceof Script)) {
                    return new Script(code, options);
                }
                this._code = code;
                this._filename = '';
                if (options) {
                    if (typeof options === 'string') {
                        this._filename = options;
                    } else if (options.filename) {
                        this._filename = options.filename;
                    }
                }
            }

            Script.prototype.runInContext = function(context, options) {
                return vm.runInContext(this._code, context, {
                    filename: this._filename
                });
            };

            Script.prototype.runInNewContext = function(sandbox, options) {
                return vm.runInNewContext(this._code, sandbox, {
                    filename: this._filename
                });
            };

            Script.prototype.runInThisContext = function(options) {
                return vm.runInThisContext(this._code, {
                    filename: this._filename
                });
            };

            Script.prototype.createCachedData = function() {
                return typeof Buffer !== 'undefined' ? Buffer.alloc(0) : new Uint8Array(0);
            };

            vm.Script = Script;

            // --- SourceTextModule ---

            function SourceTextModule(code, options) {
                if (!(this instanceof SourceTextModule)) {
                    return new SourceTextModule(code, options);
                }
                options = options || {};
                this._code = code;
                this._context = options.context || null;
                this.identifier = options.identifier || '';
                this._importModuleDynamically = options.importModuleDynamically || null;
                this._initializeImportMeta = options.initializeImportMeta || null;
                this.status = 'unlinked';
                this._linker = null;
                this._namespace = {};
                this._linkedModules = {};
            }

            SourceTextModule.prototype.link = function(linker) {
                var self = this;
                if (self.status !== 'unlinked') {
                    return Promise.reject(new Error('Module has already been linked'));
                }
                return new Promise(function(resolve, reject) {
                    try {
                        var importPattern = /import\\s+.*?from\\s+['\"]([^'\"]+)['\"]/g;
                        var match;
                        var deps = [];
                        while ((match = importPattern.exec(self._code)) !== null) {
                            deps.push(match[1]);
                        }

                        if (deps.length === 0) {
                            self.status = 'linked';
                            resolve();
                            return;
                        }

                        var pending = deps.length;
                        for (var i = 0; i < deps.length; i++) {
                            (function(specifier) {
                                var result = linker(specifier, self);
                                Promise.resolve(result).then(function(mod) {
                                    self._linkedModules[specifier] = mod;
                                    pending--;
                                    if (pending === 0) {
                                        self.status = 'linked';
                                        resolve();
                                    }
                                }).catch(reject);
                            })(deps[i]);
                        }
                    } catch (e) {
                        reject(e);
                    }
                });
            };

            SourceTextModule.prototype.evaluate = function() {
                var self = this;
                if (self.status !== 'linked') {
                    return Promise.reject(new Error('Module must be linked before evaluation'));
                }
                return new Promise(function(resolve, reject) {
                    try {
                        var moduleObj = { exports: {} };
                        var exportsObj = moduleObj.exports;
                        var code = self._code;

                        var importPattern = /import\\s+(\\{[^}]+\\}|\\*\\s+as\\s+\\w+|\\w+)\\s+from\\s+['\"]([^'\"]+)['\"]/g;
                        code = code.replace(importPattern, function(match, imports, specifier) {
                            var mod = self._linkedModules[specifier];
                            if (!mod) return '';
                            var ns = mod.namespace || mod._namespace || {};
                            return 'var __import_' + specifier.replace(/[^a-zA-Z0-9]/g, '_') + ' = ' + JSON.stringify(ns);
                        });

                        code = code.replace(/export\\s+default\\s+/g, 'module.exports.default = ');
                        code = code.replace(/export\\s+(var|let|const|function|class)\\s+(\\w+)/g, function(match, type, name) {
                            return type + ' ' + name + '; module.exports.' + name + ' = ' + name;
                        });

                        var fn;
                        if (self._context) {
                            fn = __NoCo_vm_compileFunction(code, ['module', 'exports'], self._context, self.identifier);
                        } else {
                            fn = new Function('module', 'exports', code);
                        }
                        fn(moduleObj, exportsObj);

                        self._namespace = moduleObj.exports;
                        self.status = 'evaluated';
                        resolve();
                    } catch (e) {
                        self.status = 'errored';
                        self.error = e;
                        reject(e);
                    }
                });
            };

            Object.defineProperty(SourceTextModule.prototype, 'namespace', {
                get: function() { return this._namespace; },
                enumerable: true
            });

            vm.SourceTextModule = SourceTextModule;

            // --- SyntheticModule ---

            function SyntheticModule(exportNames, evaluateCallback, options) {
                if (!(this instanceof SyntheticModule)) {
                    return new SyntheticModule(exportNames, evaluateCallback, options);
                }
                options = options || {};
                this._exportNames = exportNames || [];
                this._evaluateCallback = evaluateCallback;
                this._context = options.context || null;
                this.identifier = options.identifier || '';
                this.status = 'unlinked';
                this._namespace = {};

                for (var i = 0; i < this._exportNames.length; i++) {
                    this._namespace[this._exportNames[i]] = undefined;
                }
            }

            SyntheticModule.prototype.setExport = function(name, value) {
                if (this._exportNames.indexOf(name) === -1) {
                    throw new ReferenceError('Export "' + name + '" is not defined in module');
                }
                this._namespace[name] = value;
            };

            SyntheticModule.prototype.link = function(linker) {
                var self = this;
                if (self.status !== 'unlinked') {
                    return Promise.reject(new Error('Module has already been linked'));
                }
                self.status = 'linked';
                return Promise.resolve();
            };

            SyntheticModule.prototype.evaluate = function() {
                var self = this;
                if (self.status !== 'linked') {
                    return Promise.reject(new Error('Module must be linked before evaluation'));
                }
                return new Promise(function(resolve, reject) {
                    try {
                        self._evaluateCallback.call(self);
                        self.status = 'evaluated';
                        resolve();
                    } catch (e) {
                        self.status = 'errored';
                        self.error = e;
                        reject(e);
                    }
                });
            };

            Object.defineProperty(SyntheticModule.prototype, 'namespace', {
                get: function() { return this._namespace; },
                enumerable: true
            });

            vm.SyntheticModule = SyntheticModule;

            // --- Module (base for constants) ---
            vm.Module = function Module() {};

            // --- constants ---
            vm.constants = { USE_MAIN_CONTEXT_DEFAULT_LOADER: 0 };

            return vm;
        })();
        """

        return context.evaluateScript(script)!
    }

    /// Install essential NoCo globals into a new JSContext for vm sandboxing.
    private static func installGlobals(in newContext: JSContext, from runtime: NodeRuntime) {
        let sourceContext = runtime.context

        let globalNames = [
            "console", "process", "Buffer",
            "setTimeout", "setInterval", "setImmediate",
            "clearTimeout", "clearInterval", "clearImmediate",
            "queueMicrotask", "require", "global", "globalThis",
            "__NoCo_EventEmitter"
        ]

        for name in globalNames {
            if let value = sourceContext.objectForKeyedSubscript(name as NSString),
               !value.isUndefined {
                newContext.setObject(value, forKeyedSubscript: name as NSString)
            }
        }

        newContext.evaluateScript("""
            if (typeof global === 'undefined') { global = this; }
            if (typeof globalThis === 'undefined') { globalThis = this; }
        """)
    }
}
