import JavaScriptCore

/// Implements the Node.js `console` global object.
public struct ConsoleModule: NodeModule {
    public static let moduleName = "console"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let console = JSValue(newObjectIn: context)!

        // Install a shared format function that mirrors util.format behavior
        // This is defined here because console is installed before util module
        let formatFn = context.evaluateScript("""
        (function() {
            return function formatArgs(args) {
                if (args.length === 0) return '';
                var fmt = args[0];
                if (typeof fmt !== 'string') {
                    var parts = [];
                    for (var i = 0; i < args.length; i++) {
                        parts.push(typeof args[i] === 'object' && args[i] !== null ? JSON.stringify(args[i]) : String(args[i]));
                    }
                    return parts.join(' ');
                }
                var a = 1;
                var result = fmt.replace(/%[sdjifoO%]/g, function(m) {
                    if (m === '%%') return '%';
                    if (a >= args.length) return m;
                    var v = args[a++];
                    switch(m) {
                        case '%s': return String(v);
                        case '%d': case '%i': return parseInt(v, 10).toString();
                        case '%f': return parseFloat(v).toString();
                        case '%j': try { return JSON.stringify(v); } catch(e) { return '[Circular]'; }
                        case '%o': case '%O': try { return JSON.stringify(v); } catch(e) { return '[Circular]'; }
                        default: return m;
                    }
                });
                while (a < args.length) {
                    result += ' ' + (typeof args[a] === 'object' && args[a] !== null ? JSON.stringify(args[a]) : String(args[a]));
                    a++;
                }
                return result;
            };
        })()
        """)!

        let makeLogger = { (level: NodeRuntime.ConsoleLevel) -> @convention(block) () -> Void in
            return { [formatFn] in
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let jsArgs = JSValue(newArrayIn: context)!
                for (i, arg) in args.enumerated() {
                    jsArgs.setValue(arg, at: i)
                }
                let message = formatFn.call(withArguments: [jsArgs])?.toString() ?? ""
                runtime.consoleHandler(level, message)
            }
        }

        console.setValue(unsafeBitCast(makeLogger(.log), to: AnyObject.self), forProperty: "log")
        console.setValue(unsafeBitCast(makeLogger(.info), to: AnyObject.self), forProperty: "info")
        console.setValue(unsafeBitCast(makeLogger(.warn), to: AnyObject.self), forProperty: "warn")
        console.setValue(unsafeBitCast(makeLogger(.error), to: AnyObject.self), forProperty: "error")
        console.setValue(unsafeBitCast(makeLogger(.debug), to: AnyObject.self), forProperty: "debug")

        // console.time / console.timeEnd
        var timers: [String: CFAbsoluteTime] = [:]

        let timeBlock: @convention(block) (String) -> Void = { label in
            timers[label] = CFAbsoluteTimeGetCurrent()
        }
        console.setValue(unsafeBitCast(timeBlock, to: AnyObject.self), forProperty: "time")

        let timeEndBlock: @convention(block) (String) -> Void = { label in
            if let start = timers.removeValue(forKey: label) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let message = "\(label): \(String(format: "%.3f", elapsed))ms"
                runtime.consoleHandler(.log, message)
            }
        }
        console.setValue(unsafeBitCast(timeEndBlock, to: AnyObject.self), forProperty: "timeEnd")

        // console.assert
        let assertBlock: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let first = args.first else { return }
            if !first.toBool() {
                let rest = args.dropFirst().map { formatValue($0) }
                let message =
                    "Assertion failed"
                    + (rest.isEmpty ? "" : ": " + rest.joined(separator: " "))
                runtime.consoleHandler(.error, message)
            }
        }
        console.setValue(unsafeBitCast(assertBlock, to: AnyObject.self), forProperty: "assert")

        // console.dir - simple implementation
        let dirBlock: @convention(block) (JSValue) -> Void = { value in
            let message = formatValue(value)
            runtime.consoleHandler(.log, message)
        }
        console.setValue(unsafeBitCast(dirBlock, to: AnyObject.self), forProperty: "dir")

        // console.Console constructor (Node.js compatible)
        context.evaluateScript("""
            (function(c) {
                function Console(opts) {
                    if (!(this instanceof Console)) return new Console(opts);
                    var stdout = opts;
                    if (opts && typeof opts === 'object' && opts.write === undefined) {
                        stdout = opts.stdout || { write: function() {} };
                    }
                    this._stdout = stdout || { write: function() {} };
                    this._stderr = (opts && opts.stderr) || this._stdout;
                    this.log = function() {
                        var args = Array.prototype.slice.call(arguments);
                        var msg = args.map(String).join(' ');
                        if (this._stdout && this._stdout.write) this._stdout.write(msg + '\\n');
                    };
                    this.info = this.log;
                    this.debug = this.log;
                    this.warn = function() {
                        var args = Array.prototype.slice.call(arguments);
                        var msg = args.map(String).join(' ');
                        if (this._stderr && this._stderr.write) this._stderr.write(msg + '\\n');
                    };
                    this.error = this.warn;
                    this.dir = this.log;
                    this.time = function() {};
                    this.timeEnd = function() {};
                    this.assert = function(v) { if (!v) this.error('Assertion failed'); };
                    this.trace = function() { this.error(new Error().stack); };
                    this.clear = function() {};
                    this.count = function() {};
                    this.countReset = function() {};
                    this.group = function() {};
                    this.groupEnd = function() {};
                    this.table = this.log;
                }
                c.Console = Console;
            })
        """)!.call(withArguments: [console])

        context.setObject(console, forKeyedSubscript: "console" as NSString)
        return console
    }

    /// Format a JSValue for console output, similar to Node.js util.inspect.
    static func formatValue(_ value: JSValue) -> String {
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        if value.isBoolean { return value.toBool() ? "true" : "false" }
        if value.isNumber { return value.toNumber().stringValue }
        if value.isString { return value.toString() }

        // Check for Array
        if let context = value.context,
            let isArray = context.evaluateScript("Array.isArray"),
            isArray.call(withArguments: [value]).toBool()
        {
            let json =
                context.evaluateScript("JSON.stringify")?.call(withArguments: [value])?.toString()
                ?? "[]"
            return json
        }

        // Check for Error
        if let name = value.forProperty("stack")?.toString(), !value.forProperty("stack").isUndefined
        {
            return name
        }

        // Generic object
        if value.isObject {
            let undef: Any = JSValue(undefinedIn: value.context) as Any
            let json =
                value.context?.evaluateScript("JSON.stringify")?.call(
                    withArguments: [value, undef, 2]
                )?.toString() ?? "[Object]"
            return json == "undefined" ? "[Object]" : json
        }

        return value.toString()
    }
}
