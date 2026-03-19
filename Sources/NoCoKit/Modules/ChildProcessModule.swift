#if os(macOS)
import Foundation
@preconcurrency import JavaScriptCore

/// Implements the Node.js `child_process` module.
public struct ChildProcessModule: NodeModule {
    public static let moduleName = "child_process"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let cp = JSValue(newObjectIn: context)!

        // MARK: - spawn(command, args?, options?)

        let spawn: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let command = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("spawn requires a command string")
                return JSValue(undefinedIn: ctx)
            }

            let args: [String]
            if jsArgs.count > 1 && jsArgs[1].isArray {
                let arr = jsArgs[1]
                let len = Int(arr.forProperty("length")!.toInt32())
                args = (0..<len).map { arr.atIndex($0).toString() ?? "" }
            } else {
                args = []
            }

            let options: JSValue? = jsArgs.count > 2 && jsArgs[2].isObject ? jsArgs[2] : (
                jsArgs.count > 1 && !jsArgs[1].isArray && jsArgs[1].isObject ? jsArgs[1] : nil
            )

            return spawnProcess(command: command, args: args, options: options,
                                context: ctx, runtime: runtime)
        }
        cp.setValue(unsafeBitCast(spawn, to: AnyObject.self), forProperty: "spawn")

        // MARK: - exec(command, options?, callback?)

        let exec: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let command = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("exec requires a command string")
                return JSValue(undefinedIn: ctx)
            }

            var options: JSValue? = nil
            var callback: JSValue? = nil

            if jsArgs.count >= 3 {
                if jsArgs[1].isObject && !isFunction(jsArgs[1], in: ctx) {
                    options = jsArgs[1]
                }
                if isFunction(jsArgs[2], in: ctx) {
                    callback = jsArgs[2]
                }
            } else if jsArgs.count == 2 {
                if isFunction(jsArgs[1], in: ctx) {
                    callback = jsArgs[1]
                } else if jsArgs[1].isObject {
                    options = jsArgs[1]
                }
            }

            let shell = getShellPath()
            let childProcess = spawnProcess(
                command: shell, args: ["-c", command], options: options,
                context: ctx, runtime: runtime)

            if let callback = callback {
                bufferAndCallback(childProcess: childProcess, callback: callback,
                                  options: options, runtime: runtime)
            }

            return childProcess
        }
        cp.setValue(unsafeBitCast(exec, to: AnyObject.self), forProperty: "exec")

        // MARK: - execFile(file, args?, options?, callback?)

        let execFile: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let file = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("execFile requires a file path")
                return JSValue(undefinedIn: ctx)
            }

            var args: [String] = []
            var options: JSValue? = nil
            var callback: JSValue? = nil

            var idx = 1
            if idx < jsArgs.count && jsArgs[idx].isArray {
                let arr = jsArgs[idx]
                let len = Int(arr.forProperty("length")!.toInt32())
                args = (0..<len).map { arr.atIndex($0).toString() ?? "" }
                idx += 1
            }
            if idx < jsArgs.count && jsArgs[idx].isObject && !isFunction(jsArgs[idx], in: ctx) {
                options = jsArgs[idx]
                idx += 1
            }
            if idx < jsArgs.count && isFunction(jsArgs[idx], in: ctx) {
                callback = jsArgs[idx]
            }

            let childProcess = spawnProcess(command: file, args: args, options: options,
                                            context: ctx, runtime: runtime)

            if let callback = callback {
                bufferAndCallback(childProcess: childProcess, callback: callback,
                                  options: options, runtime: runtime)
            }

            return childProcess
        }
        cp.setValue(unsafeBitCast(execFile, to: AnyObject.self), forProperty: "execFile")

        // MARK: - execSync(command, options?)

        let execSync: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let command = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("execSync requires a command string")
                return JSValue(undefinedIn: ctx)
            }

            let options: JSValue? = jsArgs.count > 1 && jsArgs[1].isObject ? jsArgs[1] : nil
            let shell = getShellPath()

            return runSync(executable: shell, args: ["-c", command],
                           options: options, context: ctx)
        }
        cp.setValue(unsafeBitCast(execSync, to: AnyObject.self), forProperty: "execSync")

        // MARK: - execFileSync(file, args?, options?)

        let execFileSync: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let file = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("execFileSync requires a file path")
                return JSValue(undefinedIn: ctx)
            }

            var args: [String] = []
            var options: JSValue? = nil
            var idx = 1
            if idx < jsArgs.count && jsArgs[idx].isArray {
                let arr = jsArgs[idx]
                let len = Int(arr.forProperty("length")!.toInt32())
                args = (0..<len).map { arr.atIndex($0).toString() ?? "" }
                idx += 1
            }
            if idx < jsArgs.count && jsArgs[idx].isObject {
                options = jsArgs[idx]
            }

            return runSync(executable: file, args: args, options: options, context: ctx)
        }
        cp.setValue(unsafeBitCast(execFileSync, to: AnyObject.self), forProperty: "execFileSync")

        // MARK: - spawnSync(command, args?, options?)

        let spawnSync: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let command = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("spawnSync requires a command string")
                return JSValue(undefinedIn: ctx)
            }

            var args: [String] = []
            var options: JSValue? = nil
            var idx = 1
            if idx < jsArgs.count && jsArgs[idx].isArray {
                let arr = jsArgs[idx]
                let len = Int(arr.forProperty("length")!.toInt32())
                args = (0..<len).map { arr.atIndex($0).toString() ?? "" }
                idx += 1
            }
            if idx < jsArgs.count && jsArgs[idx].isObject {
                options = jsArgs[idx]
            }

            let useShell: Bool
            if let opts = options, let shellVal = opts.forProperty("shell"), !shellVal.isUndefined {
                useShell = shellVal.toBool()
            } else {
                useShell = false
            }

            let executable: String
            let finalArgs: [String]
            if useShell {
                let shell = getShellPath()
                executable = shell
                let fullCommand = ([command] + args).joined(separator: " ")
                finalArgs = ["-c", fullCommand]
            } else {
                executable = command
                finalArgs = args
            }

            return runSpawnSync(executable: executable, args: finalArgs,
                                options: options, context: ctx)
        }
        cp.setValue(unsafeBitCast(spawnSync, to: AnyObject.self), forProperty: "spawnSync")

        // MARK: - fork(modulePath, args?, options?)

        let fork: @convention(block) () -> JSValue = {
            let jsArgs = JSContext.currentArguments() as? [JSValue] ?? []
            let ctx = JSContext.current()!
            guard let modulePath = jsArgs.first?.toString() else {
                ctx.exception = ctx.createError("fork requires a module path")
                return JSValue(undefinedIn: ctx)
            }

            var args: [String] = []
            var options: JSValue? = nil
            var idx = 1
            if idx < jsArgs.count && jsArgs[idx].isArray {
                let arr = jsArgs[idx]
                let len = Int(arr.forProperty("length")!.toInt32())
                args = (0..<len).map { arr.atIndex($0).toString() ?? "" }
                idx += 1
            }
            if idx < jsArgs.count && jsArgs[idx].isObject && !isFunction(jsArgs[idx], in: ctx) {
                options = jsArgs[idx]
                idx += 1
            }

            return forkProcess(modulePath: modulePath, args: args, options: options,
                               context: ctx, runtime: runtime)
        }
        cp.setValue(unsafeBitCast(fork, to: AnyObject.self), forProperty: "fork")

        return cp
    }

    // MARK: - Helper: Check if JSValue is a function

    private static func isFunction(_ value: JSValue, in context: JSContext) -> Bool {
        let result = context.evaluateScript("(function(v) { return typeof v === 'function'; })")!
        return result.call(withArguments: [value])!.toBool()
    }

    // MARK: - Helper: Get shell path

    private static func getShellPath() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            return shell
        }
        return "/bin/sh"
    }

    // MARK: - Helper: Create Foundation.Process

    private static func createProcess(
        executable: String, args: [String], options: JSValue?
    ) -> Process {
        let proc = Process()

        // Resolve executable path
        if executable.contains("/") {
            proc.executableURL = URL(fileURLWithPath: executable)
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [executable] + args
        }

        if proc.executableURL?.path != "/usr/bin/env" {
            proc.arguments = args
        }

        // Options: cwd
        if let opts = options, let cwdVal = opts.forProperty("cwd"), cwdVal.isString {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwdVal.toString()!)
        }

        // Options: env
        if let opts = options, let envVal = opts.forProperty("env"), envVal.isObject && !envVal.isUndefined {
            var env: [String: String] = [:]
            let keys = JSContext.current()!.evaluateScript("(function(o) { return Object.keys(o); })")!
            let keysArr = keys.call(withArguments: [envVal])!
            let len = Int(keysArr.forProperty("length")!.toInt32())
            for i in 0..<len {
                let key = keysArr.atIndex(i).toString()!
                let val = envVal.forProperty(key)?.toString() ?? ""
                env[key] = val
            }
            proc.environment = env
        }

        return proc
    }

    // MARK: - spawn implementation

    private static func spawnProcess(
        command: String, args: [String], options: JSValue?,
        context: JSContext, runtime: NodeRuntime
    ) -> JSValue {
        let useShell: Bool
        if let opts = options, let shellVal = opts.forProperty("shell"), !shellVal.isUndefined {
            if shellVal.isString {
                useShell = true
            } else {
                useShell = shellVal.toBool()
            }
        } else {
            useShell = false
        }

        let executable: String
        let finalArgs: [String]
        if useShell {
            let shell = getShellPath()
            executable = shell
            let fullCommand = ([command] + args).joined(separator: " ")
            finalArgs = ["-c", fullCommand]
        } else {
            executable = command
            finalArgs = args
        }

        let proc = createProcess(executable: executable, args: finalArgs, options: options)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe

        // Create ChildProcess JS object
        let childProcess = JSValue(newObjectIn: context)!

        // EventEmitter-like: store listeners
        context.evaluateScript("""
            (function(cp) {
                cp._listeners = {};
                cp.on = function(event, fn) {
                    if (!cp._listeners[event]) cp._listeners[event] = [];
                    cp._listeners[event].push(fn);
                    return cp;
                };
                cp.once = function(event, fn) {
                    fn._once = true;
                    return cp.on(event, fn);
                };
                cp.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = cp._listeners[event] || [];
                    var remaining = [];
                    for (var i = 0; i < fns.length; i++) {
                        fns[i].apply(cp, args);
                        if (!fns[i]._once) remaining.push(fns[i]);
                    }
                    cp._listeners[event] = remaining;
                };
                cp.removeListener = function(event, fn) {
                    var fns = cp._listeners[event] || [];
                    cp._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return cp;
                };
                cp.removeAllListeners = function(event) {
                    if (event) cp._listeners[event] = [];
                    else cp._listeners = {};
                    return cp;
                };
                cp.off = cp.removeListener;
            })
        """)!.call(withArguments: [childProcess])

        // stdout EventEmitter
        let stdout = JSValue(newObjectIn: context)!
        context.evaluateScript("""
            (function(s) {
                s._listeners = {};
                s.on = function(event, fn) {
                    if (!s._listeners[event]) s._listeners[event] = [];
                    s._listeners[event].push(fn);
                    return s;
                };
                s.once = function(event, fn) {
                    fn._once = true;
                    return s.on(event, fn);
                };
                s.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = s._listeners[event] || [];
                    var remaining = [];
                    for (var i = 0; i < fns.length; i++) {
                        fns[i].apply(s, args);
                        if (!fns[i]._once) remaining.push(fns[i]);
                    }
                    s._listeners[event] = remaining;
                };
                s.removeListener = function(event, fn) {
                    var fns = s._listeners[event] || [];
                    s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return s;
                };
                s.pipe = function(dest) {
                    s.on('data', function(chunk) { dest.write(chunk); });
                    s.on('end', function() { if (typeof dest.end === 'function') dest.end(); });
                    if (typeof dest.emit === 'function') dest.emit('pipe', s);
                    return dest;
                };
                s.setEncoding = function(enc) { s._encoding = enc; return s; };
            })
        """)!.call(withArguments: [stdout])
        childProcess.setValue(stdout, forProperty: "stdout")

        // stderr EventEmitter
        let stderr = JSValue(newObjectIn: context)!
        context.evaluateScript("""
            (function(s) {
                s._listeners = {};
                s.on = function(event, fn) {
                    if (!s._listeners[event]) s._listeners[event] = [];
                    s._listeners[event].push(fn);
                    return s;
                };
                s.once = function(event, fn) {
                    fn._once = true;
                    return s.on(event, fn);
                };
                s.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = s._listeners[event] || [];
                    var remaining = [];
                    for (var i = 0; i < fns.length; i++) {
                        fns[i].apply(s, args);
                        if (!fns[i]._once) remaining.push(fns[i]);
                    }
                    s._listeners[event] = remaining;
                };
                s.removeListener = function(event, fn) {
                    var fns = s._listeners[event] || [];
                    s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return s;
                };
                s.setEncoding = function(enc) { s._encoding = enc; return s; };
                s.pipe = function(dest) {
                    s.on('data', function(chunk) { dest.write(chunk); });
                    s.on('end', function() { if (typeof dest.end === 'function') dest.end(); });
                    if (typeof dest.emit === 'function') dest.emit('pipe', s);
                    return dest;
                };
            })
        """)!.call(withArguments: [stderr])
        childProcess.setValue(stderr, forProperty: "stderr")

        // stdin (writable with EventEmitter)
        let stdin = JSValue(newObjectIn: context)!
        context.evaluateScript("""
            (function(s) {
                s._listeners = {};
                s.destroyed = false;
                s.on = function(event, fn) {
                    if (!s._listeners[event]) s._listeners[event] = [];
                    s._listeners[event].push(fn);
                    return s;
                };
                s.once = function(event, fn) {
                    fn._once = true;
                    return s.on(event, fn);
                };
                s.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = s._listeners[event] || [];
                    var remaining = [];
                    for (var i = 0; i < fns.length; i++) {
                        fns[i].apply(s, args);
                        if (!fns[i]._once) remaining.push(fns[i]);
                    }
                    s._listeners[event] = remaining;
                    return fns.length > 0;
                };
                s.removeListener = function(event, fn) {
                    var fns = s._listeners[event] || [];
                    s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return s;
                };
                s.removeAllListeners = function(event) {
                    if (event) s._listeners[event] = [];
                    else s._listeners = {};
                    return s;
                };
            })
        """)!.call(withArguments: [stdin])
        let stdinWrite: @convention(block) (JSValue) -> Bool = { data in
            let bytes: Data
            if data.isString {
                bytes = data.toString().data(using: .utf8) ?? Data()
            } else {
                let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                var buf = [UInt8]()
                for i in 0..<length {
                    buf.append(UInt8(data.atIndex(i).toInt32()))
                }
                bytes = Data(buf)
            }
            stdinPipe.fileHandleForWriting.write(bytes)
            return true
        }
        stdin.setValue(unsafeBitCast(stdinWrite, to: AnyObject.self), forProperty: "write")

        let stdinEnd: @convention(block) () -> Void = {
            stdinPipe.fileHandleForWriting.closeFile()
        }
        stdin.setValue(unsafeBitCast(stdinEnd, to: AnyObject.self), forProperty: "end")
        childProcess.setValue(stdin, forProperty: "stdin")

        // kill method
        let kill: @convention(block) (JSValue) -> Void = { signal in
            proc.terminate()
        }
        childProcess.setValue(unsafeBitCast(kill, to: AnyObject.self), forProperty: "kill")

        // connected / killed
        childProcess.setValue(false, forProperty: "killed")

        // Launch
        do {
            runtime.eventLoop.retainHandle()
            try proc.run()
            childProcess.setValue(Int(proc.processIdentifier), forProperty: "pid")

            // Read stdout asynchronously
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let s = childProcess.forProperty("stdout")!
                        s.invokeMethod("emit", withArguments: ["end"])
                        _ = ctx // keep reference
                    }
                    return
                }
                let bytes = [UInt8](data)
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let s = childProcess.forProperty("stdout")!
                    let encoding = s.forProperty("_encoding")?.toString()
                    if encoding == "utf8" || encoding == "utf-8" {
                        let str = String(data: Data(bytes), encoding: .utf8) ?? ""
                        s.invokeMethod("emit", withArguments: ["data", str])
                    } else {
                        let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                        let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                        let arr = bytes.map { Int($0) }
                        let buf = fromFn.call(withArguments: [arr])!
                        s.invokeMethod("emit", withArguments: ["data", buf])
                    }
                }
            }

            // Read stderr asynchronously
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    runtime.eventLoop.enqueueCallback {
                        let s = childProcess.forProperty("stderr")!
                        s.invokeMethod("emit", withArguments: ["end"])
                    }
                    return
                }
                let bytes = [UInt8](data)
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let s = childProcess.forProperty("stderr")!
                    let encoding = s.forProperty("_encoding")?.toString()
                    if encoding == "utf8" || encoding == "utf-8" {
                        let str = String(data: Data(bytes), encoding: .utf8) ?? ""
                        s.invokeMethod("emit", withArguments: ["data", str])
                    } else {
                        let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                        let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                        let arr = bytes.map { Int($0) }
                        let buf = fromFn.call(withArguments: [arr])!
                        s.invokeMethod("emit", withArguments: ["data", buf])
                    }
                }
            }

            // Termination handler
            proc.terminationHandler = { process in
                let code = Int(process.terminationStatus)
                let signal: String? = process.terminationReason == .uncaughtSignal ? "SIGTERM" : nil
                runtime.eventLoop.enqueueCallback {
                    childProcess.setValue(true, forProperty: "killed")
                    if let sig = signal {
                        childProcess.invokeMethod("emit", withArguments: ["exit", code, sig])
                        childProcess.invokeMethod("emit", withArguments: ["close", code, sig])
                    } else {
                        childProcess.invokeMethod("emit", withArguments: ["exit", code])
                        childProcess.invokeMethod("emit", withArguments: ["close", code])
                    }
                    runtime.eventLoop.releaseHandle()
                }
            }
        } catch {
            runtime.eventLoop.releaseHandle()
            runtime.eventLoop.enqueueCallback {
                let ctx = runtime.context
                let err = ctx.createError("spawn \(executable) ENOENT", code: "ENOENT")
                err.setValue("spawn", forProperty: "syscall")
                err.setValue(executable, forProperty: "path")
                childProcess.invokeMethod("emit", withArguments: ["error", err])
                childProcess.invokeMethod("emit", withArguments: ["close", -1])
            }
        }

        return childProcess
    }

    // MARK: - Buffer stdout/stderr and call callback (for exec/execFile)

    private static func bufferAndCallback(
        childProcess: JSValue, callback: JSValue,
        options: JSValue?, runtime: NodeRuntime
    ) {
        let maxBuffer = options?.forProperty("maxBuffer")?.toInt32() ?? 1024 * 1024
        let encoding = options?.forProperty("encoding")?.toString()

        // Use JS to collect data
        let ctx = JSContext.current()!
        ctx.evaluateScript("""
            (function(cp, maxBuf) {
                cp._stdoutBufs = [];
                cp._stderrBufs = [];
                cp._stdoutLen = 0;
                cp._stderrLen = 0;
                cp._maxBuffer = maxBuf;
                cp.stdout.on('data', function(chunk) {
                    if (typeof chunk === 'string') chunk = Buffer.from(chunk);
                    cp._stdoutBufs.push(chunk);
                    cp._stdoutLen += chunk.length;
                });
                cp.stderr.on('data', function(chunk) {
                    if (typeof chunk === 'string') chunk = Buffer.from(chunk);
                    cp._stderrBufs.push(chunk);
                    cp._stderrLen += chunk.length;
                });
            })
        """)!.call(withArguments: [childProcess, maxBuffer])

        // On close, call the callback
        let onClose: @convention(block) (JSValue, JSValue) -> Void = { code, signal in
            let ctx = JSContext.current()!
            let stdoutResult = ctx.evaluateScript("""
                (function(cp, enc) {
                    var buf = Buffer.concat(cp._stdoutBufs);
                    if (!enc || enc === 'buffer' || enc === 'undefined' || enc === 'null') return buf;
                    return buf.toString(enc);
                })
            """)!.call(withArguments: [childProcess, encoding ?? "buffer"])!

            let stderrResult = ctx.evaluateScript("""
                (function(cp, enc) {
                    var buf = Buffer.concat(cp._stderrBufs);
                    if (!enc || enc === 'buffer' || enc === 'undefined' || enc === 'null') return buf;
                    return buf.toString(enc);
                })
            """)!.call(withArguments: [childProcess, encoding ?? "buffer"])!

            let exitCode = code.toInt32()
            if exitCode != 0 {
                let errMsg = "Command failed with exit code \(exitCode)"
                let err = ctx.createError(errMsg, code: "ERR_CHILD_PROCESS_EXEC_ERROR")
                err.setValue(exitCode, forProperty: "status")
                err.setValue(stdoutResult, forProperty: "stdout")
                err.setValue(stderrResult, forProperty: "stderr")
                callback.call(withArguments: [err, stdoutResult, stderrResult])
            } else {
                callback.call(withArguments: [JSValue(nullIn: ctx)!, stdoutResult, stderrResult])
            }
        }
        childProcess.invokeMethod("on", withArguments: ["close", unsafeBitCast(onClose, to: AnyObject.self)])
    }

    // MARK: - fork implementation

    private static func forkProcess(
        modulePath: String, args: [String], options: JSValue?,
        context: JSContext, runtime: NodeRuntime
    ) -> JSValue {
        // Resolve modulePath to absolute path
        let resolvedPath: String
        if modulePath.hasPrefix("/") {
            resolvedPath = modulePath
        } else {
            resolvedPath = FileManager.default.currentDirectoryPath + "/" + modulePath
        }

        // Create a Unix domain socket at a temp path for IPC
        let socketPath = NSTemporaryDirectory() + "noco-ipc-\(UUID().uuidString).sock"
        guard let serverFD = IPCChannel.createServer(at: socketPath) else {
            context.exception = context.createError("Failed to create IPC socket")
            return JSValue(undefinedIn: context)
        }

        // Get execPath (NoCo binary): options.execPath > process.execPath
        let execPath: String
        if let opts = options, let epVal = opts.forProperty("execPath"), epVal.isString {
            execPath = epVal.toString()!
        } else {
            execPath = context.objectForKeyedSubscript("process")?
                .forProperty("execPath")?.toString()
                ?? ProcessInfo.processInfo.arguments[0]
        }

        // Build child process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.arguments = [resolvedPath] + args

        // Environment: inherit + NODE_CHANNEL_PATH
        var env = ProcessInfo.processInfo.environment
        if let opts = options, let envVal = opts.forProperty("env"), envVal.isObject && !envVal.isUndefined {
            env = [:]
            let keys = context.evaluateScript("(function(o) { return Object.keys(o); })")!
            let keysArr = keys.call(withArguments: [envVal])!
            let len = Int(keysArr.forProperty("length")!.toInt32())
            for i in 0..<len {
                let key = keysArr.atIndex(i).toString()!
                let val = envVal.forProperty(key)?.toString() ?? ""
                env[key] = val
            }
        }
        env["NODE_CHANNEL_PATH"] = socketPath
        proc.environment = env

        // Options: cwd
        if let opts = options, let cwdVal = opts.forProperty("cwd"), cwdVal.isString {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwdVal.toString()!)
        }

        // Options: silent
        let silent: Bool
        if let opts = options, let silentVal = opts.forProperty("silent"), !silentVal.isUndefined {
            silent = silentVal.toBool()
        } else {
            silent = false
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if silent {
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
        } else {
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError = FileHandle.standardError
        }

        // Create ChildProcess JS object with EventEmitter
        let childProcess = JSValue(newObjectIn: context)!
        context.evaluateScript("""
            (function(cp) {
                cp._listeners = {};
                cp.on = function(event, fn) {
                    if (!cp._listeners[event]) cp._listeners[event] = [];
                    cp._listeners[event].push(fn);
                    return cp;
                };
                cp.once = function(event, fn) {
                    fn._once = true;
                    return cp.on(event, fn);
                };
                cp.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = cp._listeners[event] || [];
                    var remaining = [];
                    for (var i = 0; i < fns.length; i++) {
                        fns[i].apply(cp, args);
                        if (!fns[i]._once) remaining.push(fns[i]);
                    }
                    cp._listeners[event] = remaining;
                };
                cp.removeListener = function(event, fn) {
                    var fns = cp._listeners[event] || [];
                    cp._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return cp;
                };
                cp.removeAllListeners = function(event) {
                    if (event) cp._listeners[event] = [];
                    else cp._listeners = {};
                    return cp;
                };
                cp.off = cp.removeListener;
            })
        """)!.call(withArguments: [childProcess])

        childProcess.setValue(true, forProperty: "connected")
        childProcess.setValue(false, forProperty: "killed")

        // Install buffered send/disconnect — messages are queued until IPC is connected
        context.evaluateScript("""
            (function(cp) {
                cp._ipcQueue = [];
                cp._ipcConnected = false;
                cp.send = function(msg) {
                    if (cp._ipcConnected && cp._ipcSend) {
                        cp._ipcSend(msg);
                    } else {
                        cp._ipcQueue.push(msg);
                    }
                };
                cp.disconnect = function() {
                    if (cp._ipcDisconnect) {
                        cp._ipcDisconnect();
                    }
                };
            })
        """)!.call(withArguments: [childProcess])

        // Setup stdout/stderr if silent
        if silent {
            let stdout = JSValue(newObjectIn: context)!
            context.evaluateScript("""
                (function(s) {
                    s._listeners = {};
                    s.on = function(event, fn) {
                        if (!s._listeners[event]) s._listeners[event] = [];
                        s._listeners[event].push(fn);
                        return s;
                    };
                    s.once = function(event, fn) {
                        fn._once = true;
                        return s.on(event, fn);
                    };
                    s.emit = function(event) {
                        var args = Array.prototype.slice.call(arguments, 1);
                        var fns = s._listeners[event] || [];
                        var remaining = [];
                        for (var i = 0; i < fns.length; i++) {
                            fns[i].apply(s, args);
                            if (!fns[i]._once) remaining.push(fns[i]);
                        }
                        s._listeners[event] = remaining;
                    };
                    s.removeListener = function(event, fn) {
                        var fns = s._listeners[event] || [];
                        s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                        return s;
                    };
                    s.pipe = function(dest) {
                        s.on('data', function(chunk) { dest.write(chunk); });
                        s.on('end', function() { if (typeof dest.end === 'function') dest.end(); });
                        if (typeof dest.emit === 'function') dest.emit('pipe', s);
                        return dest;
                    };
                    s.setEncoding = function(enc) { s._encoding = enc; return s; };
                })
            """)!.call(withArguments: [stdout])
            childProcess.setValue(stdout, forProperty: "stdout")

            let stderr = JSValue(newObjectIn: context)!
            context.evaluateScript("""
                (function(s) {
                    s._listeners = {};
                    s.on = function(event, fn) {
                        if (!s._listeners[event]) s._listeners[event] = [];
                        s._listeners[event].push(fn);
                        return s;
                    };
                    s.once = function(event, fn) {
                        fn._once = true;
                        return s.on(event, fn);
                    };
                    s.emit = function(event) {
                        var args = Array.prototype.slice.call(arguments, 1);
                        var fns = s._listeners[event] || [];
                        var remaining = [];
                        for (var i = 0; i < fns.length; i++) {
                            fns[i].apply(s, args);
                            if (!fns[i]._once) remaining.push(fns[i]);
                        }
                        s._listeners[event] = remaining;
                    };
                    s.removeListener = function(event, fn) {
                        var fns = s._listeners[event] || [];
                        s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                        return s;
                    };
                    s.setEncoding = function(enc) { s._encoding = enc; return s; };
                    s.pipe = function(dest) {
                        s.on('data', function(chunk) { dest.write(chunk); });
                        s.on('end', function() { if (typeof dest.end === 'function') dest.end(); });
                        if (typeof dest.emit === 'function') dest.emit('pipe', s);
                        return dest;
                    };
                })
            """)!.call(withArguments: [stderr])
            childProcess.setValue(stderr, forProperty: "stderr")
        } else {
            childProcess.setValue(JSValue(nullIn: context), forProperty: "stdout")
            childProcess.setValue(JSValue(nullIn: context), forProperty: "stderr")
        }

        // kill method
        let kill: @convention(block) (JSValue) -> Void = { signal in
            proc.terminate()
        }
        childProcess.setValue(unsafeBitCast(kill, to: AnyObject.self), forProperty: "kill")

        // Launch
        do {
            runtime.eventLoop.retainHandle()  // for process
            runtime.eventLoop.retainHandle()  // for IPC channel
            try proc.run()
            childProcess.setValue(Int(proc.processIdentifier), forProperty: "pid")

            // Accept child connection on background thread, then setup IPC on event loop
            let capturedSocketPath = socketPath
            DispatchQueue.global().async {
                // Accept blocks until child connects (or process exits)
                guard let connFD = IPCChannel.acceptConnection(serverFD: serverFD) else {
                    Darwin.close(serverFD)
                    unlink(capturedSocketPath)
                    runtime.eventLoop.enqueueCallback {
                        runtime.eventLoop.releaseHandle()  // for IPC channel
                    }
                    return
                }
                // Close server socket, no longer needed
                Darwin.close(serverFD)
                unlink(capturedSocketPath)

                let ipcChannel = IPCChannel(fileDescriptor: connFD, eventLoop: runtime.eventLoop)

                runtime.eventLoop.enqueueCallback {
                    // Install send/disconnect now that IPC is connected
                    self.installIPCMethods(
                        on: childProcess, ipcChannel: ipcChannel,
                        runtime: runtime, context: runtime.context
                    )

                    // Start reading IPC messages
                    ipcChannel.startReading(
                        onMessage: { jsonString in
                            let ctx = runtime.context
                            let parsed = ctx.evaluateScript("JSON.parse")!
                                .call(withArguments: [jsonString])!
                            childProcess.invokeMethod("emit", withArguments: ["message", parsed])
                        },
                        onDisconnect: {
                            childProcess.setValue(false, forProperty: "connected")
                            childProcess.invokeMethod("emit", withArguments: ["disconnect"])
                            runtime.eventLoop.releaseHandle()  // for IPC channel
                        }
                    )
                }
            }

            // Setup stdout/stderr reading if silent
            if silent {
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        runtime.eventLoop.enqueueCallback {
                            let s = childProcess.forProperty("stdout")!
                            s.invokeMethod("emit", withArguments: ["end"])
                        }
                        return
                    }
                    let bytes = [UInt8](data)
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let s = childProcess.forProperty("stdout")!
                        let encoding = s.forProperty("_encoding")?.toString()
                        if encoding == "utf8" || encoding == "utf-8" {
                            let str = String(data: Data(bytes), encoding: .utf8) ?? ""
                            s.invokeMethod("emit", withArguments: ["data", str])
                        } else {
                            let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                            let arr = bytes.map { Int($0) }
                            let buf = fromFn.call(withArguments: [arr])!
                            s.invokeMethod("emit", withArguments: ["data", buf])
                        }
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        runtime.eventLoop.enqueueCallback {
                            let s = childProcess.forProperty("stderr")!
                            s.invokeMethod("emit", withArguments: ["end"])
                        }
                        return
                    }
                    let bytes = [UInt8](data)
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let s = childProcess.forProperty("stderr")!
                        let encoding = s.forProperty("_encoding")?.toString()
                        if encoding == "utf8" || encoding == "utf-8" {
                            let str = String(data: Data(bytes), encoding: .utf8) ?? ""
                            s.invokeMethod("emit", withArguments: ["data", str])
                        } else {
                            let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                            let arr = bytes.map { Int($0) }
                            let buf = fromFn.call(withArguments: [arr])!
                            s.invokeMethod("emit", withArguments: ["data", buf])
                        }
                    }
                }
            }

            // Termination handler
            proc.terminationHandler = { process in
                let code = Int(process.terminationStatus)
                let signal: String? = process.terminationReason == .uncaughtSignal ? "SIGTERM" : nil
                runtime.eventLoop.enqueueCallback {
                    childProcess.setValue(true, forProperty: "killed")
                    if let sig = signal {
                        childProcess.invokeMethod("emit", withArguments: ["exit", code, sig])
                        childProcess.invokeMethod("emit", withArguments: ["close", code, sig])
                    } else {
                        childProcess.invokeMethod("emit", withArguments: ["exit", code])
                        childProcess.invokeMethod("emit", withArguments: ["close", code])
                    }
                    runtime.eventLoop.releaseHandle()  // for process
                }
            }
        } catch {
            Darwin.close(serverFD)
            unlink(socketPath)
            runtime.eventLoop.releaseHandle()  // for process
            runtime.eventLoop.releaseHandle()  // for IPC channel
            runtime.eventLoop.enqueueCallback {
                let ctx = runtime.context
                let err = ctx.createError("fork \(resolvedPath) ENOENT", code: "ENOENT")
                err.setValue("fork", forProperty: "syscall")
                err.setValue(resolvedPath, forProperty: "path")
                childProcess.invokeMethod("emit", withArguments: ["error", err])
                childProcess.invokeMethod("emit", withArguments: ["close", -1])
            }
        }

        return childProcess
    }

    /// Install send() and disconnect() on a child process, flushing any queued messages.
    private static func installIPCMethods(
        on childProcess: JSValue, ipcChannel: IPCChannel,
        runtime: NodeRuntime, context: JSContext
    ) {
        let send: @convention(block) (JSValue) -> Void = { message in
            let ctx = JSContext.current()!
            let jsonResult = ctx.evaluateScript("JSON.stringify")!.call(withArguments: [message])!
            guard !jsonResult.isUndefined else { return }
            ipcChannel.write(jsonResult.toString())
        }
        childProcess.setValue(unsafeBitCast(send, to: AnyObject.self), forProperty: "_ipcSend")

        let disconnect: @convention(block) () -> Void = {
            guard !ipcChannel.isClosed else { return }
            ipcChannel.close()
            childProcess.setValue(false, forProperty: "connected")
            childProcess.invokeMethod("emit", withArguments: ["disconnect"])
            runtime.eventLoop.releaseHandle()  // for IPC channel
        }
        childProcess.setValue(unsafeBitCast(disconnect, to: AnyObject.self), forProperty: "_ipcDisconnect")

        // Mark as connected and flush queued messages
        childProcess.setValue(true, forProperty: "_ipcConnected")
        context.evaluateScript("""
            (function(cp) {
                cp.send = function(msg) { cp._ipcSend(msg); };
                cp.disconnect = function() { cp._ipcDisconnect(); };
                var q = cp._ipcQueue;
                cp._ipcQueue = [];
                for (var i = 0; i < q.length; i++) {
                    cp.send(q[i]);
                }
            })
        """)!.call(withArguments: [childProcess])
    }

    // MARK: - Sync execution

    private static func runSync(
        executable: String, args: [String],
        options: JSValue?, context: JSContext
    ) -> JSValue {
        let proc = createProcess(executable: executable, args: args, options: options)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Handle stdio option for stdin
        if let opts = options, let stdioVal = opts.forProperty("stdio") {
            if stdioVal.isString && stdioVal.toString() == "inherit" {
                proc.standardInput = FileHandle.standardInput
                proc.standardOutput = FileHandle.standardOutput
                proc.standardError = FileHandle.standardError
            }
        }

        // Handle input option
        let inputPipe = Pipe()
        if let opts = options, let inputVal = opts.forProperty("input"), !inputVal.isUndefined {
            proc.standardInput = inputPipe
            let inputData: Data
            if inputVal.isString {
                inputData = inputVal.toString().data(using: .utf8) ?? Data()
            } else {
                let length = Int(inputVal.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(inputVal.atIndex(i).toInt32()))
                }
                inputData = Data(bytes)
            }
            inputPipe.fileHandleForWriting.write(inputData)
            inputPipe.fileHandleForWriting.closeFile()
        }

        do {
            try proc.run()
        } catch {
            context.exception = context.createSystemError(
                "spawnSync \(executable) ENOENT",
                code: "ENOENT", syscall: "spawnSync", path: executable
            )
            return JSValue(undefinedIn: context)
        }

        let stdoutData: Data
        let stderrData: Data
        if proc.standardOutput is Pipe {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        } else {
            stdoutData = Data()
        }
        if proc.standardError is Pipe {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        } else {
            stderrData = Data()
        }

        proc.waitUntilExit()

        let exitCode = Int(proc.terminationStatus)

        if exitCode != 0 {
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            let errMsg = "Command failed: \(executable) \(args.joined(separator: " "))"
            let err = context.createError(errMsg, code: "ERR_CHILD_PROCESS_EXEC_ERROR")
            err.setValue(exitCode, forProperty: "status")
            err.setValue(String(data: stdoutData, encoding: .utf8) ?? "", forProperty: "stdout")
            err.setValue(stderrStr, forProperty: "stderr")
            context.exception = err
            return JSValue(undefinedIn: context)
        }

        // Check encoding option
        let encoding: String?
        if let opts = options, let encVal = opts.forProperty("encoding"), encVal.isString {
            let enc = encVal.toString()!
            encoding = (enc == "null" || enc == "undefined") ? nil : enc
        } else {
            encoding = nil
        }

        if let encoding = encoding {
            if encoding == "utf8" || encoding == "utf-8" || encoding == "utf-8" {
                let str = String(data: stdoutData, encoding: .utf8) ?? ""
                return JSValue(object: str, in: context)
            }
            // For other encodings, return as string too (best effort)
            let str = String(data: stdoutData, encoding: .utf8) ?? ""
            return JSValue(object: str, in: context)
        }

        // Return as Buffer
        let bufferCtor = context.objectForKeyedSubscript("Buffer")!
        let fromFn = bufferCtor.objectForKeyedSubscript("from")!
        let arr = [UInt8](stdoutData).map { Int($0) }
        return fromFn.call(withArguments: [arr])!
    }

    // MARK: - spawnSync implementation

    private static func runSpawnSync(
        executable: String, args: [String],
        options: JSValue?, context: JSContext
    ) -> JSValue {
        let proc = createProcess(executable: executable, args: args, options: options)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Handle input option
        let inputPipe = Pipe()
        if let opts = options, let inputVal = opts.forProperty("input"), !inputVal.isUndefined {
            proc.standardInput = inputPipe
            let inputData: Data
            if inputVal.isString {
                inputData = inputVal.toString().data(using: .utf8) ?? Data()
            } else {
                let length = Int(inputVal.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(inputVal.atIndex(i).toInt32()))
                }
                inputData = Data(bytes)
            }
            inputPipe.fileHandleForWriting.write(inputData)
            inputPipe.fileHandleForWriting.closeFile()
        }

        let result = JSValue(newObjectIn: context)!

        do {
            try proc.run()
        } catch {
            result.setValue(JSValue(nullIn: context), forProperty: "pid")
            let bufferCtor = context.objectForKeyedSubscript("Buffer")!
            let emptyBuf = bufferCtor.objectForKeyedSubscript("from")!.call(withArguments: [[]])!
            result.setValue(emptyBuf, forProperty: "stdout")
            result.setValue(emptyBuf, forProperty: "stderr")
            result.setValue(JSValue(nullIn: context), forProperty: "status")
            result.setValue(JSValue(nullIn: context), forProperty: "signal")
            let err = context.createSystemError(
                "spawnSync \(executable) ENOENT",
                code: "ENOENT", syscall: "spawnSync", path: executable
            )
            result.setValue(err, forProperty: "error")
            return result
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        result.setValue(Int(proc.processIdentifier), forProperty: "pid")
        result.setValue(Int(proc.terminationStatus), forProperty: "status")

        if proc.terminationReason == .uncaughtSignal {
            result.setValue("SIGTERM", forProperty: "signal")
        } else {
            result.setValue(JSValue(nullIn: context), forProperty: "signal")
        }

        // Check encoding
        let encoding: String?
        if let opts = options, let encVal = opts.forProperty("encoding"), encVal.isString {
            let enc = encVal.toString()!
            encoding = (enc == "null" || enc == "undefined") ? nil : enc
        } else {
            encoding = nil
        }

        if let encoding = encoding, encoding != "buffer" {
            let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            result.setValue(stdoutStr, forProperty: "stdout")
            result.setValue(stderrStr, forProperty: "stderr")
        } else {
            let bufferCtor = context.objectForKeyedSubscript("Buffer")!
            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
            let stdoutArr = [UInt8](stdoutData).map { Int($0) }
            let stderrArr = [UInt8](stderrData).map { Int($0) }
            result.setValue(fromFn.call(withArguments: [stdoutArr]), forProperty: "stdout")
            result.setValue(fromFn.call(withArguments: [stderrArr]), forProperty: "stderr")
        }

        result.setValue(JSValue(nullIn: context), forProperty: "error")

        return result
    }
}
#endif
