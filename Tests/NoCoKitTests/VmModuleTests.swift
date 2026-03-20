import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Step 1: Basic API Tests

@Test func vmCreateContextAndIsContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var sandbox = { x: 42 };
        var ctx = vm.createContext(sandbox);
        JSON.stringify({
            isCtx: vm.isContext(ctx),
            isPlain: vm.isContext({}),
            sameRef: ctx === sandbox,
            xValue: ctx.x
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"isCtx\":true"))
    #expect(json.contains("\"isPlain\":false"))
    #expect(json.contains("\"sameRef\":true"))
    #expect(json.contains("\"xValue\":42"))
}

@Test func vmCreateContextIdempotent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({ a: 1 });
        var ctx2 = vm.createContext(ctx);
        ctx === ctx2;
    """)
    #expect(result?.toBool() == true)
}

@Test func vmRunInContext() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({ x: 10, y: 20 });
        vm.runInContext('x + y', ctx);
    """)
    #expect(result?.toInt32() == 30)
}

@Test func vmRunInContextModifiesSandbox() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var sandbox = { x: 1 };
        var ctx = vm.createContext(sandbox);
        vm.runInContext('x = 42; var newVar = 100;', ctx);
        JSON.stringify({ x: sandbox.x, newVar: sandbox.newVar });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"x\":42"))
    #expect(json.contains("\"newVar\":100"))
}

@Test func vmRunInNewContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var sandbox = { a: 5, b: 3 };
        vm.runInNewContext('a * b', sandbox);
    """)
    #expect(result?.toInt32() == 15)
}

@Test func vmRunInThisContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var testVal = 123;
        vm.runInThisContext('testVal + 1');
    """)
    #expect(result?.toInt32() == 124)
}

@Test func vmCompileFunction() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var fn = vm.compileFunction('return a + b', ['a', 'b']);
        fn(3, 4);
    """)
    #expect(result?.toInt32() == 7)
}

@Test func vmCompileFunctionWithContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({ multiplier: 10 });
        var fn = vm.compileFunction('return x * multiplier', ['x'], {
            parsingContext: ctx
        });
        fn(5);
    """)
    #expect(result?.toInt32() == 50)
}

@Test func vmCompileFunctionJestPattern() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var moduleExports = {};
        var moduleObj = { exports: moduleExports };
        var fn = vm.compileFunction(
            'exports.hello = function() { return "world"; };',
            ['exports', 'require', 'module', '__filename', '__dirname']
        );
        fn(moduleExports, function(){}, moduleObj, '/test.js', '/');
        moduleExports.hello();
    """)
    #expect(result?.toString() == "world")
}

@Test func vmScript() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var script = new vm.Script('x + 1');
        var ctx = vm.createContext({ x: 99 });
        script.runInContext(ctx);
    """)
    #expect(result?.toInt32() == 100)
}

@Test func vmScriptRunInNewContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var script = new vm.Script('greeting + " " + name');
        script.runInNewContext({ greeting: 'Hello', name: 'World' });
    """)
    #expect(result?.toString() == "Hello World")
}

@Test func vmScriptRunInThisContext() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var globalX = 42;
        var script = new vm.Script('globalX * 2');
        script.runInThisContext();
    """)
    #expect(result?.toInt32() == 84)
}

// MARK: - Step 2: Context Isolation Tests

@Test func vmContextIsolation() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx1 = vm.createContext({ val: 'ctx1' });
        var ctx2 = vm.createContext({ val: 'ctx2' });
        vm.runInContext('val = val + "_modified"', ctx1);
        vm.runInContext('val = val + "_modified"', ctx2);
        JSON.stringify({
            ctx1Val: vm.runInContext('val', ctx1),
            ctx2Val: vm.runInContext('val', ctx2)
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"ctx1Val\":\"ctx1_modified\""))
    #expect(json.contains("\"ctx2Val\":\"ctx2_modified\""))
}

@Test func vmContextNoGlobalLeak() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({});
        vm.runInContext('var leaked = 12345;', ctx);
        typeof leaked;
    """)
    #expect(result?.toString() == "undefined")
}

@Test func vmContextHasConsole() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({});
        vm.runInContext('typeof console !== "undefined"', ctx);
    """)
    #expect(result?.toBool() == true)
}

@Test func vmContextErrorPropagation() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    let result = runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({});
        var caught = false;
        try {
            vm.runInContext('throw new Error("sandbox error")', ctx);
        } catch(e) {
            caught = e.message === 'sandbox error';
        }
        caught;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - Step 3: ESM Module Tests

@Test func vmSyntheticModule() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({});
        var mod = new vm.SyntheticModule(['default'], function() {
            this.setExport('default', 42);
        }, { context: ctx, identifier: 'test-synthetic' });

        var results = {};
        results.statusBefore = mod.status;

        mod.link(function() { throw new Error('unreachable'); }).then(function() {
            results.statusAfterLink = mod.status;
            return mod.evaluate();
        }).then(function() {
            results.statusAfterEval = mod.status;
            results.defaultValue = mod.namespace.default;
            results.done = true;
        });
    """)

    // Run event loop to process promises
    runtime.runEventLoop(timeout: 2)

    let result = runtime.evaluate("""
        JSON.stringify(results);
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"statusBefore\":\"unlinked\""))
    #expect(json.contains("\"statusAfterLink\":\"linked\""))
    #expect(json.contains("\"statusAfterEval\":\"evaluated\""))
    #expect(json.contains("\"defaultValue\":42"))
}

@Test func vmSyntheticModuleSetExportInvalid() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var mod = new vm.SyntheticModule(['foo'], function() {});
        var caught = false;
        try {
            mod.setExport('bar', 1);
        } catch(e) {
            caught = e instanceof ReferenceError;
        }
        caught;
    """)
    #expect(result?.toBool() == true)
}

@Test func vmSourceTextModule() async throws {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        var vm = require('vm');
        var ctx = vm.createContext({});
        var mod = new vm.SourceTextModule('var result = 1 + 2; module.exports.value = result;', {
            context: ctx,
            identifier: 'test-source'
        });

        var results = {};
        results.statusBefore = mod.status;

        mod.link(function() {}).then(function() {
            results.statusAfterLink = mod.status;
            return mod.evaluate();
        }).then(function() {
            results.statusAfterEval = mod.status;
            results.value = mod.namespace.value;
            results.done = true;
        });
    """)

    runtime.runEventLoop(timeout: 2)

    let result = runtime.evaluate("JSON.stringify(results);")
    let json = result?.toString() ?? ""
    #expect(json.contains("\"statusBefore\":\"unlinked\""))
    #expect(json.contains("\"statusAfterLink\":\"linked\""))
    #expect(json.contains("\"statusAfterEval\":\"evaluated\""))
    #expect(json.contains("\"value\":3"))
}

@Test func vmScriptCreateCachedData() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        var script = new vm.Script('1+1');
        var cached = script.createCachedData();
        cached.length >= 0;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - vm.constants

@Test func vmConstants() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var vm = require('vm');
        vm.constants.USE_MAIN_CONTEXT_DEFAULT_LOADER;
    """)
    #expect(result?.toInt32() == 0)
}
