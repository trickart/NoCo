import Foundation
import JavaScriptCore
import CNodeAPI
import Synchronization

/// ThreadSafe Function data.
final class NAPIThreadSafeFunctionData {
    nonisolated(unsafe) let env: NAPIEnvironment
    nonisolated(unsafe) let callback: JSValue?
    nonisolated(unsafe) let context: UnsafeMutableRawPointer?
    let callJs: napi_threadsafe_function_call_js?
    let maxQueueSize: Int
    let state: Mutex<TSFState>

    struct TSFState: Sendable {
        var refCount: Int
        var released: Bool = false
        var isRef: Bool = true
    }

    init(env: NAPIEnvironment, callback: JSValue?, context: UnsafeMutableRawPointer?,
         callJs: napi_threadsafe_function_call_js?, maxQueueSize: Int) {
        self.env = env
        self.callback = callback
        self.context = context
        self.callJs = callJs
        self.maxQueueSize = maxQueueSize
        self.state = Mutex(TSFState(refCount: 1))
    }

    func toOpaque() -> napi_threadsafe_function {
        return OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
    }

    static func from(_ tsf: napi_threadsafe_function!) -> NAPIThreadSafeFunctionData {
        return Unmanaged<NAPIThreadSafeFunctionData>.fromOpaque(UnsafeRawPointer(tsf!)).takeUnretainedValue()
    }
}

/// Registry to prevent deallocation of threadsafe functions.
/// Thread safety: TSF creation/release happens on jsQueue; the Mutex protects cross-thread access.
nonisolated(unsafe) private var tsfRegistry: [ObjectIdentifier: NAPIThreadSafeFunctionData] = [:]

@_cdecl("napi_create_threadsafe_function")
public func _napi_create_threadsafe_function(_ env: napi_env!,
                                       _ func_: napi_value?,
                                       _ asyncResource: napi_value?,
                                       _ asyncResourceName: napi_value!,
                                       _ maxQueueSize: Int,
                                       _ initialThreadCount: Int,
                                       _ threadFinalizeData: UnsafeMutableRawPointer?,
                                       _ threadFinalizeCb: napi_finalize?,
                                       _ context: UnsafeMutableRawPointer?,
                                       _ callJsCb: napi_threadsafe_function_call_js?,
                                       _ result: UnsafeMutablePointer<napi_threadsafe_function?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let jsFn = func_.flatMap { e.unwrap($0) }

    let tsf = NAPIThreadSafeFunctionData(
        env: e, callback: jsFn, context: context,
        callJs: callJsCb, maxQueueSize: maxQueueSize
    )
    tsf.state.withLock { $0.refCount = initialThreadCount }
    tsfRegistry[ObjectIdentifier(tsf)] = tsf
    result.pointee = tsf.toOpaque()

    // TSF が存在する間はイベントループを保持（バックグラウンドスレッドからの
    // コールバックを処理するため）
    e.runtime?.eventLoop.retainHandle()

    return e.clearLastError()
}

@_cdecl("napi_get_threadsafe_function_context")
public func _napi_get_threadsafe_function_context(_ func_: napi_threadsafe_function!,
                                            _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>!) -> napi_status {
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    result.pointee = tsf.context
    return napi_ok
}

@_cdecl("napi_call_threadsafe_function")
public func _napi_call_threadsafe_function(_ func_: napi_threadsafe_function!,
                                     _ data: UnsafeMutableRawPointer?,
                                     _ isBlocking: napi_threadsafe_function_call_mode) -> napi_status {
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    let isReleased = tsf.state.withLock { $0.released }
    guard !isReleased else { return napi_closing }

    // Capture pointer values as Int for Sendable safety
    let envInt = Int(bitPattern: tsf.env.toOpaque())
    let contextInt = tsf.context.map { Int(bitPattern: $0) }
    let dataInt = data.map { Int(bitPattern: $0) }

    if let callJs = tsf.callJs {
        nonisolated(unsafe) let callJsFn = callJs
        nonisolated(unsafe) let callbackJSValue = tsf.callback
        if let runtime = tsf.env.runtime {
            runtime.eventLoop.enqueueCallback {
                let envPtr = OpaquePointer(bitPattern: envInt)
                let cbNapi: napi_value?
                if let cb = callbackJSValue {
                    let e = NAPIEnvironment.from(envPtr)
                    cbNapi = e.wrap(cb)
                } else {
                    cbNapi = nil
                }
                let ctx = contextInt.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                let d = dataInt.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                callJsFn(envPtr, cbNapi, ctx, d)
            }
        }
    } else if let callback = tsf.callback {
        nonisolated(unsafe) let cb = callback
        if let runtime = tsf.env.runtime {
            runtime.eventLoop.enqueueCallback {
                cb.call(withArguments: [])
            }
        }
    }

    return napi_ok
}

@_cdecl("napi_acquire_threadsafe_function")
public func _napi_acquire_threadsafe_function(_ func_: napi_threadsafe_function!) -> napi_status {
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    let isReleased = tsf.state.withLock { s -> Bool in
        if s.released { return true }
        s.refCount += 1
        return false
    }
    return isReleased ? napi_closing : napi_ok
}

@_cdecl("napi_release_threadsafe_function")
public func _napi_release_threadsafe_function(_ func_: napi_threadsafe_function!,
                                        _ mode: napi_threadsafe_function_release_mode) -> napi_status {
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    let (shouldRemove, wasRef) = tsf.state.withLock { s -> (Bool, Bool) in
        if mode == napi_tsfn_abort {
            let wasRef = s.isRef
            s.released = true
            s.isRef = false
            return (true, wasRef)
        }
        s.refCount -= 1
        if s.refCount <= 0 {
            let wasRef = s.isRef
            s.released = true
            s.isRef = false
            return (true, wasRef)
        }
        return (false, false)
    }
    if shouldRemove {
        tsfRegistry.removeValue(forKey: ObjectIdentifier(tsf))
        // TSF が ref 状態だった場合のみイベントループハンドルを解放
        if wasRef {
            tsf.env.runtime?.eventLoop.releaseHandle()
        }
    }
    return napi_ok
}

@_cdecl("napi_ref_threadsafe_function")
public func _napi_ref_threadsafe_function(_ env: napi_env!, _ func_: napi_threadsafe_function!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    let shouldRetain = tsf.state.withLock { s -> Bool in
        guard !s.released, !s.isRef else { return false }
        s.isRef = true
        return true
    }
    if shouldRetain {
        e.runtime?.eventLoop.retainHandle()
    }
    return e.clearLastError()
}

@_cdecl("napi_unref_threadsafe_function")
public func _napi_unref_threadsafe_function(_ env: napi_env!, _ func_: napi_threadsafe_function!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let tsf = NAPIThreadSafeFunctionData.from(func_)
    let shouldRelease = tsf.state.withLock { s -> Bool in
        guard !s.released, s.isRef else { return false }
        s.isRef = false
        return true
    }
    if shouldRelease {
        e.runtime?.eventLoop.releaseHandle()
    }
    return e.clearLastError()
}
