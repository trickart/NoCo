import JavaScriptCore

/// Implements `require('timers/promises')` — promise-based timer APIs.
public struct TimersPromisesModule: NodeModule {
    public static let moduleName = "timers/promises"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let exports = context.evaluateScript("""
            (function() {
                var exports = {};
                exports.setTimeout = function(delay, value, options) {
                    return new Promise(function(resolve) {
                        globalThis.setTimeout(function() { resolve(value); }, delay || 0);
                    });
                };
                exports.setImmediate = function(value, options) {
                    return new Promise(function(resolve) {
                        globalThis.setImmediate(function() { resolve(value); });
                    });
                };
                exports.setInterval = function(delay, value, options) {
                    // Return a minimal async iterable stub
                    var cancelled = false;
                    var obj = {};
                    obj[Symbol.asyncIterator] = function() {
                        return {
                            next: function() {
                                if (cancelled) return Promise.resolve({ done: true, value: undefined });
                                return new Promise(function(resolve) {
                                    globalThis.setTimeout(function() {
                                        if (cancelled) {
                                            resolve({ done: true, value: undefined });
                                        } else {
                                            resolve({ done: false, value: value });
                                        }
                                    }, delay || 0);
                                });
                            },
                            return: function() {
                                cancelled = true;
                                return Promise.resolve({ done: true, value: undefined });
                            }
                        };
                    };
                    return obj;
                };
                return exports;
            })()
            """)!
        return exports
    }
}
