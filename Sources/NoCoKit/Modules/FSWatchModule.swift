import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

// MARK: - Watch State

/// Shared mutable state for fs.watchFile / fs.watch, guarded by Mutex.
/// Sendable safety is guaranteed by Mutex — all mutable state is accessed only through withLock.
private final class FSWatchState: Sendable {
    struct WatchFileEntry {
        var listeners: [JSManagedValue]
        var timer: DispatchSourceTimer
        var prevMtimeMs: Double
        var prevSize: Int
    }
    struct WatchEntry {
        var id: Int
        var source: DispatchSourceProtocol
        var fd: Int32
        var watcher: JSManagedValue
        var closed: Bool = false
    }

    private struct State: ~Copyable {
        var watchFiles: [String: WatchFileEntry] = [:]
        var watches: [Int: WatchEntry] = [:]
        var nextWatchId = 1
    }

    private let state = Mutex(State())

    func withWatchFiles<T>(_ body: (inout [String: WatchFileEntry]) -> T) -> T {
        state.withLock { body(&$0.watchFiles) }
    }
    func withWatches<T>(_ body: (inout [Int: WatchEntry]) -> T) -> T {
        state.withLock { body(&$0.watches) }
    }
    func nextId() -> Int {
        state.withLock { state in
            let id = state.nextWatchId
            state.nextWatchId += 1
            return id
        }
    }
}

// MARK: - FSModule Watch Extension

extension FSModule {
    static func installWatchAPIs(fs: JSValue, context: JSContext, runtime: NodeRuntime) {
        let state = FSWatchState()

        // ------------------------------------------------------------------
        // fs.watchFile(filename, [options], listener)
        // ------------------------------------------------------------------
        let watchFile: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else {
                context.exception = JSValue(newErrorFromMessage: "watchFile requires at least 2 arguments", in: context)
                return JSValue(undefinedIn: context)
            }

            let filename = args[0].toString()!
            let resolved = (filename as NSString).standardizingPath

            let listener: JSValue
            var intervalMs: Double = 5007

            if args.count >= 3 && !args[2].isUndefined && !args[2].isNull {
                // (filename, options, listener)
                listener = args[2]
                if args[1].isObject {
                    if let iv = args[1].forProperty("interval"), !iv.isUndefined {
                        intervalMs = iv.toDouble()
                    }
                }
            } else {
                // (filename, listener)
                listener = args[1]
            }

            let managedListener = JSManagedValue(value: listener)!
            context.virtualMachine.addManagedReference(managedListener, withOwner: fs)

            // Create StatWatcher object (EventEmitter-like)
            let watcher = context.evaluateScript("""
                (function(EventEmitter) {
                    var w = new EventEmitter();
                    w.ref = function() { return w; };
                    w.unref = function() { return w; };
                    return w;
                })
            """)!.call(withArguments: [context.objectForKeyedSubscript("__NoCo_EventEmitter")!])!

            // Get initial stat
            let initStat = createStatObject(path: resolved, context: context, fs: fs)
            let initMtime = initStat?.forProperty("mtimeMs")?.toDouble() ?? 0
            let initSize = initStat != nil ? Int(initStat!.forProperty("size")!.toInt32()) : 0

            // Create polling timer
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timer.schedule(deadline: .now() + .milliseconds(Int(intervalMs)),
                          repeating: .milliseconds(Int(intervalMs)))

            timer.setEventHandler { [weak runtime] in
                guard let runtime = runtime else { return }
                let fm = FileManager.default
                let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]
                let mtime = attrs[.modificationDate] as? Date ?? Date()
                let size = attrs[.size] as? Int ?? 0
                let currentMtimeMs = floor(mtime.timeIntervalSince1970 * 1000)

                let (prevMtime, prevSize) = state.withWatchFiles { files -> (Double, Int) in
                    guard let entry = files[resolved] else { return (0, 0) }
                    return (entry.prevMtimeMs, entry.prevSize)
                }

                if currentMtimeMs != prevMtime || size != prevSize {
                    // Update stored values
                    state.withWatchFiles { files in
                        files[resolved]?.prevMtimeMs = currentMtimeMs
                        files[resolved]?.prevSize = size
                    }

                    runtime.eventLoop.enqueueCallback {
                        let currentStat = createStatObject(path: resolved, context: context, fs: fs)
                            ?? JSValue(newObjectIn: context)!
                        // Build previous stat with stored values
                        let prevStat = JSValue(newObjectIn: context)!
                        prevStat.setValue(prevMtime, forProperty: "mtimeMs")
                        prevStat.setValue(prevSize, forProperty: "size")

                        // Call all listeners for this path
                        let listeners = state.withWatchFiles { files -> [JSManagedValue] in
                            files[resolved]?.listeners ?? []
                        }
                        for ml in listeners {
                            ml.value?.call(withArguments: [currentStat, prevStat])
                        }
                    }
                }
            }

            // Store entry
            state.withWatchFiles { files in
                if var existing = files[resolved] {
                    // Add listener to existing watcher
                    existing.listeners.append(managedListener)
                    files[resolved] = existing
                } else {
                    files[resolved] = FSWatchState.WatchFileEntry(
                        listeners: [managedListener],
                        timer: timer,
                        prevMtimeMs: initMtime,
                        prevSize: initSize
                    )
                    runtime.eventLoop.retainHandle()
                    timer.resume()
                }
            }

            return watcher
        }
        fs.setValue(unsafeBitCast(watchFile, to: AnyObject.self), forProperty: "watchFile")

        // ------------------------------------------------------------------
        // fs.unwatchFile(filename, [listener])
        // ------------------------------------------------------------------
        let unwatchFile: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard let filename = args.first?.toString() else { return }
            let resolved = (filename as NSString).standardizingPath
            let specificListener: JSValue? = args.count >= 2 && !args[1].isUndefined ? args[1] : nil

            state.withWatchFiles { files in
                guard var entry = files[resolved] else { return }

                if let specific = specificListener {
                    // Remove only the matching listener
                    entry.listeners.removeAll { managed in
                        guard let val = managed.value else { return true }
                        return val.isEqual(to: specific)
                    }
                    if entry.listeners.isEmpty {
                        entry.timer.cancel()
                        files.removeValue(forKey: resolved)
                        runtime.eventLoop.releaseHandle()
                    } else {
                        files[resolved] = entry
                    }
                } else {
                    // Remove all listeners
                    entry.timer.cancel()
                    files.removeValue(forKey: resolved)
                    runtime.eventLoop.releaseHandle()
                }
            }
        }
        fs.setValue(unsafeBitCast(unwatchFile, to: AnyObject.self), forProperty: "unwatchFile")

        // ------------------------------------------------------------------
        // fs.watch(filename, [options], [listener])
        // ------------------------------------------------------------------
        let watch: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 1 else {
                context.exception = JSValue(newErrorFromMessage: "watch requires at least 1 argument", in: context)
                return JSValue(undefinedIn: context)
            }

            let filename = args[0].toString()!
            let resolved = (filename as NSString).standardizingPath
            let basename = (resolved as NSString).lastPathComponent

            var listener: JSValue? = nil

            if args.count >= 3 && !args[2].isUndefined && !args[2].isNull {
                listener = args[2]
            } else if args.count >= 2 {
                if args[1].isObject && !args[1].hasProperty("call") {
                    // options object, no listener
                } else if !args[1].isUndefined && !args[1].isNull {
                    listener = args[1]
                }
            }

            let watchId = state.nextId()

            // Create FSWatcher (EventEmitter)
            let watcher = context.evaluateScript("""
                (function(EventEmitter, watchId) {
                    var w = new EventEmitter();
                    w._watchId = watchId;
                    w._closed = false;
                    w.ref = function() { return w; };
                    w.unref = function() { return w; };
                    return w;
                })
            """)!.call(withArguments: [context.objectForKeyedSubscript("__NoCo_EventEmitter")!,
                                       watchId])!

            // Set up close method via Swift block
            let closeBlock: @convention(block) () -> Void = { [weak runtime] in
                guard let runtime = runtime else { return }
                let entry = state.withWatches { watches -> FSWatchState.WatchEntry? in
                    guard var e = watches[watchId], !e.closed else { return nil }
                    e.closed = true
                    watches[watchId] = e
                    return e
                }
                guard let entry = entry else { return }
                entry.source.cancel()
                close(entry.fd)
                runtime.eventLoop.releaseHandle()

                // Emit 'close' event
                watcher.invokeMethod("emit", withArguments: ["close"])
            }
            watcher.setValue(unsafeBitCast(closeBlock, to: AnyObject.self), forProperty: "close")

            let managedWatcher = JSManagedValue(value: watcher)!
            context.virtualMachine.addManagedReference(managedWatcher, withOwner: fs)

            // Capture listener as let for Sendable closure
            let capturedListener = listener

            // If listener provided, register it for 'change' event
            if let capturedListener = capturedListener {
                watcher.invokeMethod("on", withArguments: ["change", capturedListener])
            }

            // Open file descriptor for kqueue monitoring
            let fd = Darwin.open(resolved, O_EVTONLY)
            guard fd >= 0 else {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, watch '\(filename)'",
                    code: "ENOENT", syscall: "watch", path: filename
                )
                return watcher
            }

            // Create DispatchSource for file system events
            let eventMask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .attrib, .extend]
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: eventMask, queue: DispatchQueue.global()
            )

            source.setEventHandler { [weak runtime] in
                guard let runtime = runtime else { return }
                let data = source.data
                let isClosed = state.withWatches { watches -> Bool in
                    watches[watchId]?.closed ?? true
                }
                guard !isClosed else { return }

                let eventType: String
                if data.contains(.rename) || data.contains(.delete) {
                    eventType = "rename"
                } else {
                    eventType = "change"
                }

                runtime.eventLoop.enqueueCallback {
                    guard let w = managedWatcher.value, !w.forProperty("_closed")!.toBool() else { return }
                    w.invokeMethod("emit", withArguments: ["change", eventType, basename])
                    if let l = capturedListener {
                        l.call(withArguments: [eventType, basename])
                    }
                }

                // Auto-close on delete
                if data.contains(.delete) {
                    runtime.eventLoop.enqueueCallback {
                        guard let w = managedWatcher.value, !w.forProperty("_closed")!.toBool() else { return }
                        w.invokeMethod("close", withArguments: [])
                    }
                }
            }

            source.setCancelHandler {
                // fd is closed in the close() block, not here
            }

            // Store and activate
            state.withWatches { watches in
                watches[watchId] = FSWatchState.WatchEntry(
                    id: watchId,
                    source: source,
                    fd: fd,
                    watcher: managedWatcher
                )
            }

            runtime.eventLoop.retainHandle()
            source.resume()

            return watcher
        }
        fs.setValue(unsafeBitCast(watch, to: AnyObject.self), forProperty: "watch")
    }
}
