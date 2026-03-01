import Foundation
import JavaScriptCore

/// Central runtime class that wraps JSContext and manages module registration,
/// evaluation, and thread-safe access. Mirrors Node.js's single-threaded model
/// using a dedicated serial DispatchQueue.
public final class NodeRuntime: @unchecked Sendable {
    /// The underlying JSContext. Access only via `perform(_:)` or from the runtime queue.
    public let context: JSContext

    /// The event loop for timers and nextTick.
    public let eventLoop: EventLoop

    /// The module loader for require().
    public internal(set) var moduleLoader: ModuleLoader!

    /// Registered built-in modules.
    internal var registeredModules: [String: NodeModule.Type] = [:]

    /// The dedicated serial queue for all JS operations.
    private let jsQueue = DispatchQueue(label: "com.nodecore.js", qos: .userInitiated)

    /// Console output handler. Called for every console.log/warn/error/etc.
    /// Defaults to writing to stdout (log/info/debug) or stderr (warn/error).
    /// Replace this closure to redirect or capture console output.
    public var consoleHandler: (ConsoleLevel, String) -> Void = { level, message in
        switch level {
        case .error, .warn:
            fputs(message + "\n", stderr)
        case .log, .info, .debug:
            print(message)
        }
    }

    /// Console log levels.
    public enum ConsoleLevel: String {
        case log, info, warn, error, debug
    }

    /// The argument list exposed as `process.argv` in JavaScript.
    /// Defaults to `CommandLine.arguments` but can be overridden to follow
    /// Node.js conventions: `[execPath, scriptPath, ...userArgs]`.
    public var argv: [String]

    /// Filesystem sandbox configuration for this runtime instance.
    public var fsConfiguration = FSConfiguration()

    /// Initialize a new NodeRuntime with optional configuration.
    public init(argv: [String] = CommandLine.arguments, configure: ((NodeRuntime) -> Void)? = nil) {
        self.argv = argv
        context = JSContext()!
        eventLoop = EventLoop(queue: jsQueue)
        moduleLoader = ModuleLoader(runtime: self)

        setupExceptionHandler()
        installBuiltinModules()

        configure?(self)
    }

    // MARK: - Evaluation

    /// Evaluate a JavaScript string and return the result.
    @discardableResult
    public func evaluate(_ script: String) -> JSValue? {
        let result = perform { ctx in
            ctx.evaluateScript(script)
        }
        checkException()
        return result
    }

    /// Evaluate a JavaScript string with a source URL for better error messages.
    @discardableResult
    public func evaluate(_ script: String, sourceURL: String) -> JSValue? {
        let result = perform { ctx in
            ctx.evaluateScript(script, withSourceURL: URL(string: sourceURL))
        }
        checkException()
        return result
    }

    /// Evaluate a JavaScript file at the given path.
    @discardableResult
    public func evaluateFile(at path: String) throws -> JSValue? {
        let resolvedPath = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw NoCoError.fileNotFound(resolvedPath)
        }
        let script = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        return evaluate(script, sourceURL: resolvedPath)
    }

    // MARK: - Module Registration

    /// Register an additional built-in module.
    public func registerModule(_ module: NodeModule.Type) {
        registeredModules[module.moduleName] = module
    }

    // MARK: - Event Loop

    /// Run the event loop until no pending work or timeout.
    public func runEventLoop(timeout: TimeInterval = 30) {
        perform { _ in
            self.eventLoop.run(timeout: timeout)
        }
    }

    // MARK: - Thread-Safe Access

    /// Execute a block synchronously on the JS queue, ensuring thread safety.
    @discardableResult
    public func perform<T>(_ block: (JSContext) -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            // Already on the JS queue
            return block(context)
        }
        return jsQueue.sync {
            block(self.context)
        }
    }

    // MARK: - Private

    private let queueKey = DispatchSpecificKey<Bool>()

    private func setupExceptionHandler() {
        jsQueue.setSpecific(key: queueKey, value: true)
        // Do NOT set context.exceptionHandler — it consumes exceptions and
        // prevents them from propagating as JS throws (breaks require() errors,
        // try/catch, etc.). Instead, callers check context.exception after
        // evaluation and log uncaught errors explicitly.
    }

    /// Check for an unhandled JS exception, log it, and clear it.
    /// Returns `true` if there was an exception.
    @discardableResult
    internal func checkException() -> Bool {
        guard let exception = context.exception else { return false }
        context.exception = nil
        let message = exception.toString() ?? "Unknown JS error"
        let stack = exception.forProperty("stack")?.toString() ?? ""
        consoleHandler(.error, "Uncaught \(message)\n\(stack)")
        return true
    }

    private func installBuiltinModules() {
        // Install globals first
        ConsoleModule.install(in: context, runtime: self)
        TimersModule.install(in: context, runtime: self)
        ProcessModule.install(in: context, runtime: self)
        BufferModule.install(in: context, runtime: self)
        EventEmitterModule.install(in: context, runtime: self)

        // Register require()-able modules
        registerModule(PathModule.self)
        registerModule(URLModule.self)
        registerModule(FSModule.self)
        registerModule(CryptoModule.self)
        registerModule(StreamModule.self)
        registerModule(HTTPModule.self)
        registerModule(StringDecoderModule.self)
        registerModule(EventEmitterModule.self)
        registerModule(BufferModule.self)
        registerModule(TimersModule.self)
        registerModule(UtilModule.self)
        registerModule(AssertModule.self)
        registerModule(ZlibModule.self)
        registerModule(NetModule.self)

        // Install global require and set up global object
        context.evaluateScript("""
            if (typeof global === 'undefined') { var global = this; }
            global.global = global;
            """)

        // Minimal browser-compat globals (URL.createObjectURL, Blob)
        context.evaluateScript("""
            (function(g) {
                if (typeof g.Blob === 'undefined') {
                    g.Blob = function Blob(parts, options) {
                        this._parts = parts || [];
                    };
                }
                if (typeof g.URL === 'undefined') {
                    g.URL = function URL(input, base) {
                        if (typeof input === 'string') {
                            this.href = input;
                        }
                    };
                }
                if (!g.URL.createObjectURL) {
                    g.URL.createObjectURL = function(blob) {
                        var hex = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                            var r = Math.random() * 16 | 0;
                            var v = c === 'x' ? r : (r & 0x3 | 0x8);
                            return v.toString(16);
                        });
                        return 'blob:null/' + hex;
                    };
                    g.URL.revokeObjectURL = function(url) {};
                }
            })(this);
            """)
    }
}
