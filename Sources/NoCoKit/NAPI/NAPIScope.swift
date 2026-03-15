import Foundation
import JavaScriptCore
import CNodeAPI

// MARK: - Handle Scope

@_cdecl("napi_open_handle_scope")
public func _napi_open_handle_scope(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_handle_scope?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let scope = NAPIHandleScopeData(startId: e.valueStore.currentId)
    e.handleScopes.append(scope)
    // Use the scope's identity as the opaque pointer
    result.pointee = OpaquePointer(Unmanaged.passUnretained(scope).toOpaque())
    return e.clearLastError()
}

@_cdecl("napi_close_handle_scope")
public func _napi_close_handle_scope(_ env: napi_env!, _ scope: napi_handle_scope!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard !e.handleScopes.isEmpty else { return e.setLastError(napi_handle_scope_mismatch) }
    let top = e.handleScopes.removeLast()
    // Remove all values allocated in this scope
    e.valueStore.removeIds(top.valueIds)
    return e.clearLastError()
}

// MARK: - Escapable Handle Scope

@_cdecl("napi_open_escapable_handle_scope")
public func _napi_open_escapable_handle_scope(_ env: napi_env!, _ result: UnsafeMutablePointer<napi_escapable_handle_scope?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let scope = NAPIHandleScopeData(startId: e.valueStore.currentId, isEscapable: true)
    e.handleScopes.append(scope)
    result.pointee = OpaquePointer(Unmanaged.passUnretained(scope).toOpaque())
    return e.clearLastError()
}

@_cdecl("napi_close_escapable_handle_scope")
public func _napi_close_escapable_handle_scope(_ env: napi_env!, _ scope: napi_escapable_handle_scope!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    guard !e.handleScopes.isEmpty else { return e.setLastError(napi_handle_scope_mismatch) }
    let top = e.handleScopes.removeLast()
    // Remove values except the escaped one
    var idsToRemove = top.valueIds
    if let escapedId = top.escapedValueId {
        idsToRemove.removeAll { $0 == escapedId }
        // Move escaped value to parent scope
        if let parentScope = e.handleScopes.last {
            parentScope.valueIds.append(escapedId)
        }
    }
    e.valueStore.removeIds(idsToRemove)
    return e.clearLastError()
}

@_cdecl("napi_escape_handle")
public func _napi_escape_handle(_ env: napi_env!, _ scope: napi_escapable_handle_scope!,
                          _ escapee: napi_value!, _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)

    // Find the escapable scope
    let scopeData = Unmanaged<NAPIHandleScopeData>.fromOpaque(UnsafeRawPointer(scope)).takeUnretainedValue()

    guard scopeData.isEscapable else { return e.setLastError(napi_invalid_arg) }
    guard !scopeData.escaped else { return e.setLastError(napi_escape_called_twice) }

    scopeData.escaped = true
    let valueId = Int(bitPattern: escapee)
    scopeData.escapedValueId = valueId

    // Return the same handle (it will be preserved when scope closes)
    result.pointee = escapee
    return e.clearLastError()
}
