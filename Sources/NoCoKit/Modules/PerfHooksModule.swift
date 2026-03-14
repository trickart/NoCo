import JavaScriptCore

/// Implements a minimal `perf_hooks` module stub.
/// Jest uses `performance.mark()` for timing measurements.
public struct PerfHooksModule: NodeModule {
    public static let moduleName = "perf_hooks"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var perfHooks = {};

            var marks = {};

            var performance = {};
            performance.now = function() { return Date.now(); };
            performance.mark = function(name, options) {
                marks[name] = { startTime: Date.now(), detail: options ? options.detail : undefined };
            };
            performance.measure = function(name, startMark, endMark) {
                var start = marks[startMark] ? marks[startMark].startTime : 0;
                var end = marks[endMark] ? marks[endMark].startTime : Date.now();
                return { name: name, duration: end - start, startTime: start };
            };
            performance.clearMarks = function() { marks = {}; };
            performance.getEntries = function() { return []; };
            performance.getEntriesByName = function() { return []; };
            performance.getEntriesByType = function() { return []; };
            performance.timeOrigin = Date.now();
            performance.toJSON = function() { return { timeOrigin: performance.timeOrigin }; };

            perfHooks.performance = performance;
            perfHooks.PerformanceObserver = function PerformanceObserver(callback) {
                this.observe = function() {};
                this.disconnect = function() {};
            };

            return perfHooks;
        })();
        """
        return context.evaluateScript(script)!
    }
}
