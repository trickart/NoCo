import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Path Module Tests

@Test func pathJoin() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').join('/foo', 'bar', 'baz')")
    #expect(result?.toString() == "/foo/bar/baz")
}

@Test func pathResolve() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').resolve('/foo', 'bar')")
    #expect(result?.toString() == "/foo/bar")
}

@Test func pathBasename() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').basename('/foo/bar/baz.txt')")
    #expect(result?.toString() == "baz.txt")
}

@Test func pathBasenameWithExt() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').basename('/foo/bar/baz.txt', '.txt')")
    #expect(result?.toString() == "baz")
}

@Test func pathDirname() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').dirname('/foo/bar/baz.txt')")
    #expect(result?.toString() == "/foo/bar")
}

@Test func pathExtname() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').extname('/foo/bar/baz.txt')")
    #expect(result?.toString() == ".txt")
}

@Test func pathNormalize() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').normalize('/foo/bar//baz/../qux')")
    #expect(result?.toString() == "/foo/bar/qux")
}

@Test func pathIsAbsolute() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("require('path').isAbsolute('/foo')")
    let r2 = runtime.evaluate("require('path').isAbsolute('foo')")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == false)
}

@Test func pathParse() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var p = require('path').parse('/home/user/file.txt');
        p.dir + '|' + p.base + '|' + p.ext + '|' + p.name;
    """)
    #expect(result?.toString() == "/home/user|file.txt|.txt|file")
}

// MARK: - Path Module Edge Cases

@Test func pathRelative() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').relative('/a/b', '/a/c')")
    #expect(result?.toString() == "../c")
}

@Test func pathFormat() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        require('path').format({dir: '/home', base: 'file.txt'})
    """)
    #expect(result?.toString() == "/home/file.txt")
}

@Test func pathSep() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').sep")
    #expect(result?.toString() == "/")
}

@Test func pathDelimiter() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('path').delimiter")
    #expect(result?.toString() == ":")
}
