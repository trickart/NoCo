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

        // setImmediate(callback, ...args) — dedicated immediate queue
        let setImmediate: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let callback = args.first, !callback.isUndefined else {
                return JSValue(int32: 0, in: JSContext.current())
            }
            let extraArgs = args.count > 1 ? Array(args[1...]) : []

            let wrappedCallback: JSValue
            if extraArgs.isEmpty {
                wrappedCallback = callback
            } else {
                let bindFn = callback.invokeMethod("bind", withArguments: [JSValue(nullIn: context)!] + extraArgs)!
                wrappedCallback = bindFn
            }

            let id = runtime.eventLoop.scheduleImmediate(callback: wrappedCallback)
            return JSValue(int32: Int32(id), in: JSContext.current())
        }

        // clearImmediate(id)
        let clearImmediateFn: @convention(block) (JSValue) -> Void = { idValue in
            let id = Int(idValue.toInt32())
            runtime.eventLoop.clearImmediate(id: id)
        }

        context.setObject(unsafeBitCast(setTimeout, to: AnyObject.self),
                          forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(unsafeBitCast(setInterval, to: AnyObject.self),
                          forKeyedSubscript: "setInterval" as NSString)
        context.setObject(unsafeBitCast(clearTimer, to: AnyObject.self),
                          forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(unsafeBitCast(clearTimer, to: AnyObject.self),
                          forKeyedSubscript: "clearInterval" as NSString)
        context.setObject(unsafeBitCast(setImmediate, to: AnyObject.self),
                          forKeyedSubscript: "setImmediate" as NSString)
        context.setObject(unsafeBitCast(clearImmediateFn, to: AnyObject.self),
                          forKeyedSubscript: "clearImmediate" as NSString)

        // __timerRef(id, bool) — bridge for ref/unref
        let timerRef: @convention(block) (JSValue, JSValue) -> Void = { idValue, refValue in
            let id = Int(idValue.toInt32())
            let ref = refValue.toBool()
            runtime.eventLoop.setTimerRef(id: id, ref: ref)
        }
        context.setObject(unsafeBitCast(timerRef, to: AnyObject.self),
                          forKeyedSubscript: "__timerRef" as NSString)

        // Wrap timer functions to return Timeout objects with ref()/unref()
        context.evaluateScript("""
            (function(origSetTimeout, origSetInterval, origSetImmediate, timerRef) {
                function wrapTimeout(id) {
                    var t = { _id: id, _destroyed: false, _isRef: true };
                    t.ref = function() { t._isRef = true; timerRef(id, true); return t; };
                    t.unref = function() { t._isRef = false; timerRef(id, false); return t; };
                    t.refresh = function() { return t; };
                    t.hasRef = function() { return t._isRef; };
                    t[Symbol.toPrimitive] = function() { return id; };
                    return t;
                }
                globalThis.setTimeout = function setTimeout() {
                    var id = origSetTimeout.apply(null, arguments);
                    return wrapTimeout(id);
                };
                globalThis.setInterval = function setInterval() {
                    var id = origSetInterval.apply(null, arguments);
                    return wrapTimeout(id);
                };
                globalThis.setImmediate = function setImmediate() {
                    var id = origSetImmediate.apply(null, arguments);
                    return wrapTimeout(id);
                };
            })
        """)!.call(withArguments: [
            context.objectForKeyedSubscript("setTimeout" as NSString)!,
            context.objectForKeyedSubscript("setInterval" as NSString)!,
            context.objectForKeyedSubscript("setImmediate" as NSString)!,
            context.objectForKeyedSubscript("__timerRef" as NSString)!,
        ])

        // Also available as require('timers')
        exports.setValue(context.objectForKeyedSubscript("setTimeout" as NSString)!, forProperty: "setTimeout")
        exports.setValue(context.objectForKeyedSubscript("setInterval" as NSString)!, forProperty: "setInterval")
        exports.setValue(unsafeBitCast(clearTimer, to: AnyObject.self), forProperty: "clearTimeout")
        exports.setValue(unsafeBitCast(clearTimer, to: AnyObject.self), forProperty: "clearInterval")
        exports.setValue(context.objectForKeyedSubscript("setImmediate" as NSString)!, forProperty: "setImmediate")
        exports.setValue(unsafeBitCast(clearImmediateFn, to: AnyObject.self), forProperty: "clearImmediate")

        return exports
    }
}
