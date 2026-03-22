import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

/// Implements the Node.js `worker_threads` module.
public struct WorkerThreadsModule: NodeModule {
    public static let moduleName = "worker_threads"

    /// Global thread ID counter. Main thread = 0, workers start at 1.
    private static let nextThreadId = Mutex<Int>(1)

    private static func allocateThreadId() -> Int {
        nextThreadId.withLock { id in
            let current = id
            id += 1
            return current
        }
    }

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let workerThreads = JSValue(newObjectIn: context)!

        let isMain = runtime.workerContext == nil
        let threadId = runtime.workerContext?.threadId ?? 0

        workerThreads.setValue(isMain, forProperty: "isMainThread")
        workerThreads.setValue(threadId, forProperty: "threadId")

        if isMain {
            workerThreads.setValue(JSValue(nullIn: context), forProperty: "parentPort")
            workerThreads.setValue(JSValue(nullIn: context), forProperty: "workerData")
        } else {
            let parentPort = createParentPort(context: context, runtime: runtime)
            workerThreads.setValue(parentPort, forProperty: "parentPort")

            if let json = runtime.workerContext?.workerDataJSON {
                let data = context.evaluateScript("JSON.parse")!.call(withArguments: [json])
                workerThreads.setValue(data, forProperty: "workerData")
            } else {
                workerThreads.setValue(JSValue(nullIn: context), forProperty: "workerData")
            }
        }

        installWorkerConstructor(workerThreads, context: context, runtime: runtime)
        installMessageChannel(workerThreads, context: context)

        return workerThreads
    }

    // MARK: - parentPort (worker side)

    private static func createParentPort(context: JSContext, runtime: NodeRuntime) -> JSValue {
        let parentPort = JSValue(newObjectIn: context)!

        // Mixin EventEmitter
        mixinEventEmitter(parentPort, context: context)

        // Wrap on() to retainHandle when 'message' listener is added (keeps event loop alive)
        context.evaluateScript("""
            (function(port) {
                var _origOn = port.on;
                var _refCount = 0;
                port._ref = true;
                port.on = function(event, fn) {
                    if (event === 'message' && port._ref) {
                        _refCount++;
                        if (_refCount === 1) port._retainHandle();
                    }
                    return _origOn.call(this, event, fn);
                };
                var _origRemove = port.removeListener;
                port.removeListener = function(event, fn) {
                    if (event === 'message' && port._ref) {
                        _refCount--;
                        if (_refCount === 0) port._releaseHandle();
                    }
                    return _origRemove.call(this, event, fn);
                };
                port.unref = function() {
                    if (port._ref && _refCount > 0) port._releaseHandle();
                    port._ref = false;
                    return port;
                };
                port.ref = function() {
                    if (!port._ref && _refCount > 0) port._retainHandle();
                    port._ref = true;
                    return port;
                };
            })
        """)!.call(withArguments: [parentPort])

        let retainHandle: @convention(block) () -> Void = {
            runtime.eventLoop.retainHandle()
        }
        parentPort.setValue(unsafeBitCast(retainHandle, to: AnyObject.self), forProperty: "_retainHandle")

        let releaseHandle: @convention(block) () -> Void = {
            runtime.eventLoop.releaseHandle()
        }
        parentPort.setValue(unsafeBitCast(releaseHandle, to: AnyObject.self), forProperty: "_releaseHandle")

        // parentPort.postMessage(value) — sends message to parent
        // Use structured clone serialization to handle circular references (like vitest's test objects)
        let postMessage: @convention(block) (JSValue) -> Void = { value in
            let ctx = JSContext.current()!
            let serialized = ctx.evaluateScript("globalThis.__noco_ipc.serialize")!
                .call(withArguments: [value])!
            guard !serialized.isUndefined else { return }
            let jsonStr = serialized.toString()!
            runtime.workerContext?.parentSendMessage(jsonStr)
        }
        parentPort.setValue(unsafeBitCast(postMessage, to: AnyObject.self), forProperty: "postMessage")

        // parentPort.close() — release handle and stop receiving messages
        let close: @convention(block) () -> Void = {
            runtime.eventLoop.releaseHandle()
        }
        parentPort.setValue(unsafeBitCast(close, to: AnyObject.self), forProperty: "close")

        return parentPort
    }

    // MARK: - Worker constructor (parent side)

    private static func installWorkerConstructor(
        _ workerThreads: JSValue, context: JSContext, runtime: NodeRuntime
    ) {
        let workerCtor: @convention(block) () -> JSValue = {
            createWorker(runtime: runtime)
        }
        workerThreads.setValue(unsafeBitCast(workerCtor, to: AnyObject.self), forProperty: "Worker")
    }

    private static func createWorker(runtime: NodeRuntime) -> JSValue {
        let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
        let ctx = JSContext.current()!

        guard let filenameVal = jsArgs.first, filenameVal.isString else {
            ctx.exception = ctx.createError("Worker requires a filename or code string")
            return JSValue(undefinedIn: ctx)
        }
        let filename = filenameVal.toString()!

        let options = jsArgs.count > 1 && jsArgs[1].isObject ? jsArgs[1] : nil
        let isEval = options?.forProperty("eval")?.toBool() ?? false
        let stdoutOpt = options?.forProperty("stdout")?.toBool() ?? false
        let stderrOpt = options?.forProperty("stderr")?.toBool() ?? false
        // execArgv: accepted but no-op (JSC has no equivalent CLI options)

        // Serialize env option
        var envJSON: String? = nil
        if let envVal = options?.forProperty("env"), !envVal.isUndefined && !envVal.isNull {
            let json = ctx.evaluateScript("JSON.stringify")!.call(withArguments: [envVal])
            envJSON = json?.toString()
            if envJSON == "undefined" { envJSON = nil }
        }

        // Serialize workerData
        var workerDataJSON: String? = nil
        if let wd = options?.forProperty("workerData"), !wd.isUndefined && !wd.isNull {
            let json = ctx.evaluateScript("JSON.stringify")!.call(withArguments: [wd])
            workerDataJSON = json?.toString()
            if workerDataJSON == "undefined" { workerDataJSON = nil }
        }

        // Resolve file path
        let resolvedPath: String
        if isEval {
            resolvedPath = filename
        } else {
            let absPath: String
            if (filename as NSString).isAbsolutePath {
                absPath = filename
            } else {
                let cwd = FileManager.default.currentDirectoryPath
                absPath = (cwd as NSString).appendingPathComponent(filename)
            }
            resolvedPath = ((absPath as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        }

        // Create Worker JS object with EventEmitter
        let worker = JSValue(newObjectIn: ctx)!
        mixinEventEmitter(worker, context: ctx)

        let threadId = allocateThreadId()
        worker.setValue(threadId, forProperty: "threadId")

        // stdout/stderr PassThrough streams on parent side
        if stdoutOpt {
            let stdoutStream = ctx.evaluateScript("new (require('stream').PassThrough)()")!
            worker.setValue(stdoutStream, forProperty: "stdout")
        } else {
            worker.setValue(JSValue(nullIn: ctx), forProperty: "stdout")
        }
        if stderrOpt {
            let stderrStream = ctx.evaluateScript("new (require('stream').PassThrough)()")!
            worker.setValue(stderrStream, forProperty: "stderr")
        } else {
            worker.setValue(JSValue(nullIn: ctx), forProperty: "stderr")
        }

        // State tracking for terminate
        let workerState = WorkerState()

        // Create the worker runtime on a background thread
        runtime.eventLoop.retainHandle()

        let parentEventLoop = runtime.eventLoop

        // Closure: deliver message from worker → parent (called on worker's queue)
        // Use structured clone deserialization to reconstruct circular references
        let parentSendMessage: @Sendable (String) -> Void = { jsonStr in
            parentEventLoop.enqueueCallback {
                let parsed = runtime.context.evaluateScript("globalThis.__noco_ipc.deserialize")!
                    .call(withArguments: [jsonStr])
                worker.invokeMethod("emit", withArguments: ["message", parsed as Any])
            }
        }

        // Closure: terminate worker (called from parent)
        let onTerminate: @Sendable () -> Void = {
            let wRuntime = workerState.runtime
            wRuntime?.eventLoop.stop()
        }

        // Store a way to send messages parent → worker (set after worker runtime is created)
        let workerMailbox = WorkerMailbox()

        // worker.postMessage(value) — structured clone serialization for circular refs
        let postMessageParent: @convention(block) (JSValue) -> Void = { value in
            let ctx = JSContext.current()!
            let serialized = ctx.evaluateScript("globalThis.__noco_ipc.serialize")!
                .call(withArguments: [value])!
            guard !serialized.isUndefined else { return }
            let jsonStr = serialized.toString()!
            workerMailbox.send(jsonStr)
        }
        worker.setValue(unsafeBitCast(postMessageParent, to: AnyObject.self), forProperty: "postMessage")

        // worker.terminate() → Promise
        let terminate: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            let promiseFns = ctx.evaluateScript("""
                (function() {
                    var resolve, reject;
                    var p = new Promise(function(res, rej) { resolve = res; reject = rej; });
                    return { promise: p, resolve: resolve, reject: reject };
                })()
            """)!
            let promise = promiseFns.forProperty("promise")!

            let alreadyExited = workerState.markTerminating()
            if alreadyExited {
                let exitCode = workerState.exitCode
                promiseFns.forProperty("resolve")!.call(withArguments: [exitCode])
            } else {
                workerState.setTerminateResolve { code in
                    parentEventLoop.enqueueCallback {
                        promiseFns.forProperty("resolve")!.call(withArguments: [code])
                    }
                }
                onTerminate()
            }

            return promise
        }
        worker.setValue(unsafeBitCast(terminate, to: AnyObject.self), forProperty: "terminate")

        // worker.ref() / worker.unref() — stubs
        let ref: @convention(block) () -> Void = {}
        worker.setValue(unsafeBitCast(ref, to: AnyObject.self), forProperty: "ref")
        worker.setValue(unsafeBitCast(ref, to: AnyObject.self), forProperty: "unref")

        // Launch worker on background thread
        let capturedWorkerDataJSON = workerDataJSON
        let capturedEnvJSON = envJSON
        DispatchQueue.global(qos: .userInitiated).async {
            // Create stdio forwarding closures (worker thread → parent PassThrough)
            let parentStdoutWrite: (@Sendable (String) -> Void)?
            if stdoutOpt {
                parentStdoutWrite = { str in
                    parentEventLoop.enqueueCallback {
                        worker.forProperty("stdout")?.invokeMethod("write", withArguments: [str])
                    }
                }
            } else {
                parentStdoutWrite = nil
            }
            let parentStderrWrite: (@Sendable (String) -> Void)?
            if stderrOpt {
                parentStderrWrite = { str in
                    parentEventLoop.enqueueCallback {
                        worker.forProperty("stderr")?.invokeMethod("write", withArguments: [str])
                    }
                }
            } else {
                parentStderrWrite = nil
            }

            let workerCtx = NodeRuntime.WorkerContext(
                threadId: threadId,
                workerDataJSON: capturedWorkerDataJSON,
                parentSendMessage: parentSendMessage,
                onTerminate: onTerminate,
                envJSON: capturedEnvJSON,
                stdoutWrite: parentStdoutWrite,
                stderrWrite: parentStderrWrite
            )

            let workerRuntime = NodeRuntime(workerContext: workerCtx)
            workerState.setRuntime(workerRuntime)

            // Set up mailbox: parent → worker message delivery (structured clone deserialization)
            workerMailbox.setTarget(workerRuntime.eventLoop) { jsonStr in
                let parsed = workerRuntime.context.evaluateScript("globalThis.__noco_ipc.deserialize")!
                    .call(withArguments: [jsonStr])
                // Get the parentPort from the worker's require cache
                let wt = workerRuntime.context.evaluateScript("require('worker_threads')")!
                let pp = wt.forProperty("parentPort")!
                pp.invokeMethod("emit", withArguments: ["message", parsed as Any])
            }

            // Emit 'online' on parent
            parentEventLoop.enqueueCallback {
                worker.invokeMethod("emit", withArguments: ["online"])
            }

            // Set up worker stdio forwarding
            if let stdoutWrite = parentStdoutWrite {
                workerRuntime.stdoutHandler = { str in stdoutWrite(str) }
            }
            if let stderrWrite = parentStderrWrite {
                workerRuntime.stderrHandler = { str in stderrWrite(str) }
            }
            if parentStdoutWrite != nil || parentStderrWrite != nil {
                workerRuntime.consoleHandler = { level, message in
                    switch level {
                    case .error, .warn:
                        if let stderrWrite = parentStderrWrite {
                            stderrWrite(message + "\n")
                        } else if let stdoutWrite = parentStdoutWrite {
                            stdoutWrite(message + "\n")
                        }
                    case .log, .info, .debug:
                        if let stdoutWrite = parentStdoutWrite {
                            stdoutWrite(message + "\n")
                        }
                    }
                }
            } else {
                // No stdio streams — suppress output (errors forwarded via 'error' event)
                workerRuntime.consoleHandler = { _, _ in }
            }

            // Execute the script using perform to check exceptions before they're cleared
            var hadError = false
            workerRuntime.perform { ctx in
                if isEval {
                    ctx.evaluateScript(resolvedPath)
                } else {
                    // Use require() to load the file so ESM detection/transform is applied
                    ctx.evaluateScript("require(\(Self.jsStringLiteral(resolvedPath)))")
                }
                if let exception = ctx.exception {
                    hadError = true
                    let errMsg = exception.toString() ?? "Unknown error"
                    let errStack = exception.forProperty("stack")?.toString() ?? ""
                    ctx.exception = nil
                    parentEventLoop.enqueueCallback {
                        let err = runtime.context.createError(errMsg)
                        err.setValue(errStack, forProperty: "stack")
                        worker.invokeMethod("emit", withArguments: ["error", err])
                    }
                }
            }

            // Run worker event loop (blocks until no more work or stop() is called)
            if !hadError {
                workerRuntime.perform { _ in
                    workerRuntime.eventLoop.run(timeout: .infinity)
                }
            }

            // Worker has finished
            let exitCode = hadError ? 1 : 0
            workerState.markExited(code: exitCode)

            parentEventLoop.enqueueCallback {
                // End stdout/stderr streams before emitting exit
                if let stdout = worker.forProperty("stdout"), !stdout.isNull && !stdout.isUndefined {
                    stdout.invokeMethod("end", withArguments: [])
                }
                if let stderr = worker.forProperty("stderr"), !stderr.isNull && !stderr.isUndefined {
                    stderr.invokeMethod("end", withArguments: [])
                }
                worker.invokeMethod("emit", withArguments: ["exit", exitCode])
                runtime.eventLoop.releaseHandle()
            }
        }

        return worker
    }

    // MARK: - MessageChannel / MessagePort

    private static func installMessageChannel(_ workerThreads: JSValue, context: JSContext) {
        context.evaluateScript("""
            (function(wt) {
                var EE = this.__NoCo_EventEmitter;

                function MessagePort() {
                    this._peer = null;
                    this._closed = false;
                    if (EE) {
                        this._events = Object.create(null);
                        this._maxListeners = EE.defaultMaxListeners;
                        var proto = EE.prototype;
                        var names = Object.getOwnPropertyNames(proto);
                        for (var i = 0; i < names.length; i++) {
                            if (names[i] !== 'constructor') this[names[i]] = proto[names[i]];
                        }
                    }
                }

                MessagePort.prototype.postMessage = function(value) {
                    if (this._closed) return;
                    var peer = this._peer;
                    if (!peer || peer._closed) return;
                    var json;
                    try { json = globalThis.__noco_ipc.serialize(value); } catch(e) { return; }
                    // Deliver asynchronously via nextTick
                    process.nextTick(function() {
                        if (peer._closed) return;
                        var parsed;
                        try { parsed = globalThis.__noco_ipc.deserialize(json); } catch(e) { return; }
                        if (typeof peer.emit === 'function') {
                            peer.emit('message', parsed);
                        }
                    });
                };

                MessagePort.prototype.close = function() {
                    this._closed = true;
                    if (typeof this.emit === 'function') {
                        this.emit('close');
                    }
                };

                MessagePort.prototype.ref = function() { return this; };
                MessagePort.prototype.unref = function() { return this; };
                MessagePort.prototype.start = function() {};

                function MessageChannel() {
                    this.port1 = new MessagePort();
                    this.port2 = new MessagePort();
                    this.port1._peer = this.port2;
                    this.port2._peer = this.port1;
                }

                wt.MessagePort = MessagePort;
                wt.MessageChannel = MessageChannel;
            })
        """)!.call(withArguments: [workerThreads])
    }

    // MARK: - EventEmitter mixin helper

    /// Escape a Swift string into a JS string literal (with quotes).
    private static func jsStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    private static func mixinEventEmitter(_ target: JSValue, context: JSContext) {
        context.evaluateScript("""
            (function(obj) {
                var EE = this.__NoCo_EventEmitter;
                if (!EE) return;
                obj._events = Object.create(null);
                obj._maxListeners = EE.defaultMaxListeners;
                var proto = EE.prototype;
                var names = Object.getOwnPropertyNames(proto);
                for (var i = 0; i < names.length; i++) {
                    if (names[i] !== 'constructor') obj[names[i]] = proto[names[i]];
                }
            })
        """)!.call(withArguments: [target])
    }
}

// MARK: - Thread-safe helper types

/// Tracks worker lifecycle state across threads.
private final class WorkerState: Sendable {
    private struct State {
        var runtime: NodeRuntime?
        var exited: Bool = false
        var terminating: Bool = false
        var exitCode: Int = 0
        var terminateResolve: (@Sendable (Int) -> Void)?
    }
    private let state = Mutex(State())

    var runtime: NodeRuntime? {
        state.withLock { $0.runtime }
    }

    var exitCode: Int {
        state.withLock { $0.exitCode }
    }

    func setRuntime(_ runtime: NodeRuntime) {
        state.withLock { $0.runtime = runtime }
    }

    /// Mark as terminating. Returns true if already exited.
    func markTerminating() -> Bool {
        state.withLock { s in
            s.terminating = true
            return s.exited
        }
    }

    func setTerminateResolve(_ resolve: @escaping @Sendable (Int) -> Void) {
        state.withLock { $0.terminateResolve = resolve }
    }

    func markExited(code: Int) {
        let resolve = state.withLock { s in
            s.exited = true
            s.exitCode = code
            let r = s.terminateResolve
            s.terminateResolve = nil
            return r
        }
        resolve?(code)
    }
}

/// Delivers messages from parent to worker. Set up after worker runtime is created.
private final class WorkerMailbox: Sendable {
    private struct Target {
        var eventLoop: EventLoop?
        var handler: (@Sendable (String) -> Void)?
        var pendingMessages: [String] = []
    }
    private let target = Mutex(Target())

    func setTarget(_ eventLoop: EventLoop, handler: @escaping @Sendable (String) -> Void) {
        let pending = target.withLock { t in
            t.eventLoop = eventLoop
            t.handler = handler
            let msgs = t.pendingMessages
            t.pendingMessages.removeAll()
            return msgs
        }
        // Deliver any messages that were queued before the worker was ready
        for msg in pending {
            eventLoop.enqueueCallback { handler(msg) }
        }
    }

    func send(_ jsonStr: String) {
        let (eventLoop, handler) = target.withLock { t -> (EventLoop?, (@Sendable (String) -> Void)?) in
            if let el = t.eventLoop, let h = t.handler {
                return (el, h)
            }
            t.pendingMessages.append(jsonStr)
            return (nil, nil)
        }
        if let eventLoop, let handler {
            eventLoop.enqueueCallback { handler(jsonStr) }
        }
    }
}
