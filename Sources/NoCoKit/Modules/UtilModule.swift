import JavaScriptCore

/// Implements the Node.js `util` module (minimal subset for pngjs compatibility).
public struct UtilModule: NodeModule {
    public static let moduleName = "util"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var util = {};

            util.inherits = function(ctor, superCtor) {
                if (superCtor) {
                    ctor.super_ = superCtor;
                    Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
                }
            };

            util.deprecate = function(fn, msg) {
                return fn;
            };

            util.format = function(fmt) {
                if (typeof fmt !== 'string') {
                    var args = [];
                    for (var i = 0; i < arguments.length; i++) {
                        args.push(String(arguments[i]));
                    }
                    return args.join(' ');
                }
                var args = Array.prototype.slice.call(arguments, 1);
                var idx = 0;
                var result = fmt.replace(/%[sdj%]/g, function(match) {
                    if (match === '%%') return '%';
                    if (idx >= args.length) return match;
                    var arg = args[idx++];
                    if (match === '%s') return String(arg);
                    if (match === '%d') return Number(arg).toString();
                    if (match === '%j') {
                        try { return JSON.stringify(arg); }
                        catch(e) { return '[Circular]'; }
                    }
                    return match;
                });
                while (idx < args.length) {
                    result += ' ' + String(args[idx++]);
                }
                return result;
            };

            util.formatWithOptions = function(inspectOptions) {
                var args = Array.prototype.slice.call(arguments, 1);
                return util.format.apply(null, args);
            };

            util.inspect = function(obj, opts) {
                try {
                    return JSON.stringify(obj);
                } catch(e) {
                    return String(obj);
                }
            };

            util.isArray = Array.isArray;
            util.isBoolean = function(v) { return typeof v === 'boolean'; };
            util.isNull = function(v) { return v === null; };
            util.isNumber = function(v) { return typeof v === 'number'; };
            util.isString = function(v) { return typeof v === 'string'; };
            util.isUndefined = function(v) { return typeof v === 'undefined'; };
            util.isObject = function(v) { return typeof v === 'object' && v !== null; };
            util.isFunction = function(v) { return typeof v === 'function'; };

            var kCustomPromisifiedSymbol = Symbol.for('nodejs.util.promisify.custom');

            util.promisify = function promisify(original) {
                if (typeof original !== 'function') {
                    throw new TypeError('The "original" argument must be of type Function');
                }

                if (original[kCustomPromisifiedSymbol]) {
                    var customFn = original[kCustomPromisifiedSymbol];
                    if (typeof customFn !== 'function') {
                        throw new TypeError('The "util.promisify.custom" argument must be of type Function');
                    }
                    return customFn;
                }

                function fn() {
                    var args = Array.prototype.slice.call(arguments);
                    var self = this;
                    return new Promise(function(resolve, reject) {
                        args.push(function(err, val) {
                            if (err) {
                                reject(err);
                            } else if (arguments.length > 2) {
                                var results = Array.prototype.slice.call(arguments, 1);
                                resolve(results);
                            } else {
                                resolve(val);
                            }
                        });
                        original.apply(self, args);
                    });
                }

                return fn;
            };

            util.promisify.custom = kCustomPromisifiedSymbol;

            util.inspect.custom = Symbol.for('nodejs.util.inspect.custom');

            util.TextDecoder = typeof TextDecoder !== 'undefined' ? TextDecoder : undefined;
            util.TextEncoder = typeof TextEncoder !== 'undefined' ? TextEncoder : undefined;

            return util;
        })();
        """

        return context.evaluateScript(script)!
    }
}
