import Foundation
import JavaScriptCore
import CNodeAPI

/// Loads `.node` native addon files via dlopen/dlsym.
public enum NAPIModule {

    /// Load a .node native addon and return its exports.
    static func load(path: String, context: JSContext, runtime: NodeRuntime) -> JSValue? {
        // dlopen the .node file (which is a .dylib)
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            let err = String(cString: dlerror())
            context.exception = context.evaluateScript(
                "new Error('Failed to load native module: \(err.replacingOccurrences(of: "'", with: "\\'"))')"
            )
            return nil
        }

        // Look for napi_register_module_v1
        guard let sym = dlsym(handle, "napi_register_module_v1") else {
            dlclose(handle)
            context.exception = context.evaluateScript(
                "new Error('Native module does not export napi_register_module_v1: \(path.replacingOccurrences(of: "'", with: "\\'"))')"
            )
            return nil
        }

        // Create environment for this module
        let env = NAPIEnvironment(context: context, runtime: runtime)
        NAPIEnvironmentRegistry.register(env)

        // Create exports object
        let exports = JSValue(newObjectIn: context)!

        // Store exports in the environment's value store
        guard let exportsNapi = env.wrap(exports) else {
            dlclose(handle)
            return nil
        }

        // Cast and call napi_register_module_v1
        typealias RegisterFunc = @convention(c) (napi_env?, napi_value?) -> napi_value?
        let register = unsafeBitCast(sym, to: RegisterFunc.self)
        let result = register(env.toOpaque(), exportsNapi)

        // Check for pending exception
        if let exception = env.pendingException {
            env.pendingException = nil
            context.exception = exception
            return nil
        }

        // Get the result (module may return a different exports object)
        if let result = result, let resultValue = env.unwrap(result) {
            return resultValue
        }

        return exports
    }
}
