import Foundation
import JavaScriptCore

#if canImport(Darwin)
import Darwin
#endif

/// Implements the Node.js `os` module.
public struct OSModule: NodeModule {
    public static let moduleName = "os"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let os = JSValue(newObjectIn: context)!

        // os.EOL
        os.setValue("\n", forProperty: "EOL")

        // os.arch()
        let arch: @convention(block) () -> String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x64"
            #elseif arch(i386)
            return "ia32"
            #else
            return "unknown"
            #endif
        }
        os.setValue(unsafeBitCast(arch, to: AnyObject.self), forProperty: "arch")

        // os.platform()
        let platform: @convention(block) () -> String = {
            #if os(macOS)
            return "darwin"
            #elseif os(Linux)
            return "linux"
            #else
            return "unknown"
            #endif
        }
        os.setValue(unsafeBitCast(platform, to: AnyObject.self), forProperty: "platform")

        // os.type()
        let type: @convention(block) () -> String = {
            #if os(macOS)
            return "Darwin"
            #elseif os(Linux)
            return "Linux"
            #else
            return "Unknown"
            #endif
        }
        os.setValue(unsafeBitCast(type, to: AnyObject.self), forProperty: "type")

        // os.release()
        let release: @convention(block) () -> String = {
            var name = utsname()
            uname(&name)
            let release = name.release
            return withUnsafeBytes(of: release) { buf in
                let bytes = buf.prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        os.setValue(unsafeBitCast(release, to: AnyObject.self), forProperty: "release")

        // os.version()
        let version: @convention(block) () -> String = {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        os.setValue(unsafeBitCast(version, to: AnyObject.self), forProperty: "version")

        // os.hostname()
        let hostname: @convention(block) () -> String = {
            return ProcessInfo.processInfo.hostName
        }
        os.setValue(unsafeBitCast(hostname, to: AnyObject.self), forProperty: "hostname")

        // os.homedir()
        let homedir: @convention(block) () -> String = {
            return NSHomeDirectory()
        }
        os.setValue(unsafeBitCast(homedir, to: AnyObject.self), forProperty: "homedir")

        // os.tmpdir()
        let tmpdir: @convention(block) () -> String = {
            let tmp = NSTemporaryDirectory()
            // Remove trailing slash to match Node.js behavior
            if tmp.hasSuffix("/") && tmp.count > 1 {
                return String(tmp.dropLast())
            }
            return tmp
        }
        os.setValue(unsafeBitCast(tmpdir, to: AnyObject.self), forProperty: "tmpdir")

        // os.totalmem()
        let totalmem: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            return JSValue(double: Double(ProcessInfo.processInfo.physicalMemory), in: ctx)
        }
        os.setValue(unsafeBitCast(totalmem, to: AnyObject.self), forProperty: "totalmem")

        // os.freemem()
        let freemem: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            #if canImport(Darwin)
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                let pageSize = UInt64(getpagesize())
                let free = UInt64(stats.free_count) * pageSize
                return JSValue(double: Double(free), in: ctx)
            }
            #endif
            return JSValue(double: 0, in: ctx)
        }
        os.setValue(unsafeBitCast(freemem, to: AnyObject.self), forProperty: "freemem")

        // os.cpus()
        let cpus: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            let count = ProcessInfo.processInfo.processorCount
            let arr = JSValue(newArrayIn: ctx)!

            // Get CPU model via sysctl
            var modelSize = 0
            sysctlbyname("machdep.cpu.brand_string", nil, &modelSize, nil, 0)
            var model = "Unknown"
            if modelSize > 0 {
                var buffer = [CChar](repeating: 0, count: modelSize)
                sysctlbyname("machdep.cpu.brand_string", &buffer, &modelSize, nil, 0)
                if let nullIdx = buffer.firstIndex(of: 0) {
                    model = String(decoding: buffer[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                } else {
                    model = String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }

            // Get CPU frequency via sysctl (in Hz)
            var freq: Int64 = 0
            var freqSize = MemoryLayout<Int64>.size
            sysctlbyname("hw.cpufrequency", &freq, &freqSize, nil, 0)
            let speedMHz = freq > 0 ? Int(freq / 1_000_000) : 0

            for i in 0..<count {
                let cpuObj = JSValue(newObjectIn: ctx)!
                cpuObj.setValue(model, forProperty: "model")
                cpuObj.setValue(speedMHz, forProperty: "speed")
                let times = JSValue(newObjectIn: ctx)!
                times.setValue(0, forProperty: "user")
                times.setValue(0, forProperty: "nice")
                times.setValue(0, forProperty: "sys")
                times.setValue(0, forProperty: "idle")
                times.setValue(0, forProperty: "irq")
                cpuObj.setValue(times, forProperty: "times")
                arr.setValue(cpuObj, at: i)
            }
            return arr
        }
        os.setValue(unsafeBitCast(cpus, to: AnyObject.self), forProperty: "cpus")

        // os.loadavg()
        let loadavg: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            var loads: [Double] = [0, 0, 0]
            getloadavg(&loads, 3)
            let arr = JSValue(newArrayIn: ctx)!
            arr.setValue(loads[0], at: 0)
            arr.setValue(loads[1], at: 1)
            arr.setValue(loads[2], at: 2)
            return arr
        }
        os.setValue(unsafeBitCast(loadavg, to: AnyObject.self), forProperty: "loadavg")

        // os.uptime()
        let uptime: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            #if canImport(Darwin)
            var mib = [CTL_KERN, KERN_BOOTTIME]
            var boottime = timeval()
            var size = MemoryLayout<timeval>.size
            if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 {
                let now = time(nil)
                return JSValue(double: Double(now - boottime.tv_sec), in: ctx)
            }
            #endif
            return JSValue(double: 0, in: ctx)
        }
        os.setValue(unsafeBitCast(uptime, to: AnyObject.self), forProperty: "uptime")

        // os.endianness()
        let endianness: @convention(block) () -> String = {
            #if _endian(little)
            return "LE"
            #else
            return "BE"
            #endif
        }
        os.setValue(unsafeBitCast(endianness, to: AnyObject.self), forProperty: "endianness")

        // os.networkInterfaces()
        let networkInterfaces: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            let result = JSValue(newObjectIn: ctx)!

            #if canImport(Darwin)
            var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddrsPtr) == 0, let firstAddr = ifaddrsPtr else {
                return result
            }
            defer { freeifaddrs(ifaddrsPtr) }

            var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
            // Track array index per interface name
            var indexMap: [String: Int] = [:]

            while let addr = current {
                let name = String(cString: addr.pointee.ifa_name)
                let family = addr.pointee.ifa_addr.pointee.sa_family

                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    let entry = JSValue(newObjectIn: ctx)!
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let addrLen: socklen_t = family == UInt8(AF_INET6)
                        ? socklen_t(MemoryLayout<sockaddr_in6>.size)
                        : socklen_t(MemoryLayout<sockaddr_in>.size)

                    getnameinfo(addr.pointee.ifa_addr, addrLen,
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                    let address: String
                    if let nullIdx = host.firstIndex(of: 0) {
                        address = String(decoding: host[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    } else {
                        address = String(decoding: host.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }

                    entry.setValue(address, forProperty: "address")
                    entry.setValue(family == UInt8(AF_INET6) ? "IPv6" : "IPv4", forProperty: "family")
                    entry.setValue(family == UInt8(AF_INET6), forProperty: "internal")

                    // Netmask
                    if let netmask = addr.pointee.ifa_netmask {
                        var maskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(netmask, addrLen,
                                    &maskHost, socklen_t(maskHost.count),
                                    nil, 0, NI_NUMERICHOST)
                        let netmaskStr: String
                        if let nullIdx = maskHost.firstIndex(of: 0) {
                            netmaskStr = String(decoding: maskHost[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        } else {
                            netmaskStr = String(decoding: maskHost.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        }
                        entry.setValue(netmaskStr, forProperty: "netmask")
                    }

                    // MAC address (placeholder)
                    entry.setValue("00:00:00:00:00:00", forProperty: "mac")

                    // Internal flag: loopback detection
                    let isInternal = (addr.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) != 0
                    entry.setValue(isInternal, forProperty: "internal")

                    // CIDR prefix
                    if family == UInt8(AF_INET), let netmask = addr.pointee.ifa_netmask {
                        let sin = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        let bits = countBits(sin.sin_addr.s_addr)
                        entry.setValue("\(address)/\(bits)", forProperty: "cidr")
                    } else if family == UInt8(AF_INET6), let netmask = addr.pointee.ifa_netmask {
                        let sin6 = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                        var bits = 0
                        withUnsafeBytes(of: sin6.sin6_addr) { buf in
                            for byte in buf {
                                bits += countBits(UInt32(byte))
                            }
                        }
                        entry.setValue("\(address)/\(bits)", forProperty: "cidr")
                    }

                    // Get or create array for this interface
                    let arr: JSValue
                    if let existing = result.forProperty(name), !existing.isUndefined {
                        arr = existing
                    } else {
                        arr = JSValue(newArrayIn: ctx)!
                        result.setValue(arr, forProperty: name)
                        indexMap[name] = 0
                    }
                    let idx = indexMap[name] ?? 0
                    arr.setValue(entry, at: idx)
                    indexMap[name] = idx + 1
                }

                current = addr.pointee.ifa_next
            }
            #endif

            return result
        }
        os.setValue(unsafeBitCast(networkInterfaces, to: AnyObject.self), forProperty: "networkInterfaces")

        // os.userInfo()
        let userInfo: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            let obj = JSValue(newObjectIn: ctx)!
            obj.setValue(NSUserName(), forProperty: "username")
            obj.setValue(NSHomeDirectory(), forProperty: "homedir")
            obj.setValue(NSFullUserName(), forProperty: "shell")

            // Get uid/gid
            obj.setValue(Int(getuid()), forProperty: "uid")
            obj.setValue(Int(getgid()), forProperty: "gid")

            // Shell from environment
            if let shell = ProcessInfo.processInfo.environment["SHELL"] {
                obj.setValue(shell, forProperty: "shell")
            } else {
                obj.setValue("/bin/bash", forProperty: "shell")
            }

            return obj
        }
        os.setValue(unsafeBitCast(userInfo, to: AnyObject.self), forProperty: "userInfo")

        // os.constants
        installConstants(on: os, in: context)

        return os
    }

    // MARK: - Helpers

    /// Count set bits in a 32-bit value (for netmask prefix length).
    private static func countBits(_ value: UInt32) -> Int {
        var v = value
        var count = 0
        while v != 0 {
            count += Int(v & 1)
            v >>= 1
        }
        return count
    }

    /// Install os.constants (signals and errno).
    private static func installConstants(on os: JSValue, in context: JSContext) {
        let constants = JSValue(newObjectIn: context)!

        // Signal constants
        let signals = JSValue(newObjectIn: context)!
        signals.setValue(Int(SIGHUP), forProperty: "SIGHUP")
        signals.setValue(Int(SIGINT), forProperty: "SIGINT")
        signals.setValue(Int(SIGQUIT), forProperty: "SIGQUIT")
        signals.setValue(Int(SIGILL), forProperty: "SIGILL")
        signals.setValue(Int(SIGTRAP), forProperty: "SIGTRAP")
        signals.setValue(Int(SIGABRT), forProperty: "SIGABRT")
        signals.setValue(Int(SIGFPE), forProperty: "SIGFPE")
        signals.setValue(Int(SIGKILL), forProperty: "SIGKILL")
        signals.setValue(Int(SIGBUS), forProperty: "SIGBUS")
        signals.setValue(Int(SIGSEGV), forProperty: "SIGSEGV")
        signals.setValue(Int(SIGPIPE), forProperty: "SIGPIPE")
        signals.setValue(Int(SIGALRM), forProperty: "SIGALRM")
        signals.setValue(Int(SIGTERM), forProperty: "SIGTERM")
        signals.setValue(Int(SIGURG), forProperty: "SIGURG")
        signals.setValue(Int(SIGSTOP), forProperty: "SIGSTOP")
        signals.setValue(Int(SIGTSTP), forProperty: "SIGTSTP")
        signals.setValue(Int(SIGCONT), forProperty: "SIGCONT")
        signals.setValue(Int(SIGCHLD), forProperty: "SIGCHLD")
        signals.setValue(Int(SIGUSR1), forProperty: "SIGUSR1")
        signals.setValue(Int(SIGUSR2), forProperty: "SIGUSR2")
        constants.setValue(signals, forProperty: "signals")

        // Errno constants
        let errno_consts = JSValue(newObjectIn: context)!
        errno_consts.setValue(Int(EACCES), forProperty: "EACCES")
        errno_consts.setValue(Int(EADDRINUSE), forProperty: "EADDRINUSE")
        errno_consts.setValue(Int(ECONNREFUSED), forProperty: "ECONNREFUSED")
        errno_consts.setValue(Int(ECONNRESET), forProperty: "ECONNRESET")
        errno_consts.setValue(Int(EEXIST), forProperty: "EEXIST")
        errno_consts.setValue(Int(EISDIR), forProperty: "EISDIR")
        errno_consts.setValue(Int(EMFILE), forProperty: "EMFILE")
        errno_consts.setValue(Int(ENOENT), forProperty: "ENOENT")
        errno_consts.setValue(Int(ENOTDIR), forProperty: "ENOTDIR")
        errno_consts.setValue(Int(ENOTEMPTY), forProperty: "ENOTEMPTY")
        errno_consts.setValue(Int(EPERM), forProperty: "EPERM")
        errno_consts.setValue(Int(ETIMEDOUT), forProperty: "ETIMEDOUT")
        constants.setValue(errno_consts, forProperty: "errno")

        os.setValue(constants, forProperty: "constants")
    }
}
