import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Array Creation

@_cdecl("napi_create_array")
public func _napi_create_array(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(newArrayIn: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_array_with_length")
public func _napi_create_array_with_length(_ env: napi_env!, _ length: Int, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let arr = e.context.evaluateScript("(function(n){return new Array(n)})")!.call(withArguments: [length])!
    result.pointee = e.wrap(arr)
    return e.clearLastError()
}

// MARK: - Array Length

@_cdecl("napi_get_array_length")
public func _napi_get_array_length(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<UInt32>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let arr = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let len = arr.forProperty("length")!
    result.pointee = len.toUInt32()
    return e.clearLastError()
}

// MARK: - Element Access

@_cdecl("napi_get_element")
public func _napi_get_element(_ env: napi_env!, _ object: napi_value!, _ index: UInt32, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let val = obj.atIndex(Int(index))!
    result.pointee = e.wrap(val)
    return e.clearLastError()
}

@_cdecl("napi_set_element")
public func _napi_set_element(_ env: napi_env!, _ object: napi_value!, _ index: UInt32, _ value: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let val = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    obj.setValue(val, at: Int(index))
    return e.clearLastError()
}

@_cdecl("napi_has_element")
public func _napi_has_element(_ env: napi_env!, _ object: napi_value!, _ index: UInt32, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let has = e.context.evaluateScript("(function(o,i){return i in o})")!.call(withArguments: [obj, index])!
    result.pointee = has.toBool()
    return e.clearLastError()
}

@_cdecl("napi_delete_element")
public func _napi_delete_element(_ env: napi_env!, _ object: napi_value!, _ index: UInt32, _ result: UnsafeMutablePointer<Bool>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object) else { return e.setLastError(napi_invalid_arg) }
    let deleted = e.context.evaluateScript("(function(o,i){return delete o[i]})")!.call(withArguments: [obj, index])!
    result?.pointee = deleted.toBool()
    return e.clearLastError()
}
