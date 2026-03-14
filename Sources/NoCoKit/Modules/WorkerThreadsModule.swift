import JavaScriptCore

/// Implements a minimal `worker_threads` module stub.
/// Jest uses Worker for parallel test execution, but can fall back to single-threaded mode.
public struct WorkerThreadsModule: NodeModule {
    public static let moduleName = "worker_threads"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var workerThreads = {};

            workerThreads.isMainThread = true;
            workerThreads.parentPort = null;
            workerThreads.threadId = 0;
            workerThreads.workerData = null;

            workerThreads.Worker = function Worker(filename, options) {
                throw new Error('worker_threads.Worker is not supported in NoCo');
            };

            workerThreads.MessageChannel = function MessageChannel() {
                this.port1 = { postMessage: function() {}, on: function() {}, close: function() {} };
                this.port2 = { postMessage: function() {}, on: function() {}, close: function() {} };
            };

            workerThreads.MessagePort = function MessagePort() {};

            return workerThreads;
        })();
        """
        return context.evaluateScript(script)!
    }
}
