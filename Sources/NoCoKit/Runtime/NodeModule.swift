import JavaScriptCore

/// Protocol that all Node.js built-in modules conform to.
public protocol NodeModule {
    static var moduleName: String { get }
    static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue
}
