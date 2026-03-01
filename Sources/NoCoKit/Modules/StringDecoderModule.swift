import JavaScriptCore

/// Implements Node.js `string_decoder` built-in module.
/// Provides StringDecoder class that decodes Buffer objects into strings.
public struct StringDecoderModule: NodeModule {
    public static let moduleName = "string_decoder"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            function StringDecoder(encoding) {
                this.encoding = (encoding || 'utf8').toLowerCase();
                if (this.encoding === 'utf-8') this.encoding = 'utf8';
            }

            StringDecoder.prototype.write = function(buf) {
                if (!buf || (typeof buf.length !== 'undefined' && buf.length === 0)) return '';
                if (typeof buf === 'string') return buf;
                if (typeof buf.toString === 'function') return buf.toString(this.encoding);
                return String(buf);
            };

            StringDecoder.prototype.end = function(buf) {
                if (buf && (typeof buf.length === 'undefined' || buf.length > 0)) {
                    return this.write(buf);
                }
                return '';
            };

            return { StringDecoder: StringDecoder };
        })();
        """

        let exports = context.evaluateScript(script)!
        return exports
    }
}
