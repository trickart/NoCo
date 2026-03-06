import Testing
import JavaScriptCore
@testable import NoCoKit

@Test func ttyIsattyReturnsBool() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('tty').isatty(1)")
    #expect(result?.toString() == "boolean")
}

@Test func ttyIsattyNegativeFd() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('tty').isatty(-1)")
    #expect(result?.toBool() == false)
}

@Test func ttyIsattyStringArg() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('tty').isatty('string')")
    #expect(result?.toBool() == false)
}

@Test func ttyWriteStreamProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new (require('tty').WriteStream)(1);
        JSON.stringify({
            isTTY: ws.isTTY,
            hasColumns: typeof ws.columns === 'number',
            hasRows: typeof ws.rows === 'number'
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isTTY\":true"))
    #expect(json.contains("\"hasColumns\":true"))
    #expect(json.contains("\"hasRows\":true"))
}

@Test func ttyReadStreamProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rs = new (require('tty').ReadStream)(0);
        JSON.stringify({
            isTTY: rs.isTTY,
            isRaw: rs.isRaw,
            hasSetRawMode: typeof rs.setRawMode === 'function'
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isTTY\":true"))
    #expect(json.contains("\"isRaw\":false"))
    #expect(json.contains("\"hasSetRawMode\":true"))
}

@Test func ttyWriteStreamGetWindowSize() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new (require('tty').WriteStream)(1);
        var size = ws.getWindowSize();
        JSON.stringify({ isArray: Array.isArray(size), len: size.length });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isArray\":true"))
    #expect(json.contains("\"len\":2"))
}

@Test func ttyWriteStreamHasColors() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new (require('tty').WriteStream)(1);
        typeof ws.hasColors()
    """)
    #expect(result?.toString() == "boolean")
}

@Test func ttyWriteStreamGetColorDepth() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ws = new (require('tty').WriteStream)(1);
        typeof ws.getColorDepth()
    """)
    #expect(result?.toString() == "number")
}

@Test func ttyReadStreamSetRawMode() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rs = new (require('tty').ReadStream)(0);
        var ret = rs.setRawMode(true);
        JSON.stringify({ isRaw: rs.isRaw, returnsSelf: ret === rs });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isRaw\":true"))
    #expect(json.contains("\"returnsSelf\":true"))
}

@Test func ttyNodePrefix() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('node:tty').isatty")
    #expect(result?.toString() == "function")
}
