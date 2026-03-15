import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - References

@_cdecl("napi_create_reference")
public func _napi_create_reference(_ env: napi_env!, _ value: napi_value!, _ initialRefcount: UInt32,
                             _ result: UnsafeMutablePointer<napi_ref?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard let jsVal = e.unwrap(value) else { return e.setLastError(napi_invalid_arg) }

    let refId = e.nextRefId
    e.nextRefId += 1
    e.references[refId] = NAPIReferenceData(value: jsVal, refCount: initialRefcount)

    result.pointee = OpaquePointer(bitPattern: refId)
    return e.clearLastError()
}

@_cdecl("napi_delete_reference")
public func _napi_delete_reference(_ env: napi_env!, _ ref: napi_ref!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let refId = Int(bitPattern: ref)
    e.references.removeValue(forKey: refId)
    return e.clearLastError()
}

@_cdecl("napi_reference_ref")
public func _napi_reference_ref(_ env: napi_env!, _ ref: napi_ref!, _ result: UnsafeMutablePointer<UInt32>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let refId = Int(bitPattern: ref)
    guard let refData = e.references[refId] else { return e.setLastError(napi_invalid_arg) }
    refData.refCount += 1
    result?.pointee = refData.refCount
    return e.clearLastError()
}

@_cdecl("napi_reference_unref")
public func _napi_reference_unref(_ env: napi_env!, _ ref: napi_ref!, _ result: UnsafeMutablePointer<UInt32>?) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let refId = Int(bitPattern: ref)
    guard let refData = e.references[refId] else { return e.setLastError(napi_invalid_arg) }
    if refData.refCount > 0 { refData.refCount -= 1 }
    result?.pointee = refData.refCount
    return e.clearLastError()
}

@_cdecl("napi_get_reference_value")
public func _napi_get_reference_value(_ env: napi_env!, _ ref: napi_ref!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let refId = Int(bitPattern: ref)
    guard let refData = e.references[refId] else {
        result.pointee = nil
        return e.clearLastError()
    }
    if let value = refData.value {
        result.pointee = e.wrap(value)
    } else {
        result.pointee = nil
    }
    return e.clearLastError()
}
