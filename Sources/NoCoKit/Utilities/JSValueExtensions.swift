import JavaScriptCore

extension JSValue {
    /// Create a JS object from a Swift dictionary.
    static func object(from dict: [String: Any], in context: JSContext) -> JSValue {
        let obj = JSValue(newObjectIn: context)!
        for (key, value) in dict {
            obj.setValue(value, forProperty: key)
        }
        return obj
    }

    /// Create a JS array from Swift values.
    static func array(from values: [Any], in context: JSContext) -> JSValue {
        let arr = JSValue(newArrayIn: context)!
        for (i, value) in values.enumerated() {
            arr.setValue(value, at: i)
        }
        return arr
    }

    /// Check if the value is null or undefined.
    var isNullOrUndefined: Bool {
        isNull || isUndefined
    }

    /// Convert JSValue to optional String.
    var toString_: String? {
        isNullOrUndefined ? nil : toString()
    }

    /// Invoke this value as a function with arguments, returning the result.
    func callSafe(withArguments arguments: [Any] = []) -> JSValue? {
        guard !isUndefined && !isNull else { return nil }
        return call(withArguments: arguments)
    }

    /// Get a property, returning nil if the result is null/undefined.
    func property(_ name: String) -> JSValue? {
        let val = forProperty(name)
        return val?.isNullOrUndefined == true ? nil : val
    }
}

extension JSContext {
    /// Create a JavaScript function from a Swift closure.
    func createFunction(name: String, _ body: @escaping @convention(block) () -> Any?) -> JSValue {
        let block: @convention(block) () -> Any? = body
        let fn = JSValue(object: block, in: self)!
        fn.setValue(name, forProperty: "name")
        return fn
    }
}
