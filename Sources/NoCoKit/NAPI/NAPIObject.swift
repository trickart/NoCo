import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Object Creation

@_cdecl("napi_create_object")
public func _napi_create_object(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(newObjectIn: e.context))
    return e.clearLastError()
}

// MARK: - Property Access

@_cdecl("napi_get_property")
public func _napi_get_property(_ env: napi_env!, _ object: napi_value!, _ key: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let k = e.unwrap(key) else { return e.setLastError(napi_invalid_arg) }
    let val = obj.objectForKeyedSubscript(k)!
    result.pointee = e.wrap(val)
    return e.clearLastError()
}

@_cdecl("napi_set_property")
public func _napi_set_property(_ env: napi_env!, _ object: napi_value!, _ key: napi_value!, _ value: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let k = e.unwrap(key), let v = e.unwrap(value) else {
        return e.setLastError(napi_invalid_arg)
    }
    obj.setObject(v, forKeyedSubscript: k)
    return e.clearLastError()
}

@_cdecl("napi_has_property")
public func _napi_has_property(_ env: napi_env!, _ object: napi_value!, _ key: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let k = e.unwrap(key) else { return e.setLastError(napi_invalid_arg) }
    let has = e.context.evaluateScript("(function(o,k){return k in o})")!.call(withArguments: [obj, k])!
    result.pointee = has.toBool()
    return e.clearLastError()
}

@_cdecl("napi_delete_property")
public func _napi_delete_property(_ env: napi_env!, _ object: napi_value!, _ key: napi_value!, _ result: UnsafeMutablePointer<Bool>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let k = e.unwrap(key) else { return e.setLastError(napi_invalid_arg) }
    let deleted = e.context.evaluateScript("(function(o,k){return delete o[k]})")!.call(withArguments: [obj, k])!
    result?.pointee = deleted.toBool()
    return e.clearLastError()
}

// MARK: - Named Property Access

@_cdecl("napi_get_named_property")
public func _napi_get_named_property(_ env: napi_env!, _ object: napi_value!, _ utf8name: UnsafePointer<CChar>!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let name = String(cString: utf8name)
    let val = obj.forProperty(name) ?? JSValue(undefinedIn: e.context)!
    result.pointee = e.wrap(val)
    return e.clearLastError()
}

@_cdecl("napi_set_named_property")
public func _napi_set_named_property(_ env: napi_env!, _ object: napi_value!, _ utf8name: UnsafePointer<CChar>!, _ value: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let v = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let name = String(cString: utf8name)
    obj.setValue(v, forProperty: name)
    return e.clearLastError()
}

@_cdecl("napi_has_named_property")
public func _napi_has_named_property(_ env: napi_env!, _ object: napi_value!, _ utf8name: UnsafePointer<CChar>!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let name = String(cString: utf8name)
    let has = obj.hasProperty(name)
    result.pointee = has
    return e.clearLastError()
}

// MARK: - Define Properties

@_cdecl("napi_define_properties")
public func _napi_define_properties(_ env: napi_env!, _ object: napi_value!, _ propertyCount: Int,
                              _ properties: UnsafePointer<napi_property_descriptor>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }

    for i in 0..<propertyCount {
        let prop = properties[i]
        let name: String
        if let utf8name = prop.utf8name {
            name = String(cString: utf8name)
        } else if let napiName = prop.name, let jsName = e.unwrap(napiName) {
            name = jsName.toString()
        } else {
            continue
        }

        let attrs = prop.attributes

        if let method = prop.method {
            // Method property
            let data = prop.data
            let callback: @convention(block) () -> JSValue = {
                let ctx = JSContext.current()!
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let thisVal = JSContext.currentThis()!
                let cbInfo = NAPICallbackInfoData(thisValue: thisVal, args: args, data: data)
                e.callbackInfoStack.append(cbInfo)
                defer { e.callbackInfoStack.removeLast() }

                let result = method(env, cbInfo.toOpaque())
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
            defineProperty(obj, name: name, value: jsFn, attrs: attrs, context: e.context)
        } else if let getter = prop.getter {
            // Accessor property
            let data = prop.data
            let getterBlock: @convention(block) () -> JSValue = {
                let cbInfo = NAPICallbackInfoData(thisValue: JSContext.currentThis()!, args: [], data: data)
                e.callbackInfoStack.append(cbInfo)
                defer { e.callbackInfoStack.removeLast() }
                let result = getter(env, cbInfo.toOpaque())
                if let result = result, let val = e.unwrap(result) { return val }
                return JSValue(undefinedIn: e.context)
            }
            let getterFn = JSValue(object: unsafeBitCast(getterBlock, to: AnyObject.self), in: e.context)!

            var setterFn: JSValue?
            if let setter = prop.setter {
                let setterBlock: @convention(block) (JSValue) -> Void = { newVal in
                    let cbInfo = NAPICallbackInfoData(thisValue: JSContext.currentThis()!, args: [newVal], data: data)
                    e.callbackInfoStack.append(cbInfo)
                    defer { e.callbackInfoStack.removeLast() }
                    _ = setter(env, cbInfo.toOpaque())
                }
                setterFn = JSValue(object: unsafeBitCast(setterBlock, to: AnyObject.self), in: e.context)!
            }

            let descriptor = JSValue(newObjectIn: e.context)!
            descriptor.setValue(getterFn, forProperty: "get")
            if let sf = setterFn { descriptor.setValue(sf, forProperty: "set") }
            descriptor.setValue(attrs.rawValue & napi_enumerable.rawValue != 0, forProperty: "enumerable")
            descriptor.setValue(attrs.rawValue & napi_configurable.rawValue != 0, forProperty: "configurable")
            e.context.evaluateScript("(function(o,n,d){Object.defineProperty(o,n,d)})")!
                .call(withArguments: [obj, name, descriptor])
        } else if let value = prop.value, let jsVal = e.unwrap(value) {
            // Data property
            defineProperty(obj, name: name, value: jsVal, attrs: attrs, context: e.context)
        }
    }

    return e.clearLastError()
}

private func defineProperty(_ obj: JSValue, name: String, value: JSValue, attrs: napi_property_attributes, context: JSContext) {
    let descriptor = JSValue(newObjectIn: context)!
    descriptor.setValue(value, forProperty: "value")
    descriptor.setValue(attrs.rawValue & napi_writable.rawValue != 0, forProperty: "writable")
    descriptor.setValue(attrs.rawValue & napi_enumerable.rawValue != 0, forProperty: "enumerable")
    descriptor.setValue(attrs.rawValue & napi_configurable.rawValue != 0, forProperty: "configurable")
    context.evaluateScript("(function(o,n,d){Object.defineProperty(o,n,d)})")!
        .call(withArguments: [obj, name, descriptor])
}

// MARK: - Property Names

@_cdecl("napi_get_property_names")
public func _napi_get_property_names(_ env: napi_env!, _ object: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let names = e.context.evaluateScript("(function(o){return Object.keys(o)})")!.call(withArguments: [obj])!
    result.pointee = e.wrap(names)
    return e.clearLastError()
}

@_cdecl("napi_get_all_property_names")
public func _napi_get_all_property_names(_ env: napi_env!, _ object: napi_value!,
                                    _ collectionMode: napi_key_collection_mode,
                                    _ keyFilter: napi_key_filter,
                                    _ keyConversion: napi_key_conversion,
                                    _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }

    let ownOnly = collectionMode == napi_key_own_only
    let script: String
    if ownOnly {
        if keyFilter.rawValue & napi_key_enumerable.rawValue != 0 {
            script = "(function(o){return Object.keys(o)})"
        } else {
            script = "(function(o){return Object.getOwnPropertyNames(o)})"
        }
    } else {
        script = "(function(o){var r=[];for(var k in o)r.push(k);return r})"
    }
    let names = e.context.evaluateScript(script)!.call(withArguments: [obj])!
    result.pointee = e.wrap(names)
    return e.clearLastError()
}

// MARK: - Object Freeze/Seal

@_cdecl("napi_object_freeze")
public func _napi_object_freeze(_ env: napi_env!, _ object: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    e.context.evaluateScript("(function(o){Object.freeze(o)})")!.call(withArguments: [obj])
    return e.clearLastError()
}

@_cdecl("napi_object_seal")
public func _napi_object_seal(_ env: napi_env!, _ object: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    e.context.evaluateScript("(function(o){Object.seal(o)})")!.call(withArguments: [obj])
    return e.clearLastError()
}
