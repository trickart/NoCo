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
    private let jsQueue: DispatchQueue

    /// Worker thread context. nil for the main thread.
    public let workerContext: WorkerContext?

    /// Context passed to a worker thread runtime.
    public struct WorkerContext {
        public let threadId: Int
        public let workerDataJSON: String?
        /// Called from the worker's jsQueue to send a message (JSON) to the parent.
        public let parentSendMessage: @Sendable (String) -> Void
        /// Called from the parent to request the worker to stop.
        public let onTerminate: @Sendable () -> Void
        /// JSON string of environment variables to override process.env. nil = inherit.
        public let envJSON: String?
        /// Called from worker to forward stdout output to parent's PassThrough stream.
        public let stdoutWrite: (@Sendable (String) -> Void)?
        /// Called from worker to forward stderr output to parent's PassThrough stream.
        public let stderrWrite: (@Sendable (String) -> Void)?

        public init(
            threadId: Int,
            workerDataJSON: String?,
            parentSendMessage: @escaping @Sendable (String) -> Void,
            onTerminate: @escaping @Sendable () -> Void,
            envJSON: String? = nil,
            stdoutWrite: (@Sendable (String) -> Void)? = nil,
            stderrWrite: (@Sendable (String) -> Void)? = nil
        ) {
            self.threadId = threadId
            self.workerDataJSON = workerDataJSON
            self.parentSendMessage = parentSendMessage
            self.onTerminate = onTerminate
            self.envJSON = envJSON
            self.stdoutWrite = stdoutWrite
            self.stderrWrite = stderrWrite
        }
    }

    /// Console output handler. Called for every console.log/warn/error/etc.
    /// Defaults to writing to stdout (log/info/debug) or stderr (warn/error).
    /// Replace this closure to redirect or capture console output.
    public var consoleHandler: (ConsoleLevel, String) -> Void = { level, message in
        switch level {
        case .error, .warn:
            fputs(message + "\n", stderr)
        case .log, .info, .debug:
            print(message)
            fflush(stdout)
        }
    }

    /// Console log levels.
    public enum ConsoleLevel: String {
        case log, info, warn, error, debug
    }

    /// Raw stdout write handler. Called by process.stdout.write().
    /// Does NOT append newline. Replace to capture stdout output in tests.
    public var stdoutHandler: (String) -> Void = { str in
        print(str, terminator: "")
        fflush(stdout)
    }

    /// Raw stderr write handler. Called by process.stderr.write().
    /// Does NOT append newline. Replace to capture stderr output in tests.
    public var stderrHandler: (String) -> Void = { str in
        fputs(str, stderr)
    }

    /// The argument list exposed as `process.argv` in JavaScript.
    /// Defaults to `CommandLine.arguments` but can be overridden to follow
    /// Node.js conventions: `[execPath, scriptPath, ...userArgs]`.
    public var argv: [String]

    /// Filesystem sandbox configuration for this runtime instance.
    public var fsConfiguration = FSConfiguration()

    /// Initialize a new NodeRuntime with optional configuration.
    public init(
        argv: [String] = CommandLine.arguments,
        workerContext: WorkerContext? = nil,
        configure: ((NodeRuntime) -> Void)? = nil
    ) {
        self.argv = argv
        self.workerContext = workerContext
        if workerContext != nil {
            jsQueue = DispatchQueue(label: "com.nodecore.js.worker-\(workerContext!.threadId)", qos: .userInitiated)
        } else {
            jsQueue = DispatchQueue(label: "com.nodecore.js", qos: .userInitiated)
        }
        context = JSContext()!
        eventLoop = EventLoop(queue: jsQueue)
        moduleLoader = ModuleLoader(runtime: self)

        setupExceptionHandler()
        installBuiltinModules()

        eventLoop.onUncaughtException = { [weak self] in
            self?.checkException()
        }

        eventLoop.drainMicrotasks = { [weak self] in
            self?.context.evaluateScript("void 0")
        }

        eventLoop.onBeforeExit = { [weak self] in
            guard let self else { return false }
            let process = self.context.objectForKeyedSubscript("process")!
            let count = process.invokeMethod("listenerCount", withArguments: ["beforeExit"])!
            guard count.toInt32() > 0 else { return false }
            let exitCode = process.forProperty("exitCode") ?? JSValue(int32: 0, in: self.context)!
            process.invokeMethod("emit", withArguments: ["beforeExit", exitCode as Any])
            self.checkException()
            return self.eventLoop.hasPendingWork
        }

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
        let resolvedPath = ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw NoCoError.fileNotFound(resolvedPath)
        }
        let script = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        let strippedScript = ModuleLoader.stripShebang(script)
        return evaluate(strippedScript, sourceURL: resolvedPath)
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
    public func checkException() -> Bool {
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

        // Mixin EventEmitter onto process (must run after EventEmitter is installed)
        context.evaluateScript("""
            (function() {
                var EE = this.__NoCo_EventEmitter;
                if (!EE) return;
                var p = process;
                p._events = Object.create(null);
                p._maxListeners = EE.defaultMaxListeners;
                var proto = EE.prototype;
                var names = Object.getOwnPropertyNames(proto);
                for (var i = 0; i < names.length; i++) {
                    if (names[i] !== 'constructor') p[names[i]] = proto[names[i]];
                }
            })();
        """)

        WebCryptoModule.install(in: context, runtime: self)
        SharedArrayBufferModule.install(in: context, runtime: self)

        // Register require()-able modules
        registerModule(PathModule.self)
        registerModule(URLModule.self)
        registerModule(FSModule.self)
        registerModule(CryptoModule.self)
        registerModule(StreamModule.self)
        registerModule(HTTPModule.self)
        registerModule(HTTP2Module.self)
        registerModule(StringDecoderModule.self)
        registerModule(EventEmitterModule.self)
        registerModule(BufferModule.self)
        registerModule(TimersModule.self)
        registerModule(TimersPromisesModule.self)
        registerModule(UtilModule.self)
        registerModule(AssertModule.self)
        registerModule(ZlibModule.self)
        registerModule(NetModule.self)
        registerModule(OSModule.self)
        registerModule(QuerystringModule.self)
        registerModule(AsyncHooksModule.self)
        #if os(macOS)
        registerModule(ChildProcessModule.self)
        #endif
        registerModule(TTYModule.self)
        registerModule(ReadlineModule.self)
        registerModule(ConstantsModule.self)
        registerModule(ModuleModule.self)
        registerModule(HTTPSModule.self)
        registerModule(TestModule.self)
        registerModule(VmModule.self)
        registerModule(PerfHooksModule.self)
        registerModule(WorkerThreadsModule.self)
        registerModule(V8Module.self)
        registerModule(DNSModule.self)
        registerModule(TLSModule.self)

        // Ensure global is set (ProcessModule sets it, but guard as fallback)
        context.evaluateScript("""
            if (typeof global === 'undefined' || global !== this) {
                this.global = this;
                global = this;
            }
            """)

        // Global performance (Web API compatible)
        context.evaluateScript("""
            (function(g) {
                if (typeof g.performance === 'undefined') {
                    var _timeOrigin = Date.now();
                    var marks = {};
                    g.performance = {
                        now: function() { return Date.now() - _timeOrigin; },
                        timeOrigin: _timeOrigin,
                        mark: function(name) { marks[name] = { startTime: Date.now() - _timeOrigin }; },
                        measure: function(name, start, end) {
                            var s = marks[start] ? marks[start].startTime : 0;
                            var e = marks[end] ? marks[end].startTime : Date.now() - _timeOrigin;
                            return { name: name, duration: e - s, startTime: s };
                        },
                        clearMarks: function() { marks = {}; },
                        getEntries: function() { return []; },
                        getEntriesByName: function() { return []; },
                        getEntriesByType: function() { return []; },
                        toJSON: function() { return { timeOrigin: _timeOrigin }; }
                    };
                }
                // Minimal Event constructor
                if (typeof g.Event === 'undefined') {
                    g.Event = function Event(type, options) {
                        this.type = type;
                        this.bubbles = options && options.bubbles || false;
                        this.cancelable = options && options.cancelable || false;
                        this.composed = options && options.composed || false;
                        this.defaultPrevented = false;
                        this.target = null;
                        this.currentTarget = null;
                        this.timeStamp = Date.now();
                    };
                    g.Event.prototype.preventDefault = function() { this.defaultPrevented = true; };
                    g.Event.prototype.stopPropagation = function() {};
                    g.Event.prototype.stopImmediatePropagation = function() {};
                    g.CustomEvent = function CustomEvent(type, options) {
                        g.Event.call(this, type, options);
                        this.detail = options && options.detail || null;
                    };
                    g.CustomEvent.prototype = Object.create(g.Event.prototype);
                    g.CustomEvent.prototype.constructor = g.CustomEvent;
                }
                // Minimal EventTarget for compatibility
                if (typeof g.EventTarget === 'undefined') {
                    g.EventTarget = function EventTarget() {
                        this._listeners = {};
                    };
                    g.EventTarget.prototype.addEventListener = function(type, listener) {
                        if (!this._listeners[type]) this._listeners[type] = [];
                        this._listeners[type].push(listener);
                    };
                    g.EventTarget.prototype.removeEventListener = function(type, listener) {
                        if (!this._listeners[type]) return;
                        this._listeners[type] = this._listeners[type].filter(function(l) { return l !== listener; });
                    };
                    g.EventTarget.prototype.dispatchEvent = function(event) {
                        var listeners = this._listeners[event.type] || [];
                        for (var i = 0; i < listeners.length; i++) listeners[i].call(this, event);
                        return true;
                    };
                }
            })(this);
            """)

        // __urlParse bridge: parse a URL string using Foundation.URLComponents
        let urlParseBlock: @convention(block) (String) -> JSValue = { href in
            let ctx = JSContext.current()!
            let result = JSValue(newObjectIn: ctx)!
            guard let comp = URLComponents(string: href) else {
                result.setValue(href, forProperty: "href")
                return result
            }
            let scheme = comp.scheme ?? ""
            let hostname = comp.host ?? ""
            let port = comp.port.map { String($0) } ?? ""
            let pathname = comp.path.isEmpty ? "/" : comp.path
            let search = comp.query.map { "?\($0)" } ?? ""
            let hash = comp.fragment.map { "#\($0)" } ?? ""
            let user = comp.user ?? ""
            let password = comp.password ?? ""
            let auth = !user.isEmpty ? (password.isEmpty ? user : "\(user):\(password)") : ""
            let hostWithPort = !port.isEmpty ? "\(hostname):\(port)" : hostname
            let origin = !scheme.isEmpty ? "\(scheme)://\(hostWithPort)" : ""

            result.setValue(href, forProperty: "href")
            result.setValue(!scheme.isEmpty ? scheme + ":" : "", forProperty: "protocol")
            result.setValue(hostname, forProperty: "hostname")
            result.setValue(port, forProperty: "port")
            result.setValue(pathname, forProperty: "pathname")
            result.setValue(search, forProperty: "search")
            result.setValue(hash, forProperty: "hash")
            result.setValue(hostWithPort, forProperty: "host")
            result.setValue(origin, forProperty: "origin")
            result.setValue(auth, forProperty: "auth")
            result.setValue(user, forProperty: "username")
            result.setValue(password, forProperty: "password")
            return result
        }
        context.setObject(urlParseBlock, forKeyedSubscript: "__urlParse" as NSString)

        // Minimal browser-compat globals (URL, URLSearchParams, Blob)
        context.evaluateScript("""
            (function(g) {
                if (typeof g.Blob === 'undefined') {
                    g.Blob = function Blob(parts, options) {
                        options = options || {};
                        this._type = (options.type || '').toLowerCase();
                        var chunks = [];
                        var totalSize = 0;
                        if (parts) {
                            for (var i = 0; i < parts.length; i++) {
                                var part = parts[i];
                                var bytes;
                                if (typeof part === 'string') {
                                    bytes = new Uint8Array(Buffer.from(part, 'utf8'));
                                } else if (part instanceof ArrayBuffer) {
                                    bytes = new Uint8Array(part);
                                } else if (part instanceof Uint8Array) {
                                    bytes = new Uint8Array(part);
                                } else if (ArrayBuffer.isView(part)) {
                                    bytes = new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
                                } else if (part instanceof Blob) {
                                    bytes = part._data;
                                } else {
                                    bytes = new Uint8Array(Buffer.from(String(part), 'utf8'));
                                }
                                chunks.push(bytes);
                                totalSize += bytes.byteLength;
                            }
                        }
                        this._data = new Uint8Array(totalSize);
                        var offset = 0;
                        for (var j = 0; j < chunks.length; j++) {
                            this._data.set(chunks[j], offset);
                            offset += chunks[j].byteLength;
                        }
                    };
                    Object.defineProperty(g.Blob.prototype, 'size', {
                        get: function() { return this._data.byteLength; }
                    });
                    Object.defineProperty(g.Blob.prototype, 'type', {
                        get: function() { return this._type; }
                    });
                    g.Blob.prototype.arrayBuffer = function() {
                        var data = this._data;
                        return Promise.resolve(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
                    };
                    g.Blob.prototype.text = function() {
                        var data = this._data;
                        return Promise.resolve(Buffer.from(data).toString('utf8'));
                    };
                    g.Blob.prototype.slice = function(start, end, contentType) {
                        var size = this._data.byteLength;
                        start = start || 0;
                        end = (end === undefined || end === null) ? size : end;
                        if (start < 0) start = Math.max(size + start, 0);
                        if (end < 0) end = Math.max(size + end, 0);
                        start = Math.min(start, size);
                        end = Math.min(end, size);
                        var sliced = this._data.slice(start, end);
                        var blob = new Blob([], { type: contentType || this._type });
                        blob._data = sliced;
                        return blob;
                    };
                }

                function URLSearchParams(init) {
                    this._params = [];
                    if (typeof init === 'string') {
                        var s = init.charAt(0) === '?' ? init.slice(1) : init;
                        if (s) {
                            var pairs = s.split('&');
                            for (var i = 0; i < pairs.length; i++) {
                                var idx = pairs[i].indexOf('=');
                                if (idx === -1) {
                                    this._params.push([decodeURIComponent(pairs[i]), '']);
                                } else {
                                    this._params.push([
                                        decodeURIComponent(pairs[i].slice(0, idx)),
                                        decodeURIComponent(pairs[i].slice(idx + 1))
                                    ]);
                                }
                            }
                        }
                    }
                }
                URLSearchParams.prototype.get = function(name) {
                    for (var i = 0; i < this._params.length; i++) {
                        if (this._params[i][0] === name) return this._params[i][1];
                    }
                    return null;
                };
                URLSearchParams.prototype.has = function(name) {
                    for (var i = 0; i < this._params.length; i++) {
                        if (this._params[i][0] === name) return true;
                    }
                    return false;
                };
                URLSearchParams.prototype.toString = function() {
                    return this._params.map(function(p) {
                        return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
                    }).join('&');
                };
                URLSearchParams.prototype.forEach = function(cb) {
                    for (var i = 0; i < this._params.length; i++) {
                        cb(this._params[i][1], this._params[i][0], this);
                    }
                };
                g.URLSearchParams = URLSearchParams;

                function __urlHref(u) {
                    var s = u.protocol + '//';
                    if (u.username) { s += u.username; if (u.password) s += ':' + u.password; s += '@'; }
                    s += u.hostname;
                    if (u.port) s += ':' + u.port;
                    s += u.pathname + u.search + u.hash;
                    return s;
                }

                g.URL = function URL(input, base) {
                    if (!(this instanceof URL)) return new URL(input, base);
                    var href;
                    if (base !== undefined) {
                        var baseStr = (typeof base === 'object' && base && base.href) ? base.href : String(base);
                        // Simple base URL resolution
                        if (/^[a-zA-Z][a-zA-Z0-9+\\-.]*:\\/\\//.test(input)) {
                            href = input; // absolute URL
                        } else if (input.charAt(0) === '/') {
                            var m = baseStr.match(/^([a-zA-Z][a-zA-Z0-9+\\-.]*:\\/\\/[^/]*)/);
                            href = m ? m[1] + input : input;
                        } else {
                            var idx = baseStr.lastIndexOf('/');
                            href = baseStr.slice(0, idx + 1) + input;
                        }
                    } else {
                        href = String(input);
                    }
                    var parsed = __urlParse(href);
                    this._ = {
                        protocol: parsed.protocol || '',
                        hostname: parsed.hostname || '',
                        port: parsed.port || '',
                        pathname: parsed.pathname || '/',
                        search: parsed.search || '',
                        hash: parsed.hash || '',
                        username: parsed.username || '',
                        password: parsed.password || ''
                    };
                    this.searchParams = new URLSearchParams(this._.search);
                };

                (function() {
                    var simple = ['protocol','hostname','port','pathname','username','password'];
                    for (var i = 0; i < simple.length; i++) {
                        (function(prop) {
                            Object.defineProperty(g.URL.prototype, prop, {
                                get: function() { return this._[prop]; },
                                set: function(v) { this._[prop] = v; },
                                enumerable: true, configurable: true
                            });
                        })(simple[i]);
                    }
                    Object.defineProperty(g.URL.prototype, 'search', {
                        get: function() { return this._.search; },
                        set: function(v) {
                            this._.search = v;
                            this.searchParams = new URLSearchParams(v);
                        },
                        enumerable: true, configurable: true
                    });
                    Object.defineProperty(g.URL.prototype, 'hash', {
                        get: function() { return this._.hash; },
                        set: function(v) { this._.hash = v; },
                        enumerable: true, configurable: true
                    });
                    Object.defineProperty(g.URL.prototype, 'host', {
                        get: function() {
                            return this._.port ? this._.hostname + ':' + this._.port : this._.hostname;
                        },
                        set: function(v) {
                            var parts = v.split(':');
                            this._.hostname = parts[0];
                            this._.port = parts[1] || '';
                        },
                        enumerable: true, configurable: true
                    });
                    Object.defineProperty(g.URL.prototype, 'origin', {
                        get: function() { return this._.protocol + '//' + this.host; },
                        enumerable: true, configurable: true
                    });
                    Object.defineProperty(g.URL.prototype, 'href', {
                        get: function() { return __urlHref(this._); },
                        set: function(v) {
                            var p = __urlParse(v);
                            this._.protocol = p.protocol || '';
                            this._.hostname = p.hostname || '';
                            this._.port = p.port || '';
                            this._.pathname = p.pathname || '/';
                            this._.search = p.search || '';
                            this._.hash = p.hash || '';
                            this._.username = p.username || '';
                            this._.password = p.password || '';
                            this.searchParams = new URLSearchParams(this._.search);
                        },
                        enumerable: true, configurable: true
                    });
                })();

                g.URL.prototype.toString = function() { return this.href; };
                g.URL.prototype.toJSON = function() { return this.href; };

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
                if (!g.URL.canParse) {
                    g.URL.canParse = function(url, base) {
                        try {
                            new g.URL(url, base);
                            return true;
                        } catch(e) {
                            return false;
                        }
                    };
                }
            })(this);
            """)

        // V8-compatible Error.captureStackTrace / Error.prepareStackTrace polyfill
        context.evaluateScript("""
            (function(g) {
                // Parse JSC stack trace string into call site objects
                function parseStack(stackStr) {
                    if (!stackStr) return [];
                    var lines = stackStr.split('\\n');
                    var sites = [];
                    for (var i = 0; i < lines.length; i++) {
                        var line = lines[i];
                        // JSC format: "funcName@file:line:col" or "@file:line:col" or "funcName@"
                        var match = line.match(/^(.*)@(.*?):(\\d+):(\\d+)$/);
                        if (!match) {
                            match = line.match(/^(.*)@(.*?):(\\d+)$/);
                        }
                        if (!match) {
                            // Handle "funcName@" or "funcName@[native code]" (no line/col)
                            match = line.match(/^(.*)@(.*)$/);
                            if (match) match = [match[0], match[1], match[2], null, null];
                        }
                        if (match) {
                            (function(funcName, fileName, lineNo, colNo) {
                                sites.push({
                                    getFileName: function() { return fileName || null; },
                                    getLineNumber: function() { return parseInt(lineNo, 10) || null; },
                                    getColumnNumber: function() { return parseInt(colNo || '0', 10) || null; },
                                    getFunctionName: function() { return funcName || null; },
                                    getMethodName: function() { return funcName || null; },
                                    getTypeName: function() { return null; },
                                    isEval: function() { return false; },
                                    isNative: function() { return fileName === '[native code]'; },
                                    isConstructor: function() { return false; },
                                    isToplevel: function() { return !funcName; },
                                    getEvalOrigin: function() { return undefined; },
                                    getThis: function() { return undefined; },
                                    toString: function() {
                                        var s = funcName ? funcName : '<anonymous>';
                                        if (fileName) s += ' (' + fileName;
                                        if (lineNo) s += ':' + lineNo;
                                        if (colNo) s += ':' + colNo;
                                        if (fileName) s += ')';
                                        return s;
                                    }
                                });
                            })(match[1], match[2], match[3], match[4]);
                        }
                    }
                    return sites;
                }

                Error.captureStackTrace = function(targetObject, constructorOpt) {
                    var err = new Error();
                    var stackStr = err.stack || '';
                    // Parse into structured call sites
                    var callSites = parseStack(stackStr);
                    // Remove internal frames (captureStackTrace itself, and the caller if constructorOpt)
                    // Remove at least the first 2 frames (Error constructor + captureStackTrace)
                    callSites = callSites.slice(2);
                    if (constructorOpt) {
                        // Remove frames up to and including constructorOpt
                        var name = constructorOpt.name || '';
                        if (name) {
                            for (var i = 0; i < callSites.length; i++) {
                                if (callSites[i].getFunctionName() === name) {
                                    callSites = callSites.slice(i + 1);
                                    break;
                                }
                            }
                        }
                    }
                    // If prepareStackTrace is set, call it
                    if (typeof Error.prepareStackTrace === 'function') {
                        Object.defineProperty(targetObject, 'stack', {
                            get: function() {
                                var prep = Error.prepareStackTrace;
                                return prep(targetObject, callSites);
                            },
                            set: function(v) {
                                Object.defineProperty(targetObject, 'stack', {
                                    value: v, writable: true, configurable: true
                                });
                            },
                            configurable: true
                        });
                    } else {
                        // Format as string like V8
                        var formatted = callSites.map(function(s) { return '    at ' + s.toString(); }).join('\\n');
                        targetObject.stack = (targetObject.name || 'Error') +
                            (targetObject.message ? ': ' + targetObject.message : '') +
                            (formatted ? '\\n' + formatted : '');
                    }
                };
                Error.stackTraceLimit = 10;
            })(this);
            """)

        // Install ESM runtime functions (__esm_import, __esm_export, etc.)
        ESMRuntime.install(in: context, runtime: self)

        // Install IPC structured clone helpers (used by child_process advanced serialization)
        context.evaluateScript("""
        Object.defineProperty(globalThis, '__noco_ipc', {
            value: (function() {
                function serialize(value) {
                    var nextId = 0;
                    var seen = new WeakMap();
                    function walk(val) {
                        if (val === null || typeof val !== 'object') return val;
                        if (typeof val === 'function') return undefined;
                        // MessagePort — not transferable via serialization
                        if (val._isMessagePort) return { '$messagePort': true };
                        // SharedArrayBuffer
                        if (typeof SharedArrayBuffer !== 'undefined' && val instanceof SharedArrayBuffer) {
                            return { '$sab': val._sabId, '$sabLen': val.byteLength };
                        }
                        // Circular reference detection
                        if (seen.has(val)) return { '$circRef': seen.get(val) };
                        var id = nextId++;
                        seen.set(val, id);
                        // Date
                        if (val instanceof Date) return { '$id': id, '$date': val.toISOString() };
                        // RegExp
                        if (val instanceof RegExp) return { '$id': id, '$regexp': { source: val.source, flags: val.flags } };
                        // Map
                        if (val instanceof Map) {
                            var mapEntries = [];
                            val.forEach(function(v, k) { mapEntries.push([walk(k), walk(v)]); });
                            return { '$id': id, '$map': mapEntries };
                        }
                        // Set
                        if (val instanceof Set) {
                            var setItems = [];
                            val.forEach(function(v) { setItems.push(walk(v)); });
                            return { '$id': id, '$set': setItems };
                        }
                        // Error
                        if (val instanceof Error) {
                            return { '$id': id, '$error': { name: val.name, message: val.message, stack: val.stack, code: val.code } };
                        }
                        // ArrayBuffer (not SharedArrayBuffer)
                        if (val instanceof ArrayBuffer) {
                            return { '$id': id, '$ab': Array.from(new Uint8Array(val)) };
                        }
                        // TypedArray (Uint8Array, Int32Array, Float64Array, etc.)
                        if (ArrayBuffer.isView(val) && !(val instanceof DataView)) {
                            return { '$id': id, '$ta': { type: val.constructor.name, data: Array.from(val) } };
                        }
                        // DataView
                        if (val instanceof DataView) {
                            return { '$id': id, '$dv': { byteOffset: val.byteOffset, byteLength: val.byteLength, buffer: walk(val.buffer) } };
                        }
                        // Buffer (Node.js)
                        if (typeof Buffer !== 'undefined' && Buffer.isBuffer(val)) {
                            return { '$id': id, '$buffer': Array.from(val) };
                        }
                        // Array
                        if (Array.isArray(val)) {
                            var items = [];
                            for (var i = 0; i < val.length; i++) items[i] = walk(val[i]);
                            return { '$id': id, '$array': items };
                        }
                        // Plain object
                        var obj = { '$id': id };
                        var keys = Object.keys(val);
                        for (var i = 0; i < keys.length; i++) {
                            obj[keys[i]] = walk(val[keys[i]]);
                        }
                        return obj;
                    }
                    return JSON.stringify(walk(value));
                }
                function deserialize(jsonStr) {
                    var raw = JSON.parse(jsonStr);
                    var registry = {};
                    function restore(val) {
                        if (val === null || typeof val !== 'object') return val;
                        if (val['$circRef'] !== undefined) return registry[val['$circRef']];
                        if (val['$messagePort'] !== undefined) return {};
                        if (val['$sab'] !== undefined && typeof SharedArrayBuffer !== 'undefined') {
                            return SharedArrayBuffer._fromId(val['$sab']);
                        }
                        var id = val['$id'];
                        // Date
                        if (val['$date'] !== undefined) {
                            var d = new Date(val['$date']);
                            if (id !== undefined) registry[id] = d;
                            return d;
                        }
                        // RegExp
                        if (val['$regexp'] !== undefined) {
                            var r = new RegExp(val['$regexp'].source, val['$regexp'].flags);
                            if (id !== undefined) registry[id] = r;
                            return r;
                        }
                        // Map
                        if (val['$map'] !== undefined) {
                            var m = new Map();
                            if (id !== undefined) registry[id] = m;
                            var entries = val['$map'];
                            for (var i = 0; i < entries.length; i++) m.set(restore(entries[i][0]), restore(entries[i][1]));
                            return m;
                        }
                        // Set
                        if (val['$set'] !== undefined) {
                            var s = new Set();
                            if (id !== undefined) registry[id] = s;
                            var setItems = val['$set'];
                            for (var i = 0; i < setItems.length; i++) s.add(restore(setItems[i]));
                            return s;
                        }
                        // Error
                        if (val['$error'] !== undefined) {
                            var e = new Error(val['$error'].message);
                            e.name = val['$error'].name;
                            if (val['$error'].stack) e.stack = val['$error'].stack;
                            if (val['$error'].code) e.code = val['$error'].code;
                            if (id !== undefined) registry[id] = e;
                            return e;
                        }
                        // ArrayBuffer
                        if (val['$ab'] !== undefined) {
                            var ab = new Uint8Array(val['$ab']).buffer;
                            if (id !== undefined) registry[id] = ab;
                            return ab;
                        }
                        // TypedArray
                        if (val['$ta'] !== undefined) {
                            var TACtor = globalThis[val['$ta'].type] || Uint8Array;
                            var ta = new TACtor(val['$ta'].data);
                            if (id !== undefined) registry[id] = ta;
                            return ta;
                        }
                        // DataView
                        if (val['$dv'] !== undefined) {
                            var dvBuf = restore(val['$dv'].buffer);
                            var dv = new DataView(dvBuf, val['$dv'].byteOffset, val['$dv'].byteLength);
                            if (id !== undefined) registry[id] = dv;
                            return dv;
                        }
                        // Buffer
                        if (val['$buffer'] !== undefined && typeof Buffer !== 'undefined') {
                            var buf = Buffer.from(val['$buffer']);
                            if (id !== undefined) registry[id] = buf;
                            return buf;
                        }
                        // Array
                        if (val['$array'] !== undefined) {
                            var result = [];
                            if (id !== undefined) registry[id] = result;
                            var items = val['$array'];
                            for (var i = 0; i < items.length; i++) result[i] = restore(items[i]);
                            return result;
                        }
                        // Plain object
                        var result = {};
                        if (id !== undefined) registry[id] = result;
                        var keys = Object.keys(val);
                        for (var i = 0; i < keys.length; i++) {
                            if (keys[i] === '$id') continue;
                            result[keys[i]] = restore(val[keys[i]]);
                        }
                        return result;
                    }
                    return restore(raw);
                }
                return { serialize: serialize, deserialize: deserialize };
            })(),
            writable: false, enumerable: false, configurable: false
        });
        """)

        // WebAPIModule depends on Blob (for File extends Blob), so install after Blob
        WebAPIModule.install(in: context, runtime: self)

        // Setup child-side IPC if NODE_CHANNEL_PATH is set
        #if os(macOS)
        if let socketPath = ProcessInfo.processInfo.environment["NODE_CHANNEL_PATH"] {
            setupChildIPC(socketPath: socketPath)
        }
        #endif
    }

    #if os(macOS)
    /// Setup IPC channel for the child side of a fork().
    /// Connects to the parent's Unix domain socket, then installs
    /// `process.send()`, `process.disconnect()`, `process.connected`,
    /// and delivers incoming messages via `process.emit('message', data)`.
    private func setupChildIPC(socketPath: String) {
        guard let fd = IPCChannel.connectTo(path: socketPath) else { return }
        let ipcChannel = IPCChannel(fileDescriptor: fd, eventLoop: eventLoop)
        let process = context.objectForKeyedSubscript("process")!
        let useAdvanced = ProcessInfo.processInfo.environment["NODE_CHANNEL_SERIALIZATION_MODE"] == "advanced"

        process.setValue(true, forProperty: "connected")

        // process.send(message)
        let send: @convention(block) (JSValue) -> Void = { [weak self] message in
            guard let self else { return }
            let result: String
            if useAdvanced {
                let serialized = self.context.evaluateScript("globalThis.__noco_ipc.serialize")!
                    .call(withArguments: [message])!
                guard !serialized.isUndefined else { return }
                result = serialized.toString()
            } else {
                // Try JSON.stringify first; fall back to structured clone on failure (e.g. cyclic refs)
                let jsonResult = self.context.evaluateScript("JSON.stringify")!
                    .call(withArguments: [message])
                if let json = jsonResult, !json.isUndefined, self.context.exception == nil {
                    result = json.toString()
                } else {
                    self.context.exception = nil
                    let serialized = self.context.evaluateScript("globalThis.__noco_ipc.serialize")!
                        .call(withArguments: [message])!
                    guard !serialized.isUndefined else { return }
                    result = serialized.toString()
                }
            }
            ipcChannel.write(result)
        }
        process.setValue(unsafeBitCast(send, to: AnyObject.self), forProperty: "send")

        // process.disconnect()
        let disconnect: @convention(block) () -> Void = { [weak self] in
            guard !ipcChannel.isClosed else { return }
            ipcChannel.close()
            let p = self?.context.objectForKeyedSubscript("process")
            p?.setValue(false, forProperty: "connected")
            p?.invokeMethod("emit", withArguments: ["disconnect"])
            self?.eventLoop.releaseHandle()
        }
        process.setValue(unsafeBitCast(disconnect, to: AnyObject.self), forProperty: "disconnect")

        // Retain handle to keep event loop alive while IPC is open
        eventLoop.retainHandle()

        // Start reading IPC messages (delivered via enqueueCallback, so safe after EventEmitter init)
        ipcChannel.startReading(
            onMessage: { [weak self] jsonString in
                guard let self else { return }
                let ctx = self.context
                let parsed: JSValue
                if useAdvanced {
                    parsed = ctx.evaluateScript("globalThis.__noco_ipc.deserialize")!
                        .call(withArguments: [jsonString])!
                } else {
                    // Try JSON.parse first; fall back to structured clone deserialize
                    let jsonParsed = ctx.evaluateScript("JSON.parse")!
                        .call(withArguments: [jsonString])
                    if let jp = jsonParsed, !jp.isUndefined, ctx.exception == nil {
                        parsed = jp
                    } else {
                        ctx.exception = nil
                        parsed = ctx.evaluateScript("globalThis.__noco_ipc.deserialize")!
                            .call(withArguments: [jsonString])!
                    }
                }
                let p = ctx.objectForKeyedSubscript("process")!
                p.invokeMethod("emit", withArguments: ["message", parsed])
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                let p = self.context.objectForKeyedSubscript("process")!
                p.setValue(false, forProperty: "connected")
                p.invokeMethod("emit", withArguments: ["disconnect"])
                self.eventLoop.releaseHandle()
            }
        )
    }
    #endif
}
