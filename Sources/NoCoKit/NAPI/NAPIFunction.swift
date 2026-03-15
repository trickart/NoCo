import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Function Creation

@_cdecl("napi_create_function")
public func _napi_create_function(_ env: napi_env!, _ utf8name: UnsafePointer<CChar>?,
                            _ length: Int, _ cb: napi_callback!, _ data: UnsafeMutableRawPointer?,
                            _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let envPtr = env!

    let callback: @convention(block) () -> JSValue = {
        let ctx = JSContext.current()!
        let args = JSContext.currentArguments() as? [JSValue] ?? []
        let thisVal = JSContext.currentThis()!
        let cbInfo = NAPICallbackInfoData(thisValue: thisVal, args: args, data: data)
        e.callbackInfoStack.append(cbInfo)
        defer { e.callbackInfoStack.removeLast() }

        let result = cb(envPtr, cbInfo.toOpaque())
        if let exception = e.pendingException {
            e.pendingException = nil
            ctx.exception = exception
            return JSValue(undefinedIn: ctx)
        }
        if let result = result, let val = e.unwrap(result) {
            return val
        }
        return JSValue(undefinedIn: ctx)
    }

    let jsFn = JSValue(object: unsafeBitCast(callback, to: AnyObject.self), in: e.context)!
    if let utf8name = utf8name {
        let name = length == -1 ? String(cString: utf8name) : String(decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(utf8name)), count: length), as: UTF8.self)
        if !name.isEmpty {
            e.context.evaluateScript("(function(f,n){Object.defineProperty(f,'name',{value:n})})")!
                .call(withArguments: [jsFn, name])
        }
    }

    result.pointee = e.wrap(jsFn)
    return e.clearLastError()
}

// MARK: - Function Calling

@_cdecl("napi_call_function")
public func _napi_call_function(_ env: napi_env!, _ recv: napi_value!, _ func_: napi_value!,
                          _ argc: Int, _ argv: UnsafePointer<napi_value?>?,
                          _ result: UnsafeMutablePointer<napi_value?>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let fn = e.unwrap(func_) else { return e.setLastError(napi_invalid_arg) }
    let thisVal = e.unwrap(recv) ?? JSValue(undefinedIn: e.context)!

    var args: [JSValue] = []
    if let argv = argv {
        for i in 0..<argc {
            if let argPtr = argv[i], let arg = e.unwrap(argPtr) {
                args.append(arg)
            } else {
                args.append(JSValue(undefinedIn: e.context))
            }
        }
    }

    // Use call with this binding
    let callResult = e.context.evaluateScript("(function(fn,t,a){return fn.apply(t,a)})")!
        .call(withArguments: [fn, thisVal, JSValue.array(from: args, in: e.context)])!

    if let exception = e.context.exception {
        e.context.exception = nil
        e.pendingException = exception
        return e.setLastError(napi_pending_exception)
    }

    result?.pointee = e.wrap(callResult)
    return e.clearLastError()
}

@_cdecl("napi_new_instance")
public func _napi_new_instance(_ env: napi_env!, _ constructor: napi_value!, _ argc: Int,
                         _ argv: UnsafePointer<napi_value?>?,
                         _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let ctor = e.unwrap(constructor) else { return e.setLastError(napi_invalid_arg) }

    var args: [JSValue] = []
    if let argv = argv {
        for i in 0..<argc {
            if let argPtr = argv[i], let arg = e.unwrap(argPtr) {
                args.append(arg)
            } else {
                args.append(JSValue(undefinedIn: e.context))
            }
        }
    }

    let instance = ctor.construct(withArguments: args)!

    if let exception = e.context.exception {
        e.context.exception = nil
        e.pendingException = exception
        return e.setLastError(napi_pending_exception)
    }

    result.pointee = e.wrap(instance)
    return e.clearLastError()
}

// MARK: - Callback Info

@_cdecl("napi_get_cb_info")
public func _napi_get_cb_info(_ env: napi_env!, _ cbinfo: napi_callback_info!,
                        _ argc: UnsafeMutablePointer<Int>?,
                        _ argv: UnsafeMutablePointer<napi_value?>?,
                        _ thisArg: UnsafeMutablePointer<napi_value?>?,
                        _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let info = NAPICallbackInfoData.from(cbinfo)

    if let argc = argc {
        let requested = argc.pointee
        argc.pointee = info.args.count

        if let argv = argv {
            let count = min(requested, info.args.count)
            for i in 0..<count {
                argv[i] = e.wrap(info.args[i])
            }
            // Fill remaining with undefined
            for i in count..<requested {
                argv[i] = e.wrap(JSValue(undefinedIn: e.context))
            }
        }
    }

    thisArg?.pointee = e.wrap(info.thisValue)
    data?.pointee = info.data

    return e.clearLastError()
}

// MARK: - Define Class

@_cdecl("napi_define_class")
public func _napi_define_class(_ env: napi_env!, _ utf8name: UnsafePointer<CChar>!, _ length: Int,
                         _ constructor: napi_callback!, _ data: UnsafeMutableRawPointer?,
                         _ propertyCount: Int,
                         _ properties: UnsafePointer<napi_property_descriptor>?,
                         _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let envPtr = env!

    let name = length == -1 ? String(cString: utf8name) : String(decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(utf8name)), count: length), as: UTF8.self)

    // Create constructor function
    let ctorBlock: @convention(block) () -> JSValue = {
        let ctx = JSContext.current()!
        let args = JSContext.currentArguments() as? [JSValue] ?? []
        let thisVal = JSContext.currentThis()!
        let cbInfo = NAPICallbackInfoData(thisValue: thisVal, args: args, data: data)
        e.callbackInfoStack.append(cbInfo)
        defer { e.callbackInfoStack.removeLast() }

        let result = constructor(envPtr, cbInfo.toOpaque())
        if let exception = e.pendingException {
            e.pendingException = nil
            ctx.exception = exception
            return JSValue(undefinedIn: ctx)
        }
        if let result = result, let val = e.unwrap(result) {
            return val
        }
        return JSValue(undefinedIn: ctx)
    }

    // Create class using JS
    let ctorFn = JSValue(object: unsafeBitCast(ctorBlock, to: AnyObject.self), in: e.context)!
    let classFn = e.context.evaluateScript("""
        (function(impl, name) {
            var C = function() { return impl.apply(this, arguments); };
            Object.defineProperty(C, 'name', {value: name});
            return C;
        })
    """)!.call(withArguments: [ctorFn, name])!

    // Define properties on prototype and constructor
    if let properties = properties, propertyCount > 0 {
        let prototype = classFn.forProperty("prototype")!
        for i in 0..<propertyCount {
            let prop = properties[i]
            let isStatic = prop.attributes.rawValue & napi_static_property.rawValue != 0
            let target = isStatic ? classFn : prototype

            // Reuse napi_define_properties logic for single property
            let status = _napi_define_properties(env, isStatic ? e.wrap(classFn) : e.wrap(prototype), 1, properties.advanced(by: i))
            if status != napi_ok { return status }
            _ = target // suppress unused warning
        }
    }

    result.pointee = e.wrap(classFn)
    return e.clearLastError()
}
