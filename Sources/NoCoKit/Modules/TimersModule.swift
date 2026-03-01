import JavaScriptCore

/// Implements Node.js global timer functions:
/// setTimeout, setInterval, clearTimeout, clearInterval.
public struct TimersModule: NodeModule {
    public static let moduleName = "timers"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let exports = JSValue(newObjectIn: context)!

        // setTimeout(callback, delay, ...args)
        let setTimeout: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let callback = args.first, !callback.isUndefined else {
                return JSValue(int32: 0, in: JSContext.current())
            }
            let delay = args.count > 1 ? args[1].toDouble() : 0
            let extraArgs = args.count > 2 ? Array(args[2...]) : []

            let wrappedCallback: JSValue
            if extraArgs.isEmpty {
                wrappedCallback = callback
            } else {
                // Wrap to pass extra args
                let bindFn = callback.invokeMethod("bind", withArguments: [JSValue(nullIn: context)!] + extraArgs)!
                wrappedCallback = bindFn
            }

            let id = runtime.eventLoop.scheduleTimer(
                callback: wrappedCallback,
                delay: delay,
                repeats: false,
                context: context
            )
            return JSValue(int32: Int32(id), in: JSContext.current())
        }

        // setInterval(callback, delay, ...args)
        let setInterval: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let callback = args.first, !callback.isUndefined else {
                return JSValue(int32: 0, in: JSContext.current())
            }
            let delay = args.count > 1 ? args[1].toDouble() : 0
            let extraArgs = args.count > 2 ? Array(args[2...]) : []

            let wrappedCallback: JSValue
            if extraArgs.isEmpty {
                wrappedCallback = callback
            } else {
                let bindFn = callback.invokeMethod("bind", withArguments: [JSValue(nullIn: context)!] + extraArgs)!
                wrappedCallback = bindFn
            }

            let id = runtime.eventLoop.scheduleTimer(
                callback: wrappedCallback,
                delay: delay,
                repeats: true,
                context: context
            )
            return JSValue(int32: Int32(id), in: JSContext.current())
        }

        // clearTimeout / clearInterval
        let clearTimer: @convention(block) (JSValue) -> Void = { idValue in
            let id = Int(idValue.toInt32())
            runtime.eventLoop.clearTimer(id: id)
        }

        context.setObject(unsafeBitCast(setTimeout, to: AnyObject.self),
                          forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(unsafeBitCast(setInterval, to: AnyObject.self),
                          forKeyedSubscript: "setInterval" as NSString)
        context.setObject(unsafeBitCast(clearTimer, to: AnyObject.self),
                          forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(unsafeBitCast(clearTimer, to: AnyObject.self),
                          forKeyedSubscript: "clearInterval" as NSString)

        // Also available as require('timers')
        exports.setValue(unsafeBitCast(setTimeout, to: AnyObject.self), forProperty: "setTimeout")
        exports.setValue(unsafeBitCast(setInterval, to: AnyObject.self), forProperty: "setInterval")
        exports.setValue(unsafeBitCast(clearTimer, to: AnyObject.self), forProperty: "clearTimeout")
        exports.setValue(unsafeBitCast(clearTimer, to: AnyObject.self), forProperty: "clearInterval")

        return exports
    }
}
