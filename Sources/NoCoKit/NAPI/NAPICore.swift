import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Version / Error Info

@_cdecl("napi_get_version")
public func _napi_get_version(_ env: napi_env!, _ result: UnsafeMutablePointer<UInt32>!) -> napi_status {
    result.pointee = 9
    return NAPIEnvironment.from(env).clearLastError()
}

private nonisolated(unsafe) let nodeVersion = napi_node_version(major: 22, minor: 0, patch: 0, release: nil)

@_cdecl("napi_get_node_version")
public func _napi_get_node_version(_ env: napi_env!, _ result: UnsafeMutablePointer<UnsafePointer<napi_node_version>?>!) -> napi_status {
    withUnsafePointer(to: nodeVersion) { ptr in
        result.pointee = ptr
    }
    return NAPIEnvironment.from(env).clearLastError()
}

@_cdecl("napi_get_last_error_info")
public func _napi_get_last_error_info(_ env: napi_env!, _ result: UnsafeMutablePointer<UnsafePointer<napi_extended_error_info>?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = UnsafePointer(e.lastErrorPtr)
    return napi_ok
}

// MARK: - Primitive Values

@_cdecl("napi_get_undefined")
public func _napi_get_undefined(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(undefinedIn: e.context))
    return e.clearLastError()
}

@_cdecl("napi_get_null")
public func _napi_get_null(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(nullIn: e.context))
    return e.clearLastError()
}

@_cdecl("napi_get_global")
public func _napi_get_global(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(e.context.globalObject)
    return e.clearLastError()
}

@_cdecl("napi_get_boolean")
public func _napi_get_boolean(_ env: napi_env!, _ value: Bool, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(bool: value, in: e.context))
    return e.clearLastError()
}

// MARK: - Number Creation

@_cdecl("napi_create_int32")
public func _napi_create_int32(_ env: napi_env!, _ value: Int32, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(int32: value, in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_uint32")
public func _napi_create_uint32(_ env: napi_env!, _ value: UInt32, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(uInt32: value, in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_int64")
public func _napi_create_int64(_ env: napi_env!, _ value: Int64, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(double: Double(value), in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_double")
public func _napi_create_double(_ env: napi_env!, _ value: Double, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(double: value, in: e.context))
    return e.clearLastError()
}

// MARK: - Number Extraction

@_cdecl("napi_get_value_int32")
public func _napi_get_value_int32(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Int32>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = jsVal.toInt32()
    return e.clearLastError()
}

@_cdecl("napi_get_value_uint32")
public func _napi_get_value_uint32(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<UInt32>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = jsVal.toUInt32()
    return e.clearLastError()
}

@_cdecl("napi_get_value_int64")
public func _napi_get_value_int64(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Int64>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = Int64(jsVal.toDouble())
    return e.clearLastError()
}

@_cdecl("napi_get_value_double")
public func _napi_get_value_double(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Double>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = jsVal.toDouble()
    return e.clearLastError()
}

@_cdecl("napi_get_value_bool")
public func _napi_get_value_bool(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = jsVal.toBool()
    return e.clearLastError()
}

// MARK: - String Creation

@_cdecl("napi_create_string_utf8")
public func _napi_create_string_utf8(_ env: napi_env!, _ str: UnsafePointer<CChar>!, _ length: Int, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let swiftStr: String
    if length == -1 { // NAPI_AUTO_LENGTH
        swiftStr = String(cString: str)
    } else {
        swiftStr = String(decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(str)), count: length), as: UTF8.self)
    }
    result.pointee = e.wrap(JSValue(object: swiftStr, in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_string_utf16")
public func _napi_create_string_utf16(_ env: napi_env!, _ str: UnsafePointer<UInt16>!, _ length: Int, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let actualLength = length == -1 ? Int(strlen(UnsafeRawPointer(str).assumingMemoryBound(to: CChar.self)) / 2) : length
    let swiftStr = String(decoding: UnsafeBufferPointer(start: str, count: actualLength), as: UTF16.self)
    result.pointee = e.wrap(JSValue(object: swiftStr, in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_create_string_latin1")
public func _napi_create_string_latin1(_ env: napi_env!, _ str: UnsafePointer<CChar>!, _ length: Int, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let actualLength = length == -1 ? Int(strlen(str)) : length
    let data = Data(bytes: str, count: actualLength)
    let swiftStr = String(data: data, encoding: .isoLatin1) ?? ""
    result.pointee = e.wrap(JSValue(object: swiftStr, in: e.context))
    return e.clearLastError()
}

// MARK: - String Extraction

@_cdecl("napi_get_value_string_utf8")
public func _napi_get_value_string_utf8(_ env: napi_env!, _ value: napi_value!, _ buf: UnsafeMutablePointer<CChar>?, _ bufsize: Int, _ result: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let str = jsVal.toString() ?? ""
    let utf8 = Array(str.utf8)

    if let buf = buf, bufsize > 0 {
        let copyLen = min(utf8.count, bufsize - 1)
        utf8.withUnsafeBufferPointer { src in
            buf.withMemoryRebound(to: UInt8.self, capacity: copyLen) { dst in
                dst.update(from: src.baseAddress!, count: copyLen)
            }
        }
        buf[copyLen] = 0
        result?.pointee = copyLen
    } else {
        result?.pointee = utf8.count
    }
    return e.clearLastError()
}

@_cdecl("napi_get_value_string_utf16")
public func _napi_get_value_string_utf16(_ env: napi_env!, _ value: napi_value!, _ buf: UnsafeMutablePointer<UInt16>?, _ bufsize: Int, _ result: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let str = jsVal.toString() ?? ""
    let utf16 = Array(str.utf16)

    if let buf = buf, bufsize > 0 {
        let copyLen = min(utf16.count, bufsize - 1)
        for i in 0..<copyLen {
            buf[i] = utf16[i]
        }
        buf[copyLen] = 0
        result?.pointee = copyLen
    } else {
        result?.pointee = utf16.count
    }
    return e.clearLastError()
}

@_cdecl("napi_get_value_string_latin1")
public func _napi_get_value_string_latin1(_ env: napi_env!, _ value: napi_value!, _ buf: UnsafeMutablePointer<CChar>?, _ bufsize: Int, _ result: UnsafeMutablePointer<Int>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let str = jsVal.toString() ?? ""
    let latin1 = Array(str.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })

    if let buf = buf, bufsize > 0 {
        let copyLen = min(latin1.count, bufsize - 1)
        buf.withMemoryRebound(to: UInt8.self, capacity: copyLen) { dst in
            for i in 0..<copyLen {
                dst[i] = latin1[i]
            }
        }
        buf[copyLen] = 0
        result?.pointee = copyLen
    } else {
        result?.pointee = latin1.count
    }
    return e.clearLastError()
}

// MARK: - Coercion

@_cdecl("napi_coerce_to_bool")
public func _napi_coerce_to_bool(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = e.wrap(JSValue(bool: jsVal.toBool(), in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_coerce_to_number")
public func _napi_coerce_to_number(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    result.pointee = e.wrap(JSValue(double: jsVal.toDouble(), in: e.context))
    return e.clearLastError()
}

@_cdecl("napi_coerce_to_object")
public func _napi_coerce_to_object(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let obj = e.context.evaluateScript("(function(v) { return Object(v); })")!.call(withArguments: [jsVal])!
    result.pointee = e.wrap(obj)
    return e.clearLastError()
}

@_cdecl("napi_coerce_to_string")
public func _napi_coerce_to_string(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let str = e.context.evaluateScript("(function(v) { return String(v); })")!.call(withArguments: [jsVal])!
    result.pointee = e.wrap(str)
    return e.clearLastError()
}

// MARK: - Script Execution

@_cdecl("napi_run_script")
public func _napi_run_script(_ env: napi_env!, _ script: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(script) else { return e.setLastError(napi_invalid_arg) }
    let code = jsVal.toString() ?? ""
    if let res = e.context.evaluateScript(code) {
        if let exception = e.context.exception {
            e.context.exception = nil
            e.pendingException = exception
            return e.setLastError(napi_pending_exception)
        }
        result.pointee = e.wrap(res)
    } else {
        result.pointee = e.wrap(JSValue(undefinedIn: e.context))
    }
    return e.clearLastError()
}

// MARK: - Symbol

@_cdecl("napi_create_symbol")
public func _napi_create_symbol(_ env: napi_env!, _ description: napi_value?, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let desc: JSValue?
    if let description = description {
        desc = e.unwrap(description)
    } else {
        desc = nil
    }
    let symbolFn = e.context.evaluateScript("Symbol")!
    let sym: JSValue
    if let desc = desc, !desc.isUndefined {
        sym = symbolFn.call(withArguments: [desc])!
    } else {
        sym = symbolFn.call(withArguments: [])!
    }
    result.pointee = e.wrap(sym)
    return e.clearLastError()
}

// MARK: - Misc

@_cdecl("napi_fatal_error")
public func _napi_fatal_error(_ location: UnsafePointer<CChar>?, _ locationLen: Int,
                        _ message: UnsafePointer<CChar>?, _ messageLen: Int) {
    let loc: String
    if let location = location {
        loc = locationLen == -1 ? String(cString: location) : String(decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(location)), count: locationLen), as: UTF8.self)
    } else {
        loc = "<unknown>"
    }
    let msg: String
    if let message = message {
        msg = messageLen == -1 ? String(cString: message) : String(decoding: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(message)), count: messageLen), as: UTF8.self)
    } else {
        msg = "<unknown>"
    }
    fatalError("N-API fatal error at \(loc): \(msg)")
}

@_cdecl("napi_adjust_external_memory")
public func _napi_adjust_external_memory(_ env: napi_env!, _ changeInBytes: Int64, _ result: UnsafeMutablePointer<Int64>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = 0
    return e.clearLastError()
}
