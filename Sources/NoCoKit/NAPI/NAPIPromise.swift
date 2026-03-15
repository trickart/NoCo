import Foundation
import JavaScriptCore
import CNodeAPI

/// Storage for deferred resolve/reject functions.
final class NAPIDeferredData {
    let resolve: JSValue
    let reject: JSValue

    init(resolve: JSValue, reject: JSValue) {
        self.resolve = resolve
        self.reject = reject
    }

    func toOpaque() -> napi_deferred {
        return OpaquePointer(Unmanaged.passRetained(self).toOpaque())
    }

    static func from(_ deferred: napi_deferred!) -> NAPIDeferredData {
        return Unmanaged<NAPIDeferredData>.fromOpaque(UnsafeRawPointer(deferred!)).takeRetainedValue()
    }
}

// MARK: - Promise Creation

@_cdecl("napi_create_promise")
public func _napi_create_promise(_ env: napi_env!, _ deferred: UnsafeMutablePointer<napi_deferred?>!,
                           _ promise: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)

    // Create promise and capture resolve/reject
    let result = e.context.evaluateScript("""
        (function() {
            var _resolve, _reject;
            var p = new Promise(function(resolve, reject) {
                _resolve = resolve;
                _reject = reject;
            });
            return { promise: p, resolve: _resolve, reject: _reject };
        })()
    """)!

    let promiseVal = result.forProperty("promise")!
    let resolveVal = result.forProperty("resolve")!
    let rejectVal = result.forProperty("reject")!

    let deferredData = NAPIDeferredData(resolve: resolveVal, reject: rejectVal)
    deferred.pointee = deferredData.toOpaque()
    promise.pointee = e.wrap(promiseVal)

    return e.clearLastError()
}

@_cdecl("napi_resolve_deferred")
public func _napi_resolve_deferred(_ env: napi_env!, _ deferred: napi_deferred!, _ resolution: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let d = NAPIDeferredData.from(deferred)
    guard let val = e.unwrap(resolution) else { return e.setLastError(napi_invalid_arg) }
    d.resolve.call(withArguments: [val])
    return e.clearLastError()
}

@_cdecl("napi_reject_deferred")
public func _napi_reject_deferred(_ env: napi_env!, _ deferred: napi_deferred!, _ rejection: napi_value!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let d = NAPIDeferredData.from(deferred)
    guard let val = e.unwrap(rejection) else { return e.setLastError(napi_invalid_arg) }
    d.reject.call(withArguments: [val])
    return e.clearLastError()
}
