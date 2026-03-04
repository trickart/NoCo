import Foundation
import JavaScriptCore

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

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let process = JSValue(newObjectIn: context)!

        // process.version
        process.setValue("v18.0.0", forProperty: "version")

        // process.versions
        let versions = JSValue(newObjectIn: context)!
        versions.setValue("18.0.0", forProperty: "node")
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

        // process.argv
        let argv = JSValue.array(from: runtime.argv, in: context)
        process.setValue(argv, forProperty: "argv")

        // process.env
        let env = JSValue(newObjectIn: context)!
        for (key, value) in ProcessInfo.processInfo.environment {
            env.setValue(value, forProperty: key)
        }
        process.setValue(env, forProperty: "env")

        // process.cwd()
        let cwd: @convention(block) () -> String = {
            FileManager.default.currentDirectoryPath
        }
        process.setValue(unsafeBitCast(cwd, to: AnyObject.self), forProperty: "cwd")

        // process.exit(code)
        let exit: @convention(block) (JSValue) -> Void = { code in
            let exitCode = code.isUndefined ? 0 : Int32(code.toInt32())
            runtime.consoleHandler(.info, "process.exit(\(exitCode)) called")
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
            print(str, terminator: "")
            runtime.consoleHandler(.log, str)
            return true
        }
        stdout.setValue(unsafeBitCast(stdoutWrite, to: AnyObject.self), forProperty: "write")
        stdout.setValue(stdoutIsTTY, forProperty: "isTTY")
        stdout.setValue(getTerminalColumns(), forProperty: "columns")

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
            })
        """)!.call(withArguments: [stdout])
        process.setValue(stdout, forProperty: "stdout")

        let stderr = JSValue(newObjectIn: context)!
        let stderrWrite: @convention(block) (String) -> Bool = { str in
            fputs(str, Foundation.stderr)
            runtime.consoleHandler(.error, str)
            return true
        }
        stderr.setValue(unsafeBitCast(stderrWrite, to: AnyObject.self), forProperty: "write")
        stderr.setValue(stderrIsTTY, forProperty: "isTTY")
        stderr.setValue(getTerminalColumns(), forProperty: "columns")

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
            })
        """)!.call(withArguments: [stderr])
        process.setValue(stderr, forProperty: "stderr")

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
