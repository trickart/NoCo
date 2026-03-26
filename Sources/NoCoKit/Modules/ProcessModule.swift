import Foundation
@preconcurrency import JavaScriptCore

/// Implements the Node.js `process` global object.
public struct ProcessModule: NodeModule {
    public static let moduleName = "process"

    private static func getTerminalColumns() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    private static func getTerminalRows() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_row > 0 {
            return Int(ws.ws_row)
        }
        return 24
    }

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let startTime = Date()
        let process = JSValue(newObjectIn: context)!

        // process.version
        process.setValue("v22.15.0", forProperty: "version")

        // process.versions
        let versions = JSValue(newObjectIn: context)!
        versions.setValue("22.15.0", forProperty: "node")
        versions.setValue("10.2", forProperty: "v8")
        process.setValue(versions, forProperty: "versions")

        // process.platform
        #if os(iOS)
        process.setValue("darwin", forProperty: "platform")
        #elseif os(macOS)
        process.setValue("darwin", forProperty: "platform")
        #else
        process.setValue("unknown", forProperty: "platform")
        #endif

        // process.arch
        #if arch(arm64)
        process.setValue("arm64", forProperty: "arch")
        #elseif arch(x86_64)
        process.setValue("x64", forProperty: "arch")
        #else
        process.setValue("unknown", forProperty: "arch")
        #endif

        // process.pid
        process.setValue(ProcessInfo.processInfo.processIdentifier, forProperty: "pid")

        // process.getuid / process.getgid / process.getgroups
        let getuidFn: @convention(block) () -> UInt32 = { getuid() }
        process.setValue(unsafeBitCast(getuidFn, to: AnyObject.self), forProperty: "getuid")
        let getgidFn: @convention(block) () -> UInt32 = { getgid() }
        process.setValue(unsafeBitCast(getgidFn, to: AnyObject.self), forProperty: "getgid")
        let getgroupsFn: @convention(block) () -> [UInt32] = {
            var groups = [gid_t](repeating: 0, count: 64)
            let count = getgroups(Int32(groups.count), &groups)
            if count > 0 {
                return Array(groups.prefix(Int(count)))
            }
            return [getgid()]
        }
        process.setValue(unsafeBitCast(getgroupsFn, to: AnyObject.self), forProperty: "getgroups")

        // process.kill(pid, signal)
        let killFn: @convention(block) (JSValue, JSValue) -> Void = { pidVal, signalVal in
            let pid = pidVal.toInt32()
            guard pid != 0 else {
                context.exception = JSValue(newErrorFromMessage: "Invalid pid: 0", in: context)
                return
            }
            // Map signal name to number
            var sig: Int32 = 15 // SIGTERM default
            if !signalVal.isUndefined {
                if signalVal.isNumber {
                    sig = signalVal.toInt32()
                } else if let name = signalVal.toString() {
                    let signalMap: [String: Int32] = [
                        "SIGHUP": 1, "SIGINT": 2, "SIGQUIT": 3, "SIGKILL": 9,
                        "SIGTERM": 15, "SIGUSR1": 30, "SIGUSR2": 31, "SIGSTOP": 17,
                        "SIGCONT": 19, "SIGPIPE": 13, "SIGALRM": 14
                    ]
                    sig = signalMap[name] ?? 15
                }
            }
            let result = Darwin.kill(pid, sig)
            if result != 0 {
                let errCode = errno
                if errCode == ESRCH {
                    context.exception = context.createSystemError(
                        "kill \(sig) \(pid) - No such process",
                        code: "ESRCH", syscall: "kill"
                    )
                } else if errCode == EPERM {
                    context.exception = context.createSystemError(
                        "kill \(sig) \(pid) - Operation not permitted",
                        code: "EPERM", syscall: "kill"
                    )
                }
            }
        }
        process.setValue(unsafeBitCast(killFn, to: AnyObject.self), forProperty: "kill")

        // process.argv
        let argv = JSValue.array(from: runtime.argv, in: context)
        process.setValue(argv, forProperty: "argv")

        // process.env
        let env = JSValue(newObjectIn: context)!
        if let envJSON = runtime.workerContext?.envJSON {
            // Worker with explicit env option — complete replacement (not merge)
            context.evaluateScript("""
                (function(env, json) {
                    var src = JSON.parse(json);
                    var keys = Object.keys(src);
                    for (var i = 0; i < keys.length; i++) {
                        env[keys[i]] = String(src[keys[i]]);
                    }
                })
            """)!.call(withArguments: [env, envJSON])
        } else {
            for (key, value) in ProcessInfo.processInfo.environment {
                env.setValue(value, forProperty: key)
            }
        }
        process.setValue(env, forProperty: "env")

        // process.cwd()
        let cwd: @convention(block) () -> String = {
            FileManager.default.currentDirectoryPath
        }
        process.setValue(unsafeBitCast(cwd, to: AnyObject.self), forProperty: "cwd")

        // process.chdir(directory)
        let chdir: @convention(block) (String) -> Void = { directory in
            let path: String
            if directory.hasPrefix("/") {
                path = directory
            } else {
                path = FileManager.default.currentDirectoryPath + "/" + directory
            }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                let ctx = JSContext.current()!
                let escaped = path.replacingOccurrences(of: "'", with: "\\'")
                ctx.exception = ctx.evaluateScript(
                    "new Error('ENOENT: no such file or directory, chdir \\'\(escaped)\\'');"
                )
                return
            }
            FileManager.default.changeCurrentDirectoryPath(path)
        }
        process.setValue(unsafeBitCast(chdir, to: AnyObject.self), forProperty: "chdir")

        // process.exit(code) — Node.js 互換: exit イベントを emit してプロセスを終了
        let exit: @convention(block) (JSValue) -> Void = { code in
            let exitCode = code.isUndefined ? 0 : Int32(code.toInt32())
            let p = runtime.context.objectForKeyedSubscript("process")!
            p.invokeMethod("emit", withArguments: ["exit", Int(exitCode)])
            runtime.eventLoop.stop()
        }
        process.setValue(unsafeBitCast(exit, to: AnyObject.self), forProperty: "exit")

        // process.nextTick(callback, ...args)
        let nextTick: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let callback = args.first else { return }
            let extraArgs = args.count > 1 ? Array(args[1...]) : []

            if extraArgs.isEmpty {
                runtime.eventLoop.enqueueNextTick(callback)
            } else {
                let bound = callback.invokeMethod("bind", withArguments: [JSValue(nullIn: context)!] + extraArgs)!
                runtime.eventLoop.enqueueNextTick(bound)
            }
        }
        process.setValue(unsafeBitCast(nextTick, to: AnyObject.self), forProperty: "nextTick")

        // process.hrtime()
        let hrtime: @convention(block) (JSValue) -> JSValue = { prev in
            let now = DispatchTime.now()
            let nanos = now.uptimeNanoseconds
            let seconds = Int(nanos / 1_000_000_000)
            let remainingNanos = Int(nanos % 1_000_000_000)

            if !prev.isUndefined && prev.isObject {
                let prevSec = prev.atIndex(0).toInt32()
                let prevNano = prev.atIndex(1).toInt32()
                let diffSec = Int32(seconds) - prevSec
                var diffNano = Int32(remainingNanos) - prevNano
                var adjSec = diffSec
                if diffNano < 0 {
                    adjSec -= 1
                    diffNano += 1_000_000_000
                }
                return JSValue.array(from: [adjSec, diffNano], in: JSContext.current())
            }

            return JSValue.array(from: [seconds, remainingNanos], in: JSContext.current())
        }
        process.setValue(unsafeBitCast(hrtime, to: AnyObject.self), forProperty: "hrtime")

        // process.hrtime.bigint()
        let hrtimeObj = process.forProperty("hrtime")!
        context.evaluateScript("""
            (function(hrtime) {
                hrtime.bigint = function() {
                    var t = hrtime();
                    return BigInt(t[0]) * 1000000000n + BigInt(t[1]);
                };
            })
        """)!.call(withArguments: [hrtimeObj])

        // process.uptime()
        let uptime: @convention(block) () -> Double = {
            return Date().timeIntervalSince(startTime)
        }
        process.setValue(unsafeBitCast(uptime, to: AnyObject.self), forProperty: "uptime")

        // process.execPath
        process.setValue(ProcessInfo.processInfo.arguments[0], forProperty: "execPath")

        // process.execArgv
        process.setValue(JSValue(newArrayIn: context), forProperty: "execArgv")

        // process.exitCode (get/set via defineProperty)
        context.evaluateScript("""
            (function(p) {
                var _exitCode = 0;
                Object.defineProperty(p, 'exitCode', {
                    get: function() { return _exitCode; },
                    set: function(v) { _exitCode = v; },
                    enumerable: true, configurable: true
                });
            })
        """)!.call(withArguments: [process])

        // process.stdout / process.stderr (enhanced)
        let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
        let stderrIsTTY = isatty(STDERR_FILENO) != 0

        let stdout = JSValue(newObjectIn: context)!
        let stdoutWrite: @convention(block) (String) -> Bool = { str in
            runtime.stdoutHandler(str)
            return true
        }
        stdout.setValue(unsafeBitCast(stdoutWrite, to: AnyObject.self), forProperty: "write")
        stdout.setValue(stdoutIsTTY, forProperty: "isTTY")
        stdout.setValue(getTerminalColumns(), forProperty: "columns")
        stdout.setValue(getTerminalRows(), forProperty: "rows")

        let stdoutHasColors: @convention(block) () -> Bool = {
            guard stdoutIsTTY else { return false }
            return ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        }
        stdout.setValue(unsafeBitCast(stdoutHasColors, to: AnyObject.self), forProperty: "hasColors")

        // stdout EventEmitter stubs
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
                s.off = s.removeListener;
                s.removeAllListeners = function(event) {
                    if (event) s._listeners[event] = [];
                    else s._listeners = {};
                    return s;
                };
                s._maxListeners = 10;
                s.getMaxListeners = function() { return s._maxListeners; };
                s.setMaxListeners = function(n) { s._maxListeners = n; return s; };
                s.listenerCount = function(event) { return (s._listeners[event] || []).length; };
                s.listeners = function(event) { return (s._listeners[event] || []).slice(); };
                s.prependListener = function(event, fn) {
                    if (!s._listeners[event]) s._listeners[event] = [];
                    s._listeners[event].unshift(fn);
                    return s;
                };
                s.end = function() { return s; };
                s.writable = true;
                s._pipedFrom = [];
                s.pipe = function(dest) { return dest; };
                s.unpipe = function() { return s; };
            })
        """)!.call(withArguments: [stdout])
        process.setValue(stdout, forProperty: "stdout")

        let stderr = JSValue(newObjectIn: context)!
        let stderrWrite: @convention(block) (String) -> Bool = { str in
            runtime.stderrHandler(str)
            return true
        }
        stderr.setValue(unsafeBitCast(stderrWrite, to: AnyObject.self), forProperty: "write")
        stderr.setValue(stderrIsTTY, forProperty: "isTTY")
        stderr.setValue(getTerminalColumns(), forProperty: "columns")
        stderr.setValue(getTerminalRows(), forProperty: "rows")

        let stderrHasColors: @convention(block) () -> Bool = {
            guard stderrIsTTY else { return false }
            return ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        }
        stderr.setValue(unsafeBitCast(stderrHasColors, to: AnyObject.self), forProperty: "hasColors")

        // stderr EventEmitter stubs
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
                s.off = s.removeListener;
                s.removeAllListeners = function(event) {
                    if (event) s._listeners[event] = [];
                    else s._listeners = {};
                    return s;
                };
                s._maxListeners = 10;
                s.getMaxListeners = function() { return s._maxListeners; };
                s.setMaxListeners = function(n) { s._maxListeners = n; return s; };
                s.listenerCount = function(event) { return (s._listeners[event] || []).length; };
                s.listeners = function(event) { return (s._listeners[event] || []).slice(); };
                s.prependListener = function(event, fn) {
                    if (!s._listeners[event]) s._listeners[event] = [];
                    s._listeners[event].unshift(fn);
                    return s;
                };
                s.end = function() { return s; };
                s.writable = true;
                s._pipedFrom = [];
                s.pipe = function(dest) { return dest; };
                s.unpipe = function() { return s; };
            })
        """)!.call(withArguments: [stderr])
        process.setValue(stderr, forProperty: "stderr")

        // process.stdin
        let stdinIsTTY = isatty(STDIN_FILENO) != 0
        let stdin = JSValue(newObjectIn: context)!
        stdin.setValue(stdinIsTTY, forProperty: "isTTY")
        stdin.setValue(0, forProperty: "fd")
        stdin.setValue(true, forProperty: "readable")

        // stdin EventEmitter stubs + resume/pause/setEncoding
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
                    return fns.length > 0;
                };
                s.removeListener = function(event, fn) {
                    var fns = s._listeners[event] || [];
                    s._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return s;
                };
                s.off = s.removeListener;
                s.removeAllListeners = function(event) {
                    if (event) s._listeners[event] = [];
                    else s._listeners = {};
                    return s;
                };
                s.resume = function() { return s; };
                s.pause = function() { return s; };
                s.setEncoding = function() { return s; };
            })
        """)!.call(withArguments: [stdin])
        process.setValue(stdin, forProperty: "stdin")

        // __NoCo_startStdinReading: reads lines from stdin on a background thread
        let startStdinReading: @convention(block) (JSValue) -> Void = { callback in
            let el = runtime.eventLoop
            DispatchQueue.global(qos: .userInitiated).async {
                while let line = Swift.readLine(strippingNewline: false) {
                    let captured = line
                    el.enqueueCallback {
                        callback.call(withArguments: [captured])
                    }
                }
                // EOF
                el.enqueueCallback {
                    callback.call(withArguments: [JSValue(nullIn: runtime.context)!])
                }
            }
        }
        context.setObject(
            unsafeBitCast(startStdinReading, to: AnyObject.self),
            forKeyedSubscript: "__NoCo_startStdinReading" as NSString
        )

        // process.memoryUsage()
        let memoryUsage: @convention(block) () -> JSValue = {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let rss = result == KERN_SUCCESS ? info.resident_size : 0
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!
            obj.setValue(rss, forProperty: "rss")
            obj.setValue(rss, forProperty: "heapTotal")
            obj.setValue(rss, forProperty: "heapUsed")
            obj.setValue(0, forProperty: "external")
            return obj
        }
        process.setValue(unsafeBitCast(memoryUsage, to: AnyObject.self), forProperty: "memoryUsage")

        // process EventEmitter methods (Node.js の process は EventEmitter)
        context.evaluateScript("""
            (function(p) {
                p._listeners = {};
                p.on = function(event, fn) {
                    if (!p._listeners[event]) p._listeners[event] = [];
                    p._listeners[event].push(fn);
                    return p;
                };
                p.addListener = p.on;
                p.once = function(event, fn) {
                    fn._once = true;
                    return p.on(event, fn);
                };
                p.emit = function(event) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var fns = (p._listeners[event] || []).slice();
                    for (var i = 0; i < fns.length; i++) {
                        if (fns[i]._once) {
                            p.removeListener(event, fns[i]);
                        }
                        fns[i].apply(p, args);
                    }
                    return fns.length > 0;
                };
                p.removeListener = function(event, fn) {
                    var fns = p._listeners[event] || [];
                    p._listeners[event] = fns.filter(function(f) { return f !== fn; });
                    return p;
                };
                p.off = p.removeListener;
                p.removeAllListeners = function(event) {
                    if (event) delete p._listeners[event];
                    else p._listeners = {};
                    return p;
                };
                p.listeners = function(event) { return (p._listeners[event] || []).slice(); };
                p.listenerCount = function(event) { return (p._listeners[event] || []).length; };
                p.eventNames = function() { return Object.keys(p._listeners); };
                p.prependListener = function(event, fn) {
                    if (!p._listeners[event]) p._listeners[event] = [];
                    p._listeners[event].unshift(fn);
                    return p;
                };
                p.prependOnceListener = function(event, fn) {
                    fn._once = true;
                    return p.prependListener(event, fn);
                };
                p.setMaxListeners = function() { return p; };
                p.getMaxListeners = function() { return 10; };
                p.rawListeners = p.listeners;
            })
        """)!.call(withArguments: [process])

        context.setObject(process, forKeyedSubscript: "process" as NSString)

        // Set global to the actual global object (not process)
        context.evaluateScript("""
            (function() {
                var g = this;
                g.global = g;
                g.process = process;
            })();
        """)

        return process
    }
}
