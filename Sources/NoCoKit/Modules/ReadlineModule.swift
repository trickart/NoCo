import Foundation
import JavaScriptCore

/// Implements the Node.js `readline` module.
public struct ReadlineModule: NodeModule {
    public static let moduleName = "readline"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let readline = context.evaluateScript("""
        (function(EventEmitter) {

            class Interface extends EventEmitter {
                constructor(options) {
                    super();

                    // Handle createInterface(input, output) two-arg form
                    if (options && typeof options.on === 'function' && !options.input) {
                        options = { input: options };
                    }
                    options = options || {};

                    this.input = options.input || null;
                    this.output = options.output || null;
                    this.terminal = options.terminal !== undefined ? options.terminal : false;
                    this._prompt = options.prompt !== undefined ? options.prompt : '> ';
                    this._closed = false;
                    this._lineBuffer = '';
                    this._questionCallback = null;

                    var self = this;

                    if (this.input) {
                        if (this.input === process.stdin) {
                            // Use native stdin reading
                            if (typeof __NoCo_startStdinReading === 'function') {
                                __NoCo_startStdinReading(function(data) {
                                    if (data === null) {
                                        self.close();
                                        return;
                                    }
                                    self._processData(data);
                                });
                            }
                        } else if (typeof this.input.on === 'function') {
                            // Custom EventEmitter input
                            this.input.on('data', function(data) {
                                if (self._closed) return;
                                var str = typeof data === 'string' ? data : data.toString();
                                self._processData(str);
                            });
                            this.input.on('end', function() {
                                if (!self._closed) self.close();
                            });
                        }
                    }
                }

                _processData(data) {
                    this._lineBuffer += data;
                    var lines = this._lineBuffer.split('\\n');
                    // Keep the last incomplete piece in the buffer
                    this._lineBuffer = lines.pop() || '';
                    for (var i = 0; i < lines.length; i++) {
                        this._onLine(lines[i]);
                    }
                }

                _onLine(line) {
                    // Remove trailing \\r for CRLF
                    if (line.length > 0 && line.charCodeAt(line.length - 1) === 13) {
                        line = line.slice(0, -1);
                    }
                    if (this._questionCallback) {
                        var cb = this._questionCallback;
                        this._questionCallback = null;
                        cb(line);
                    }
                    this.emit('line', line);
                }

                question(query, options, callback) {
                    if (typeof options === 'function') {
                        callback = options;
                        options = {};
                    }
                    if (this.output && typeof this.output.write === 'function') {
                        this.output.write(query);
                    }
                    this._questionCallback = callback || null;
                }

                close() {
                    if (this._closed) return;
                    this._closed = true;
                    // Flush remaining buffer as last line
                    if (this._lineBuffer.length > 0) {
                        this._onLine(this._lineBuffer);
                        this._lineBuffer = '';
                    }
                    this.emit('close');
                }

                prompt(preserveCursor) {
                    if (this.output && typeof this.output.write === 'function') {
                        this.output.write(this._prompt);
                    }
                }

                setPrompt(prompt) {
                    this._prompt = prompt;
                }

                pause() {
                    this.emit('pause');
                    return this;
                }

                resume() {
                    this.emit('resume');
                    return this;
                }

                write(data, key) {
                    // stub for compatibility
                }

                [Symbol.asyncIterator]() {
                    var self = this;
                    var buffer = [];
                    var resolve = null;
                    var done = false;

                    self.on('line', function(line) {
                        if (resolve) {
                            var r = resolve;
                            resolve = null;
                            r({ value: line, done: false });
                        } else {
                            buffer.push(line);
                        }
                    });
                    self.on('close', function() {
                        done = true;
                        if (resolve) {
                            var r = resolve;
                            resolve = null;
                            r({ value: undefined, done: true });
                        }
                    });

                    return {
                        next: function() {
                            if (buffer.length > 0) {
                                return Promise.resolve({ value: buffer.shift(), done: false });
                            }
                            if (done) {
                                return Promise.resolve({ value: undefined, done: true });
                            }
                            return new Promise(function(r) { resolve = r; });
                        }
                    };
                }
            }

            function createInterface(inputOrOptions, output, completer, terminal) {
                var opts;
                if (inputOrOptions && typeof inputOrOptions === 'object' && !inputOrOptions.on) {
                    opts = inputOrOptions;
                } else {
                    opts = {
                        input: inputOrOptions,
                        output: output,
                        completer: completer,
                        terminal: terminal
                    };
                }
                return new Interface(opts);
            }

            // promises API
            class PromiseInterface extends Interface {
                question(query, options) {
                    var self = this;
                    if (typeof options === 'function') {
                        // fallback to callback style
                        return super.question(query, options);
                    }
                    return new Promise(function(resolve) {
                        Interface.prototype.question.call(self, query, options || {}, function(answer) {
                            resolve(answer);
                        });
                    });
                }
            }

            var promises = {
                createInterface: function(options) {
                    return new PromiseInterface(options);
                }
            };

            var mod = {
                createInterface: createInterface,
                Interface: Interface,
                promises: promises,
                clearLine: function() {},
                clearScreenDown: function() {},
                cursorTo: function() {},
                moveCursor: function() {},
                emitKeypressEvents: function() {}
            };
            return mod;
        })
        """)!.call(withArguments: [context.objectForKeyedSubscript("__NoCo_EventEmitter")!])!

        return readline
    }
}
