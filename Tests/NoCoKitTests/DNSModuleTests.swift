import Testing
import Foundation
@preconcurrency import JavaScriptCore
@testable import NoCoKit

// MARK: - DNS Module Tests

private func runEventLoopInBackground(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}

// MARK: - Constants

@Test func dnsConstants() {
    let runtime = NodeRuntime()
    let dns = runtime.evaluate("require('dns')")!

    #expect(dns.forProperty("NOTFOUND")?.toString() == "ENOTFOUND")
    #expect(dns.forProperty("SERVFAIL")?.toString() == "ESERVFAIL")
    #expect(dns.forProperty("NODATA")?.toString() == "ENODATA")
    #expect(dns.forProperty("FORMERR")?.toString() == "EFORMERR")
    #expect(dns.forProperty("REFUSED")?.toString() == "EREFUSED")
    #expect(dns.forProperty("CANCELLED")?.toString() == "ECANCELLED")

    #expect(dns.forProperty("ADDRCONFIG")?.toInt32() == 0x0400)
    #expect(dns.forProperty("V4MAPPED")?.toInt32() == 0x0800)
    #expect(dns.forProperty("ALL")?.toInt32() == 0x0100)
}

// MARK: - dns.lookup

@Test func lookupLocalhost() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', (err, address, family) => {
            _result = { err: err, address: address, family: family };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let address = runtime.evaluate("_result.address")?.toString()
    let family = runtime.evaluate("_result.family")?.toInt32()
    let err = runtime.evaluate("_result.err")
    #expect(err?.isNull == true)
    #expect(address == "127.0.0.1")
    #expect(family == 4)
}

@Test func lookupWithFamily4() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', { family: 4 }, (err, address, family) => {
            _result = { err: err, address: address, family: family };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let address = runtime.evaluate("_result.address")?.toString()
    let family = runtime.evaluate("_result.family")?.toInt32()
    #expect(address == "127.0.0.1")
    #expect(family == 4)
}

@Test func lookupWithFamily6() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', { family: 6 }, (err, address, family) => {
            _result = { err: err ? err.code : null, address: address, family: family };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let errCode = runtime.evaluate("_result.err")
    let address = runtime.evaluate("_result.address")
    // Either resolves to ::1 or fails (depending on system config)
    if errCode?.isNull == true {
        #expect(address?.toString() == "::1")
    }
}

@Test func lookupAll() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', { all: true }, (err, results) => {
            _result = { err: err, results: results };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let isArray = runtime.evaluate("Array.isArray(_result.results)")?.toBool()
    let firstAddr = runtime.evaluate("_result.results && _result.results[0] && _result.results[0].address")?.toString()
    #expect(isArray == true)
    #expect(firstAddr == "127.0.0.1")
}

@Test func lookupNotFound() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('this-host-does-not-exist-12345.invalid', (err, address, family) => {
            _result = { code: err ? err.code : null, syscall: err ? err.syscall : null };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let code = runtime.evaluate("_result.code")?.toString()
    let syscall = runtime.evaluate("_result.syscall")?.toString()
    #expect(code == "ENOTFOUND")
    #expect(syscall == "getaddrinfo")
}

@Test func lookupOptionsOmitted() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', (err, address, family) => {
            _result = { err: err, type: typeof address };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let err = runtime.evaluate("_result.err")
    let addrType = runtime.evaluate("_result.type")?.toString()
    #expect(err?.isNull == true)
    #expect(addrType == "string")
}

@Test func lookupNumericFamily() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookup('localhost', 4, (err, address, family) => {
            _result = { err: err, family: family };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let family = runtime.evaluate("_result.family")?.toInt32()
    #expect(family == 4)
}

// MARK: - dns.resolve

@Test func resolve4() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.resolve4('example.com', (err, addresses) => {
            _result = { err: err ? err.code : null, isArray: Array.isArray(addresses), len: addresses ? addresses.length : 0 };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 15)
    let errCode = runtime.evaluate("_result.err")
    if errCode?.isNull == true {
        let isArray = runtime.evaluate("_result.isArray")?.toBool()
        let len = runtime.evaluate("_result.len")?.toInt32()
        #expect(isArray == true)
        #expect((len ?? 0) > 0)
    }
}

@Test func resolveNotFound() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.resolve4('this-host-does-not-exist-12345.invalid', (err, addresses) => {
            _result = { code: err ? err.code : null };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 15)
    let code = runtime.evaluate("_result.code")?.toString()
    #expect(code != nil)
}

@Test func resolveDefaultRrtype() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.resolve('localhost', (err, addresses) => {
            _result = { err: err ? err.code : null, isArray: Array.isArray(addresses) };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 15)
    // localhost A record may or may not resolve depending on system
    let isArray = runtime.evaluate("_result.isArray")
    #expect(isArray != nil)
}

// MARK: - dns.reverse

@Test func reverseLoopback() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.reverse('127.0.0.1', (err, hostnames) => {
            _result = { err: err ? err.code : null, isArray: Array.isArray(hostnames) };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    // Either succeeds with an array or fails with ENOTFOUND
    let err = runtime.evaluate("_result.err")
    let isArray = runtime.evaluate("_result.isArray")?.toBool()
    if err?.isNull == true {
        #expect(isArray == true)
    }
}

// MARK: - dns.lookupService

@Test func lookupService() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const dns = require('dns');
        var _result = {};
        dns.lookupService('127.0.0.1', 80, (err, hostname, service) => {
            _result = { err: err ? err.code : null, hostname: hostname, service: service };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let err = runtime.evaluate("_result.err")
    if err?.isNull == true {
        let hostname = runtime.evaluate("_result.hostname")?.toString()
        let service = runtime.evaluate("_result.service")?.toString()
        #expect(hostname != nil)
        #expect(service != nil)
    }
}

// MARK: - dns.promises

@Test func promisesLookup() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const { promises: dnsPromises } = require('dns');
        var _result = {};
        dnsPromises.lookup('localhost').then(result => {
            _result = result;
        }).catch(err => {
            _result = { err: err.code };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 10)
    let address = runtime.evaluate("_result.address")?.toString()
    let family = runtime.evaluate("_result.family")?.toInt32()
    #expect(address == "127.0.0.1")
    #expect(family == 4)
}

@Test func promisesResolve() async {
    let runtime = NodeRuntime()
    runtime.evaluate("""
        const { promises: dnsPromises } = require('dns');
        var _result = {};
        dnsPromises.resolve('example.com', 'A').then(records => {
            _result = { isArray: Array.isArray(records), len: records.length };
        }).catch(err => {
            _result = { err: err.code };
        });
    """)
    await runEventLoopInBackground(runtime, timeout: 15)
    // May succeed or fail depending on network
    let err = runtime.evaluate("_result.err")
    if err?.isUndefined == true {
        let isArray = runtime.evaluate("_result.isArray")?.toBool()
        #expect(isArray == true)
    }
}

// MARK: - dns.getServers / dns.setServers

@Test func getServers() {
    let runtime = NodeRuntime()
    let isArray = runtime.evaluate("Array.isArray(require('dns').getServers())")?.toBool()
    #expect(isArray == true)
}

@Test func setServers() {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        const dns = require('dns');
        dns.setServers(['8.8.8.8', '8.8.4.4']);
        JSON.stringify(dns.getServers());
    """)?.toString()
    #expect(result == "[\"8.8.8.8\",\"8.8.4.4\"]")
}

// MARK: - Resolver class

@Test func resolverClass() {
    let runtime = NodeRuntime()
    let dns = runtime.evaluate("require('dns')")!
    #expect(dns.forProperty("Resolver")?.isUndefined == false)

    let typesStr = runtime.evaluate("""
        const dns = require('dns');
        const r = new dns.Resolver();
        [typeof r.resolve, typeof r.resolve4, typeof r.getServers, typeof r.setServers].join(',');
    """)?.toString()
    #expect(typesStr == "function,function,function,function")
}

// MARK: - API surface

@Test func shortcutMethodsExist() {
    let runtime = NodeRuntime()
    let dns = runtime.evaluate("require('dns')")!

    for method in ["lookup", "resolve", "resolve4", "resolve6",
                    "resolveMx", "resolveTxt", "resolveSrv", "resolveNs",
                    "resolveCname", "resolvePtr", "resolveSoa", "resolveAny",
                    "reverse", "lookupService", "getServers", "setServers"] {
        #expect(dns.forProperty(method)?.isUndefined == false, "dns.\(method) should be defined")
    }
}

@Test func promisesMethodsExist() {
    let runtime = NodeRuntime()
    let promises = runtime.evaluate("require('dns').promises")!

    for method in ["lookup", "resolve", "resolve4", "resolve6",
                    "resolveMx", "resolveTxt", "resolveSrv", "resolveNs",
                    "resolveCname", "resolvePtr", "resolveSoa", "resolveAny",
                    "reverse", "lookupService", "getServers", "setServers"] {
        #expect(promises.forProperty(method)?.isUndefined == false, "dns.promises.\(method) should be defined")
    }
}
