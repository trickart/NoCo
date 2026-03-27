import JavaScriptCore

/// Implements the Node.js `assert` module (minimal subset).
public struct AssertModule: NodeModule {
    public static let moduleName = "assert"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            function assert(value, message) {
                if (!value) {
                    throw new Error(message || 'AssertionError: ' + String(value) + ' == true');
                }
            }

            assert.ok = assert;

            assert.equal = function(actual, expected, message) {
                if (actual != expected) {
                    throw new Error(message || 'AssertionError: ' + actual + ' == ' + expected);
                }
            };

            assert.strictEqual = function(actual, expected, message) {
                if (actual !== expected) {
                    throw new Error(message || 'AssertionError: ' + actual + ' === ' + expected);
                }
            };

            assert.notEqual = function(actual, expected, message) {
                if (actual == expected) {
                    throw new Error(message || 'AssertionError: ' + actual + ' != ' + expected);
                }
            };

            assert.notStrictEqual = function(actual, expected, message) {
                if (actual === expected) {
                    throw new Error(message || 'AssertionError: ' + actual + ' !== ' + expected);
                }
            };

            assert.fail = function(message) {
                throw new Error(message || 'AssertionError: Failed');
            };

            assert.throws = function(block, error, message) {
                var threw = false;
                var caught;
                try { block(); } catch(e) { threw = true; caught = e; }
                if (!threw) {
                    throw new Error(message || 'AssertionError: Missing expected exception');
                }
                if (error) {
                    if (error instanceof RegExp) {
                        if (!error.test(caught.message || String(caught))) {
                            throw new Error(message || 'AssertionError: ' + caught.message + ' does not match ' + error);
                        }
                    } else if (typeof error === 'function') {
                        if (!(caught instanceof error)) {
                            throw new Error(message || 'AssertionError: unexpected error type');
                        }
                    } else if (typeof error === 'object') {
                        var keys = Object.keys(error);
                        for (var i = 0; i < keys.length; i++) {
                            if (caught[keys[i]] !== error[keys[i]]) {
                                throw new Error(message || 'AssertionError: error.' + keys[i] + ' expected ' + JSON.stringify(error[keys[i]]) + ' but got ' + JSON.stringify(caught[keys[i]]));
                            }
                        }
                    }
                }
            };

            assert.doesNotThrow = function(block, message) {
                try { block(); } catch(e) {
                    throw new Error(message || 'AssertionError: Got unwanted exception: ' + e.message);
                }
            };

            function deepEqual(a, b) {
                if (a === b) return true;
                if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
                if (Array.isArray(a) !== Array.isArray(b)) return false;
                var keysA = Object.keys(a), keysB = Object.keys(b);
                if (keysA.length !== keysB.length) return false;
                for (var i = 0; i < keysA.length; i++) {
                    if (!Object.prototype.hasOwnProperty.call(b, keysA[i])) return false;
                    if (!deepEqual(a[keysA[i]], b[keysA[i]])) return false;
                }
                return true;
            }

            assert.deepEqual = function(actual, expected, message) {
                if (!deepEqual(actual, expected)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(actual) + ' deepEqual ' + JSON.stringify(expected));
                }
            };

            assert.deepStrictEqual = function(actual, expected, message) {
                if (!deepEqual(actual, expected)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(actual) + ' deepStrictEqual ' + JSON.stringify(expected));
                }
            };

            assert.notDeepEqual = function(actual, expected, message) {
                if (deepEqual(actual, expected)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(actual) + ' notDeepEqual ' + JSON.stringify(expected));
                }
            };

            assert.notDeepStrictEqual = function(actual, expected, message) {
                if (deepEqual(actual, expected)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(actual) + ' notDeepStrictEqual ' + JSON.stringify(expected));
                }
            };

            assert.rejects = function(asyncFn, error, message) {
                var promise = typeof asyncFn === 'function' ? asyncFn() : asyncFn;
                return promise.then(function() {
                    throw new Error(message || 'AssertionError: Missing expected rejection');
                }, function(caught) {
                    if (error) {
                        if (error instanceof RegExp) {
                            if (!error.test(caught.message || String(caught))) {
                                throw new Error(message || 'AssertionError: ' + caught.message + ' does not match ' + error);
                            }
                        } else if (typeof error === 'function') {
                            if (!(caught instanceof error)) {
                                throw new Error(message || 'AssertionError: unexpected rejection type');
                            }
                        } else if (typeof error === 'object') {
                            var keys = Object.keys(error);
                            for (var i = 0; i < keys.length; i++) {
                                if (caught[keys[i]] !== error[keys[i]]) {
                                    throw new Error(message || 'AssertionError: error.' + keys[i] + ' expected ' + JSON.stringify(error[keys[i]]) + ' but got ' + JSON.stringify(caught[keys[i]]));
                                }
                            }
                        }
                    }
                });
            };

            assert.doesNotReject = function(asyncFn, message) {
                var promise = typeof asyncFn === 'function' ? asyncFn() : asyncFn;
                return promise.then(function() {}, function(e) {
                    throw new Error(message || 'AssertionError: Got unwanted rejection: ' + e.message);
                });
            };

            assert.ifError = function(value) {
                if (value !== null && value !== undefined) {
                    throw value instanceof Error ? value : new Error('ifError got unwanted exception: ' + value);
                }
            };

            assert.match = function(string, regexp, message) {
                if (!regexp.test(string)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(string) + ' does not match ' + regexp);
                }
            };

            assert.doesNotMatch = function(string, regexp, message) {
                if (regexp.test(string)) {
                    throw new Error(message || 'AssertionError: ' + JSON.stringify(string) + ' should not match ' + regexp);
                }
            };

            return assert;
        })();
        """

        return context.evaluateScript(script)!
    }
}
