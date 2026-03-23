import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

// MARK: - SharedMemoryStore

/// Manages shared memory blocks across workers with reference counting.
final class SharedMemoryStore: Sendable {
    static let shared = SharedMemoryStore()

    private struct Block: Sendable {
        let rawAddress: UInt
        let byteLength: Int
        var refCount: Int

        var pointer: UnsafeMutableRawPointer {
            UnsafeMutableRawPointer(bitPattern: rawAddress)!
        }

        init(pointer: UnsafeMutableRawPointer, byteLength: Int, refCount: Int) {
            self.rawAddress = UInt(bitPattern: pointer)
            self.byteLength = byteLength
            self.refCount = refCount
        }
    }

    private struct State {
        var blocks: [UInt64: Block] = [:]
        var nextId: UInt64 = 1
    }

    private let state = Mutex<State>(State())

    func allocate(byteLength: Int) -> UInt64 {
        let size = max(0, byteLength)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 8)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let addr = UInt(bitPattern: ptr)
        return state.withLock { s in
            let id = s.nextId
            s.nextId += 1
            s.blocks[id] = Block(pointer: UnsafeMutableRawPointer(bitPattern: addr)!, byteLength: size, refCount: 1)
            return id
        }
    }

    func retain(_ id: UInt64) {
        state.withLock { $0.blocks[id]?.refCount += 1 }
    }

    func release(_ id: UInt64) {
        state.withLock { s in
            guard var block = s.blocks[id] else { return }
            block.refCount -= 1
            if block.refCount <= 0 {
                block.pointer.deallocate()
                s.blocks.removeValue(forKey: id)
            } else {
                s.blocks[id] = block
            }
        }
    }

    func get(_ id: UInt64) -> (pointer: UnsafeMutableRawPointer, byteLength: Int)? {
        state.withLock { s in
            guard let block = s.blocks[id] else { return nil }
            return (block.pointer, block.byteLength)
        }
    }
}

// MARK: - SharedWaitStore

/// Manages Atomics.wait/notify waiters keyed by memory address + byte offset.
final class SharedWaitStore: Sendable {
    static let shared = SharedWaitStore()

    private struct WaitKey: Hashable {
        let address: UInt  // base pointer address
        let byteOffset: Int
    }

    private let waiters = Mutex<[WaitKey: [DispatchSemaphore]]>([:])

    func addWaiter(address: UnsafeMutableRawPointer, byteOffset: Int) -> DispatchSemaphore {
        let key = WaitKey(address: UInt(bitPattern: address), byteOffset: byteOffset)
        let sem = DispatchSemaphore(value: 0)
        waiters.withLock { w in
            w[key, default: []].append(sem)
        }
        return sem
    }

    func removeWaiter(address: UnsafeMutableRawPointer, byteOffset: Int, semaphore: DispatchSemaphore) {
        let key = WaitKey(address: UInt(bitPattern: address), byteOffset: byteOffset)
        waiters.withLock { w in
            w[key]?.removeAll { $0 === semaphore }
            if w[key]?.isEmpty == true { w.removeValue(forKey: key) }
        }
    }

    func notify(address: UnsafeMutableRawPointer, byteOffset: Int, count: Int) -> Int {
        let key = WaitKey(address: UInt(bitPattern: address), byteOffset: byteOffset)
        return waiters.withLock { w in
            guard var list = w[key], !list.isEmpty else { return 0 }
            let wakeCount = min(count, list.count)
            for i in 0..<wakeCount {
                list[i].signal()
            }
            list.removeFirst(wakeCount)
            if list.isEmpty {
                w.removeValue(forKey: key)
            } else {
                w[key] = list
            }
            return wakeCount
        }
    }
}

// MARK: - SharedArrayBufferModule

public struct SharedArrayBufferModule: NodeModule {
    public static let moduleName = "shared_array_buffer"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        installNativeFunctions(in: context)
        installJSConstructor(in: context)
        installAtomicsOverrides(in: context)
        return JSValue(undefinedIn: context)
    }

    // MARK: - Native functions

    private static func installNativeFunctions(in context: JSContext) {
        // _sabAllocate(byteLength) -> { id, arrayBuffer }
        let allocate: @convention(block) (Int) -> JSValue = { byteLength in
            let ctx = JSContext.current()!
            let id = SharedMemoryStore.shared.allocate(byteLength: byteLength)
            guard let (ptr, len) = SharedMemoryStore.shared.get(id) else {
                return JSValue(undefinedIn: ctx)
            }
            guard let ab = createExternalArrayBuffer(in: ctx, pointer: ptr, length: len) else {
                SharedMemoryStore.shared.release(id)
                return JSValue(undefinedIn: ctx)
            }
            let result = JSValue(newObjectIn: ctx)!
            result.setValue(NSNumber(value: id), forProperty: "id")
            result.setValue(ab, forProperty: "arrayBuffer")
            return result
        }
        context.setObject(
            unsafeBitCast(allocate, to: AnyObject.self),
            forKeyedSubscript: "_sabAllocate" as NSString
        )

        // _sabFromId(id) -> { id, arrayBuffer }  (retains the block)
        let fromId: @convention(block) (JSValue) -> JSValue = { idVal in
            let ctx = JSContext.current()!
            let id = UInt64(idVal.toDouble())
            SharedMemoryStore.shared.retain(id)
            guard let (ptr, len) = SharedMemoryStore.shared.get(id) else {
                return JSValue(undefinedIn: ctx)
            }
            guard let ab = createExternalArrayBuffer(in: ctx, pointer: ptr, length: len) else {
                return JSValue(undefinedIn: ctx)
            }
            let result = JSValue(newObjectIn: ctx)!
            result.setValue(NSNumber(value: id), forProperty: "id")
            result.setValue(ab, forProperty: "arrayBuffer")
            return result
        }
        context.setObject(
            unsafeBitCast(fromId, to: AnyObject.self),
            forKeyedSubscript: "_sabFromId" as NSString
        )

        // _sabRelease(id)
        let release: @convention(block) (JSValue) -> Void = { idVal in
            let id = UInt64(idVal.toDouble())
            SharedMemoryStore.shared.release(id)
        }
        context.setObject(
            unsafeBitCast(release, to: AnyObject.self),
            forKeyedSubscript: "_sabRelease" as NSString
        )

        // _sabSlice(id, begin, end) -> { id, arrayBuffer }
        let slice: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { idVal, beginVal, endVal in
            let ctx = JSContext.current()!
            let srcId = UInt64(idVal.toDouble())
            guard let (srcPtr, srcLen) = SharedMemoryStore.shared.get(srcId) else {
                return JSValue(undefinedIn: ctx)
            }

            var begin = beginVal.isUndefined ? 0 : Int(beginVal.toInt32())
            var end = endVal.isUndefined ? srcLen : Int(endVal.toInt32())

            if begin < 0 { begin = max(srcLen + begin, 0) }
            if end < 0 { end = max(srcLen + end, 0) }
            begin = min(begin, srcLen)
            end = min(end, srcLen)

            let sliceLen = max(0, end - begin)
            let newId = SharedMemoryStore.shared.allocate(byteLength: sliceLen)
            guard let (dstPtr, _) = SharedMemoryStore.shared.get(newId) else {
                return JSValue(undefinedIn: ctx)
            }

            if sliceLen > 0 {
                dstPtr.copyMemory(from: srcPtr.advanced(by: begin), byteCount: sliceLen)
            }

            guard let ab = createExternalArrayBuffer(in: ctx, pointer: dstPtr, length: sliceLen) else {
                SharedMemoryStore.shared.release(newId)
                return JSValue(undefinedIn: ctx)
            }

            let result = JSValue(newObjectIn: ctx)!
            result.setValue(NSNumber(value: newId), forProperty: "id")
            result.setValue(ab, forProperty: "arrayBuffer")
            return result
        }
        context.setObject(
            unsafeBitCast(slice, to: AnyObject.self),
            forKeyedSubscript: "_sabSlice" as NSString
        )

        // _atomicsWait(sabId, typedArrayByteOffset, index, expectedValue, timeout)
        // Returns "ok", "not-equal", or "timed-out"
        let atomicsWait: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> String = {
            sabIdVal, taByteOffsetVal, indexVal, expectedVal, timeoutVal in

            let sabId = UInt64(sabIdVal.toDouble())
            let taByteOffset = Int(taByteOffsetVal.toInt32())
            let index = Int(indexVal.toInt32())
            let expected = expectedVal.toInt32()
            let timeout = timeoutVal.isUndefined ? Double.infinity : timeoutVal.toDouble()

            guard let (ptr, _) = SharedMemoryStore.shared.get(sabId) else {
                return "not-equal"
            }

            let byteOffset = taByteOffset + index * MemoryLayout<Int32>.stride
            let valuePtr = ptr.advanced(by: byteOffset).assumingMemoryBound(to: Int32.self)

            // Atomically check the current value
            let current = valuePtr.pointee
            if current != expected {
                return "not-equal"
            }

            let sem = SharedWaitStore.shared.addWaiter(address: ptr, byteOffset: byteOffset)

            // Re-check after adding waiter to avoid race
            if valuePtr.pointee != expected {
                SharedWaitStore.shared.removeWaiter(address: ptr, byteOffset: byteOffset, semaphore: sem)
                return "not-equal"
            }

            let result: DispatchTimeoutResult
            if timeout.isInfinite || timeout < 0 {
                sem.wait()
                result = .success
            } else {
                let deadline = DispatchTime.now() + .milliseconds(Int(timeout))
                result = sem.wait(timeout: deadline)
            }

            SharedWaitStore.shared.removeWaiter(address: ptr, byteOffset: byteOffset, semaphore: sem)

            return result == .success ? "ok" : "timed-out"
        }
        context.setObject(
            unsafeBitCast(atomicsWait, to: AnyObject.self),
            forKeyedSubscript: "_atomicsWait" as NSString
        )

        // _atomicsNotify(sabId, typedArrayByteOffset, index, count) -> wokenCount
        let atomicsNotify: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Int = {
            sabIdVal, taByteOffsetVal, indexVal, countVal in

            let sabId = UInt64(sabIdVal.toDouble())
            let index = Int(indexVal.toInt32())
            let taByteOffset = Int(taByteOffsetVal.toInt32())
            let count = countVal.isUndefined ? Int.max : Int(countVal.toInt32())

            guard let (ptr, _) = SharedMemoryStore.shared.get(sabId) else {
                return 0
            }

            let byteOffset = taByteOffset + index * MemoryLayout<Int32>.stride
            return SharedWaitStore.shared.notify(address: ptr, byteOffset: byteOffset, count: count)
        }
        context.setObject(
            unsafeBitCast(atomicsNotify, to: AnyObject.self),
            forKeyedSubscript: "_atomicsNotify" as NSString
        )
    }

    // MARK: - JS Constructor & TypedArray intercepts

    private static func installJSConstructor(in context: JSContext) {
        context.evaluateScript("""
        (function(global) {
            var _sabAllocate = global._sabAllocate;
            var _sabFromId = global._sabFromId;
            var _sabRelease = global._sabRelease;
            var _sabSlice = global._sabSlice;

            var _fr = new FinalizationRegistry(function(id) {
                _sabRelease(id);
            });

            function SharedArrayBuffer(byteLength) {
                if (!(this instanceof SharedArrayBuffer)) {
                    throw new TypeError('Constructor SharedArrayBuffer requires "new"');
                }
                if (typeof byteLength !== 'number' || byteLength < 0) {
                    byteLength = 0;
                }
                byteLength = Math.floor(byteLength);
                var result = _sabAllocate(byteLength);
                this._sabId = result.id;
                this._arrayBuffer = result.arrayBuffer;
                _fr.register(this, result.id);
            }

            Object.defineProperty(SharedArrayBuffer.prototype, 'byteLength', {
                get: function() {
                    return this._arrayBuffer.byteLength;
                },
                configurable: false,
                enumerable: false
            });

            SharedArrayBuffer.prototype.slice = function(begin, end) {
                var result = _sabSlice(this._sabId, begin, end);
                var sab = Object.create(SharedArrayBuffer.prototype);
                sab._sabId = result.id;
                sab._arrayBuffer = result.arrayBuffer;
                _fr.register(sab, result.id);
                return sab;
            };

            SharedArrayBuffer.prototype[Symbol.toStringTag] = 'SharedArrayBuffer';

            // Helper to create SAB from existing id (used by IPC deserialization)
            SharedArrayBuffer._fromId = function(id) {
                var result = _sabFromId(id);
                var sab = Object.create(SharedArrayBuffer.prototype);
                sab._sabId = result.id;
                sab._arrayBuffer = result.arrayBuffer;
                _fr.register(sab, result.id);
                return sab;
            };

            global.SharedArrayBuffer = SharedArrayBuffer;

            // Intercept TypedArray constructors to unwrap SharedArrayBuffer.
            // Use Proxy + Reflect.construct to preserve new.target for class extends.
            var typedArrays = [
                'Int8Array', 'Uint8Array', 'Uint8ClampedArray',
                'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array',
                'Float32Array', 'Float64Array', 'BigInt64Array', 'BigUint64Array'
            ];

            var handler = {
                construct: function(target, args, newTarget) {
                    var sabSource = null;
                    if (args[0] instanceof SharedArrayBuffer) {
                        sabSource = args[0];
                        args[0] = sabSource._arrayBuffer;
                    }
                    var result = Reflect.construct(target, args, newTarget);
                    if (sabSource) {
                        Object.defineProperty(result, '_sharedArrayBuffer', {
                            value: sabSource,
                            writable: false,
                            enumerable: false,
                            configurable: false
                        });
                    }
                    return result;
                }
            };

            typedArrays.forEach(function(name) {
                var Original = global[name];
                if (!Original) return;
                global[name] = new Proxy(Original, handler);
            });

            // Intercept DataView
            global.DataView = new Proxy(global.DataView, {
                construct: function(target, args, newTarget) {
                    if (args[0] instanceof SharedArrayBuffer) {
                        args[0] = args[0]._arrayBuffer;
                    }
                    return Reflect.construct(target, args, newTarget);
                }
            });

            // Clean up globals
            delete global._sabAllocate;
            delete global._sabFromId;
            delete global._sabRelease;
            delete global._sabSlice;
        })(this);
        """)
    }

    // MARK: - Atomics.wait / Atomics.notify overrides

    private static func installAtomicsOverrides(in context: JSContext) {
        context.evaluateScript("""
        (function(global) {
            if (typeof Atomics === 'undefined') return;

            var _atomicsWait = global._atomicsWait;
            var _atomicsNotify = global._atomicsNotify;
            var origWait = Atomics.wait;
            var origNotify = Atomics.notify;

            Atomics.wait = function(typedArray, index, value, timeout) {
                // Check if backed by SharedArrayBuffer
                var sab = typedArray._sharedArrayBuffer;
                if (sab && sab._sabId !== undefined) {
                    var expected = value | 0;
                    var byteOffset = typedArray.byteOffset || 0;
                    return _atomicsWait(sab._sabId, byteOffset, index, expected, timeout);
                }
                // Fallback to original (will likely throw, but that's correct behavior)
                return origWait.call(Atomics, typedArray, index, value, timeout);
            };

            Atomics.notify = function(typedArray, index, count) {
                var sab = typedArray._sharedArrayBuffer;
                if (sab && sab._sabId !== undefined) {
                    var byteOffset = typedArray.byteOffset || 0;
                    return _atomicsNotify(sab._sabId, byteOffset, index, count);
                }
                return origNotify.call(Atomics, typedArray, index, count);
            };

            // Clean up globals
            delete global._atomicsWait;
            delete global._atomicsNotify;
        })(this);
        """)
    }

    // MARK: - Helpers

    /// Create an ArrayBuffer backed by external memory using JSC C API.
    private static func createExternalArrayBuffer(
        in context: JSContext, pointer: UnsafeMutableRawPointer, length: Int
    ) -> JSValue? {
        let deallocator: JSTypedArrayBytesDeallocator = { _, _ in
            // Memory is managed by SharedMemoryStore, not by JSC GC
        }

        var exception: JSValueRef?
        guard let abRef = JSObjectMakeArrayBufferWithBytesNoCopy(
            context.jsGlobalContextRef,
            pointer,
            length,
            deallocator,
            nil,
            &exception
        ) else {
            return nil
        }

        return JSValue(jsValueRef: abRef, in: context)
    }
}
