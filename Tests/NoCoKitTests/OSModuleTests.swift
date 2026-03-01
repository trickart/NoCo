import Testing
import JavaScriptCore
@testable import NoCoKit

// MARK: - OS Module Tests

@Test func osArch() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').arch()")
    #if arch(arm64)
    #expect(result?.toString() == "arm64")
    #elseif arch(x86_64)
    #expect(result?.toString() == "x64")
    #endif
}

@Test func osPlatform() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').platform()")
    #expect(result?.toString() == "darwin")
}

@Test func osType() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').type()")
    #expect(result?.toString() == "Darwin")
}

@Test func osRelease() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').release()")
    let str = result?.toString() ?? ""
    // Release should be a version-like string (e.g. "24.3.0")
    #expect(!str.isEmpty)
    #expect(str.contains("."))
}

@Test func osVersion() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').version()")
    let str = result?.toString() ?? ""
    #expect(!str.isEmpty)
}

@Test func osHostname() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').hostname()")
    let str = result?.toString() ?? ""
    #expect(!str.isEmpty)
}

@Test func osHomedir() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').homedir()")
    let str = result?.toString() ?? ""
    #expect(str.hasPrefix("/"))
}

@Test func osTmpdir() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').tmpdir()")
    let str = result?.toString() ?? ""
    #expect(!str.isEmpty)
    // Should not end with trailing slash (Node.js behavior)
    #expect(!str.hasSuffix("/"))
}

@Test func osTotalmem() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').totalmem()")
    let mem = result?.toDouble() ?? 0
    // Should be at least 1GB
    #expect(mem > 1_000_000_000)
}

@Test func osFreemem() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').freemem()")
    let mem = result?.toDouble() ?? 0
    // Should be positive
    #expect(mem > 0)
}

@Test func osCpus() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var cpus = require('os').cpus();
        JSON.stringify({ length: cpus.length, hasModel: typeof cpus[0].model === 'string', hasTimes: typeof cpus[0].times === 'object' });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"hasModel\":true"))
    #expect(json.contains("\"hasTimes\":true"))

    // Length should match processor count
    let countResult = runtime.evaluate("require('os').cpus().length")
    let count = countResult?.toInt32() ?? 0
    #expect(count > 0)
}

@Test func osLoadavg() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var avg = require('os').loadavg();
        JSON.stringify({ length: avg.length, isArray: Array.isArray(avg) });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"length\":3"))
    #expect(json.contains("\"isArray\":true"))
}

@Test func osUptime() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').uptime()")
    let uptime = result?.toDouble() ?? 0
    // Uptime should be positive
    #expect(uptime > 0)
}

@Test func osEndianness() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').endianness()")
    let str = result?.toString() ?? ""
    #expect(str == "LE" || str == "BE")
}

@Test func osEOL() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("require('os').EOL")
    #expect(result?.toString() == "\n")
}

@Test func osNetworkInterfaces() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ni = require('os').networkInterfaces();
        var keys = Object.keys(ni);
        JSON.stringify({ hasKeys: keys.length > 0, isObject: typeof ni === 'object' });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"hasKeys\":true"))
    #expect(json.contains("\"isObject\":true"))
}

@Test func osNetworkInterfacesStructure() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var ni = require('os').networkInterfaces();
        var lo = ni['lo0'];
        var entry = lo ? lo[0] : null;
        entry ? JSON.stringify({
            hasAddress: typeof entry.address === 'string',
            hasFamily: typeof entry.family === 'string',
            hasNetmask: typeof entry.netmask === 'string'
        }) : 'no_lo0';
    """)
    let str = result?.toString() ?? ""
    if str != "no_lo0" {
        #expect(str.contains("\"hasAddress\":true"))
        #expect(str.contains("\"hasFamily\":true"))
    }
}

@Test func osUserInfo() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var info = require('os').userInfo();
        JSON.stringify({
            hasUsername: typeof info.username === 'string',
            hasHomedir: typeof info.homedir === 'string',
            hasShell: typeof info.shell === 'string',
            hasUid: typeof info.uid === 'number',
            hasGid: typeof info.gid === 'number'
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"hasUsername\":true"))
    #expect(json.contains("\"hasHomedir\":true"))
    #expect(json.contains("\"hasShell\":true"))
    #expect(json.contains("\"hasUid\":true"))
    #expect(json.contains("\"hasGid\":true"))
}

@Test func osConstants() async throws {
    let runtime = NodeRuntime()
    // Check signal constants
    let sigint = runtime.evaluate("require('os').constants.signals.SIGINT")
    #expect(sigint?.toInt32() == 2)

    let sigterm = runtime.evaluate("require('os').constants.signals.SIGTERM")
    #expect(sigterm?.toInt32() == 15)

    // Check errno constants
    let enoent = runtime.evaluate("require('os').constants.errno.ENOENT")
    #expect(enoent?.toInt32() == 2)
}

@Test func osModuleRequireMultipleTimes() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var os1 = require('os');
        var os2 = require('os');
        os1 === os2;
    """)
    #expect(result?.toBool() == true)
}
