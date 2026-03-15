import Foundation
import JavaScriptCore

/// Implements the Node.js `path` module (POSIX variant).
public struct PathModule: NodeModule {
    public static let moduleName = "path"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let path = JSValue(newObjectIn: context)!

        // path.sep
        path.setValue("/", forProperty: "sep")

        // path.delimiter
        path.setValue(":", forProperty: "delimiter")

        // path.join(...paths)
        let join: @convention(block) () -> String = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            let parts = args.compactMap { $0.toString() }.filter { !$0.isEmpty }
            if parts.isEmpty { return "." }

            var joined = parts.joined(separator: "/")
            joined = normalizePath(joined)
            return joined
        }
        path.setValue(unsafeBitCast(join, to: AnyObject.self), forProperty: "join")

        // path.resolve(...paths)
        let resolve: @convention(block) () -> String = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            let parts = args.compactMap { $0.toString() }

            var resolved = ""
            for part in parts.reversed() {
                if resolved.isEmpty {
                    resolved = part
                } else {
                    resolved = part + "/" + resolved
                }
                if part.hasPrefix("/") {
                    break
                }
            }
            if !resolved.hasPrefix("/") {
                resolved = FileManager.default.currentDirectoryPath + "/" + resolved
            }
            return normalizePath(resolved)
        }
        path.setValue(unsafeBitCast(resolve, to: AnyObject.self), forProperty: "resolve")

        // path.basename(path, ext?)
        let basename: @convention(block) (String, JSValue) -> String = { p, ext in
            var name = (p as NSString).lastPathComponent
            if !ext.isUndefined, let extStr = ext.toString(), name.hasSuffix(extStr) {
                name = String(name.dropLast(extStr.count))
            }
            return name
        }
        path.setValue(unsafeBitCast(basename, to: AnyObject.self), forProperty: "basename")

        // path.dirname(path)
        let dirname: @convention(block) (String) -> String = { p in
            let result = (p as NSString).deletingLastPathComponent
            return result.isEmpty ? "." : result
        }
        path.setValue(unsafeBitCast(dirname, to: AnyObject.self), forProperty: "dirname")

        // path.extname(path)
        let extname: @convention(block) (String) -> String = { p in
            let ext = (p as NSString).pathExtension
            return ext.isEmpty ? "" : "." + ext
        }
        path.setValue(unsafeBitCast(extname, to: AnyObject.self), forProperty: "extname")

        // path.normalize(path)
        let normalize: @convention(block) (String) -> String = { p in
            return normalizePath(p)
        }
        path.setValue(unsafeBitCast(normalize, to: AnyObject.self), forProperty: "normalize")

        // path.isAbsolute(path)
        let isAbsolute: @convention(block) (String) -> Bool = { p in
            return p.hasPrefix("/")
        }
        path.setValue(unsafeBitCast(isAbsolute, to: AnyObject.self), forProperty: "isAbsolute")

        // path.relative(from, to)
        let relative: @convention(block) (String, String) -> String = { from, to in
            let fromParts = normalizePath(from).split(separator: "/").map(String.init)
            let toParts = normalizePath(to).split(separator: "/").map(String.init)

            var commonLen = 0
            let maxLen = min(fromParts.count, toParts.count)
            for i in 0..<maxLen {
                if fromParts[i] == toParts[i] {
                    commonLen = i + 1
                } else {
                    break
                }
            }

            var result: [String] = []
            for _ in commonLen..<fromParts.count {
                result.append("..")
            }
            result.append(contentsOf: toParts[commonLen...])
            return result.joined(separator: "/")
        }
        path.setValue(unsafeBitCast(relative, to: AnyObject.self), forProperty: "relative")

        // path.parse(path)
        let parse: @convention(block) (String) -> JSValue = { p in
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!
            let dir = (p as NSString).deletingLastPathComponent
            let base = (p as NSString).lastPathComponent
            let ext = (p as NSString).pathExtension
            let name = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
            let root = p.hasPrefix("/") ? "/" : ""

            obj.setValue(root, forProperty: "root")
            obj.setValue(dir.isEmpty ? "" : dir, forProperty: "dir")
            obj.setValue(base, forProperty: "base")
            obj.setValue(ext.isEmpty ? "" : "." + ext, forProperty: "ext")
            obj.setValue(name, forProperty: "name")
            return obj
        }
        path.setValue(unsafeBitCast(parse, to: AnyObject.self), forProperty: "parse")

        // path.format(pathObject)
        let format: @convention(block) (JSValue) -> String = { obj in
            let dir = obj.forProperty("dir")?.toString() ?? ""
            let base = obj.forProperty("base")?.toString() ?? ""
            let name = obj.forProperty("name")?.toString() ?? ""
            let ext = obj.forProperty("ext")?.toString() ?? ""

            let effectiveBase = base.isEmpty ? name + ext : base
            if dir.isEmpty {
                return effectiveBase
            }
            return dir + "/" + effectiveBase
        }
        path.setValue(unsafeBitCast(format, to: AnyObject.self), forProperty: "format")

        // path.posix = path (we only implement posix)
        path.setValue(path, forProperty: "posix")

        // path.win32 stub (same as posix with win32-style sep/delimiter)
        let win32Script = """
        (function(posix) {
            var win32 = {};
            Object.keys(posix).forEach(function(k) { win32[k] = posix[k]; });
            win32.sep = '\\\\';
            win32.delimiter = ';';
            return win32;
        })
        """
        let win32 = context.evaluateScript(win32Script)!.call(withArguments: [path])!
        path.setValue(win32, forProperty: "win32")

        return path
    }

    /// Normalize a path: resolve . and .., remove duplicate slashes.
    private static func normalizePath(_ path: String) -> String {
        if path.isEmpty { return "." }
        let isAbsolute = path.hasPrefix("/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [String] = []

        for part in parts {
            let p = String(part)
            if p == "." {
                continue
            } else if p == ".." {
                if !stack.isEmpty && stack.last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            } else {
                stack.append(p)
            }
        }

        var result = stack.joined(separator: "/")
        if isAbsolute {
            result = "/" + result
        }
        return result.isEmpty ? (isAbsolute ? "/" : ".") : result
    }
}
