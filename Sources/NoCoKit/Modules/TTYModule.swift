import Foundation
import JavaScriptCore

/// Implements the Node.js `tty` module.
public struct TTYModule: NodeModule {
    public static let moduleName = "tty"

    private static func getTerminalSize() -> (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 && ws.ws_col > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let tty = JSValue(newObjectIn: context)!

        // tty.isatty(fd)
        let isattyFn: @convention(block) (JSValue) -> Bool = { fdVal in
            guard fdVal.isNumber else { return false }
            let fd = fdVal.toInt32()
            guard fd >= 0 else { return false }
            return Darwin.isatty(fd) != 0
        }
        tty.setValue(unsafeBitCast(isattyFn, to: AnyObject.self), forProperty: "isatty")

        // tty.ReadStream and tty.WriteStream as JS constructors
        let size = getTerminalSize()
        let columns = size.columns
        let rows = size.rows

        context.evaluateScript("""
            (function(tty, columns, rows) {
                function ReadStream(fd) {
                    this.fd = fd;
                    this.isTTY = true;
                    this.isRaw = false;
                }
                ReadStream.prototype.setRawMode = function(mode) {
                    this.isRaw = !!mode;
                    return this;
                };

                function WriteStream(fd) {
                    this.fd = fd;
                    this.isTTY = true;
                    this.columns = columns;
                    this.rows = rows;
                }
                WriteStream.prototype.getWindowSize = function() {
                    return [this.columns, this.rows];
                };
                WriteStream.prototype.getColorDepth = function(env) {
                    var e = env || (typeof process !== 'undefined' ? process.env : {}) || {};
                    if (e.NO_COLOR !== undefined) return 1;
                    if (e.FORCE_COLOR !== undefined) {
                        var fc = e.FORCE_COLOR;
                        if (fc === '0' || fc === 'false') return 1;
                        if (fc === '1' || fc === 'true' || fc === '') return 4;
                        if (fc === '2') return 8;
                        if (fc === '3') return 24;
                        return 4;
                    }
                    var term = e.TERM || '';
                    var colorterm = e.COLORTERM || '';
                    if (colorterm === 'truecolor' || colorterm === '24bit') return 24;
                    if (term === 'xterm-256color' || term === 'screen-256color') return 8;
                    if (colorterm) return 4;
                    if (term && term !== 'dumb') return 4;
                    return 1;
                };
                WriteStream.prototype.hasColors = function(count, env) {
                    if (typeof count === 'object' && count !== null) {
                        env = count;
                        count = 16;
                    }
                    if (count === undefined) count = 16;
                    var depth = this.getColorDepth(env);
                    return Math.pow(2, depth) >= count;
                };

                tty.ReadStream = ReadStream;
                tty.WriteStream = WriteStream;
            })
        """)!.call(withArguments: [tty, columns, rows])

        return tty
    }
}
