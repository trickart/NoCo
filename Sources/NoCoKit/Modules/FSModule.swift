import Foundation
@preconcurrency import JavaScriptCore

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

/// Implements the Node.js `fs` module.
public struct FSModule: NodeModule {
    public static let moduleName = "fs"

    /// The filesystem configuration. Set on the runtime before creating the module.
    public nonisolated(unsafe) static var configuration = FSConfiguration()

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let fs = JSValue(newObjectIn: context)!
        let fm = FileManager.default
        let config = configuration

        // Helper: validate path within sandbox
        func validatePath(_ path: String) -> String? {
            let resolved = (path as NSString).standardizingPath
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
            do {
                let items = try fm.contentsOfDirectory(atPath: resolved)
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
            let size = attrs[.size] as? Int ?? 0
            let mtime = attrs[.modificationDate] as? Date ?? Date()
            let ctime = attrs[.creationDate] as? Date ?? Date()

            stat.setValue(size, forProperty: "size")
            stat.setValue(mtime.timeIntervalSince1970 * 1000, forProperty: "mtimeMs")
            stat.setValue(ctime.timeIntervalSince1970 * 1000, forProperty: "ctimeMs")
            stat.setValue(ctime.timeIntervalSince1970 * 1000, forProperty: "birthtimeMs")

            let isDir = isDirFlag.boolValue
            let isFile = !isDir

            let isDirectoryFn: @convention(block) () -> Bool = { isDir }
            stat.setValue(unsafeBitCast(isDirectoryFn, to: AnyObject.self), forProperty: "isDirectory")

            let isFileFn: @convention(block) () -> Bool = { isFile }
            stat.setValue(unsafeBitCast(isFileFn, to: AnyObject.self), forProperty: "isFile")

            let fileType = attrs[.type] as? FileAttributeType
            let isSymlinkFn: @convention(block) () -> Bool = { fileType == .typeSymbolicLink }
            stat.setValue(unsafeBitCast(isSymlinkFn, to: AnyObject.self), forProperty: "isSymbolicLink")

            return stat
        }
        fs.setValue(unsafeBitCast(statSync, to: AnyObject.self), forProperty: "statSync")

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

        // Async versions using GCD
        installAsyncVersions(fs: fs, context: context, runtime: runtime, config: config)

        return fs
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
            DispatchQueue.global().async {
                let data = FileManager.default.contents(atPath: resolved)
                runtime.perform { ctx in
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

            DispatchQueue.global().async {
                FileManager.default.createFile(atPath: resolved, contents: writeData, attributes: nil)
                runtime.perform { ctx in
                    callback.call(withArguments: [JSValue(nullIn: ctx)!])
                }
            }
        }
        fs.setValue(unsafeBitCast(writeFile, to: AnyObject.self), forProperty: "writeFile")

        // fs.stat(path, callback)
        let stat: @convention(block) (String, JSValue) -> Void = { path, callback in
            DispatchQueue.global().async {
                runtime.perform { ctx in
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
                }
            }
        }
        fs.setValue(unsafeBitCast(stat, to: AnyObject.self), forProperty: "stat")
    }
}
