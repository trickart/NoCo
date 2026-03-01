import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Buffer Module Tests

@Test func bufferFromString() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.from('hello').toString()")
    #expect(result?.toString() == "hello")
}

@Test func bufferHex() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.from('hello').toString('hex')")
    #expect(result?.toString() == "68656c6c6f")
}

@Test func bufferBase64() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.from('hello').toString('base64')")
    #expect(result?.toString() == "aGVsbG8=")
}

@Test func bufferAlloc() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.alloc(5, 0x41).toString()")
    #expect(result?.toString() == "AAAAA")
}

@Test func bufferConcat() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        Buffer.concat([Buffer.from('hello'), Buffer.from(' world')]).toString()
    """)
    #expect(result?.toString() == "hello world")
}

@Test func bufferIsBuffer() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("Buffer.isBuffer(Buffer.from('test'))")
    let r2 = runtime.evaluate("Buffer.isBuffer('test')")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == false)
}

// MARK: - Buffer Module Edge Cases

@Test func bufferFromArray() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var b = Buffer.from([1, 2, 3]);
        b.length + ':' + b[0] + ':' + b[1] + ':' + b[2];
    """)
    #expect(result?.toString() == "3:1:2:3")
}

@Test func bufferFromHex() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.from('68656c6c6f', 'hex').toString()")
    #expect(result?.toString() == "hello")
}

@Test func bufferFromBase64() async throws {
    let runtime = NodeRuntime()
    // Use a base64 string with no padding to avoid atob polyfill edge case
    let result = runtime.evaluate("Buffer.from('YWJj', 'base64').toString()")
    #expect(result?.toString() == "abc")
}

@Test func bufferSlice() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.from('hello').slice(1, 3).toString()")
    #expect(result?.toString() == "el")
}

@Test func bufferCopy() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var src = Buffer.from('hello');
        var dst = Buffer.alloc(5);
        var copied = src.copy(dst);
        copied + ':' + dst.toString();
    """)
    #expect(result?.toString() == "5:hello")
}

@Test func bufferEquals() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("Buffer.from('hello').equals(Buffer.from('hello'))")
    let r2 = runtime.evaluate("Buffer.from('hello').equals(Buffer.from('world'))")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == false)
}

@Test func bufferCompare() async throws {
    let runtime = NodeRuntime()
    let eq = runtime.evaluate("Buffer.from('abc').compare(Buffer.from('abc'))")
    let lt = runtime.evaluate("Buffer.from('abc').compare(Buffer.from('def'))")
    let gt = runtime.evaluate("Buffer.from('def').compare(Buffer.from('abc'))")
    #expect(eq?.toInt32() == 0)
    #expect(lt?.toInt32() == -1)
    #expect(gt?.toInt32() == 1)
}

@Test func bufferWrite() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var b = Buffer.alloc(5);
        var written = b.write('hi');
        written + ':' + b.toString().substring(0, 2);
    """)
    #expect(result?.toString() == "2:hi")
}

@Test func bufferFill() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var b = Buffer.alloc(3);
        b.fill(0x41);
        b.toString();
    """)
    #expect(result?.toString() == "AAA")
}

@Test func bufferIndexOf() async throws {
    let runtime = NodeRuntime()
    // Search by number
    let r1 = runtime.evaluate("Buffer.from([1, 2, 3, 4]).indexOf(3)")
    #expect(r1?.toInt32() == 2)

    // Search by string
    let r2 = runtime.evaluate("Buffer.from('hello world').indexOf('world')")
    #expect(r2?.toInt32() == 6)

    // Not found
    let r3 = runtime.evaluate("Buffer.from('hello').indexOf('xyz')")
    #expect(r3?.toInt32() == -1)
}

@Test func bufferIncludes() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("Buffer.from('hello').includes('ell')")
    let r2 = runtime.evaluate("Buffer.from('hello').includes('xyz')")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == false)
}

@Test func bufferToJSON() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var j = Buffer.from([1, 2, 3]).toJSON();
        j.type + ':' + JSON.stringify(j.data);
    """)
    #expect(result?.toString() == "Buffer:[1,2,3]")
}

@Test func bufferByteLength() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.byteLength('hello')")
    #expect(result?.toInt32() == 5)
}

@Test func bufferIsEncoding() async throws {
    let runtime = NodeRuntime()
    let r1 = runtime.evaluate("Buffer.isEncoding('utf8')")
    let r2 = runtime.evaluate("Buffer.isEncoding('hex')")
    let r3 = runtime.evaluate("Buffer.isEncoding('invalid_encoding')")
    #expect(r1?.toBool() == true)
    #expect(r2?.toBool() == true)
    #expect(r3?.toBool() == false)
}

@Test func bufferAllocUnsafe() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("Buffer.allocUnsafe(10).length")
    #expect(result?.toInt32() == 10)
}

@Test func bufferReadWriteUInt() async throws {
    let runtime = NodeRuntime()
    // readUInt8 / writeUInt8
    let r1 = runtime.evaluate("""
        var b = Buffer.alloc(4);
        b.writeUInt8(0xFF, 0);
        b.readUInt8(0);
    """)
    #expect(r1?.toInt32() == 255)

    // readUInt16BE / writeUInt16BE
    let r2 = runtime.evaluate("""
        var b = Buffer.alloc(4);
        b.writeUInt16BE(0x0102, 0);
        b.readUInt16BE(0);
    """)
    #expect(r2?.toInt32() == 0x0102)

    // readUInt16LE
    let r3 = runtime.evaluate("""
        var b = Buffer.alloc(4);
        b.writeUInt16BE(0x0102, 0);
        b.readUInt16LE(0);
    """)
    #expect(r3?.toInt32() == 0x0201)
}

@Test func bufferReduce() async throws {
    let runtime = NodeRuntime()
    // sum of bytes
    let r1 = runtime.evaluate("""
        Buffer.from([1,2,3,4,5]).reduce(function(a, c) { return a + c; }, 0);
    """)
    #expect(r1?.toInt32() == 15)

    // without initialValue (starts from first element)
    let r2 = runtime.evaluate("""
        Buffer.from([10,20,30]).reduce(function(a, c) { return a + c; });
    """)
    #expect(r2?.toInt32() == 60)

    // build string from bytes (receiptio pattern)
    let r3 = runtime.evaluate("""
        Buffer.from([0x45,0x50,0x53,0x4f,0x4e]).reduce(function(a, c) { return a + String.fromCharCode(c); }, '');
    """)
    #expect(r3?.toString() == "EPSON")

    // reduce on subarray result
    let r4 = runtime.evaluate("""
        var buf = Buffer.from([0x5f, 0x45, 0x50, 0x53, 0x4f, 0x4e, 0x00]);
        buf.subarray(1, buf.length - 1).reduce(function(a, c) { return a + String.fromCharCode(c); }, '');
    """)
    #expect(r4?.toString() == "EPSON")
}
