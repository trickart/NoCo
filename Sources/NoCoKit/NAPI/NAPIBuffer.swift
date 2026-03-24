import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Buffer

@_cdecl("napi_create_buffer")
public func _napi_create_buffer(_ env: napi_env!, _ length: Int,
                          _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                          _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let buf = e.context.evaluateScript("(function(n){return Buffer.alloc(n)})")!.call(withArguments: [length])!
    result.pointee = e.wrap(buf)

    // For data pointer, we can't easily provide direct memory access from JSC Buffer.
    // Set to nil; callers should use napi_get_buffer_info after creation if they need the pointer.
    data?.pointee = nil
    return e.clearLastError()
}

@_cdecl("napi_create_buffer_copy")
public func _napi_create_buffer_copy(_ env: napi_env!, _ length: Int, _ data: UnsafeRawPointer!,
                               _ resultData: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                               _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)

    // Create a Buffer from the data
    let jsArray = JSValue(newArrayIn: e.context)!
    for i in 0..<length {
        jsArray.setValue(data.load(fromByteOffset: i, as: UInt8.self), at: i)
    }
    let buf = e.context.evaluateScript("(function(a){return Buffer.from(a)})")!.call(withArguments: [jsArray])!
    result.pointee = e.wrap(buf)
    resultData?.pointee = nil
    return e.clearLastError()
}

@_cdecl("napi_create_external_buffer")
public func _napi_create_external_buffer(_ env: napi_env!, _ length: Int,
                                    _ data: UnsafeMutableRawPointer?,
                                    _ finalizeCb: napi_finalize?,
                                    _ finalizeHint: UnsafeMutableRawPointer?,
                                    _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)

    // Create a Buffer and copy data from the external pointer
    if let data = data, length > 0 {
        let jsArray = JSValue(newArrayIn: e.context)!
        let src = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<length {
            jsArray.setValue(src[i], at: i)
        }
        let buf = e.context.evaluateScript("(function(a){return Buffer.from(a)})")!.call(withArguments: [jsArray])!
        result.pointee = e.wrap(buf)
    } else {
        let buf = e.context.evaluateScript("(function(n){return Buffer.alloc(n)})")!.call(withArguments: [length])!
        result.pointee = e.wrap(buf)
    }

    // Call finalize callback to free the external data
    if let finalizeCb = finalizeCb {
        finalizeCb(env, data, finalizeHint)
    }

    return e.clearLastError()
}

@_cdecl("napi_get_buffer_info")
public func _napi_get_buffer_info(_ env: napi_env!, _ value: napi_value!,
                            _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                            _ length: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let buf = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }

    let len = buf.forProperty("length")?.toInt32() ?? 0
    length?.pointee = Int(len)
    // Direct memory access is not easily available through JSC's high-level API.
    data?.pointee = nil
    return e.clearLastError()
}

// MARK: - ArrayBuffer

@_cdecl("napi_create_arraybuffer")
public func _napi_create_arraybuffer(_ env: napi_env!, _ byteLength: Int,
                               _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                               _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let ab = e.context.evaluateScript("(function(n){return new ArrayBuffer(n)})")!.call(withArguments: [byteLength])!
    result.pointee = e.wrap(ab)
    data?.pointee = nil
    return e.clearLastError()
}

@_cdecl("napi_create_external_arraybuffer")
public func _napi_create_external_arraybuffer(_ env: napi_env!, _ externalData: UnsafeMutableRawPointer?,
                                        _ byteLength: Int,
                                        _ finalizeCb: napi_finalize?,
                                        _ finalizeHint: UnsafeMutableRawPointer?,
                                        _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    // Create an ArrayBuffer and copy data in (JSC doesn't support external backing stores easily)
    let ab = e.context.evaluateScript("(function(n){return new ArrayBuffer(n)})")!.call(withArguments: [byteLength])!

    if let externalData = externalData, byteLength > 0 {
        // Copy data into the ArrayBuffer via Uint8Array
        let u8 = e.context.evaluateScript("(function(ab){return new Uint8Array(ab)})")!.call(withArguments: [ab])!
        let src = externalData.assumingMemoryBound(to: UInt8.self)
        for i in 0..<byteLength {
            u8.setValue(src[i], at: i)
        }
    }

    result.pointee = e.wrap(ab)
    return e.clearLastError()
}

@_cdecl("napi_get_arraybuffer_info")
public func _napi_get_arraybuffer_info(_ env: napi_env!, _ arraybuffer: napi_value!,
                                 _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                                 _ byteLength: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let ab = e.unwrap(arraybuffer) else { return e.setLastError(napi_invalid_arg) }
    let len = ab.forProperty("byteLength")?.toInt32() ?? 0
    byteLength?.pointee = Int(len)
    data?.pointee = nil
    return e.clearLastError()
}

@_cdecl("napi_detach_arraybuffer")
public func _napi_detach_arraybuffer(_ env: napi_env!, _ arraybuffer: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    // JSC doesn't support detaching ArrayBuffers via the high-level API
    return e.clearLastError()
}

@_cdecl("napi_is_detached_arraybuffer")
public func _napi_is_detached_arraybuffer(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = false
    return e.clearLastError()
}

// MARK: - TypedArray

@_cdecl("napi_create_typedarray")
public func _napi_create_typedarray(_ env: napi_env!, _ type: napi_typedarray_type,
                              _ length: Int, _ arraybuffer: napi_value!,
                              _ byteOffset: Int,
                              _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let ab = e.unwrap(arraybuffer) else { return e.setLastError(napi_invalid_arg) }

    let ctorName: String
    switch type {
    case napi_int8_array: ctorName = "Int8Array"
    case napi_uint8_array: ctorName = "Uint8Array"
    case napi_uint8_clamped_array: ctorName = "Uint8ClampedArray"
    case napi_int16_array: ctorName = "Int16Array"
    case napi_uint16_array: ctorName = "Uint16Array"
    case napi_int32_array: ctorName = "Int32Array"
    case napi_uint32_array: ctorName = "Uint32Array"
    case napi_float32_array: ctorName = "Float32Array"
    case napi_float64_array: ctorName = "Float64Array"
    case napi_bigint64_array: ctorName = "BigInt64Array"
    case napi_biguint64_array: ctorName = "BigUint64Array"
    default: ctorName = "Uint8Array"
    }

    let ta = e.context.evaluateScript("(function(ab,o,n,C){return new (eval(C))(ab,o,n)})")!
        .call(withArguments: [ab, byteOffset, length, ctorName])!
    result.pointee = e.wrap(ta)
    return e.clearLastError()
}

@_cdecl("napi_get_typedarray_info")
public func _napi_get_typedarray_info(_ env: napi_env!, _ typedarray: napi_value!,
                                _ type: UnsafeMutablePointer<napi_typedarray_type>?,
                                _ length: UnsafeMutablePointer<Int>?,
                                _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                                _ arraybuffer: UnsafeMutablePointer<napi_value?>?,
                                _ byteOffset: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let ta = e.unwrap(typedarray) else { return e.setLastError(napi_invalid_arg) }

    length?.pointee = Int(ta.forProperty("length")?.toInt32() ?? 0)
    byteOffset?.pointee = Int(ta.forProperty("byteOffset")?.toInt32() ?? 0)
    data?.pointee = nil

    if let arraybuffer = arraybuffer {
        let ab = ta.forProperty("buffer")!
        arraybuffer.pointee = e.wrap(ab)
    }

    if let type = type {
        let ctorName = e.context.evaluateScript("(function(v){return v.constructor.name})")!.call(withArguments: [ta])!.toString() ?? ""
        switch ctorName {
        case "Int8Array": type.pointee = napi_int8_array
        case "Uint8Array": type.pointee = napi_uint8_array
        case "Uint8ClampedArray": type.pointee = napi_uint8_clamped_array
        case "Int16Array": type.pointee = napi_int16_array
        case "Uint16Array": type.pointee = napi_uint16_array
        case "Int32Array": type.pointee = napi_int32_array
        case "Uint32Array": type.pointee = napi_uint32_array
        case "Float32Array": type.pointee = napi_float32_array
        case "Float64Array": type.pointee = napi_float64_array
        case "BigInt64Array": type.pointee = napi_bigint64_array
        case "BigUint64Array": type.pointee = napi_biguint64_array
        default: type.pointee = napi_uint8_array
        }
    }

    return e.clearLastError()
}

// MARK: - DataView

@_cdecl("napi_create_dataview")
public func _napi_create_dataview(_ env: napi_env!, _ byteLength: Int, _ arraybuffer: napi_value!,
                            _ byteOffset: Int, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let ab = e.unwrap(arraybuffer) else { return e.setLastError(napi_invalid_arg) }
    let dv = e.context.evaluateScript("(function(ab,o,n){return new DataView(ab,o,n)})")!
        .call(withArguments: [ab, byteOffset, byteLength])!
    result.pointee = e.wrap(dv)
    return e.clearLastError()
}

@_cdecl("napi_get_dataview_info")
public func _napi_get_dataview_info(_ env: napi_env!, _ dataview: napi_value!,
                              _ byteLength: UnsafeMutablePointer<Int>?,
                              _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                              _ arraybuffer: UnsafeMutablePointer<napi_value?>?,
                              _ byteOffset: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let dv = e.unwrap(dataview) else { return e.setLastError(napi_invalid_arg) }
    byteLength?.pointee = Int(dv.forProperty("byteLength")?.toInt32() ?? 0)
    byteOffset?.pointee = Int(dv.forProperty("byteOffset")?.toInt32() ?? 0)
    data?.pointee = nil
    if let arraybuffer = arraybuffer {
        arraybuffer.pointee = e.wrap(dv.forProperty("buffer")!)
    }
    return e.clearLastError()
}
