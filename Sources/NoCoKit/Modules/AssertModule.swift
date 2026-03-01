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
                try { block(); } catch(e) { threw = true; }
                if (!threw) {
                    throw new Error(message || 'AssertionError: Missing expected exception');
                }
            };

            return assert;
        })();
        """

        return context.evaluateScript(script)!
    }
}
