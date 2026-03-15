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

            var ansiStyles = {
                reset: ['\\x1b[0m', '\\x1b[0m'],
                bold: ['\\x1b[1m', '\\x1b[22m'],
                dim: ['\\x1b[2m', '\\x1b[22m'],
                italic: ['\\x1b[3m', '\\x1b[23m'],
                underline: ['\\x1b[4m', '\\x1b[24m'],
                inverse: ['\\x1b[7m', '\\x1b[27m'],
                hidden: ['\\x1b[8m', '\\x1b[28m'],
                strikethrough: ['\\x1b[9m', '\\x1b[29m'],
                black: ['\\x1b[30m', '\\x1b[39m'],
                red: ['\\x1b[31m', '\\x1b[39m'],
                green: ['\\x1b[32m', '\\x1b[39m'],
                yellow: ['\\x1b[33m', '\\x1b[39m'],
                blue: ['\\x1b[34m', '\\x1b[39m'],
                magenta: ['\\x1b[35m', '\\x1b[39m'],
                cyan: ['\\x1b[36m', '\\x1b[39m'],
                white: ['\\x1b[37m', '\\x1b[39m'],
                gray: ['\\x1b[90m', '\\x1b[39m'],
                grey: ['\\x1b[90m', '\\x1b[39m'],
                bgBlack: ['\\x1b[40m', '\\x1b[49m'],
                bgRed: ['\\x1b[41m', '\\x1b[49m'],
                bgGreen: ['\\x1b[42m', '\\x1b[49m'],
                bgYellow: ['\\x1b[43m', '\\x1b[49m'],
                bgBlue: ['\\x1b[44m', '\\x1b[49m'],
                bgMagenta: ['\\x1b[45m', '\\x1b[49m'],
                bgCyan: ['\\x1b[46m', '\\x1b[49m'],
                bgWhite: ['\\x1b[47m', '\\x1b[49m'],
            };

            util.styleText = function styleText(format, text) {
                if (Array.isArray(format)) {
                    var result = text;
                    for (var i = 0; i < format.length; i++) {
                        result = util.styleText(format[i], result);
                    }
                    return result;
                }
                var style = ansiStyles[format];
                if (!style) return String(text);
                return style[0] + text + style[1];
            };

            util.stripVTControlCharacters = function stripVTControlCharacters(str) {
                return String(str).replace(/\\x1b\\[[0-9;]*m/g, '');
            };

            util.parseEnv = function parseEnv(content) {
                var result = {};
                var lines = String(content).split('\\n');
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (!line || line[0] === '#') continue;
                    var eq = line.indexOf('=');
                    if (eq === -1) continue;
                    var key = line.substring(0, eq).trim();
                    var val = line.substring(eq + 1).trim();
                    if ((val[0] === '"' && val[val.length-1] === '"') ||
                        (val[0] === "'" && val[val.length-1] === "'")) {
                        val = val.substring(1, val.length - 1);
                    }
                    result[key] = val;
                }
                return result;
            };

            return util;
        })();
        """

        return context.evaluateScript(script)!
    }
}
