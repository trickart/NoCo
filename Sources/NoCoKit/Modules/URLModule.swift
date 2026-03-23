import Foundation
import JavaScriptCore

/// Implements the Node.js `url` module.
public struct URLModule: NodeModule {
    public static let moduleName = "url"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let urlModule = JSValue(newObjectIn: context)!

        // url.parse(urlString, parseQueryString?, slashesDenoteHost?)
        let parse: @convention(block) (String, JSValue, JSValue) -> JSValue = {
            urlString, parseQS, slashes in
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!

            guard let url = URL(string: urlString) else {
                // Return object with null fields
                for key in [
                    "protocol", "slashes", "auth", "host", "port", "hostname",
                    "hash", "search", "query", "pathname", "path", "href",
                ] {
                    obj.setValue(JSValue(nullIn: ctx), forProperty: key)
                }
                obj.setValue(urlString, forProperty: "href")
                return obj
            }

            let scheme = url.scheme
            obj.setValue(
                scheme != nil ? scheme! + ":" : JSValue(nullIn: ctx), forProperty: "protocol")
            obj.setValue(
                scheme != nil && ["http", "https", "ftp"].contains(scheme!), forProperty: "slashes")
            obj.setValue(JSValue(nullIn: ctx), forProperty: "auth")

            if let user = url.user {
                let auth =
                    url.password != nil ? "\(user):\(url.password!)" : user
                obj.setValue(auth, forProperty: "auth")
            }

            let hostname = url.host ?? ""
            let port = url.port
            let host = port != nil ? "\(hostname):\(port!)" : hostname

            obj.setValue(host.isEmpty ? JSValue(nullIn: ctx) : JSValue(object: host, in: ctx),
                         forProperty: "host")
            obj.setValue(port != nil ? String(port!) : JSValue(nullIn: ctx), forProperty: "port")
            obj.setValue(hostname.isEmpty ? JSValue(nullIn: ctx) : JSValue(object: hostname, in: ctx),
                         forProperty: "hostname")

            let fragment = url.fragment
            obj.setValue(
                fragment != nil ? "#" + fragment! : JSValue(nullIn: ctx), forProperty: "hash")

            let query = url.query
            let search = query != nil ? "?" + query! : nil
            obj.setValue(
                search != nil ? JSValue(object: search!, in: ctx) : JSValue(nullIn: ctx),
                forProperty: "search")

            // query
            if parseQS.toBool() && query != nil {
                let queryObj = JSValue(newObjectIn: ctx)!
                let pairs = query!.split(separator: "&")
                for pair in pairs {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    let key =
                        String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let value =
                        kv.count > 1
                        ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                    queryObj.setValue(value, forProperty: key)
                }
                obj.setValue(queryObj, forProperty: "query")
            } else {
                obj.setValue(
                    query != nil ? JSValue(object: query!, in: ctx) : JSValue(nullIn: ctx),
                    forProperty: "query")
            }

            let pathname = url.path
            obj.setValue(pathname.isEmpty ? "/" : pathname, forProperty: "pathname")
            let fullPath = (pathname.isEmpty ? "/" : pathname) + (search ?? "")
            obj.setValue(fullPath, forProperty: "path")
            obj.setValue(urlString, forProperty: "href")

            return obj
        }
        urlModule.setValue(unsafeBitCast(parse, to: AnyObject.self), forProperty: "parse")

        // url.format(urlObject)
        let format: @convention(block) (JSValue) -> String = { obj in
            func getProp(_ name: String) -> String? {
                let val = obj.forProperty(name)
                if val == nil || val!.isNull || val!.isUndefined { return nil }
                let str = val!.toString()
                if str == nil || str == "null" || str == "undefined" { return nil }
                return str
            }

            var result = ""
            if let proto = getProp("protocol") {
                result += proto
                if obj.forProperty("slashes")?.toBool() == true {
                    result += "//"
                }
            }
            if let auth = getProp("auth") {
                result += auth + "@"
            }
            if let host = getProp("host") {
                result += host
            } else {
                if let hostname = getProp("hostname") {
                    result += hostname
                    if let port = getProp("port") {
                        result += ":" + port
                    }
                }
            }
            if let pathname = getProp("pathname") {
                result += pathname
            }
            if let search = getProp("search") {
                result += search
            }
            if let hash = getProp("hash") {
                result += hash
            }
            return result
        }
        urlModule.setValue(unsafeBitCast(format, to: AnyObject.self), forProperty: "format")

        // url.resolve(from, to)
        let resolve: @convention(block) (String, String) -> String = { from, to in
            guard let base = URL(string: from) else { return to }
            guard let resolved = URL(string: to, relativeTo: base) else { return to }
            return resolved.absoluteString
        }
        urlModule.setValue(unsafeBitCast(resolve, to: AnyObject.self), forProperty: "resolve")

        // url.fileURLToPath(url)
        let fileURLToPath: @convention(block) (JSValue) -> JSValue = { urlVal in
            let ctx = JSContext.current()!
            let str = urlVal.isString ? urlVal.toString()! : urlVal.forProperty("href")?.toString() ?? urlVal.toString()!
            if str.hasPrefix("file://") {
                let path = String(str.dropFirst("file://".count))
                let decoded = path.removingPercentEncoding ?? path
                return JSValue(object: decoded, in: ctx)
            }
            ctx.exception = ctx.createError("The URL must be of scheme file", code: "ERR_INVALID_URL_SCHEME")
            return JSValue(undefinedIn: ctx)
        }
        urlModule.setValue(unsafeBitCast(fileURLToPath, to: AnyObject.self), forProperty: "fileURLToPath")

        // url.pathToFileURL(path)
        let pathToFileURL: @convention(block) (String) -> JSValue = { path in
            let ctx = JSContext.current()!
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let href = "file://" + encoded
            let urlObj = ctx.evaluateScript("new URL('\(href.replacingOccurrences(of: "'", with: "\\'"))')")
            return urlObj ?? JSValue(undefinedIn: ctx)
        }
        urlModule.setValue(unsafeBitCast(pathToFileURL, to: AnyObject.self), forProperty: "pathToFileURL")

        // url.domainToASCII / url.domainToUnicode stubs
        let domainToASCII: @convention(block) (String) -> String = { domain in domain }
        urlModule.setValue(unsafeBitCast(domainToASCII, to: AnyObject.self), forProperty: "domainToASCII")
        urlModule.setValue(unsafeBitCast(domainToASCII, to: AnyObject.self), forProperty: "domainToUnicode")

        // Export global URL and URLSearchParams classes
        let globalURL = context.objectForKeyedSubscript("URL" as NSString)
        urlModule.setValue(globalURL, forProperty: "URL")
        let globalURLSearchParams = context.objectForKeyedSubscript("URLSearchParams" as NSString)
        urlModule.setValue(globalURLSearchParams, forProperty: "URLSearchParams")

        return urlModule
    }
}
