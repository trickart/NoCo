import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - Process Module Tests

@Test func processProperties() async throws {
    let runtime = NodeRuntime()

    let platform = runtime.evaluate("process.platform")?.toString()
    #expect(platform == "darwin")

    let version = runtime.evaluate("process.version")?.toString()
    #expect(version == "v18.0.0")
}

@Test func processCwd() async throws {
    let runtime = NodeRuntime()
    let cwd = runtime.evaluate("process.cwd()")?.toString()
    #expect(cwd != nil && !cwd!.isEmpty)
}

@Test func processNextTick() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("process.nextTick(function() { console.log('ticked'); })")
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("ticked"))
}

// MARK: - Process Module Edge Cases

@Test func processArch() async throws {
    let runtime = NodeRuntime()
    let arch = runtime.evaluate("process.arch")?.toString()
    #expect(arch == "arm64" || arch == "x64")
}

@Test func processPid() async throws {
    let runtime = NodeRuntime()
    let pid = runtime.evaluate("process.pid")?.toInt32() ?? 0
    #expect(pid > 0)
}

@Test func processArgv() async throws {
    let runtime = NodeRuntime()
    let isArray = runtime.evaluate("Array.isArray(process.argv)")?.toBool()
    #expect(isArray == true)
}

@Test func processEnv() async throws {
    let runtime = NodeRuntime()
    let isObj = runtime.evaluate("typeof process.env === 'object'")?.toBool()
    #expect(isObj == true)
    let hasPath = runtime.evaluate("typeof process.env.PATH === 'string'")?.toBool()
    #expect(hasPath == true)
}

@Test func processExit() async throws {
    let runtime = NodeRuntime()
    var messages: [(NodeRuntime.ConsoleLevel, String)] = []
    runtime.consoleHandler = { level, msg in messages.append((level, msg)) }

    runtime.evaluate("""
        setTimeout(function() { console.log('should not fire'); }, 5000);
        process.exit(0);
    """)
    runtime.runEventLoop(timeout: 0.2)

    // process.exit should have stopped the event loop
    #expect(messages.contains(where: { $0.1.contains("process.exit") }))
    #expect(!messages.contains(where: { $0.1 == "should not fire" }))
}

@Test func processHrtime() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var hr = process.hrtime();
        Array.isArray(hr) && hr.length === 2 && typeof hr[0] === 'number' && typeof hr[1] === 'number';
    """)
    #expect(result?.toBool() == true)

    // Seconds should be positive
    let seconds = runtime.evaluate("process.hrtime()[0]")?.toInt32() ?? 0
    #expect(seconds >= 0)
}

@Test func processMemoryUsage() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var mem = process.memoryUsage();
        typeof mem.rss === 'number' && mem.rss > 0;
    """)
    #expect(result?.toBool() == true)
}

@Test func processStdoutWrite() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.stdoutHandler = { msg in messages.append(msg) }

    runtime.evaluate("process.stdout.write('hello stdout')")
    #expect(messages.contains("hello stdout"))
}

@Test func processNextTickWithArgs() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        process.nextTick(function(a, b) {
            console.log(a + ':' + b);
        }, 'arg1', 'arg2');
    """)
    runtime.runEventLoop(timeout: 1)

    #expect(messages.contains("arg1:arg2"))
}

// MARK: - Global Object Tests

@Test func processGlobalIsGlobalObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        (function() {
            var g = this;
            var globalIsThis = (global === g);
            var globalIsNotProcess = (global !== process);
            return globalIsThis && globalIsNotProcess;
        })();
    """)
    #expect(result?.toBool() == true)
}

@Test func processGlobalHasCorrectProperties() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        [
            global.process === process,
            global.global === global,
            typeof global.console === 'object',
            typeof global.setTimeout === 'function',
            typeof global.Buffer === 'function'
        ].every(function(v) { return v === true; });
    """)
    #expect(result?.toBool() == true)
}

// MARK: - process.uptime / hrtime.bigint / chdir Tests

@Test func processUptime() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var u = process.uptime();
        typeof u === 'number' && u >= 0 && u < 10;
    """)
    #expect(result?.toBool() == true)
}

@Test func processHrtimeBigint() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var b = process.hrtime.bigint();
        typeof b === 'bigint' && b > 0n;
    """)
    #expect(result?.toBool() == true)
}

@Test func processChdir() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var original = process.cwd();
        process.chdir('/tmp');
        var changed = process.cwd();
        process.chdir(original);
        // macOS resolves /tmp to /private/tmp
        changed === '/tmp' || changed === '/private/tmp';
    """)
    #expect(result?.toBool() == true)
}

@Test func processChdirNonexistent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var threw = false;
        try {
            process.chdir('/nonexistent_dir_12345');
        } catch (e) {
            threw = e.message.indexOf('ENOENT') !== -1;
        }
        threw;
    """)
    #expect(result?.toBool() == true)
}

// MARK: - process EventEmitter Tests

@Test func processIsEventEmitter() async throws {
    let runtime = NodeRuntime()
    var messages: [String] = []
    runtime.consoleHandler = { _, msg in messages.append(msg) }

    runtime.evaluate("""
        var received = '';
        process.on('deprecation', function(msg) { received = msg; });
        process.emit('deprecation', 'test-dep');
        console.log('received:' + received);
        console.log('hasOn:' + (typeof process.on === 'function'));
        console.log('hasEmit:' + (typeof process.emit === 'function'));
    """)
    #expect(messages.contains("received:test-dep"))
    #expect(messages.contains("hasOn:true"))
    #expect(messages.contains("hasEmit:true"))
}
