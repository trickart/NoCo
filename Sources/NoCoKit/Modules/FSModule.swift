import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

/// Configuration for filesystem sandbox.
public struct FSConfiguration {
    /// Root directory for file operations. nil means no restriction.
    public var rootDirectory: String?
    /// Whether write operations are allowed.
    public var writable: Bool

    public init(rootDirectory: String? = nil, writable: Bool = true) {
        self.rootDirectory = rootDirectory
        self.writable = writable
    }
}

/// Manages file descriptor table for fd-based fs APIs.
/// Thread-safe: accessed from both jsQueue and GCD background queues.
final class FileDescriptorTable: Sendable {
    private struct State {
        var nextFd = 3 // 0=stdin, 1=stdout, 2=stderr are reserved
        var table: [Int: FileHandle] = [:]
    }
    private let state = Mutex(State())

    func allocate(_ handle: FileHandle) -> Int {
        state.withLock { state in
            let fd = state.nextFd
            state.nextFd += 1
            state.table[fd] = handle
            return fd
        }
    }

    func get(_ fd: Int) -> FileHandle? {
        state.withLock { $0.table[fd] }
    }

    func remove(_ fd: Int) {
        state.withLock { $0.table.removeValue(forKey: fd) }
    }
}

/// Implements the Node.js `fs` module.
public struct FSModule: NodeModule {
    public static let moduleName = "fs"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let fs = JSValue(newObjectIn: context)!
        let fm = FileManager.default
        let config = runtime.fsConfiguration

        // Helper: strip file:// URL prefix if present
        func stripFileURL(_ path: String) -> String {
            if path.hasPrefix("file://") {
                let stripped = String(path.dropFirst("file://".count))
                return stripped.removingPercentEncoding ?? stripped
            }
            return path
        }

        // Helper: validate path within sandbox
        func validatePath(_ path: String) -> String? {
            let resolved = (stripFileURL(path) as NSString).standardizingPath
            if let root = config.rootDirectory {
                let rootResolved = (root as NSString).standardizingPath
                if !resolved.hasPrefix(rootResolved) {
                    context.exception = context.createSystemError(
                        "Access denied: '\(path)' is outside sandbox",
                        code: "EACCES", syscall: "open", path: path
                    )
                    return nil
                }
            }
            return resolved
        }

        func validateWrite(_ path: String) -> String? {
            guard config.writable else {
                context.exception = context.createSystemError(
                    "Write access denied", code: "EACCES", syscall: "write", path: path
                )
                return nil
            }
            return validatePath(path)
        }

        // fs.Stats constructor for instanceof support
        context.evaluateScript("""
            (function(fs) {
                function Stats() {}
                fs.Stats = Stats;
            })
        """)!.call(withArguments: [fs])

        // fs.readFileSync(path, options?)
        let readFileSync: @convention(block) (String, JSValue) -> JSValue = {
            path, options in
            guard let resolved = validatePath(path) else {
                return JSValue(undefinedIn: context)
            }
            guard let data = fm.contents(atPath: resolved) else {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, open '\(path)'",
                    code: "ENOENT", syscall: "open", path: path
                )
                return JSValue(undefinedIn: context)
            }

            // Check encoding option
            var encoding: String? = nil
            if options.isString {
                encoding = options.toString()
            } else if options.isObject {
                encoding = options.forProperty("encoding")?.toString()
                if encoding == "undefined" || encoding == "null" { encoding = nil }
            }

            if let encoding = encoding, encoding.lowercased() == "utf8" || encoding.lowercased() == "utf-8" {
                let str = String(data: data, encoding: .utf8) ?? ""
                return JSValue(object: str, in: context)
            }

            // Return as Buffer
            let bufferCtor = context.objectForKeyedSubscript("Buffer")!
            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
            let arr = [UInt8](data).map { Int($0) }
            return fromFn.call(withArguments: [arr])
        }
        fs.setValue(unsafeBitCast(readFileSync, to: AnyObject.self), forProperty: "readFileSync")

        // fs.writeFileSync(path, data, options?)
        let writeFileSync: @convention(block) (String, JSValue, JSValue) -> Void = {
            path, data, options in
            guard let resolved = validateWrite(path) else { return }

            let writeData: Data
            if data.isString {
                writeData = data.toString().data(using: .utf8)!
            } else {
                // Assume Buffer/Uint8Array
                let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(data.atIndex(i).toInt32()))
                }
                writeData = Data(bytes)
            }

            fm.createFile(atPath: resolved, contents: writeData, attributes: nil)
        }
        fs.setValue(unsafeBitCast(writeFileSync, to: AnyObject.self), forProperty: "writeFileSync")

        // fs.existsSync(path)
        let existsSync: @convention(block) (String) -> Bool = { path in
            let resolved = (path as NSString).standardizingPath
            return fm.fileExists(atPath: resolved)
        }
        fs.setValue(unsafeBitCast(existsSync, to: AnyObject.self), forProperty: "existsSync")

        // fs.mkdirSync(path, options?)
        let mkdirSync: @convention(block) (String, JSValue) -> Void = { path, options in
            guard let resolved = validateWrite(path) else { return }
            let recursive = options.isObject ? (options.forProperty("recursive")?.toBool() ?? false) : false
            do {
                try fm.createDirectory(
                    atPath: resolved, withIntermediateDirectories: recursive, attributes: nil
                )
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "ENOENT", syscall: "mkdir", path: path
                )
            }
        }
        fs.setValue(unsafeBitCast(mkdirSync, to: AnyObject.self), forProperty: "mkdirSync")

        // fs.readdirSync(path, options?)
        let readdirSync: @convention(block) (String, JSValue) -> JSValue = { path, options in
            guard let resolved = validatePath(path) else {
                return JSValue(undefinedIn: context)
            }
            let withFileTypes = options.isObject && options.forProperty("withFileTypes")?.toBool() == true
            do {
                let items = try fm.contentsOfDirectory(atPath: resolved)
                if withFileTypes {
                    return Self.createDirentArray(items, directory: resolved, fm: fm, context: context)
                }
                return JSValue.array(from: items, in: context)
            } catch {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, scandir '\(path)'",
                    code: "ENOENT", syscall: "scandir", path: path
                )
                return JSValue(undefinedIn: context)
            }
        }
        fs.setValue(unsafeBitCast(readdirSync, to: AnyObject.self), forProperty: "readdirSync")

        // fs.statSync(path)
        let statSync: @convention(block) (String) -> JSValue = { path in
            guard let resolved = validatePath(path) else {
                return JSValue(undefinedIn: context)
            }
            // stat follows symlinks; use fileExists to determine type
            var isDirFlag: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDirFlag) else {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, stat '\(path)'",
                    code: "ENOENT", syscall: "stat", path: path
                )
                return JSValue(undefinedIn: context)
            }

            // Get attributes (may be of the symlink itself, but we use fileExists for type)
            let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]

            let stat = JSValue(newObjectIn: context)!
            // Set prototype to fs.Stats.prototype for instanceof support
            context.evaluateScript("(function(s, fs) { Object.setPrototypeOf(s, fs.Stats.prototype); })")!
                .call(withArguments: [stat, fs])
            let size = attrs[.size] as? Int ?? 0
            let mtime = attrs[.modificationDate] as? Date ?? Date()
            let ctime = attrs[.creationDate] as? Date ?? Date()
            let ino = (attrs[.systemFileNumber] as? UInt) ?? 0
            let dev = (attrs[.systemNumber] as? UInt) ?? 0
            let nlink = (attrs[.referenceCount] as? UInt) ?? 1
            let posix = (attrs[.posixPermissions] as? Int) ?? 0o644
            // S_IFREG = 0o100000, S_IFDIR = 0o040000
            let mode = (isDirFlag.boolValue ? 0o040000 : 0o100000) | posix

            stat.setValue(size, forProperty: "size")
            stat.setValue(ino, forProperty: "ino")
            stat.setValue(dev, forProperty: "dev")
            stat.setValue(nlink, forProperty: "nlink")
            stat.setValue(mode, forProperty: "mode")
            let mtimeMs = floor(mtime.timeIntervalSince1970 * 1000)
            let ctimeMs = floor(ctime.timeIntervalSince1970 * 1000)
            stat.setValue(mtimeMs, forProperty: "mtimeMs")
            stat.setValue(ctimeMs, forProperty: "ctimeMs")
            stat.setValue(ctimeMs, forProperty: "birthtimeMs")

            let dateConstructor = context.objectForKeyedSubscript("Date")!
            let mtimeDate = dateConstructor.construct(withArguments: [mtimeMs])!
            let ctimeDate = dateConstructor.construct(withArguments: [ctimeMs])!
            let birthtimeDate = dateConstructor.construct(withArguments: [ctimeMs])!
            stat.setValue(mtimeDate, forProperty: "mtime")
            stat.setValue(ctimeDate, forProperty: "ctime")
            stat.setValue(birthtimeDate, forProperty: "birthtime")

            let isDir = isDirFlag.boolValue
            let isFile = !isDir

            let isDirectoryFn: @convention(block) () -> Bool = { isDir }
            stat.setValue(unsafeBitCast(isDirectoryFn, to: AnyObject.self), forProperty: "isDirectory")

            let isFileFn: @convention(block) () -> Bool = { isFile }
            stat.setValue(unsafeBitCast(isFileFn, to: AnyObject.self), forProperty: "isFile")

            let fileType = attrs[.type] as? FileAttributeType
            let isSymlinkFn: @convention(block) () -> Bool = { fileType == .typeSymbolicLink }
            stat.setValue(unsafeBitCast(isSymlinkFn, to: AnyObject.self), forProperty: "isSymbolicLink")

            let falseFn: @convention(block) () -> Bool = { false }
            stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isBlockDevice")
            stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isCharacterDevice")
            stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isFIFO")
            stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isSocket")

            return stat
        }
        fs.setValue(unsafeBitCast(statSync, to: AnyObject.self), forProperty: "statSync")
        // fs.lstatSync — same as statSync for now (symlink info via attrs[.type])
        fs.setValue(unsafeBitCast(statSync, to: AnyObject.self), forProperty: "lstatSync")

        // fs.unlinkSync(path)
        let unlinkSync: @convention(block) (String) -> Void = { path in
            guard let resolved = validateWrite(path) else { return }
            do {
                try fm.removeItem(atPath: resolved)
            } catch {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, unlink '\(path)'",
                    code: "ENOENT", syscall: "unlink", path: path
                )
            }
        }
        fs.setValue(unsafeBitCast(unlinkSync, to: AnyObject.self), forProperty: "unlinkSync")

        // fs.unlink(path, callback)
        let unlink: @convention(block) (String, JSValue) -> Void = { [weak runtime] path, callback in
            guard let resolved = validateWrite(path) else { return }
            guard let runtime = runtime else { return }
            DispatchQueue.global().async {
                let localFm = FileManager.default
                do {
                    try localFm.removeItem(atPath: resolved)
                    runtime.eventLoop.enqueueCallback {
                        if !callback.isUndefined {
                            callback.call(withArguments: [JSValue(nullIn: context)!])
                        }
                    }
                } catch {
                    runtime.eventLoop.enqueueCallback {
                        let err = context.createSystemError(
                            "ENOENT: no such file or directory, unlink '\(path)'",
                            code: "ENOENT", syscall: "unlink", path: path
                        )
                        if !callback.isUndefined {
                            callback.call(withArguments: [err as Any])
                        }
                    }
                }
            }
        }
        fs.setValue(unsafeBitCast(unlink, to: AnyObject.self), forProperty: "unlink")

        // fs.rmdirSync(path)
        let rmdirSync: @convention(block) (String, JSValue) -> Void = { path, options in
            guard let resolved = validateWrite(path) else { return }
            do {
                try fm.removeItem(atPath: resolved)
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "ENOENT", syscall: "rmdir", path: path
                )
            }
        }
        fs.setValue(unsafeBitCast(rmdirSync, to: AnyObject.self), forProperty: "rmdirSync")

        // fs.rmSync(path, options) — recursive removal with force option
        let rmSync: @convention(block) (String, JSValue) -> Void = { path, options in
            guard let resolved = validateWrite(path) else { return }
            let force = options.isObject ? (options.forProperty("force")?.toBool() ?? false) : false
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: resolved, isDirectory: &isDir) {
                if !force {
                    context.exception = context.createSystemError(
                        "ENOENT: no such file or directory, rm '\(path)'",
                        code: "ENOENT", syscall: "rm", path: path
                    )
                }
                return
            }
            do {
                try fm.removeItem(atPath: resolved)
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "ERR_FS_RM", syscall: "rm", path: path
                )
            }
        }
        fs.setValue(unsafeBitCast(rmSync, to: AnyObject.self), forProperty: "rmSync")

        // fs.renameSync(oldPath, newPath)
        let renameSync: @convention(block) (String, String) -> Void = { oldPath, newPath in
            guard let oldResolved = validateWrite(oldPath),
                  let newResolved = validateWrite(newPath) else { return }
            do {
                try fm.moveItem(atPath: oldResolved, toPath: newResolved)
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "ENOENT", syscall: "rename", path: oldPath
                )
            }
        }
        fs.setValue(unsafeBitCast(renameSync, to: AnyObject.self), forProperty: "renameSync")

        // fs.copyFileSync(src, dest)
        let copyFileSync: @convention(block) (String, String) -> Void = { src, dest in
            guard let srcResolved = validatePath(src),
                  let destResolved = validateWrite(dest) else { return }
            do {
                if fm.fileExists(atPath: destResolved) {
                    try fm.removeItem(atPath: destResolved)
                }
                try fm.copyItem(atPath: srcResolved, toPath: destResolved)
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "ENOENT", syscall: "copyfile", path: src
                )
            }
        }
        fs.setValue(unsafeBitCast(copyFileSync, to: AnyObject.self), forProperty: "copyFileSync")

        // fs.appendFileSync(path, data, options?)
        let appendFileSync: @convention(block) (String, JSValue, JSValue) -> Void = {
            path, data, options in
            guard let resolved = validateWrite(path) else { return }

            let appendData: Data
            if data.isString {
                appendData = data.toString().data(using: .utf8)!
            } else {
                let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(data.atIndex(i).toInt32()))
                }
                appendData = Data(bytes)
            }

            if let handle = FileHandle(forWritingAtPath: resolved) {
                handle.seekToEndOfFile()
                handle.write(appendData)
                handle.closeFile()
            } else {
                fm.createFile(atPath: resolved, contents: appendData, attributes: nil)
            }
        }
        fs.setValue(unsafeBitCast(appendFileSync, to: AnyObject.self), forProperty: "appendFileSync")

        // fs.utimesSync(path, atime, mtime)
        let utimesSync: @convention(block) (String, JSValue, JSValue) -> Void = { path, atimeVal, mtimeVal in
            guard let resolved = validatePath(path) else { return }
            guard fm.fileExists(atPath: resolved) else {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, utime '\(path)'",
                    code: "ENOENT", syscall: "utime", path: path
                )
                return
            }

            func toDate(_ val: JSValue) -> Date {
                if val.isInstance(of: context.objectForKeyedSubscript("Date")) {
                    let ms = val.invokeMethod("getTime", withArguments: [])!.toDouble()
                    return Date(timeIntervalSince1970: ms / 1000.0)
                }
                let sec = val.toDouble()
                return Date(timeIntervalSince1970: sec)
            }

            let mtime = toDate(mtimeVal)
            let attrs: [FileAttributeKey: Any] = [.modificationDate: mtime]

            do {
                try fm.setAttributes(attrs, ofItemAtPath: resolved)
            } catch {
                context.exception = context.createSystemError(
                    error.localizedDescription, code: "EPERM", syscall: "utime", path: path
                )
            }
        }
        fs.setValue(unsafeBitCast(utimesSync, to: AnyObject.self), forProperty: "utimesSync")

        // fs.createReadStream(path, options?)
        let createReadStream: @convention(block) (String, JSValue) -> JSValue = { path, options in
            let highWaterMark: Int
            var startVal: UInt64 = 0
            var endVal: Int64 = -1 // -1 means read to EOF

            if options.isObject && !options.isUndefined {
                if let hwm = options.forProperty("highWaterMark"), !hwm.isUndefined {
                    highWaterMark = Int(hwm.toInt32())
                } else {
                    highWaterMark = 65536
                }
                if let s = options.forProperty("start"), !s.isUndefined {
                    startVal = UInt64(s.toInt32())
                }
                if let e = options.forProperty("end"), !e.isUndefined {
                    endVal = Int64(e.toInt32())
                }
            } else {
                highWaterMark = 65536
            }

            let start = startVal
            let end = endVal

            // Create a Readable instance
            let streamModule = context.objectForKeyedSubscript("require")!.call(withArguments: ["stream"])!
            let readableCtor = streamModule.forProperty("Readable")!
            let readable = readableCtor.construct(withArguments: [] as [Any])!

            // Validate path
            let resolved = (path as NSString).standardizingPath
            if let root = config.rootDirectory {
                let rootResolved = (root as NSString).standardizingPath
                if !resolved.hasPrefix(rootResolved) {
                    // Emit error on next tick
                    let errMsg = "Access denied: '\(path)' is outside sandbox"
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(errMsg, code: "EACCES", syscall: "open", path: path)
                        readable.invokeMethod("emit", withArguments: ["error", err as Any])
                    }
                    return readable
                }
            }

            readable.setValue(resolved, forProperty: "path")

            // Read file in background
            DispatchQueue.global().async {
                guard let handle = FileHandle(forReadingAtPath: resolved) else {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, open '\(path)'",
                            code: "ENOENT", syscall: "open", path: path
                        )
                        readable.invokeMethod("emit", withArguments: ["error", err as Any])
                    }
                    return
                }

                handle.seek(toFileOffset: start)
                var totalRead: Int64 = Int64(start)
                let endByte = end // inclusive

                while true {
                    var bytesToRead = highWaterMark
                    if endByte >= 0 {
                        let remaining = endByte - totalRead + 1
                        if remaining <= 0 { break }
                        bytesToRead = min(bytesToRead, Int(remaining))
                    }

                    let data = handle.readData(ofLength: bytesToRead)
                    if data.isEmpty { break }

                    totalRead += Int64(data.count)
                    let bytes = [UInt8](data)

                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                        let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                        let arr = bytes.map { Int($0) }
                        let buf = fromFn.call(withArguments: [arr])!
                        readable.invokeMethod("emit", withArguments: ["data", buf])
                    }

                    if endByte >= 0 && totalRead > endByte { break }
                }

                handle.closeFile()

                runtime.eventLoop.enqueueCallback {
                    readable.invokeMethod("emit", withArguments: ["end"])
                }
            }

            return readable
        }
        fs.setValue(unsafeBitCast(createReadStream, to: AnyObject.self), forProperty: "createReadStream")

        // fs.createWriteStream(path, options?)
        let createWriteStream: @convention(block) (String, JSValue) -> JSValue = { path, options in
            var flags = "w"
            var encodingOpt = "utf8"

            if options.isObject && !options.isUndefined {
                if let f = options.forProperty("flags"), !f.isUndefined, let s = f.toString() {
                    flags = s
                }
                if let e = options.forProperty("encoding"), !e.isUndefined, let s = e.toString() {
                    encodingOpt = s
                }
            }
            let encoding = encodingOpt

            // Create a Writable instance
            let streamModule = context.objectForKeyedSubscript("require")!.call(withArguments: ["stream"])!
            let writableCtor = streamModule.forProperty("Writable")!
            let writable = writableCtor.construct(withArguments: [] as [Any])!

            // Validate path
            let resolved = (path as NSString).standardizingPath
            if !config.writable {
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let err = ctx.createSystemError("Write access denied", code: "EACCES", syscall: "open", path: path)
                    writable.invokeMethod("emit", withArguments: ["error", err as Any])
                }
                return writable
            }
            if let root = config.rootDirectory {
                let rootResolved = (root as NSString).standardizingPath
                if !resolved.hasPrefix(rootResolved) {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "Access denied: '\(path)' is outside sandbox",
                            code: "EACCES", syscall: "open", path: path
                        )
                        writable.invokeMethod("emit", withArguments: ["error", err as Any])
                    }
                    return writable
                }
            }

            writable.setValue(resolved, forProperty: "path")
            writable.setValue(0, forProperty: "bytesWritten")

            let isAppend = flags == "a"

            // Pending operations before file is open
            class PendingOp {
                enum Kind { case write, end }
                let kind: Kind
                let args: [JSValue]
                init(kind: Kind, args: [JSValue]) {
                    self.kind = kind
                    self.args = args
                }
            }
            let pendingOps = NSMutableArray()

            // Initial _write buffers until file is open
            let initialWrite: @convention(block) (JSValue, JSValue, JSValue) -> Void = { chunk, encodingVal, callback in
                pendingOps.add(PendingOp(kind: .write, args: [chunk, encodingVal, callback]))
            }
            writable.setValue(unsafeBitCast(initialWrite, to: AnyObject.self), forProperty: "_write")

            // Buffer end() calls before file is open
            let origEnd = writable.forProperty("end")!
            let initialEnd: @convention(block) (JSValue, JSValue, JSValue) -> Void = { _, _, _ in
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                pendingOps.add(PendingOp(kind: .end, args: args))
            }
            writable.setValue(unsafeBitCast(initialEnd, to: AnyObject.self), forProperty: "end")

            // Open file in background
            DispatchQueue.global().async {
                let dir = (resolved as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: dir) {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, open '\(path)'",
                            code: "ENOENT", syscall: "open", path: path
                        )
                        writable.invokeMethod("emit", withArguments: ["error", err as Any])
                    }
                    return
                }

                // Create/truncate file for 'w' mode, create if needed for 'a' mode
                if !isAppend {
                    fm.createFile(atPath: resolved, contents: nil, attributes: nil)
                } else if !fm.fileExists(atPath: resolved) {
                    fm.createFile(atPath: resolved, contents: nil, attributes: nil)
                }

                guard let handle = FileHandle(forWritingAtPath: resolved) else {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, open '\(path)'",
                            code: "ENOENT", syscall: "open", path: path
                        )
                        writable.invokeMethod("emit", withArguments: ["error", err as Any])
                    }
                    return
                }

                if isAppend {
                    handle.seekToEndOfFile()
                }

                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context

                    // Helper: convert chunk to Data
                    func chunkToData(_ chunk: JSValue) -> Data {
                        if chunk.isString, let str = chunk.toString() {
                            return str.data(using: .utf8) ?? Data()
                        } else {
                            let length = chunk.forProperty("length")?.toInt32() ?? 0
                            var bytes = [UInt8]()
                            for i in 0..<length {
                                bytes.append(UInt8(chunk.atIndex(Int(i)).toInt32()))
                            }
                            return Data(bytes)
                        }
                    }

                    // Real _write implementation
                    let realWrite: @convention(block) (JSValue, JSValue, JSValue) -> Void = { chunk, encodingVal, callback in
                        let data = chunkToData(chunk)

                        DispatchQueue.global().async {
                            handle.write(data)

                            runtime.eventLoop.enqueueCallback {
                                let current = writable.forProperty("bytesWritten")?.toInt32() ?? 0
                                writable.setValue(Int(current) + data.count, forProperty: "bytesWritten")
                                callback.call(withArguments: [] as [Any])
                            }
                        }
                    }
                    writable.setValue(unsafeBitCast(realWrite, to: AnyObject.self), forProperty: "_write")

                    // Restore original end and add close-on-finish behavior
                    writable.setValue(origEnd, forProperty: "end")

                    let onFinish: @convention(block) () -> Void = {
                        DispatchQueue.global().async {
                            handle.closeFile()
                            runtime.eventLoop.enqueueCallback {
                                writable.invokeMethod("emit", withArguments: ["close"])
                            }
                        }
                    }
                    writable.invokeMethod("on", withArguments: ["finish", unsafeBitCast(onFinish, to: AnyObject.self)])

                    // Flush pending operations in order
                    let pending = pendingOps.copy() as! [Any]
                    pendingOps.removeAllObjects()
                    for item in pending {
                        if let op = item as? PendingOp {
                            switch op.kind {
                            case .write:
                                // Synchronously write pending data (file is open, we're on jsQueue)
                                let chunk = op.args[0]
                                let data = chunkToData(chunk)
                                handle.write(data)
                                let current = writable.forProperty("bytesWritten")?.toInt32() ?? 0
                                writable.setValue(Int(current) + data.count, forProperty: "bytesWritten")
                                op.args[2].call(withArguments: [] as [Any])
                            case .end:
                                writable.invokeMethod("end", withArguments: op.args)
                            }
                        }
                    }

                    writable.invokeMethod("emit", withArguments: ["open"])
                }
            }

            return writable
        }
        fs.setValue(unsafeBitCast(createWriteStream, to: AnyObject.self), forProperty: "createWriteStream")

        // fs.realpathSync(path)
        let realpathSync: @convention(block) (String) -> JSValue = { path in
            guard let resolved = validatePath(path) else {
                return JSValue(undefinedIn: context)
            }
            let realPath = (resolved as NSString).resolvingSymlinksInPath
            guard fm.fileExists(atPath: realPath) else {
                context.exception = context.createSystemError(
                    "ENOENT: no such file or directory, realpath '\(path)'",
                    code: "ENOENT", syscall: "realpath", path: path
                )
                return JSValue(undefinedIn: context)
            }
            return JSValue(object: realPath, in: context)
        }
        fs.setValue(unsafeBitCast(realpathSync, to: AnyObject.self), forProperty: "realpathSync")

        // fs.realpath(path, options, callback)
        let realpath: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else { return }
            let path = args[0].toString()!
            let callback = args.count >= 3 ? args[2] : args[1]
            let resolved = (path as NSString).standardizingPath
            DispatchQueue.global().async {
                let realPath = (resolved as NSString).resolvingSymlinksInPath
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    if fm.fileExists(atPath: realPath) {
                        callback.call(withArguments: [JSValue(nullIn: ctx)!, realPath])
                    } else {
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, realpath '\(path)'",
                            code: "ENOENT", syscall: "realpath", path: path
                        )
                        callback.call(withArguments: [err])
                    }
                }
            }
        }
        fs.setValue(unsafeBitCast(realpath, to: AnyObject.self), forProperty: "realpath")

        // fs.realpathSync.native = fs.realpathSync
        let realpathSyncObj = fs.forProperty("realpathSync")!
        realpathSyncObj.setValue(realpathSyncObj, forProperty: "native")

        // fs.realpath.native = fs.realpath
        let realpathObj = fs.forProperty("realpath")!
        realpathObj.setValue(realpathObj, forProperty: "native")

        // fd-based APIs
        installFdAPIs(fs: fs, context: context, runtime: runtime, config: config)

        // Async versions using GCD
        installAsyncVersions(fs: fs, context: context, runtime: runtime, config: config)

        // Watch APIs (watchFile, unwatchFile, watch)
        installWatchAPIs(fs: fs, context: context, runtime: runtime)

        return fs
    }

    /// Create a stat object from file attributes, reusable by statSync and watchFile.
    static func createStatObject(path: String, context: JSContext, fs: JSValue) -> JSValue? {
        let fm = FileManager.default
        var isDirFlag: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirFlag) else {
            return nil
        }

        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]

        let stat = JSValue(newObjectIn: context)!
        context.evaluateScript("(function(s, fs) { Object.setPrototypeOf(s, fs.Stats.prototype); })")!
            .call(withArguments: [stat, fs])
        let size = attrs[.size] as? Int ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? Date()
        let ctime = attrs[.creationDate] as? Date ?? Date()
        let ino = (attrs[.systemFileNumber] as? UInt) ?? 0
        let dev = (attrs[.systemNumber] as? UInt) ?? 0
        let nlink = (attrs[.referenceCount] as? UInt) ?? 1
        let posix = (attrs[.posixPermissions] as? Int) ?? 0o644
        let mode = (isDirFlag.boolValue ? 0o040000 : 0o100000) | posix

        stat.setValue(size, forProperty: "size")
        stat.setValue(ino, forProperty: "ino")
        stat.setValue(dev, forProperty: "dev")
        stat.setValue(nlink, forProperty: "nlink")
        stat.setValue(mode, forProperty: "mode")
        let mtimeMs = floor(mtime.timeIntervalSince1970 * 1000)
        let ctimeMs = floor(ctime.timeIntervalSince1970 * 1000)
        stat.setValue(mtimeMs, forProperty: "mtimeMs")
        stat.setValue(ctimeMs, forProperty: "ctimeMs")
        stat.setValue(ctimeMs, forProperty: "birthtimeMs")

        let dateConstructor = context.objectForKeyedSubscript("Date")!
        let mtimeDate = dateConstructor.construct(withArguments: [mtimeMs])!
        let ctimeDate = dateConstructor.construct(withArguments: [ctimeMs])!
        let birthtimeDate = dateConstructor.construct(withArguments: [ctimeMs])!
        stat.setValue(mtimeDate, forProperty: "mtime")
        stat.setValue(ctimeDate, forProperty: "ctime")
        stat.setValue(birthtimeDate, forProperty: "birthtime")

        let isDir = isDirFlag.boolValue
        let isFile = !isDir

        let isDirectoryFn: @convention(block) () -> Bool = { isDir }
        stat.setValue(unsafeBitCast(isDirectoryFn, to: AnyObject.self), forProperty: "isDirectory")

        let isFileFn: @convention(block) () -> Bool = { isFile }
        stat.setValue(unsafeBitCast(isFileFn, to: AnyObject.self), forProperty: "isFile")

        let fileType = attrs[.type] as? FileAttributeType
        let isSymlinkFn: @convention(block) () -> Bool = { fileType == .typeSymbolicLink }
        stat.setValue(unsafeBitCast(isSymlinkFn, to: AnyObject.self), forProperty: "isSymbolicLink")

        let falseFn: @convention(block) () -> Bool = { false }
        stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isBlockDevice")
        stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isCharacterDevice")
        stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isFIFO")
        stat.setValue(unsafeBitCast(falseFn, to: AnyObject.self), forProperty: "isSocket")

        return stat
    }

    /// Convert JSValue data to Data for writing
    private static func jsValueToData(_ data: JSValue, encoding: String? = nil) -> Data {
        if data.isString {
            return data.toString().data(using: .utf8) ?? Data()
        } else {
            // Buffer/Uint8Array
            let length = Int(data.forProperty("length")?.toInt32() ?? 0)
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for i in 0..<length {
                bytes.append(UInt8(data.atIndex(i).toInt32()))
            }
            return Data(bytes)
        }
    }

    /// Open a file and return a FileHandle based on flags
    private static func openFile(at path: String, flags: String) throws -> FileHandle {
        let fm = FileManager.default
        switch flags {
        case "r":
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            return handle
        case "w", "w+":
            fm.createFile(atPath: path, contents: nil, attributes: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            handle.truncateFile(atOffset: 0)
            return handle
        case "wx", "wx+":
            if fm.fileExists(atPath: path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST),
                              userInfo: [NSLocalizedDescriptionKey: "EEXIST: file already exists, open '\(path)'"])
            }
            fm.createFile(atPath: path, contents: nil, attributes: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            return handle
        case "a", "a+", "as", "as+":
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil, attributes: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            handle.seekToEndOfFile()
            return handle
        case "ax", "ax+":
            if fm.fileExists(atPath: path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST),
                              userInfo: [NSLocalizedDescriptionKey: "EEXIST: file already exists, open '\(path)'"])
            }
            fm.createFile(atPath: path, contents: nil, attributes: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            return handle
        default:
            // Default to read
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                              userInfo: [NSLocalizedDescriptionKey: "ENOENT: no such file or directory, open '\(path)'"])
            }
            return handle
        }
    }

    private static func installFdAPIs(
        fs: JSValue, context: JSContext, runtime: NodeRuntime, config: FSConfiguration
    ) {
        let fdTable = FileDescriptorTable()
        let fm = FileManager.default

        // Helper: strip file:// URL prefix if present
        func stripFileURL(_ path: String) -> String {
            if path.hasPrefix("file://") {
                let stripped = String(path.dropFirst("file://".count))
                return stripped.removingPercentEncoding ?? stripped
            }
            return path
        }

        // Helper: validate path within sandbox
        func validatePath(_ path: String) -> String? {
            let resolved = (stripFileURL(path) as NSString).standardizingPath
            if let root = config.rootDirectory {
                let rootResolved = (root as NSString).standardizingPath
                if !resolved.hasPrefix(rootResolved) {
                    context.exception = context.createSystemError(
                        "Access denied: '\(path)' is outside sandbox",
                        code: "EACCES", syscall: "open", path: path
                    )
                    return nil
                }
            }
            return resolved
        }

        // fs.openSync(path, flags[, mode])
        let openSync: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else {
                context.exception = JSValue(newErrorFromMessage: "path and flags are required", in: context)
                return JSValue(undefinedIn: context)
            }

            let path = args[0].toString()!
            let flags = args[1].toString() ?? "r"
            let resolved = (path as NSString).standardizingPath

            if let root = config.rootDirectory {
                let rootResolved = (root as NSString).standardizingPath
                if !resolved.hasPrefix(rootResolved) {
                    context.exception = context.createSystemError(
                        "Access denied: '\(path)' is outside sandbox",
                        code: "EACCES", syscall: "open", path: path
                    )
                    return JSValue(undefinedIn: context)
                }
            }

            do {
                let handle = try openFile(at: resolved, flags: flags)
                let fd = fdTable.allocate(handle)
                return JSValue(int32: Int32(fd), in: context)
            } catch {
                let code = flags.contains("x") && fm.fileExists(atPath: resolved) ? "EEXIST" : "ENOENT"
                context.exception = context.createSystemError(
                    error.localizedDescription, code: code, syscall: "open", path: path
                )
                return JSValue(undefinedIn: context)
            }
        }
        fs.setValue(unsafeBitCast(openSync, to: AnyObject.self), forProperty: "openSync")

        // fs.open(path, flags[, mode], callback)
        let open: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 3 else { return }

            let path = args[0].toString()!
            let flags = args[1].toString() ?? "r"
            // callback is the last argument
            let callback = args.last!
            let resolved = (path as NSString).standardizingPath

            DispatchQueue.global().async {
                do {
                    let handle = try openFile(at: resolved, flags: flags)
                    let fd = fdTable.allocate(handle)
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        callback.call(withArguments: [JSValue(nullIn: ctx)!, fd])
                    }
                } catch {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let code = flags.contains("x") && fm.fileExists(atPath: resolved) ? "EEXIST" : "ENOENT"
                        let err = ctx.createSystemError(
                            error.localizedDescription, code: code, syscall: "open", path: path
                        )
                        callback.call(withArguments: [err])
                    }
                }
            }
        }
        fs.setValue(unsafeBitCast(open, to: AnyObject.self), forProperty: "open")

        // fs.writeSync(fd, data[, ...args])
        // Signatures: writeSync(fd, buffer[, offset[, length[, position]]])
        //             writeSync(fd, string[, position[, encoding]])
        let writeSync: @convention(block) () -> JSValue = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else {
                return JSValue(int32: 0, in: context)
            }

            let fd = Int(args[0].toInt32())
            let data = args[1]
            let writeData = jsValueToData(data)
            let byteCount = writeData.count

            if fd == 1 {
                // stdout - use stdoutHandler to avoid double output
                if let str = String(data: writeData, encoding: .utf8) {
                    runtime.stdoutHandler(str)
                } else {
                    FileHandle.standardOutput.write(writeData)
                }
                return JSValue(int32: Int32(byteCount), in: context)
            } else if fd == 2 {
                // stderr
                if let str = String(data: writeData, encoding: .utf8) {
                    runtime.stderrHandler(str)
                } else {
                    FileHandle.standardError.write(writeData)
                }
                return JSValue(int32: Int32(byteCount), in: context)
            }

            guard let handle = fdTable.get(fd) else {
                context.exception = context.createSystemError(
                    "EBADF: bad file descriptor, write",
                    code: "EBADF", syscall: "write"
                )
                return JSValue(undefinedIn: context)
            }

            handle.write(writeData)
            return JSValue(int32: Int32(byteCount), in: context)
        }
        fs.setValue(unsafeBitCast(writeSync, to: AnyObject.self), forProperty: "writeSync")

        // fs.write(fd, data[, ...args], callback)
        let write: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 3 else { return }

            let fd = Int(args[0].toInt32())
            let data = args[1]
            let callback = args.last!
            let writeData = jsValueToData(data)
            let byteCount = writeData.count

            if fd == 1 {
                if let str = String(data: writeData, encoding: .utf8) {
                    runtime.stdoutHandler(str)
                } else {
                    FileHandle.standardOutput.write(writeData)
                }
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!, byteCount, data])
                }
                return
            } else if fd == 2 {
                if let str = String(data: writeData, encoding: .utf8) {
                    runtime.stderrHandler(str)
                } else {
                    FileHandle.standardError.write(writeData)
                }
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!, byteCount, data])
                }
                return
            }

            guard let handle = fdTable.get(fd) else {
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let err = ctx.createSystemError(
                        "EBADF: bad file descriptor, write",
                        code: "EBADF", syscall: "write"
                    )
                    callback.call(withArguments: [err])
                }
                return
            }

            DispatchQueue.global().async {
                handle.write(writeData)
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!, byteCount, data])
                }
            }
        }
        fs.setValue(unsafeBitCast(write, to: AnyObject.self), forProperty: "write")

        // fs.closeSync(fd)
        let closeSync: @convention(block) (JSValue) -> Void = { fdVal in
            let fd = Int(fdVal.toInt32())
            // Skip stdin/stdout/stderr
            guard fd > 2 else { return }
            guard let handle = fdTable.get(fd) else {
                context.exception = context.createSystemError(
                    "EBADF: bad file descriptor, close",
                    code: "EBADF", syscall: "close"
                )
                return
            }
            handle.closeFile()
            fdTable.remove(fd)
        }
        fs.setValue(unsafeBitCast(closeSync, to: AnyObject.self), forProperty: "closeSync")

        // fs.close(fd, callback)
        let close: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 1 else { return }

            let fd = Int(args[0].toInt32())
            let callback = args.count >= 2 ? args[1] : nil

            // Skip stdin/stdout/stderr
            guard fd > 2 else {
                if let cb = callback, !cb.isUndefined {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        cb.call(withArguments: [JSValue(nullIn: ctx)!])
                    }
                }
                return
            }

            guard let handle = fdTable.get(fd) else {
                if let cb = callback, !cb.isUndefined {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "EBADF: bad file descriptor, close",
                            code: "EBADF", syscall: "close"
                        )
                        cb.call(withArguments: [err])
                    }
                }
                return
            }

            DispatchQueue.global().async {
                handle.closeFile()
                fdTable.remove(fd)
                if let cb = callback, !cb.isUndefined {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        cb.call(withArguments: [JSValue(nullIn: ctx)!])
                    }
                }
            }
        }
        fs.setValue(unsafeBitCast(close, to: AnyObject.self), forProperty: "close")

        // fs.fsyncSync(fd)
        let fsyncSync: @convention(block) (JSValue) -> Void = { fdVal in
            let fd = Int(fdVal.toInt32())
            guard fd > 2, let handle = fdTable.get(fd) else { return }
            handle.synchronizeFile()
        }
        fs.setValue(unsafeBitCast(fsyncSync, to: AnyObject.self), forProperty: "fsyncSync")

        // fs.fsync(fd, callback)
        let fsync: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else { return }

            let fd = Int(args[0].toInt32())
            let callback = args[1]

            guard fd > 2, let handle = fdTable.get(fd) else {
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!])
                }
                return
            }

            DispatchQueue.global().async {
                handle.synchronizeFile()
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!])
                }
            }
        }
        fs.setValue(unsafeBitCast(fsync, to: AnyObject.self), forProperty: "fsync")

        // fs.mkdir(path, opts, callback)
        let mkdir: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else { return }

            let path = args[0].toString()!
            let callback: JSValue
            let recursive: Bool

            if args.count >= 3 && !args[2].isUndefined {
                callback = args[2]
                recursive = args[1].isObject ? (args[1].forProperty("recursive")?.toBool() ?? false) : false
            } else {
                callback = args[1]
                recursive = false
            }

            let resolved = (path as NSString).standardizingPath

            DispatchQueue.global().async {
                do {
                    try fm.createDirectory(
                        atPath: resolved, withIntermediateDirectories: recursive, attributes: nil
                    )
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        callback.call(withArguments: [JSValue(nullIn: ctx)!])
                    }
                } catch {
                    runtime.eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            error.localizedDescription, code: "ENOENT", syscall: "mkdir", path: path
                        )
                        callback.call(withArguments: [err])
                    }
                }
            }
        }
        fs.setValue(unsafeBitCast(mkdir, to: AnyObject.self), forProperty: "mkdir")
    }

    private static func installAsyncVersions(
        fs: JSValue, context: JSContext, runtime: NodeRuntime, config: FSConfiguration
    ) {
        // fs.readFile(path, options, callback)
        let readFile: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else { return }

            let path = args[0].toString()!
            let callback: JSValue
            let encoding: String?

            if args.count >= 3 && !args[2].isUndefined {
                callback = args[2]
                if args[1].isString {
                    encoding = args[1].toString()
                } else if args[1].isObject {
                    encoding = args[1].forProperty("encoding")?.toString()
                } else {
                    encoding = nil
                }
            } else {
                callback = args[1]
                encoding = nil
            }

            let resolved = (path as NSString).standardizingPath
            runtime.eventLoop.retainHandle()
            DispatchQueue.global().async {
                let data = FileManager.default.contents(atPath: resolved)
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    if let data = data {
                        if let enc = encoding, (enc.lowercased() == "utf8" || enc.lowercased() == "utf-8") {
                            let str = String(data: data, encoding: .utf8) ?? ""
                            callback.call(withArguments: [JSValue(nullIn: ctx)!, str])
                        } else {
                            let bufferCtor = ctx.objectForKeyedSubscript("Buffer")!
                            let fromFn = bufferCtor.objectForKeyedSubscript("from")!
                            let arr = [UInt8](data).map { Int($0) }
                            let buf = fromFn.call(withArguments: [arr])!
                            callback.call(withArguments: [JSValue(nullIn: ctx)!, buf])
                        }
                    } else {
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, open '\(path)'",
                            code: "ENOENT", syscall: "open", path: path
                        )
                        callback.call(withArguments: [err])
                    }
                    runtime.eventLoop.releaseHandle()
                }
            }
        }
        fs.setValue(unsafeBitCast(readFile, to: AnyObject.self), forProperty: "readFile")

        // fs.writeFile(path, data, options, callback)
        let writeFile: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 3 else { return }

            let path = args[0].toString()!
            let data = args[1]
            let callback = args.count >= 4 ? args[3] : args[2]

            let resolved = (path as NSString).standardizingPath
            let writeData: Data
            if data.isString {
                writeData = data.toString().data(using: .utf8)!
            } else {
                let length = Int(data.forProperty("length")?.toInt32() ?? 0)
                var bytes = [UInt8]()
                for i in 0..<length {
                    bytes.append(UInt8(data.atIndex(i).toInt32()))
                }
                writeData = Data(bytes)
            }

            runtime.eventLoop.retainHandle()
            DispatchQueue.global().async {
                FileManager.default.createFile(atPath: resolved, contents: writeData, attributes: nil)
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!])
                    runtime.eventLoop.releaseHandle()
                }
            }
        }
        fs.setValue(unsafeBitCast(writeFile, to: AnyObject.self), forProperty: "writeFile")

        // fs.stat(path, callback)
        let stat: @convention(block) (String, JSValue) -> Void = { path, callback in
            runtime.eventLoop.retainHandle()
            DispatchQueue.global().async {
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    // Reuse statSync logic by calling it
                    let fsObj = ctx.objectForKeyedSubscript("require" as NSString)?.call(withArguments: ["fs"])
                    if let statResult = fsObj?.invokeMethod("statSync", withArguments: [path]) {
                        if ctx.exception != nil {
                            let err = ctx.exception!
                            ctx.exception = nil
                            callback.call(withArguments: [err])
                        } else {
                            callback.call(withArguments: [JSValue(nullIn: ctx)!, statResult])
                        }
                    }
                    runtime.eventLoop.releaseHandle()
                }
            }
        }
        fs.setValue(unsafeBitCast(stat, to: AnyObject.self), forProperty: "stat")

        // fs.lstat(path, callback) — same as stat for now
        fs.setValue(unsafeBitCast(stat, to: AnyObject.self), forProperty: "lstat")

        // fs.readdir(path, options, callback)
        let readdir: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            guard args.count >= 2 else { return }

            let path = args[0].toString()!
            let callback: JSValue
            let opts: JSValue?

            if args.count >= 3 && args[2].isObject == false && !args[2].isUndefined && !args[2].isNull {
                // readdir(path, callback)
                callback = args[1]
                opts = nil
            } else if args.count >= 3 {
                callback = args[args.count - 1]
                opts = args[1]
            } else {
                callback = args[1]
                opts = nil
            }

            let withFileTypes = opts?.isObject == true && opts?.forProperty("withFileTypes")?.toBool() == true

            let resolved = (path as NSString).standardizingPath
            runtime.eventLoop.retainHandle()
            DispatchQueue.global().async {
                let localFm = FileManager.default
                let entries: [String]?
                do {
                    entries = try localFm.contentsOfDirectory(atPath: resolved)
                } catch {
                    entries = nil
                }
                runtime.eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    if let entries = entries {
                        if withFileTypes {
                            let arr = Self.createDirentArray(entries, directory: resolved, fm: localFm, context: ctx)
                            callback.call(withArguments: [JSValue(nullIn: ctx)!, arr])
                        } else {
                            let arr = JSValue(newArrayIn: ctx)!
                            for (i, entry) in entries.enumerated() {
                                arr.setValue(entry, at: i)
                            }
                            callback.call(withArguments: [JSValue(nullIn: ctx)!, arr])
                        }
                    } else {
                        let err = ctx.createSystemError(
                            "ENOENT: no such file or directory, scandir '\(path)'",
                            code: "ENOENT", syscall: "scandir", path: path
                        )
                        callback.call(withArguments: [err])
                    }
                    runtime.eventLoop.releaseHandle()
                }
            }
        }
        fs.setValue(unsafeBitCast(readdir, to: AnyObject.self), forProperty: "readdir")
    }

    /// Create an array of Dirent-like objects from directory entries.
    private static func createDirentArray(_ entries: [String], directory: String, fm: FileManager, context: JSContext) -> JSValue {
        let arr = JSValue(newArrayIn: context)!
        for (i, entry) in entries.enumerated() {
            let entryPath = (directory as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: entryPath, isDirectory: &isDir)
            let attrs = (try? fm.attributesOfItem(atPath: entryPath)) ?? [:]
            let fileType = attrs[.type] as? FileAttributeType
            let isSymlink = fileType == .typeSymbolicLink

            let dirent = JSValue(newObjectIn: context)!
            dirent.setValue(entry, forProperty: "name")

            let isDirVal = exists && isDir.boolValue
            let isFileVal = exists && !isDir.boolValue
            let isDirectoryFn: @convention(block) () -> Bool = { isDirVal }
            let isFileFn: @convention(block) () -> Bool = { isFileVal }
            let isSymlinkFn: @convention(block) () -> Bool = { isSymlink }
            let isBlockDevFn: @convention(block) () -> Bool = { false }
            let isCharDevFn: @convention(block) () -> Bool = { false }
            let isFIFOFn: @convention(block) () -> Bool = { false }
            let isSocketFn: @convention(block) () -> Bool = { false }

            dirent.setValue(unsafeBitCast(isDirectoryFn, to: AnyObject.self), forProperty: "isDirectory")
            dirent.setValue(unsafeBitCast(isFileFn, to: AnyObject.self), forProperty: "isFile")
            dirent.setValue(unsafeBitCast(isSymlinkFn, to: AnyObject.self), forProperty: "isSymbolicLink")
            dirent.setValue(unsafeBitCast(isBlockDevFn, to: AnyObject.self), forProperty: "isBlockDevice")
            dirent.setValue(unsafeBitCast(isCharDevFn, to: AnyObject.self), forProperty: "isCharacterDevice")
            dirent.setValue(unsafeBitCast(isFIFOFn, to: AnyObject.self), forProperty: "isFIFO")
            dirent.setValue(unsafeBitCast(isSocketFn, to: AnyObject.self), forProperty: "isSocket")

            arr.setValue(dirent, at: i)
        }
        return arr
    }
}
