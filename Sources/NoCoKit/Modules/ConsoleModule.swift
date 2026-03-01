import JavaScriptCore

/// Implements the Node.js `console` global object.
public struct ConsoleModule: NodeModule {
    public static let moduleName = "console"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let console = JSValue(newObjectIn: context)!

        let makeLogger = { (level: NodeRuntime.ConsoleLevel) -> @convention(block) () -> Void in
            return {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let message = args.map { formatValue($0) }.joined(separator: " ")
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
