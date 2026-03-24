@preconcurrency import JavaScriptCore
import Foundation
import dnssd

// MARK: - DNS query context and C callback (file-level for compiler compatibility)

private struct DNSQueryContext {
    var results: [[String: String]] = []
    var error: Int32 = 0
}

/// Parse a DNS compressed name from wire format data.
private func parseDNSNameFromWire(data: UnsafePointer<UInt8>, length: Int, offset: Int = 0) -> (name: String, bytesConsumed: Int) {
    var labels: [String] = []
    var pos = offset
    var bytesConsumed = 0
    var jumped = false

    while pos < length {
        let labelLen = Int(data[pos])
        if labelLen == 0 {
            if !jumped { bytesConsumed = pos - offset + 1 }
            break
        }
        if labelLen & 0xC0 == 0xC0 {
            if !jumped { bytesConsumed = pos - offset + 2 }
            let pointer = (Int(data[pos] & 0x3F) << 8) | Int(data[pos + 1])
            pos = pointer
            jumped = true
            continue
        }
        pos += 1
        if pos + labelLen > length { break }
        let label = String(bytes: Array(UnsafeBufferPointer(start: data + pos, count: labelLen)), encoding: .utf8) ?? ""
        labels.append(label)
        pos += labelLen
        if !jumped { bytesConsumed = pos - offset }
    }

    return (labels.joined(separator: "."), bytesConsumed)
}

private func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func dnsQueryCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ rrtype: UInt16,
    _ rrclass: UInt16,
    _ rdlen: UInt16,
    _ rdata: UnsafeRawPointer?,
    _ ttl: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = context else { return }
    let ctx = context.assumingMemoryBound(to: DNSQueryContext.self)

    if errorCode != kDNSServiceErr_NoError {
        ctx.pointee.error = errorCode
        return
    }

    guard let rdata = rdata, rdlen > 0 else { return }
    let dataPtr = rdata.assumingMemoryBound(to: UInt8.self)

    switch rrtype {
    case UInt16(kDNSServiceType_A):
        if rdlen >= 4 {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, rdata, &buf, socklen_t(INET_ADDRSTRLEN))
            let addr = stringFromCStringBuffer(buf)
            ctx.pointee.results.append(["type": "A", "value": addr])
        }

    case UInt16(kDNSServiceType_AAAA):
        if rdlen >= 16 {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, rdata, &buf, socklen_t(INET6_ADDRSTRLEN))
            let addr = stringFromCStringBuffer(buf)
            ctx.pointee.results.append(["type": "AAAA", "value": addr])
        }

    case UInt16(kDNSServiceType_MX):
        if rdlen >= 3 {
            let priority = (UInt16(dataPtr[0]) << 8) | UInt16(dataPtr[1])
            let (exchange, _) = parseDNSNameFromWire(data: dataPtr, length: Int(rdlen), offset: 2)
            ctx.pointee.results.append([
                "type": "MX", "priority": String(priority), "exchange": exchange
            ])
        }

    case UInt16(kDNSServiceType_TXT):
        var offset = 0
        var chunks: [String] = []
        while offset < Int(rdlen) {
            let len = Int(dataPtr[offset])
            offset += 1
            if offset + len <= Int(rdlen) {
                let str = String(bytes: Array(UnsafeBufferPointer(start: dataPtr + offset, count: len)),
                                encoding: .utf8) ?? ""
                chunks.append(str)
            }
            offset += len
        }
        ctx.pointee.results.append(["type": "TXT", "entries": chunks.joined(separator: "\u{0}")])

    case UInt16(kDNSServiceType_SRV):
        if rdlen >= 7 {
            let priority = (UInt16(dataPtr[0]) << 8) | UInt16(dataPtr[1])
            let weight = (UInt16(dataPtr[2]) << 8) | UInt16(dataPtr[3])
            let port = (UInt16(dataPtr[4]) << 8) | UInt16(dataPtr[5])
            let (target, _) = parseDNSNameFromWire(data: dataPtr, length: Int(rdlen), offset: 6)
            ctx.pointee.results.append([
                "type": "SRV", "priority": String(priority),
                "weight": String(weight), "port": String(port), "name": target
            ])
        }

    case UInt16(kDNSServiceType_NS),
         UInt16(kDNSServiceType_CNAME),
         UInt16(kDNSServiceType_PTR):
        let (name, _) = parseDNSNameFromWire(data: dataPtr, length: Int(rdlen))
        let typeLabel: String
        switch rrtype {
        case UInt16(kDNSServiceType_NS): typeLabel = "NS"
        case UInt16(kDNSServiceType_CNAME): typeLabel = "CNAME"
        default: typeLabel = "PTR"
        }
        ctx.pointee.results.append(["type": typeLabel, "value": name])

    case UInt16(kDNSServiceType_SOA):
        if rdlen > 20 {
            let (nsname, consumed1) = parseDNSNameFromWire(data: dataPtr, length: Int(rdlen))
            let (hostmaster, consumed2) = parseDNSNameFromWire(data: dataPtr, length: Int(rdlen), offset: consumed1)
            let numOffset = consumed1 + consumed2
            if numOffset + 20 <= Int(rdlen) {
                let p = dataPtr + numOffset
                let serial = (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
                let refresh = (UInt32(p[4]) << 24) | (UInt32(p[5]) << 16) | (UInt32(p[6]) << 8) | UInt32(p[7])
                let retry = (UInt32(p[8]) << 24) | (UInt32(p[9]) << 16) | (UInt32(p[10]) << 8) | UInt32(p[11])
                let expire = (UInt32(p[12]) << 24) | (UInt32(p[13]) << 16) | (UInt32(p[14]) << 8) | UInt32(p[15])
                let minttl = (UInt32(p[16]) << 24) | (UInt32(p[17]) << 16) | (UInt32(p[18]) << 8) | UInt32(p[19])
                ctx.pointee.results.append([
                    "type": "SOA", "nsname": nsname, "hostmaster": hostmaster,
                    "serial": String(serial), "refresh": String(refresh),
                    "retry": String(retry), "expire": String(expire), "minttl": String(minttl)
                ])
            }
        }

    default:
        break
    }
}

/// Full implementation of the Node.js `dns` module.
/// Uses POSIX `getaddrinfo`/`getnameinfo` for lookup/reverse and `dnssd` for resolve.
public struct DNSModule: NodeModule {
    public static let moduleName = "dns"

    // MARK: - getaddrinfo error mapping

    private static func mapGaiError(_ gaiCode: Int32) -> (code: String, message: String) {
        switch gaiCode {
        case EAI_NONAME:
            return ("ENOTFOUND", "getaddrinfo ENOTFOUND")
        case EAI_AGAIN:
            return ("EAGAIN", "getaddrinfo EAGAIN")
        #if canImport(Darwin)
        case EAI_BADHINTS:
            return ("EBADFAMILY", "getaddrinfo EBADFAMILY")
        #endif
        case EAI_SERVICE:
            return ("ENOTFOUND", "getaddrinfo ENOTFOUND")
        case EAI_FAMILY:
            return ("EBADFAMILY", "getaddrinfo EBADFAMILY")
        case EAI_MEMORY:
            return ("ENOMEM", "getaddrinfo ENOMEM")
        case EAI_FAIL:
            return ("ESERVFAIL", "getaddrinfo ESERVFAIL")
        default:
            let msg = String(cString: gai_strerror(gaiCode))
            return ("EAI_\(gaiCode)", "getaddrinfo \(msg)")
        }
    }

    // MARK: - Install

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        // ── Native: __dnsLookup(hostname, family, all, verbatim, callback) ──
        let lookupBlock: @convention(block) (NSString, Int, Bool, Bool, JSValue) -> Void = {
            hostname, family, all, verbatim, callback in

            let host = hostname as String
            let eventLoop = runtime.eventLoop
            eventLoop.retainHandle()

            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                switch family {
                case 4: hints.ai_family = AF_INET
                case 6: hints.ai_family = AF_INET6
                default: hints.ai_family = AF_UNSPEC
                }

                var res: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &res)

                if status != 0 {
                    let mapped = mapGaiError(status)
                    let errMsg = "\(mapped.message) \(host)"
                    let errCode = mapped.code
                    eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(errMsg, code: errCode, syscall: "getaddrinfo")
                        err.setValue(host, forProperty: "hostname")
                        callback.call(withArguments: [err])
                        eventLoop.releaseHandle()
                    }
                    return
                }

                defer { freeaddrinfo(res) }

                var addresses: [(address: String, family: Int)] = []
                var current = res
                while let info = current {
                    if info.pointee.ai_family == AF_INET {
                        var addr = sockaddr_in()
                        memcpy(&addr, info.pointee.ai_addr, Int(MemoryLayout<sockaddr_in>.size))
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var inAddr = addr.sin_addr
                        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                        addresses.append((stringFromCStringBuffer(buf), 4))
                    } else if info.pointee.ai_family == AF_INET6 {
                        var addr = sockaddr_in6()
                        memcpy(&addr, info.pointee.ai_addr, Int(MemoryLayout<sockaddr_in6>.size))
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        var in6Addr = addr.sin6_addr
                        inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                        addresses.append((stringFromCStringBuffer(buf), 6))
                    }
                    current = info.pointee.ai_next
                }

                if !verbatim {
                    addresses.sort { $0.family < $1.family }
                }

                // Extract Sendable data before enqueueCallback
                let addrList = addresses.map { (addr: $0.address, fam: $0.family) }
                eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    if addrList.isEmpty {
                        let err = ctx.createSystemError(
                            "getaddrinfo ENOTFOUND \(host)",
                            code: "ENOTFOUND", syscall: "getaddrinfo"
                        )
                        err.setValue(host, forProperty: "hostname")
                        callback.call(withArguments: [err])
                    } else if all {
                        let arr = JSValue(newArrayIn: ctx)!
                        for (i, r) in addrList.enumerated() {
                            let obj = JSValue(newObjectIn: ctx)!
                            obj.setValue(r.addr, forProperty: "address")
                            obj.setValue(r.fam, forProperty: "family")
                            arr.setValue(obj, at: i)
                        }
                        callback.call(withArguments: [JSValue(nullIn: ctx)!, arr])
                    } else {
                        let r = addrList[0]
                        callback.call(withArguments: [JSValue(nullIn: ctx)!, r.addr, r.fam])
                    }
                    eventLoop.releaseHandle()
                }
            }
        }
        context.setObject(unsafeBitCast(lookupBlock, to: AnyObject.self),
                         forKeyedSubscript: "__dnsLookup" as NSString)

        // ── Native: __dnsReverse(ip, callback) ──
        let reverseBlock: @convention(block) (NSString, JSValue) -> Void = { ip, callback in
            let ipStr = ip as String
            let eventLoop = runtime.eventLoop
            eventLoop.retainHandle()

            DispatchQueue.global(qos: .userInitiated).async {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var status: Int32 = 0

                if ipStr.contains(":") {
                    var addr6 = sockaddr_in6()
                    addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    addr6.sin6_family = sa_family_t(AF_INET6)
                    guard inet_pton(AF_INET6, ipStr, &addr6.sin6_addr) == 1 else {
                        eventLoop.enqueueCallback {
                            let ctx = runtime.context
                            let err = ctx.createSystemError(
                                "getnameinfo EINVAL \(ipStr)",
                                code: "EINVAL", syscall: "getnameinfo"
                            )
                            callback.call(withArguments: [err])
                            eventLoop.releaseHandle()
                        }
                        return
                    }
                    status = withUnsafePointer(to: &addr6) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST),
                                       nil, 0, NI_NAMEREQD)
                        }
                    }
                } else {
                    var addr4 = sockaddr_in()
                    addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr4.sin_family = sa_family_t(AF_INET)
                    guard inet_pton(AF_INET, ipStr, &addr4.sin_addr) == 1 else {
                        eventLoop.enqueueCallback {
                            let ctx = runtime.context
                            let err = ctx.createSystemError(
                                "getnameinfo EINVAL \(ipStr)",
                                code: "EINVAL", syscall: "getnameinfo"
                            )
                            callback.call(withArguments: [err])
                            eventLoop.releaseHandle()
                        }
                        return
                    }
                    status = withUnsafePointer(to: &addr4) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST),
                                       nil, 0, NI_NAMEREQD)
                        }
                    }
                }

                if status != 0 {
                    eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "getHostByAddr ENOTFOUND \(ipStr)",
                            code: "ENOTFOUND", syscall: "getHostByAddr"
                        )
                        err.setValue(ipStr, forProperty: "hostname")
                        callback.call(withArguments: [err])
                        eventLoop.releaseHandle()
                    }
                    return
                }

                let hostname = stringFromCStringBuffer(hostBuf)
                eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let arr = JSValue(newArrayIn: ctx)!
                    arr.setValue(hostname, at: 0)
                    callback.call(withArguments: [JSValue(nullIn: ctx)!, arr])
                    eventLoop.releaseHandle()
                }
            }
        }
        context.setObject(unsafeBitCast(reverseBlock, to: AnyObject.self),
                         forKeyedSubscript: "__dnsReverse" as NSString)

        // ── Native: __dnsLookupService(address, port, callback) ──
        let lookupServiceBlock: @convention(block) (NSString, Int, JSValue) -> Void = {
            address, port, callback in

            let addrStr = address as String
            let eventLoop = runtime.eventLoop
            eventLoop.retainHandle()

            DispatchQueue.global(qos: .userInitiated).async {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var servBuf = [CChar](repeating: 0, count: Int(NI_MAXSERV))
                var status: Int32 = 0

                if addrStr.contains(":") {
                    var addr6 = sockaddr_in6()
                    addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    addr6.sin6_family = sa_family_t(AF_INET6)
                    addr6.sin6_port = UInt16(port).bigEndian
                    inet_pton(AF_INET6, addrStr, &addr6.sin6_addr)
                    status = withUnsafePointer(to: &addr6) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST),
                                       &servBuf, socklen_t(NI_MAXSERV), 0)
                        }
                    }
                } else {
                    var addr4 = sockaddr_in()
                    addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr4.sin_family = sa_family_t(AF_INET)
                    addr4.sin_port = UInt16(port).bigEndian
                    inet_pton(AF_INET, addrStr, &addr4.sin_addr)
                    status = withUnsafePointer(to: &addr4) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                       &hostBuf, socklen_t(NI_MAXHOST),
                                       &servBuf, socklen_t(NI_MAXSERV), 0)
                        }
                    }
                }

                if status != 0 {
                    eventLoop.enqueueCallback {
                        let ctx = runtime.context
                        let err = ctx.createSystemError(
                            "getnameinfo ENOTFOUND \(addrStr)",
                            code: "ENOTFOUND", syscall: "getnameinfo"
                        )
                        callback.call(withArguments: [err])
                        eventLoop.releaseHandle()
                    }
                    return
                }

                let hostname = stringFromCStringBuffer(hostBuf)
                let service = stringFromCStringBuffer(servBuf)
                eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    callback.call(withArguments: [JSValue(nullIn: ctx)!, hostname, service])
                    eventLoop.releaseHandle()
                }
            }
        }
        context.setObject(unsafeBitCast(lookupServiceBlock, to: AnyObject.self),
                         forKeyedSubscript: "__dnsLookupService" as NSString)

        // ── Native: __dnsResolve(hostname, rrtype, callback) ──
        let resolveBlock: @convention(block) (NSString, NSString, JSValue) -> Void = {
            hostname, rrtype, callback in

            let host = hostname as String
            let typeStr = rrtype as String
            let eventLoop = runtime.eventLoop
            eventLoop.retainHandle()

            let recordType: UInt16
            switch typeStr {
            case "A":     recordType = UInt16(kDNSServiceType_A)
            case "AAAA":  recordType = UInt16(kDNSServiceType_AAAA)
            case "MX":    recordType = UInt16(kDNSServiceType_MX)
            case "TXT":   recordType = UInt16(kDNSServiceType_TXT)
            case "SRV":   recordType = UInt16(kDNSServiceType_SRV)
            case "NS":    recordType = UInt16(kDNSServiceType_NS)
            case "CNAME": recordType = UInt16(kDNSServiceType_CNAME)
            case "PTR":   recordType = UInt16(kDNSServiceType_PTR)
            case "SOA":   recordType = UInt16(kDNSServiceType_SOA)
            case "ANY":   recordType = UInt16(kDNSServiceType_ANY)
            default:
                eventLoop.enqueueCallback {
                    let ctx = runtime.context
                    let err = ctx.createError("queryType is not valid", code: "ERR_INVALID_ARG_VALUE")
                    callback.call(withArguments: [err])
                    eventLoop.releaseHandle()
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let (results, error) = executeDNSQuery(host: host, recordType: recordType)
                deliverDNSResults(
                    queryResults: results, queryError: error,
                    host: host, typeStr: typeStr,
                    callback: callback, eventLoop: eventLoop, runtime: runtime
                )
            }
        }
        context.setObject(unsafeBitCast(resolveBlock, to: AnyObject.self),
                         forKeyedSubscript: "__dnsResolve" as NSString)

        // ── Native: __dnsGetServers() ──
        let getServersBlock: @convention(block) () -> JSValue = {
            let ctx = JSContext.current()!
            let arr = JSValue(newArrayIn: ctx)!
            if let contents = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
                var idx = 0
                for line in contents.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("nameserver ") {
                        let server = trimmed.dropFirst("nameserver ".count)
                            .trimmingCharacters(in: .whitespaces)
                        if !server.isEmpty {
                            arr.setValue(server, at: idx)
                            idx += 1
                        }
                    }
                }
            }
            return arr
        }
        context.setObject(unsafeBitCast(getServersBlock, to: AnyObject.self),
                         forKeyedSubscript: "__dnsGetServers" as NSString)

        // ── JS wrapper ──
        let script = """
        (function() {
            var dns = {};
            var _servers = [];

            // ── Error code constants ──
            dns.NODATA = 'ENODATA';
            dns.FORMERR = 'EFORMERR';
            dns.SERVFAIL = 'ESERVFAIL';
            dns.NOTFOUND = 'ENOTFOUND';
            dns.NOTIMP = 'ENOTIMP';
            dns.REFUSED = 'EREFUSED';
            dns.BADQUERY = 'EBADQUERY';
            dns.BADNAME = 'EBADNAME';
            dns.BADFAMILY = 'EBADFAMILY';
            dns.BADRESP = 'EBADRESP';
            dns.CONNREFUSED = 'ECONNREFUSED';
            dns.TIMEOUT = 'ETIMEOUT';
            dns.EOF = 'EOF';
            dns.FILE = 'EFILE';
            dns.NOMEM = 'ENOMEM';
            dns.DESTRUCTION = 'EDESTRUCTION';
            dns.BADSTR = 'EBADSTR';
            dns.BADFLAGS = 'EBADFLAGS';
            dns.NONAME = 'ENONAME';
            dns.BADHINTS = 'EBADHINTS';
            dns.NOTINITIALIZED = 'ENOTINITIALIZED';
            dns.LOADIPHLPAPI = 'ELOADIPHLPAPI';
            dns.ADDRGETNETWORKPARAMS = 'EADDRGETNETWORKPARAMS';
            dns.CANCELLED = 'ECANCELLED';

            // ── Hint constants ──
            dns.ADDRCONFIG = 0x0400;
            dns.V4MAPPED = 0x0800;
            dns.ALL = 0x0100;

            // ── dns.lookup(hostname[, options], callback) ──
            dns.lookup = function lookup(hostname, options, callback) {
                if (typeof options === 'function') {
                    callback = options;
                    options = {};
                }
                if (typeof options === 'number') {
                    options = { family: options };
                }
                if (!options) options = {};
                var family = options.family || 0;
                var all = !!options.all;
                var verbatim = options.verbatim !== undefined ? !!options.verbatim : false;
                if (typeof callback !== 'function') {
                    throw new TypeError('callback must be a function');
                }
                __dnsLookup(hostname, family, all, verbatim, callback);
            };

            // ── dns.resolve(hostname[, rrtype], callback) ──
            dns.resolve = function resolve(hostname, rrtype, callback) {
                if (typeof rrtype === 'function') {
                    callback = rrtype;
                    rrtype = 'A';
                }
                if (typeof callback !== 'function') {
                    throw new TypeError('callback must be a function');
                }
                __dnsResolve(hostname, rrtype, callback);
            };

            // ── Shortcut resolve methods ──
            dns.resolve4 = function resolve4(hostname, options, callback) {
                if (typeof options === 'function') { callback = options; options = {}; }
                dns.resolve(hostname, 'A', function(err, records) {
                    if (err) return callback(err);
                    callback(null, records);
                });
            };

            dns.resolve6 = function resolve6(hostname, options, callback) {
                if (typeof options === 'function') { callback = options; options = {}; }
                dns.resolve(hostname, 'AAAA', function(err, records) {
                    if (err) return callback(err);
                    callback(null, records);
                });
            };

            dns.resolveMx = function resolveMx(hostname, callback) {
                dns.resolve(hostname, 'MX', callback);
            };

            dns.resolveTxt = function resolveTxt(hostname, callback) {
                dns.resolve(hostname, 'TXT', callback);
            };

            dns.resolveSrv = function resolveSrv(hostname, callback) {
                dns.resolve(hostname, 'SRV', callback);
            };

            dns.resolveNs = function resolveNs(hostname, callback) {
                dns.resolve(hostname, 'NS', callback);
            };

            dns.resolveCname = function resolveCname(hostname, callback) {
                dns.resolve(hostname, 'CNAME', callback);
            };

            dns.resolvePtr = function resolvePtr(hostname, callback) {
                dns.resolve(hostname, 'PTR', callback);
            };

            dns.resolveSoa = function resolveSoa(hostname, callback) {
                dns.resolve(hostname, 'SOA', callback);
            };

            dns.resolveAny = function resolveAny(hostname, callback) {
                dns.resolve(hostname, 'ANY', callback);
            };

            // ── dns.reverse(ip, callback) ──
            dns.reverse = function reverse(ip, callback) {
                if (typeof callback !== 'function') {
                    throw new TypeError('callback must be a function');
                }
                __dnsReverse(ip, callback);
            };

            // ── dns.lookupService(address, port, callback) ──
            dns.lookupService = function lookupService(address, port, callback) {
                if (typeof callback !== 'function') {
                    throw new TypeError('callback must be a function');
                }
                __dnsLookupService(address, port, callback);
            };

            // ── dns.getServers() / dns.setServers() ──
            dns.getServers = function getServers() {
                if (_servers.length > 0) return _servers.slice();
                var result = __dnsGetServers();
                return Array.isArray(result) ? result : [];
            };

            dns.setServers = function setServers(servers) {
                if (!Array.isArray(servers)) {
                    throw new TypeError('servers must be an array');
                }
                _servers = servers.slice();
            };

            // ── Resolver class ──
            function Resolver() {
                this._servers = [];
            }
            Resolver.prototype.resolve = dns.resolve;
            Resolver.prototype.resolve4 = dns.resolve4;
            Resolver.prototype.resolve6 = dns.resolve6;
            Resolver.prototype.resolveMx = dns.resolveMx;
            Resolver.prototype.resolveTxt = dns.resolveTxt;
            Resolver.prototype.resolveSrv = dns.resolveSrv;
            Resolver.prototype.resolveNs = dns.resolveNs;
            Resolver.prototype.resolveCname = dns.resolveCname;
            Resolver.prototype.resolvePtr = dns.resolvePtr;
            Resolver.prototype.resolveSoa = dns.resolveSoa;
            Resolver.prototype.resolveAny = dns.resolveAny;
            Resolver.prototype.reverse = dns.reverse;
            Resolver.prototype.getServers = function() {
                if (this._servers.length > 0) return this._servers.slice();
                return dns.getServers();
            };
            Resolver.prototype.setServers = function(servers) {
                this._servers = servers.slice();
            };
            Resolver.prototype.cancel = function() {};
            dns.Resolver = Resolver;

            // ── dns.promises ──
            dns.promises = {};

            dns.promises.lookup = function(hostname, options) {
                return new Promise(function(resolve, reject) {
                    var opts = options || {};
                    if (typeof opts === 'number') opts = { family: opts };
                    dns.lookup(hostname, opts, function(err, address, family) {
                        if (err) return reject(err);
                        if (opts.all) {
                            resolve(address);
                        } else {
                            resolve({ address: address, family: family });
                        }
                    });
                });
            };

            dns.promises.resolve = function(hostname, rrtype) {
                return new Promise(function(resolve, reject) {
                    dns.resolve(hostname, rrtype || 'A', function(err, records) {
                        if (err) return reject(err);
                        resolve(records);
                    });
                });
            };

            dns.promises.resolve4 = function(hostname, options) {
                return new Promise(function(resolve, reject) {
                    dns.resolve4(hostname, options || {}, function(err, records) {
                        if (err) return reject(err);
                        resolve(records);
                    });
                });
            };

            dns.promises.resolve6 = function(hostname, options) {
                return new Promise(function(resolve, reject) {
                    dns.resolve6(hostname, options || {}, function(err, records) {
                        if (err) return reject(err);
                        resolve(records);
                    });
                });
            };

            dns.promises.resolveMx = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveMx(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveTxt = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveTxt(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveSrv = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveSrv(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveNs = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveNs(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveCname = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveCname(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolvePtr = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolvePtr(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveSoa = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveSoa(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.resolveAny = function(hostname) {
                return new Promise(function(resolve, reject) {
                    dns.resolveAny(hostname, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.reverse = function(ip) {
                return new Promise(function(resolve, reject) {
                    dns.reverse(ip, function(err, r) { err ? reject(err) : resolve(r); });
                });
            };

            dns.promises.lookupService = function(address, port) {
                return new Promise(function(resolve, reject) {
                    dns.lookupService(address, port, function(err, hostname, service) {
                        if (err) return reject(err);
                        resolve({ hostname: hostname, service: service });
                    });
                });
            };

            dns.promises.getServers = dns.getServers;
            dns.promises.setServers = dns.setServers;
            dns.promises.Resolver = Resolver;

            return dns;
        })();
        """
        return context.evaluateScript(script)!
    }

    // MARK: - DNS Query via dnssd

    /// Execute a DNS query synchronously (called on a background thread).
    /// Returns (results, errorCode). If errorCode < 0, it's a service creation error.
    private static func executeDNSQuery(
        host: String,
        recordType: UInt16
    ) -> (results: [[String: String]], error: Int32) {
        var sdRef: DNSServiceRef?
        let ctx = UnsafeMutablePointer<DNSQueryContext>.allocate(capacity: 1)
        ctx.initialize(to: DNSQueryContext())

        let err = DNSServiceQueryRecord(
            &sdRef, kDNSServiceFlagsTimeout, 0,
            host, recordType, UInt16(kDNSServiceClass_IN),
            dnsQueryCallback, ctx
        )

        if err != kDNSServiceErr_NoError {
            let result = ctx.pointee
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            return (result.results, -1)
        }

        let fd = DNSServiceRefSockFD(sdRef!)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, 5000)

        if pollResult > 0 {
            DNSServiceProcessResult(sdRef!)
        }

        DNSServiceRefDeallocate(sdRef!)

        let result = ctx.pointee
        ctx.deinitialize(count: 1)
        ctx.deallocate()
        return (result.results, result.error)
    }

    /// Convert DNS query results to JSValue and deliver via callback on the JS thread.
    private static func deliverDNSResults(
        queryResults: [[String: String]],
        queryError: Int32,
        host: String,
        typeStr: String,
        callback: JSValue,
        eventLoop: EventLoop,
        runtime: NodeRuntime
    ) {
        // Service creation failure
        if queryError < 0 {
            eventLoop.enqueueCallback {
                let ctx = runtime.context
                let jsErr = ctx.createSystemError(
                    "query\(typeStr) ESERVFAIL \(host)",
                    code: "ESERVFAIL", syscall: "query\(typeStr)"
                )
                jsErr.setValue(host, forProperty: "hostname")
                callback.call(withArguments: [jsErr])
                eventLoop.releaseHandle()
            }
            return
        }

        // DNS error
        if queryError != 0 {
            eventLoop.enqueueCallback {
                let ctx = runtime.context
                let jsErr = ctx.createSystemError(
                    "query\(typeStr) ENOTFOUND \(host)",
                    code: "ENOTFOUND", syscall: "query\(typeStr)"
                )
                jsErr.setValue(host, forProperty: "hostname")
                callback.call(withArguments: [jsErr])
                eventLoop.releaseHandle()
            }
            return
        }

        eventLoop.enqueueCallback {
            let ctx = runtime.context
            let jsResults: JSValue

            switch typeStr {
            case "A", "AAAA":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    arr.setValue(r["value"], at: i)
                }
                jsResults = arr

            case "MX":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    let obj = JSValue(newObjectIn: ctx)!
                    obj.setValue(Int(r["priority"] ?? "0") ?? 0, forProperty: "priority")
                    obj.setValue(r["exchange"], forProperty: "exchange")
                    arr.setValue(obj, at: i)
                }
                jsResults = arr

            case "TXT":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    let entries = (r["entries"] ?? "").components(separatedBy: "\u{0}")
                    let inner = JSValue(newArrayIn: ctx)!
                    for (j, e) in entries.enumerated() {
                        inner.setValue(e, at: j)
                    }
                    arr.setValue(inner, at: i)
                }
                jsResults = arr

            case "SRV":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    let obj = JSValue(newObjectIn: ctx)!
                    obj.setValue(Int(r["priority"] ?? "0") ?? 0, forProperty: "priority")
                    obj.setValue(Int(r["weight"] ?? "0") ?? 0, forProperty: "weight")
                    obj.setValue(Int(r["port"] ?? "0") ?? 0, forProperty: "port")
                    obj.setValue(r["name"], forProperty: "name")
                    arr.setValue(obj, at: i)
                }
                jsResults = arr

            case "NS", "CNAME", "PTR":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    arr.setValue(r["value"], at: i)
                }
                jsResults = arr

            case "SOA":
                if let r = queryResults.first {
                    let obj = JSValue(newObjectIn: ctx)!
                    obj.setValue(r["nsname"], forProperty: "nsname")
                    obj.setValue(r["hostmaster"], forProperty: "hostmaster")
                    obj.setValue(Int(r["serial"] ?? "0") ?? 0, forProperty: "serial")
                    obj.setValue(Int(r["refresh"] ?? "0") ?? 0, forProperty: "refresh")
                    obj.setValue(Int(r["retry"] ?? "0") ?? 0, forProperty: "retry")
                    obj.setValue(Int(r["expire"] ?? "0") ?? 0, forProperty: "expire")
                    obj.setValue(Int(r["minttl"] ?? "0") ?? 0, forProperty: "minttl")
                    jsResults = obj
                } else {
                    let jsErr = ctx.createSystemError(
                        "querySOA ENOTFOUND \(host)",
                        code: "ENOTFOUND", syscall: "querySOA"
                    )
                    jsErr.setValue(host, forProperty: "hostname")
                    callback.call(withArguments: [jsErr])
                    eventLoop.releaseHandle()
                    return
                }

            case "ANY":
                let arr = JSValue(newArrayIn: ctx)!
                for (i, r) in queryResults.enumerated() {
                    let obj = JSValue(newObjectIn: ctx)!
                    for (key, value) in r {
                        if key == "priority" || key == "weight" || key == "port" ||
                           key == "serial" || key == "refresh" || key == "retry" ||
                           key == "expire" || key == "minttl" {
                            obj.setValue(Int(value) ?? 0, forProperty: key)
                        } else {
                            obj.setValue(value, forProperty: key)
                        }
                    }
                    arr.setValue(obj, at: i)
                }
                jsResults = arr

            default:
                jsResults = JSValue(newArrayIn: ctx)!
            }

            callback.call(withArguments: [JSValue(nullIn: ctx)!, jsResults])
            eventLoop.releaseHandle()
        }
    }
}
