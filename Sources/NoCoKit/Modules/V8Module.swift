import JavaScriptCore

/// Implements a minimal `v8` module stub.
/// Jest uses serialize/deserialize for caching and setFlagsFromString for GC control.
public struct V8Module: NodeModule {
    public static let moduleName = "v8"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var v8 = {};

            v8.serialize = function(value) {
                var json = globalThis.__noco_ipc.serialize(value);
                if (typeof Buffer !== 'undefined') {
                    return Buffer.from(json, 'utf8');
                }
                return new TextEncoder().encode(json);
            };

            v8.deserialize = function(buffer) {
                var str;
                if (typeof Buffer !== 'undefined' && Buffer.isBuffer(buffer)) {
                    str = buffer.toString('utf8');
                } else {
                    str = new TextDecoder().decode(buffer);
                }
                return globalThis.__noco_ipc.deserialize(str);
            };

            v8.setFlagsFromString = function(flags) {
                // No-op: JSC doesn't support V8 flags
            };

            v8.getHeapStatistics = function() {
                return {
                    total_heap_size: 0,
                    total_heap_size_executable: 0,
                    total_physical_size: 0,
                    total_available_size: 0,
                    used_heap_size: 0,
                    heap_size_limit: 0,
                    malloced_memory: 0,
                    peak_malloced_memory: 0,
                    does_zap_garbage: 0
                };
            };

            v8.getHeapSnapshot = function() {
                // Return a readable stream-like object
                var Readable = require('stream').Readable;
                if (Readable) {
                    var r = new Readable({ read: function() { this.push(null); } });
                    return r;
                }
                return { read: function() { return null; } };
            };

            return v8;
        })();
        """
        return context.evaluateScript(script)!
    }
}
