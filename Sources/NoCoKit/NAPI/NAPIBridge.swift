import Foundation
import JavaScriptCore
import CNodeAPI
import Synchronization

/// N-API environment — the backing store for `napi_env`.
/// Each .node module gets its own environment.
final class NAPIEnvironment {
    let context: JSContext
    weak var runtime: NodeRuntime?
    var valueStore: NAPIValueStore
    var handleScopes: [NAPIHandleScopeData] = []
    let lastErrorPtr: UnsafeMutablePointer<napi_extended_error_info>
    private var lastErrorMessage: UnsafeMutablePointer<CChar>?
    var pendingException: JSValue?

    // napi_wrap: JSValue identity → native pointer
    var wrapMap: [ObjectIdentifier: (pointer: UnsafeMutableRawPointer, Release)] = [:]
    typealias Release = (@convention(c) (napi_env?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?

    // napi_create_external: ID → (data, Release)
    var externalDataMap: [Int: (data: UnsafeMutableRawPointer?, Release)] = [:]
    var nextExternalId: Int = 1

    // napi_ref
    var references: [Int: NAPIReferenceData] = [:]
    var nextRefId: Int = 1

    // Weak ref to self (for passing env pointer)
    private var _envPointer: napi_env?

    // Cleanup hooks
    var cleanupHooks: [(UnsafeMutableRawPointer?) -> Void] = []

    // Callback info stack (for nested calls)
    var callbackInfoStack: [NAPICallbackInfoData] = []

    init(context: JSContext, runtime: NodeRuntime) {
        self.context = context
        self.runtime = runtime
        self.valueStore = NAPIValueStore()
        self.lastErrorPtr = .allocate(capacity: 1)
        self.lastErrorPtr.initialize(to: napi_extended_error_info(
            error_message: nil,
            engine_reserved: nil,
            engine_error_code: 0,
            error_code: napi_ok
        ))
        // Open initial handle scope
        handleScopes.append(NAPIHandleScopeData(startId: valueStore.currentId))
    }

    deinit {
        if let msg = lastErrorMessage {
            free(msg)
        }
        lastErrorPtr.deallocate()
    }

    func toOpaque() -> napi_env {
        if _envPointer == nil {
            _envPointer = OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
        }
        return _envPointer!
    }

    static func from(_ env: napi_env!) -> NAPIEnvironment {
        return Unmanaged<NAPIEnvironment>.fromOpaque(UnsafeRawPointer(env!)).takeUnretainedValue()
    }

    func setLastError(_ status: napi_status, message: String? = nil) -> napi_status {
        if let msg = lastErrorMessage {
            free(msg)
            lastErrorMessage = nil
        }
        if let message = message {
            lastErrorMessage = strdup(message)
        }
        lastErrorPtr.pointee.error_code = status
        lastErrorPtr.pointee.error_message = lastErrorMessage.map { UnsafePointer($0) }
        return status
    }

    func clearLastError() -> napi_status {
        return setLastError(napi_ok)
    }

    /// Store a JSValue in the current handle scope and return its napi_value.
    func wrap(_ value: JSValue) -> napi_value? {
        let id = valueStore.store(value)
        handleScopes.last?.valueIds.append(id)
        return OpaquePointer(bitPattern: id)
    }

    /// Retrieve a JSValue from a napi_value.
    func unwrap(_ value: napi_value?) -> JSValue? {
        guard let value = value else { return nil }
        let id = Int(bitPattern: value)
        return valueStore.get(id)
    }
}

/// Maps integer IDs to JSValues. IDs are encoded as OpaquePointer for napi_value.
final class NAPIValueStore {
    private var values: [Int: JSValue] = [:]
    private var _nextId: Int = 1

    var currentId: Int { _nextId }

    func store(_ value: JSValue) -> Int {
        let id = _nextId
        _nextId += 1
        values[id] = value
        return id
    }

    func get(_ id: Int) -> JSValue? {
        return values[id]
    }

    func remove(_ id: Int) {
        values.removeValue(forKey: id)
    }

    func removeIds(_ ids: [Int]) {
        for id in ids {
            values.removeValue(forKey: id)
        }
    }
}

/// Data for handle scope tracking.
final class NAPIHandleScopeData {
    let startId: Int
    var valueIds: [Int] = []
    var isEscapable: Bool = false
    var escaped: Bool = false
    var escapedValueId: Int?

    init(startId: Int, isEscapable: Bool = false) {
        self.startId = startId
        self.isEscapable = isEscapable
    }
}

/// Data for napi_ref.
final class NAPIReferenceData {
    var value: JSValue?
    var refCount: UInt32

    init(value: JSValue?, refCount: UInt32) {
        self.value = value
        self.refCount = refCount
    }
}

/// Data for napi_callback_info.
final class NAPICallbackInfoData {
    let thisValue: JSValue
    let args: [JSValue]
    let data: UnsafeMutableRawPointer?

    init(thisValue: JSValue, args: [JSValue], data: UnsafeMutableRawPointer?) {
        self.thisValue = thisValue
        self.args = args
        self.data = data
    }

    func toOpaque() -> napi_callback_info {
        return OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
    }

    static func from(_ info: napi_callback_info!) -> NAPICallbackInfoData {
        return Unmanaged<NAPICallbackInfoData>.fromOpaque(UnsafeRawPointer(info!)).takeUnretainedValue()
    }
}

/// Global registry for NAPIEnvironment instances (prevents deallocation).
/// Access is only from jsQueue (single-threaded JS execution model).
enum NAPIEnvironmentRegistry {
    nonisolated(unsafe) private static var environments: [ObjectIdentifier: NAPIEnvironment] = [:]

    static func register(_ env: NAPIEnvironment) {
        environments[ObjectIdentifier(env)] = env
    }

    static func unregister(_ env: NAPIEnvironment) {
        environments.removeValue(forKey: ObjectIdentifier(env))
    }
}
