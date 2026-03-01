import JavaScriptCore

/// Implements basic Node.js Readable and Writable streams (pure JS, EventEmitter-based).
public struct StreamModule: NodeModule {
    public static let moduleName = "stream"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function(EventEmitter) {
            if (!EventEmitter) EventEmitter = (function() {
                // Minimal fallback if EventEmitter wasn't installed yet
                class EE {
                    constructor() { this._events = {}; }
                    on(e,f) { (this._events[e]=this._events[e]||[]).push(f); return this; }
                    emit(e) {
                        const a = Array.prototype.slice.call(arguments, 1);
                        (this._events[e]||[]).forEach(function(f){f.apply(this,a);}.bind(this));
                        return (this._events[e]||[]).length > 0;
                    }
                    once(e,f) { f._once=true; return this.on(e,f); }
                    removeListener(e,f) {
                        const l=this._events[e]; if(l){const i=l.indexOf(f);if(i!==-1)l.splice(i,1);}
                        return this;
                    }
                    off(e,f) { return this.removeListener(e,f); }
                    removeAllListeners(e) { if(e)delete this._events[e];else this._events={}; return this; }
                    listeners(e) { return (this._events[e]||[]).slice(); }
                    listenerCount(e) { return (this._events[e]||[]).length; }
                    eventNames() { return Object.keys(this._events); }
                }
                return EE;
            })();

            // Plain function constructor for Stream base class (supports .call() pattern)
            function Stream(options) {
                if (!(this instanceof Stream)) {
                    return new Stream(options);
                }
                // Initialize EventEmitter properties directly (can't call ES6 class constructor)
                this._events = Object.create(null);
                this._maxListeners = EventEmitter.defaultMaxListeners;
                this.readable = false;
                this.writable = false;
            }
            Stream.prototype = Object.create(EventEmitter.prototype);
            Stream.prototype.constructor = Stream;
            Stream.prototype.pipe = function(dest, options) {
                var source = this;
                function onData(chunk) { dest.write(chunk); }
                source.on('data', onData);
                source.on('end', function() {
                    if (!options || options.end !== false) { dest.end(); }
                });
                dest.emit('pipe', source);
                return dest;
            };

            class Readable extends EventEmitter {
                constructor(options) {
                    super();
                    this.readable = true;
                    this._readableState = {
                        buffer: [],
                        ended: false,
                        flowing: null,
                        encoding: null
                    };
                    if (options && options.read) {
                        this._read = options.read;
                    }
                }

                read(size) {
                    const state = this._readableState;
                    if (state.buffer.length === 0) {
                        if (state.ended) return null;
                        return null;
                    }
                    const chunk = state.buffer.shift();
                    if (state.buffer.length === 0 && state.ended) {
                        const self = this;
                        setTimeout(function() { self.emit('end'); }, 0);
                    }
                    return chunk;
                }

                push(chunk) {
                    if (chunk === null) {
                        this._readableState.ended = true;
                        if (this._readableState.buffer.length === 0) {
                            const self = this;
                            setTimeout(function() { self.emit('end'); }, 0);
                        }
                        return false;
                    }
                    this._readableState.buffer.push(chunk);
                    this.emit('data', chunk);
                    return true;
                }

                setEncoding(encoding) {
                    this._readableState.encoding = encoding;
                    return this;
                }

                pipe(destination, options) {
                    const source = this;
                    function onData(chunk) {
                        destination.write(chunk);
                    }
                    source.on('data', onData);
                    source.on('end', function() {
                        if (!options || options.end !== false) {
                            destination.end();
                        }
                    });
                    destination.emit('pipe', source);
                    return destination;
                }

                unpipe(destination) {
                    this.removeAllListeners('data');
                    return this;
                }

                resume() {
                    this._readableState.flowing = true;
                    return this;
                }

                pause() {
                    this._readableState.flowing = false;
                    return this;
                }

                destroy(err) {
                    this._readableState.ended = true;
                    this._readableState.buffer = [];
                    if (err) this.emit('error', err);
                    this.emit('close');
                    return this;
                }

                _read(size) {
                    // Override in subclass
                }

                [Symbol.asyncIterator]() {
                    const stream = this;
                    const buffer = [];
                    let done = false;
                    let resolve = null;

                    stream.on('data', function(chunk) {
                        if (resolve) {
                            const r = resolve;
                            resolve = null;
                            r({ value: chunk, done: false });
                        } else {
                            buffer.push(chunk);
                        }
                    });

                    stream.on('end', function() {
                        done = true;
                        if (resolve) {
                            const r = resolve;
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

            class Writable extends EventEmitter {
                constructor(options) {
                    super();
                    this.writable = true;
                    this._writableState = {
                        ended: false,
                        finished: false
                    };
                    if (options && options.write) {
                        this._write = options.write;
                    }
                }

                write(chunk, encoding, callback) {
                    if (typeof encoding === 'function') {
                        callback = encoding;
                        encoding = 'utf8';
                    }
                    if (this._writableState.ended) {
                        const err = new Error('write after end');
                        if (callback) callback(err);
                        this.emit('error', err);
                        return false;
                    }
                    if (this._write) {
                        this._write(chunk, encoding || 'utf8', callback || function(){});
                    } else if (callback) {
                        callback();
                    }
                    return true;
                }

                end(chunk, encoding, callback) {
                    if (typeof chunk === 'function') {
                        callback = chunk;
                        chunk = null;
                    }
                    if (typeof encoding === 'function') {
                        callback = encoding;
                        encoding = null;
                    }
                    if (chunk !== null && chunk !== undefined) {
                        this.write(chunk, encoding);
                    }
                    this._writableState.ended = true;
                    this._writableState.finished = true;
                    this.emit('finish');
                    if (callback) callback();
                    return this;
                }

                destroy(err) {
                    this._writableState.ended = true;
                    if (err) this.emit('error', err);
                    this.emit('close');
                    return this;
                }

                _write(chunk, encoding, callback) {
                    callback();
                }
            }

            class Duplex extends Readable {
                constructor(options) {
                    super(options);
                    this.writable = true;
                    this._writableState = {
                        ended: false,
                        finished: false
                    };
                    if (options && options.write) {
                        this._write = options.write;
                    }
                }
            }
            // Mixin Writable methods
            Duplex.prototype.write = Writable.prototype.write;
            Duplex.prototype.end = Writable.prototype.end;
            Duplex.prototype._write = Writable.prototype._write;

            class Transform extends Duplex {
                constructor(options) {
                    super(options);
                    if (options && options.transform) {
                        this._transform = options.transform;
                    }
                    if (options && options.flush) {
                        this._flush = options.flush;
                    }
                    if (options && options.construct) {
                        options.construct.call(this, function(err) {
                            if (err) this.destroy(err);
                        }.bind(this));
                    }
                }

                _transform(chunk, encoding, callback) {
                    this.push(chunk);
                    callback();
                }

                _write(chunk, encoding, callback) {
                    this._transform(chunk, encoding, function(err, data) {
                        if (data !== undefined) this.push(data);
                        callback(err);
                    }.bind(this));
                }
            }

            Transform.prototype.end = function(chunk, encoding, callback) {
                if (typeof chunk === 'function') { callback = chunk; chunk = null; }
                if (typeof encoding === 'function') { callback = encoding; encoding = null; }
                if (chunk !== null && chunk !== undefined) { this.write(chunk, encoding); }
                this._writableState.ended = true;
                var self = this;
                if (this._flush) {
                    this._flush(function(err) {
                        self._writableState.finished = true;
                        self.emit('finish');
                        if (callback) callback(err);
                    });
                } else {
                    this._writableState.finished = true;
                    this.emit('finish');
                    if (callback) callback();
                }
                return this;
            };

            class PassThrough extends Transform {
                _transform(chunk, encoding, callback) {
                    this.push(chunk);
                    callback();
                }
            }

            // Readable.toWeb() - converts a Node.js Readable to a Web ReadableStream
            Readable.toWeb = function(readable) {
                return new ReadableStream({
                    start: function(controller) {
                        readable.on('data', function(chunk) {
                            controller.enqueue(chunk);
                        });
                        readable.on('end', function() {
                            controller.close();
                        });
                        readable.on('error', function(err) {
                            controller.error(err);
                        });
                    }
                });
            };

            // Node.js: require('stream') returns Stream itself, with subclasses as properties
            Stream.Readable = Readable;
            Stream.Writable = Writable;
            Stream.Duplex = Duplex;
            Stream.Transform = Transform;
            Stream.PassThrough = PassThrough;
            Stream.Stream = Stream;
            return Stream;
        })(this.__NoCo_EventEmitter);
        """

        let exports = context.evaluateScript(script)!
        return exports
    }
}
