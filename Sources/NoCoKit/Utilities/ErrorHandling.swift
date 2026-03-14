import JavaScriptCore

/// Errors thrown by NoCo runtime.
public enum NoCoError: Error, CustomStringConvertible {
    case jsException(String)
    case moduleNotFound(String)
    case fileNotFound(String)
    case evaluationFailed(String)
    case sandboxViolation(String)
    case scriptNotFound(String, available: [String])

    public var description: String {
        switch self {
        case .jsException(let msg): return "JSException: \(msg)"
        case .moduleNotFound(let name): return "Cannot find module '\(name)'"
        case .fileNotFound(let path): return "ENOENT: no such file or directory, open '\(path)'"
        case .evaluationFailed(let msg): return "EvaluationFailed: \(msg)"
        case .sandboxViolation(let msg): return "SandboxViolation: \(msg)"
        case .scriptNotFound(let name, let available):
            var msg = "Script \"\(name)\" not found in package.json."
            if !available.isEmpty {
                msg += "\nAvailable scripts: \(available.sorted().joined(separator: ", "))"
            }
            return msg
        }
    }
}

extension JSContext {
    /// Create a Node.js-style Error object.
    func createError(_ message: String, code: String? = nil) -> JSValue {
        let error = JSValue(newErrorFromMessage: message, in: self)!
        if let code = code {
            error.setValue(code, forProperty: "code")
        }
        return error
    }

    /// Create a Node.js-style system error (e.g., ENOENT).
    func createSystemError(
        _ message: String,
        code: String,
        syscall: String? = nil,
        path: String? = nil
    ) -> JSValue {
        let error = createError(message, code: code)
        if let syscall = syscall {
            error.setValue(syscall, forProperty: "syscall")
        }
        if let path = path {
            error.setValue(path, forProperty: "path")
        }
        return error
    }
}
