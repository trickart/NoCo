import Testing
import JavaScriptCore
@testable import NoCoKit

// Minimal valid WASM module: exports add(i32, i32) -> i32
// (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
private let wasmBytesJS = "new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11])"

// MARK: - Sync WebAssembly API

@Test func webAssemblyModuleSync() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        var mod = new WebAssembly.Module(bytes);
        typeof mod;
    """)
    #expect(result?.toString() == "object")
}

@Test func webAssemblyInstanceSync() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        var mod = new WebAssembly.Module(bytes);
        var inst = new WebAssembly.Instance(mod);
        inst.exports.add(2, 3);
    """)
    #expect(result?.toInt32() == 5)
}

// MARK: - Async WebAssembly API (JSC native, resolved via CFRunLoop)

@Test func webAssemblyCompileResolves() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        WebAssembly.compile(bytes).then(function(mod) {
            console.log('compiled:' + (mod instanceof WebAssembly.Module));
        }).catch(function(e) {
            console.log('error:' + e.message);
        });
        // keepalive: RunLoop idle wait 中に DeferredWorkTimer が fire する
        setTimeout(function() {}, 500);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("compiled:true"))
}

@Test func webAssemblyInstantiateWithBytes() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        WebAssembly.instantiate(bytes).then(function(result) {
            console.log('module:' + (result.module instanceof WebAssembly.Module));
            console.log('add:' + result.instance.exports.add(10, 20));
        });
        setTimeout(function() {}, 500);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("module:true"))
    #expect(messages.contains("add:30"))
}

@Test func webAssemblyInstantiateWithModule() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        var mod = new WebAssembly.Module(bytes);
        WebAssembly.instantiate(mod).then(function(inst) {
            console.log('add:' + inst.exports.add(7, 8));
        });
        setTimeout(function() {}, 500);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("add:15"))
}

@Test func webAssemblyCompileRejectsInvalidBytes() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        WebAssembly.compile(new Uint8Array([0, 1, 2, 3])).then(function() {
            console.log('unexpected-resolve');
        }).catch(function(e) {
            console.log('rejected:' + (e instanceof WebAssembly.CompileError));
        });
        setTimeout(function() {}, 500);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("rejected:true"))
}

@Test func webAssemblyValidateSync() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        [WebAssembly.validate(bytes), WebAssembly.validate(new Uint8Array([0,1,2]))].join(',');
    """)
    #expect(result?.toString() == "true,false")
}

@Test func webAssemblyAsyncChainProgresses() async throws {
    // compile → instantiate → call の async chain が CFRunLoop idle wait で完了する
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var bytes = \(wasmBytesJS);
        var done = false;
        (async function() {
            var mod = await WebAssembly.compile(bytes);
            var inst = await WebAssembly.instantiate(mod);
            console.log('chain:' + inst.exports.add(100, 200));
            done = true;
        })();
        var t = setInterval(function() { if (done) clearInterval(t); }, 50);
    """)
    runtime.runEventLoop(timeout: 2)

    #expect(messages.contains("chain:300"))
}
