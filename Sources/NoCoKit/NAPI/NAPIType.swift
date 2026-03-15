import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Type Checking

@_cdecl("napi_typeof")
public func _napi_typeof(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<napi_valuetype>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }

    // Check for external (tagged with __napi_external marker)
    if jsVal.isObject, let marker = jsVal.forProperty("__napi_external"), marker.toBool() {
        result.pointee = napi_external
        return e.clearLastError()
    }

    let typeStr = e.context.evaluateScript("(function(v){return typeof v})")!.call(withArguments: [jsVal])!.toString() ?? ""
    switch typeStr {
    case "undefined": result.pointee = napi_undefined
    case "boolean": result.pointee = napi_boolean
    case "number": result.pointee = napi_number
    case "string": result.pointee = napi_string
    case "symbol": result.pointee = napi_symbol
    case "function": result.pointee = napi_function
    case "bigint": result.pointee = napi_bigint
    case "object":
        if jsVal.isNull {
            result.pointee = napi_null
        } else {
            result.pointee = napi_object
        }
    default: result.pointee = napi_undefined
    }
    return e.clearLastError()
}

@_cdecl("napi_is_array")
public func _napi_is_array(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let isArr = e.context.evaluateScript("(function(v){return Array.isArray(v)})")!.call(withArguments: [jsVal])!
    result.pointee = isArr.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_arraybuffer")
public func _napi_is_arraybuffer(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return v instanceof ArrayBuffer})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_buffer")
public func _napi_is_buffer(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return typeof Buffer!=='undefined'&&Buffer.isBuffer(v)})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_date")
public func _napi_is_date(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return v instanceof Date})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_typedarray")
public func _napi_is_typedarray(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return ArrayBuffer.isView(v)&&!(v instanceof DataView)})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_dataview")
public func _napi_is_dataview(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return v instanceof DataView})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

@_cdecl("napi_is_promise")
public func _napi_is_promise(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(v){return v instanceof Promise})")!.call(withArguments: [jsVal])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

// MARK: - Comparison

@_cdecl("napi_strict_equals")
public func _napi_strict_equals(_ env: napi_env!, _ lhs: napi_value!, _ rhs: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let l = e.unwrap(lhs), let r = e.unwrap(rhs) else { return e.setLastError(napi_invalid_arg) }
    let eq = e.context.evaluateScript("(function(a,b){return a===b})")!.call(withArguments: [l, r])!
    result.pointee = eq.toBool()
    return e.clearLastError()
}

@_cdecl("napi_instanceof")
public func _napi_instanceof(_ env: napi_env!, _ object: napi_value!, _ constructor: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let obj = e.unwrap(object), let ctor = e.unwrap(constructor) else { return e.setLastError(napi_invalid_arg) }
    let is_ = e.context.evaluateScript("(function(o,c){return o instanceof c})")!.call(withArguments: [obj, ctor])!
    result.pointee = is_.toBool()
    return e.clearLastError()
}

// MARK: - Date

@_cdecl("napi_create_date")
public func _napi_create_date(_ env: napi_env!, _ time: Double, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let date = e.context.evaluateScript("(function(t){return new Date(t)})")!.call(withArguments: [time])!
    result.pointee = e.wrap(date)
    return e.clearLastError()
}

@_cdecl("napi_get_date_value")
public func _napi_get_date_value(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Double>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let time = e.context.evaluateScript("(function(d){return d.getTime()})")!.call(withArguments: [jsVal])!
    result.pointee = time.toDouble()
    return e.clearLastError()
}

// MARK: - BigInt (stub)

@_cdecl("napi_create_bigint_int64")
public func _napi_create_bigint_int64(_ env: napi_env!, _ value: Int64, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let bigint = e.context.evaluateScript("(function(v){return BigInt(v)})")!.call(withArguments: [value])!
    result.pointee = e.wrap(bigint)
    return e.clearLastError()
}

@_cdecl("napi_create_bigint_uint64")
public func _napi_create_bigint_uint64(_ env: napi_env!, _ value: UInt64, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let bigint = e.context.evaluateScript("(function(v){return BigInt(v)})")!.call(withArguments: [NSNumber(value: value)])!
    result.pointee = e.wrap(bigint)
    return e.clearLastError()
}

@_cdecl("napi_get_value_bigint_int64")
public func _napi_get_value_bigint_int64(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Int64>!, _ lossless: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let num = e.context.evaluateScript("(function(v){return Number(v)})")!.call(withArguments: [jsVal])!
    result.pointee = Int64(num.toDouble())
    lossless.pointee = true
    return e.clearLastError()
}

@_cdecl("napi_get_value_bigint_uint64")
public func _napi_get_value_bigint_uint64(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<UInt64>!, _ lossless: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let num = e.context.evaluateScript("(function(v){return Number(v)})")!.call(withArguments: [jsVal])!
    result.pointee = UInt64(num.toDouble())
    lossless.pointee = true
    return e.clearLastError()
}
