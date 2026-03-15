import JavaScriptCore

/// Minimal stub for the Node.js `dns` module.
public struct DNSModule: NodeModule {
    public static let moduleName = "dns"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var dns = {};

            dns.lookup = function lookup(hostname, options, callback) {
                if (typeof options === 'function') {
                    callback = options;
                    options = {};
                }
                if (typeof callback === 'function') {
                    if (hostname === 'localhost' || hostname === '127.0.0.1') {
                        callback(null, '127.0.0.1', 4);
                    } else {
                        callback(null, '0.0.0.0', 4);
                    }
                }
            };

            dns.resolve = function resolve(hostname, rrtype, callback) {
                if (typeof rrtype === 'function') {
                    callback = rrtype;
                    rrtype = 'A';
                }
                if (typeof callback === 'function') {
                    callback(null, []);
                }
            };

            dns.promises = {};
            dns.promises.lookup = function lookup(hostname) {
                return Promise.resolve({ address: '127.0.0.1', family: 4 });
            };
            dns.promises.resolve = function resolve(hostname) {
                return Promise.resolve([]);
            };

            return dns;
        })();
        """
        return context.evaluateScript(script)!
    }
}
