import Foundation
import JavaScriptCore
import CNodeAPI
import Synchronization

/// Async work data.
final class NAPIAsyncWorkData {
    nonisolated(unsafe) let env: NAPIEnvironment
    nonisolated(unsafe) let execute: napi_async_execute_callback
    nonisolated(unsafe) let complete: napi_async_complete_callback
    nonisolated(unsafe) let data: UnsafeMutableRawPointer?
    let cancelled: Mutex<Bool>

    init(env: NAPIEnvironment, execute: napi_async_execute_callback,
         complete: napi_async_complete_callback, data: UnsafeMutableRawPointer?) {
        self.env = env
        self.execute = execute
        self.complete = complete
        self.data = data
        self.cancelled = Mutex(false)
    }

    func toOpaque() -> napi_async_work {
        return OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
    }

    static func from(_ work: napi_async_work!) -> NAPIAsyncWorkData {
        return Unmanaged<NAPIAsyncWorkData>.fromOpaque(UnsafeRawPointer(work!)).takeUnretainedValue()
    }
}

/// Registry to prevent deallocation.
/// Access from both JS thread and background threads.
nonisolated(unsafe) private var asyncWorkRegistry: [ObjectIdentifier: NAPIAsyncWorkData] = [:]

@_cdecl("napi_create_async_work")
public func _napi_create_async_work(_ env: napi_env!,
                              _ asyncResource: napi_value?,
                              _ asyncResourceName: napi_value!,
                              _ execute: napi_async_execute_callback!,
                              _ complete: napi_async_complete_callback!,
                              _ data: UnsafeMutableRawPointer?,
                              _ result: UnsafeMutablePointer<napi_async_work?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let work = NAPIAsyncWorkData(env: e, execute: execute, complete: complete, data: data)
    asyncWorkRegistry[ObjectIdentifier(work)] = work
    result.pointee = work.toOpaque()
    return e.clearLastError()
}

@_cdecl("napi_queue_async_work")
public func _napi_queue_async_work(_ env: napi_env!, _ work: napi_async_work!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let workData = NAPIAsyncWorkData.from(work)

    // Capture values as Int for Sendable safety
    let envInt = Int(bitPattern: env!)
    let executeFn = workData.execute
    let completeFn = workData.complete
    let dataPtr = workData.data

    nonisolated(unsafe) let execFn = executeFn
    nonisolated(unsafe) let compFn = completeFn
    nonisolated(unsafe) let dPtr = dataPtr
    nonisolated(unsafe) let wd = workData

    DispatchQueue.global(qos: .userInitiated).async {
        let envPtr = OpaquePointer(bitPattern: envInt)
        execFn(envPtr, dPtr)

        if let runtime = wd.env.runtime {
            let isCancelled = wd.cancelled.withLock { $0 }
            runtime.eventLoop.enqueueCallback {
                let status: napi_status = isCancelled ? napi_cancelled : napi_ok
                compFn(envPtr, status, dPtr)
            }
        }
    }

    return e.clearLastError()
}

@_cdecl("napi_cancel_async_work")
public func _napi_cancel_async_work(_ env: napi_env!, _ work: napi_async_work!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let workData = NAPIAsyncWorkData.from(work)
    workData.cancelled.withLock { $0 = true }
    return e.clearLastError()
}

@_cdecl("napi_delete_async_work")
public func _napi_delete_async_work(_ env: napi_env!, _ work: napi_async_work!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    let workData = NAPIAsyncWorkData.from(work)
    asyncWorkRegistry.removeValue(forKey: ObjectIdentifier(workData))
    return e.clearLastError()
}

// MARK: - Async Init (no-op stubs)

@_cdecl("napi_async_init")
public func _napi_async_init(_ env: napi_env!, _ asyncResource: napi_value?, _ asyncResourceName: napi_value!,
                       _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(newObjectIn: e.context))
    return e.clearLastError()
}

@_cdecl("napi_async_destroy")
public func _napi_async_destroy(_ env: napi_env!, _ asyncContext: napi_value!) -> napi_status {
    return NAPIEnvironment.from(env).clearLastError()
}

@_cdecl("napi_open_callback_scope")
public func _napi_open_callback_scope(_ env: napi_env!, _ resourceObject: napi_value!, _ context: napi_value!,
                                _ result: UnsafeMutablePointer<napi_value?>!) -> napi_status {
    let e = NAPIEnvironment.from(env)
    result.pointee = e.wrap(JSValue(newObjectIn: e.context))
    return e.clearLastError()
}

@_cdecl("napi_close_callback_scope")
public func _napi_close_callback_scope(_ env: napi_env!, _ scope: napi_value!) -> napi_status {
    return NAPIEnvironment.from(env).clearLastError()
}
