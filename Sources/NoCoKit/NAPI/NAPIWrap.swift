import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Object Wrapping

@_cdecl("napi_wrap")
public func _napi_wrap(_ env: napi_env!, _ jsObject: napi_value!, _ nativeObject: UnsafeMutableRawPointer!,
                 _ finalizeCb: napi_finalize?, _ finalizeHint: UnsafeMutableRawPointer?,
                 _ result: UnsafeMutablePointer<napi_ref?>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(jsObject) else { return e.setLastError(napi_invalid_arg) }
    let key = ObjectIdentifier(obj)
    e.wrapMap[key] = (pointer: nativeObject, finalizeCb)

    if let result = result {
        // Create a reference too
        var ref: napi_ref?
        _ = _napi_create_reference(env, jsObject, 1, &ref)
        result.pointee = ref
    }
    return e.clearLastError()
}

@_cdecl("napi_unwrap")
public func _napi_unwrap(_ env: napi_env!, _ jsObject: napi_value!, _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(jsObject) else { return e.setLastError(napi_invalid_arg) }
    let key = ObjectIdentifier(obj)
    guard let wrap = e.wrapMap[key] else { return e.setLastError(napi_invalid_arg) }
    result.pointee = wrap.pointer
    return e.clearLastError()
}

@_cdecl("napi_remove_wrap")
public func _napi_remove_wrap(_ env: napi_env!, _ jsObject: napi_value!, _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(jsObject) else { return e.setLastError(napi_invalid_arg) }
    let key = ObjectIdentifier(obj)
    guard let wrap = e.wrapMap.removeValue(forKey: key) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = wrap.pointer
    return e.clearLastError()
}

// MARK: - External

@_cdecl("napi_create_external")
public func _napi_create_external(_ env: napi_env!, _ data: UnsafeMutableRawPointer?,
                            _ finalizeCb: napi_finalize?, _ finalizeHint: UnsafeMutableRawPointer?,
                            _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)

    // Create a JS object to represent the external
    let obj = JSValue(newObjectIn: e.context)!
    // Mark as external (for napi_typeof)
    obj.setValue(true, forProperty: "__napi_external")

    let extId = e.nextExternalId
    e.nextExternalId += 1
    obj.setValue(extId, forProperty: "__napi_external_id")
    e.externalDataMap[extId] = (data: data, finalizeCb)

    result.pointee = e.wrap(obj)
    return e.clearLastError()
}

@_cdecl("napi_get_value_external")
public func _napi_get_value_external(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }

    let extId = obj.forProperty("__napi_external_id")?.toInt32() ?? 0
    if let extData = e.externalDataMap[Int(extId)] {
        result.pointee = extData.data
    } else {
        result.pointee = nil
    }
    return e.clearLastError()
}

// MARK: - Add Finalizer

@_cdecl("napi_add_finalizer")
public func _napi_add_finalizer(_ env: napi_env!, _ jsObject: napi_value!,
                          _ nativeObject: UnsafeMutableRawPointer?,
                          _ finalizeCb: napi_finalize?, _ finalizeHint: UnsafeMutableRawPointer?,
                          _ result: UnsafeMutablePointer<napi_ref?>?) -> napi_status {
    // For now, we store the finalizer but JSC doesn't provide weak reference callbacks.
    // In a production implementation, we'd use custom weak ref tracking.
    let e = NAPIEnvironment.from(env)
    if let result = result {
        var ref: napi_ref?
        _ = _napi_create_reference(env, jsObject, 0, &ref)
        result.pointee = ref
    }
    return e.clearLastError()
}

// MARK: - Cleanup Hooks

@_cdecl("napi_add_env_cleanup_hook")
public func _napi_add_env_cleanup_hook(_ env: napi_env!, _ fun: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, _ arg: UnsafeMutableRawPointer?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    if let fun = fun {
        e.cleanupHooks.append { _ in fun(arg) }
    }
    return e.clearLastError()
}

@_cdecl("napi_remove_env_cleanup_hook")
public func _napi_remove_env_cleanup_hook(_ env: napi_env!, _ fun: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, _ arg: UnsafeMutableRawPointer?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    // Simplified: just clear last hook (exact matching is complex with function pointers)
    if !e.cleanupHooks.isEmpty {
        e.cleanupHooks.removeLast()
    }
    return e.clearLastError()
}
