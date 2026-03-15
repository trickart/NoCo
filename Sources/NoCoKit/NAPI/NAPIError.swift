import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Throw

@_cdecl("napi_throw")
public func _napi_throw(_ env: napi_env!, _ error: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(error) else { return e.setLastError(napi_invalid_arg) }
    e.pendingException = jsVal
    return e.clearLastError()
}

@_cdecl("napi_throw_error")
public func _napi_throw_error(_ env: napi_env!, _ code: UnsafePointer<CChar>?, _ msg: UnsafePointer<CChar>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let message = String(cString: msg)
    let error = e.context.evaluateScript("(function(m){return new Error(m)})")!.call(withArguments: [message])!
    if let code = code {
        error.setValue(String(cString: code), forProperty: "code")
    }
    e.pendingException = error
    return e.clearLastError()
}

@_cdecl("napi_throw_type_error")
public func _napi_throw_type_error(_ env: napi_env!, _ code: UnsafePointer<CChar>?, _ msg: UnsafePointer<CChar>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let message = String(cString: msg)
    let error = e.context.evaluateScript("(function(m){return new TypeError(m)})")!.call(withArguments: [message])!
    if let code = code {
        error.setValue(String(cString: code), forProperty: "code")
    }
    e.pendingException = error
    return e.clearLastError()
}

@_cdecl("napi_throw_range_error")
public func _napi_throw_range_error(_ env: napi_env!, _ code: UnsafePointer<CChar>?, _ msg: UnsafePointer<CChar>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let message = String(cString: msg)
    let error = e.context.evaluateScript("(function(m){return new RangeError(m)})")!.call(withArguments: [message])!
    if let code = code {
        error.setValue(String(cString: code), forProperty: "code")
    }
    e.pendingException = error
    return e.clearLastError()
}

@_cdecl("node_api_throw_syntax_error")
public func _node_api_throw_syntax_error(_ env: napi_env!, _ code: UnsafePointer<CChar>?, _ msg: UnsafePointer<CChar>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let message = String(cString: msg)
    let error = e.context.evaluateScript("(function(m){return new SyntaxError(m)})")!.call(withArguments: [message])!
    if let code = code {
        error.setValue(String(cString: code), forProperty: "code")
    }
    e.pendingException = error
    return e.clearLastError()
}

// MARK: - Error Creation

@_cdecl("napi_create_error")
public func _napi_create_error(_ env: napi_env!, _ code: napi_value?, _ msg: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let msgVal = e.unwrap(msg) else { return e.setLastError(napi_invalid_arg) }
    let error = e.context.evaluateScript("(function(m){return new Error(m)})")!.call(withArguments: [msgVal])!
    if let code = code, let codeVal = e.unwrap(code), !codeVal.isUndefined {
        error.setValue(codeVal, forProperty: "code")
    }
    result.pointee = e.wrap(error)
    return e.clearLastError()
}

@_cdecl("napi_create_type_error")
public func _napi_create_type_error(_ env: napi_env!, _ code: napi_value?, _ msg: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let msgVal = e.unwrap(msg) else { return e.setLastError(napi_invalid_arg) }
    let error = e.context.evaluateScript("(function(m){return new TypeError(m)})")!.call(withArguments: [msgVal])!
    if let code = code, let codeVal = e.unwrap(code), !codeVal.isUndefined {
        error.setValue(codeVal, forProperty: "code")
    }
    result.pointee = e.wrap(error)
    return e.clearLastError()
}

@_cdecl("napi_create_range_error")
public func _napi_create_range_error(_ env: napi_env!, _ code: napi_value?, _ msg: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let msgVal = e.unwrap(msg) else { return e.setLastError(napi_invalid_arg) }
    let error = e.context.evaluateScript("(function(m){return new RangeError(m)})")!.call(withArguments: [msgVal])!
    if let code = code, let codeVal = e.unwrap(code), !codeVal.isUndefined {
        error.setValue(codeVal, forProperty: "code")
    }
    result.pointee = e.wrap(error)
    return e.clearLastError()
}

@_cdecl("node_api_create_syntax_error")
public func _node_api_create_syntax_error(_ env: napi_env!, _ code: napi_value?, _ msg: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let msgVal = e.unwrap(msg) else { return e.setLastError(napi_invalid_arg) }
    let error = e.context.evaluateScript("(function(m){return new SyntaxError(m)})")!.call(withArguments: [msgVal])!
    if let code = code, let codeVal = e.unwrap(code), !codeVal.isUndefined {
        error.setValue(codeVal, forProperty: "code")
    }
    result.pointee = e.wrap(error)
    return e.clearLastError()
}

// MARK: - Exception Management

@_cdecl("napi_is_exception_pending")
public func _napi_is_exception_pending(_ env: napi_env!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.pendingException != nil
    return napi_ok
}

@_cdecl("napi_get_and_clear_last_exception")
public func _napi_get_and_clear_last_exception(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    if let exception = e.pendingException {
        result.pointee = e.wrap(exception)
        e.pendingException = nil
    } else {
        result.pointee = e.wrap(JSValue(undefinedIn: e.context))
    }
    return napi_ok
}

// MARK: - Error Check

@_cdecl("napi_is_error")
public func _napi_is_error(_ env: napi_env!, _ value: napi_value!, _ result: UnsafeMutablePointer<Bool>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }
    let isErr = e.context.evaluateScript("(function(v){return v instanceof Error})")!.call(withArguments: [jsVal])!
    result.pointee = isErr.toBool()
    return e.clearLastError()
}

@_cdecl("napi_fatal_exception")
public func _napi_fatal_exception(_ env: napi_env!, _ err: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(err) else { return e.setLastError(napi_invalid_arg) }
    let msg = jsVal.forProperty("message")?.toString() ?? jsVal.toString() ?? "Unknown error"
    fputs("FATAL ERROR: \(msg)\n", stderr)
    return e.clearLastError()
}
