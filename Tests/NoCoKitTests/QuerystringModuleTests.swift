import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Querystring Module Tests

@Test func querystringStringifyBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({foo: 'bar', baz: 'qux'})")
    #expect(result?.toString() == "foo=bar&baz=qux")
}

@Test func querystringStringifyArray() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({a: [1, 2, 3]})")
    #expect(result?.toString() == "a=1&a=2&a=3")
}

@Test func querystringStringifyCustomSepEq() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({foo: 'bar', baz: 'qux'}, ';', ':')")
    #expect(result?.toString() == "foo:bar;baz:qux")
}

@Test func querystringStringifyEncoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({key: 'hello world', special: 'a=b&c'})")
    #expect(result?.toString() == "key=hello%20world&special=a%3Db%26c")
}

@Test func querystringStringifyEmpty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({})")
    #expect(result?.toString() == "")
}

@Test func querystringStringifyNullUndefined() async throws {
    let runtime = NodeRuntime()
    let result1 = runtime.evaluate("require('querystring').stringify(null)")
    #expect(result1?.toString() == "")

    let result2 = runtime.evaluate("require('querystring').stringify(undefined)")
    #expect(result2?.toString() == "")
}

@Test func querystringStringifyUndefinedValue() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').stringify({a: 'b', c: undefined})")
    #expect(result?.toString() == "a=b")
}

@Test func querystringParseBasic() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('foo=bar&baz=qux');
        JSON.stringify({foo: obj.foo, baz: obj.baz});
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"foo\":\"bar\""))
    #expect(json.contains("\"baz\":\"qux\""))
}

@Test func querystringParseDuplicateKeys() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('a=1&a=2&a=3');
        JSON.stringify(obj.a);
    """)
    #expect(result?.toString() == "[\"1\",\"2\",\"3\"]")
}

@Test func querystringParseCustomSepEq() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('foo:bar;baz:qux', ';', ':');
        JSON.stringify({foo: obj.foo, baz: obj.baz});
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"foo\":\"bar\""))
    #expect(json.contains("\"baz\":\"qux\""))
}

@Test func querystringParseDecoding() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('key=hello%20world&special=a%3Db%26c');
        JSON.stringify({key: obj.key, special: obj.special});
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"key\":\"hello world\""))
    #expect(json.contains("\"special\":\"a=b&c\""))
}

@Test func querystringParseEmptyString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('');
        JSON.stringify(Object.keys(obj).length);
    """)
    #expect(result?.toString() == "0")
}

@Test func querystringParseNoValue() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('foo&bar');
        JSON.stringify({foo: obj.foo, bar: obj.bar});
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"foo\":\"\""))
    #expect(json.contains("\"bar\":\"\""))
}

@Test func querystringParseMaxKeys() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('a=1&b=2&c=3&d=4&e=5', null, null, {maxKeys: 3});
        Object.keys(obj).length;
    """)
    #expect(result?.toInt32() == 3)
}

@Test func querystringParseMaxKeysZero() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var obj = require('querystring').parse('a=1&b=2&c=3', null, null, {maxKeys: 0});
        Object.keys(obj).length;
    """)
    // maxKeys 0 means no limit
    #expect(result?.toInt32() == 3)
}

@Test func querystringEscape() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').escape('hello world&foo=bar')")
    #expect(result?.toString() == "hello%20world%26foo%3Dbar")
}

@Test func querystringUnescape() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').unescape('hello%20world%26foo%3Dbar')")
    #expect(result?.toString() == "hello world&foo=bar")
}

@Test func querystringUnescapeInvalid() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('querystring').unescape('%E0%A4%A')")
    // Should return original string on decode failure
    #expect(result?.toString() == "%E0%A4%A")
}

@Test func querystringDecodeAlias() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var qs = require('querystring');
        qs.decode === qs.parse;
    """)
    #expect(result?.toBool() == true)
}

@Test func querystringEncodeAlias() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var qs = require('querystring');
        qs.encode === qs.stringify;
    """)
    #expect(result?.toBool() == true)
}

@Test func querystringRoundtrip() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var qs = require('querystring');
        var original = {name: 'John Doe', age: '30', city: 'New York'};
        var encoded = qs.stringify(original);
        var decoded = qs.parse(encoded);
        JSON.stringify({name: decoded.name, age: decoded.age, city: decoded.city});
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"name\":\"John Doe\""))
    #expect(json.contains("\"age\":\"30\""))
    #expect(json.contains("\"city\":\"New York\""))
}

@Test func querystringModuleRequireMultipleTimes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var qs1 = require('querystring');
        var qs2 = require('querystring');
        qs1 === qs2;
    """)
    #expect(result?.toBool() == true)
}

@Test func querystringCustomEncodeFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var qs = require('querystring');
        qs.stringify({a: 'b c'}, null, null, {
            encodeURIComponent: function(s) { return s.replace(/ /g, '+'); }
        });
    """)
    #expect(result?.toString() == "a=b+c")
}
