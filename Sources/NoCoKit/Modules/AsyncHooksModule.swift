import JavaScriptCore

/// Implements the Node.js `async_hooks` module (AsyncLocalStorage subset).
public struct AsyncHooksModule: NodeModule {
    public static let moduleName = "async_hooks"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            function AsyncLocalStorage() {
                this._store = undefined;
            }

            AsyncLocalStorage.prototype.run = function(store, callback) {
                var previous = this._store;
                this._store = store;
                try {
                    var args = [];
                    for (var i = 2; i < arguments.length; i++) {
                        args.push(arguments[i]);
                    }
                    var result = callback.apply(null, args);
                    this._store = previous;
                    if (result && typeof result.then === 'function') {
                        // Use Promise.prototype.then to avoid triggering
                        // Symbol.species (which can re-invoke subclass
                        // constructors like ProcessPromise and cause disarm).
                        var self = this;
                        var savedStore = store;
                        Promise.prototype.then.call(result,
                            function(v) { self._store = previous; },
                            function(e) { self._store = previous; }
                        );
                        this._store = savedStore;
                    }
                    return result;
                } catch(e) {
                    this._store = previous;
                    throw e;
                }
            };

            AsyncLocalStorage.prototype.getStore = function() {
                return this._store;
            };

            AsyncLocalStorage.prototype.exit = function(callback) {
                var previous = this._store;
                this._store = undefined;
                try {
                    var args = [];
                    for (var i = 1; i < arguments.length; i++) {
                        args.push(arguments[i]);
                    }
                    var result = callback.apply(null, args);
                    this._store = previous;
                    return result;
                } catch(e) {
                    this._store = previous;
                    throw e;
                }
            };

            AsyncLocalStorage.prototype.enterWith = function(store) {
                this._store = store;
            };

            AsyncLocalStorage.prototype.disable = function() {
                this._store = undefined;
            };

            function AsyncResource(type, opts) {
                this.type = type;
            }
            AsyncResource.prototype.runInAsyncScope = function(fn, thisArg) {
                var args = [];
                for (var i = 2; i < arguments.length; i++) {
                    args.push(arguments[i]);
                }
                return fn.apply(thisArg, args);
            };
            AsyncResource.prototype.emitDestroy = function() { return this; };
            AsyncResource.prototype.asyncId = function() { return 0; };
            AsyncResource.prototype.triggerAsyncId = function() { return 0; };

            return {
                AsyncLocalStorage: AsyncLocalStorage,
                AsyncResource: AsyncResource
            };
        })()
        """
        return context.evaluateScript(script)!
    }
}
