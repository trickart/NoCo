import JavaScriptCore

/// Implements the Node.js `querystring` module.
public struct QuerystringModule: NodeModule {
    public static let moduleName = "querystring"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var qs = {};

            qs.escape = function(str) {
                return encodeURIComponent(str);
            };

            qs.unescape = function(str) {
                try {
                    return decodeURIComponent(str);
                } catch (e) {
                    return str;
                }
            };

            qs.stringify = function(obj, sep, eq, options) {
                sep = sep || '&';
                eq = eq || '=';
                var encode = (options && typeof options.encodeURIComponent === 'function')
                    ? options.encodeURIComponent : qs.escape;

                if (obj === null || obj === undefined || typeof obj !== 'object') {
                    return '';
                }

                var keys = Object.keys(obj);
                var pairs = [];
                for (var i = 0; i < keys.length; i++) {
                    var key = keys[i];
                    var value = obj[key];
                    var encodedKey = encode(key);

                    if (Array.isArray(value)) {
                        for (var j = 0; j < value.length; j++) {
                            pairs.push(encodedKey + eq + encode(String(value[j])));
                        }
                    } else if (value === undefined) {
                        // skip undefined values
                    } else {
                        pairs.push(encodedKey + eq + encode(String(value)));
                    }
                }
                return pairs.join(sep);
            };

            qs.parse = function(str, sep, eq, options) {
                sep = sep || '&';
                eq = eq || '=';
                var maxKeys = 1000;
                if (options && typeof options.maxKeys === 'number') {
                    maxKeys = options.maxKeys;
                }
                var decode = (options && typeof options.decodeURIComponent === 'function')
                    ? options.decodeURIComponent : qs.unescape;

                var obj = Object.create(null);

                if (typeof str !== 'string' || str.length === 0) {
                    return obj;
                }

                var parts = str.split(sep);
                var len = (maxKeys > 0 && parts.length > maxKeys) ? maxKeys : parts.length;

                for (var i = 0; i < len; i++) {
                    var part = parts[i];
                    var eqIdx = part.indexOf(eq);
                    var key, value;

                    if (eqIdx >= 0) {
                        key = decode(part.substring(0, eqIdx));
                        value = decode(part.substring(eqIdx + eq.length));
                    } else {
                        key = decode(part);
                        value = '';
                    }

                    if (key in obj) {
                        if (Array.isArray(obj[key])) {
                            obj[key].push(value);
                        } else {
                            obj[key] = [obj[key], value];
                        }
                    } else {
                        obj[key] = value;
                    }
                }

                return obj;
            };

            qs.decode = qs.parse;
            qs.encode = qs.stringify;

            return qs;
        })();
        """

        return context.evaluateScript(script)!
    }
}
