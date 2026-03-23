import JavaScriptCore

/// Implements Node.js EventEmitter as a pure JavaScript class.
public struct EventEmitterModule: NodeModule {
    public static let moduleName = "events"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            'use strict';

            class EventEmitter {
                constructor() {
                    this._events = Object.create(null);
                    this._maxListeners = EventEmitter.defaultMaxListeners;
                }

                // Lazy initialization for mixin pattern (e.g. Express copies methods without calling constructor)
                _initEvents() {
                    if (!this._events) this._events = Object.create(null);
                    if (this._maxListeners === undefined) this._maxListeners = EventEmitter.defaultMaxListeners;
                }

                static get defaultMaxListeners() {
                    return EventEmitter._defaultMaxListeners || 10;
                }

                static set defaultMaxListeners(n) {
                    EventEmitter._defaultMaxListeners = n;
                }

                setMaxListeners(n) {
                    this._initEvents();
                    this._maxListeners = n;
                    return this;
                }

                getMaxListeners() {
                    this._initEvents();
                    return this._maxListeners;
                }

                emit(event) {
                    this._initEvents();
                    const listeners = this._events[event];
                    if (!listeners || listeners.length === 0) {
                        if (event === 'error') {
                            const args = Array.prototype.slice.call(arguments, 1);
                            const err = args[0] || new Error('Unhandled error.');
                            throw err;
                        }
                        return false;
                    }

                    const args = Array.prototype.slice.call(arguments, 1);
                    const copy = listeners.slice();
                    for (let i = 0; i < copy.length; i++) {
                        const listener = copy[i];
                        if (listener._once) {
                            this.removeListener(event, listener);
                        }
                        listener.apply(this, args);
                    }
                    return true;
                }

                on(event, listener) {
                    return this.addListener(event, listener);
                }

                addListener(event, listener) {
                    this._initEvents();
                    if (typeof listener !== 'function') {
                        throw new TypeError('The "listener" argument must be of type Function.');
                    }
                    if (!this._events[event]) {
                        this._events[event] = [];
                    }
                    this._events[event].push(listener);

                    if (event !== 'newListener') {
                        this.emit('newListener', event, listener);
                    }

                    return this;
                }

                once(event, listener) {
                    if (typeof listener !== 'function') {
                        throw new TypeError('The "listener" argument must be of type Function.');
                    }
                    listener._once = true;
                    return this.addListener(event, listener);
                }

                removeListener(event, listener) {
                    this._initEvents();
                    const listeners = this._events[event];
                    if (!listeners) return this;

                    const index = listeners.indexOf(listener);
                    if (index !== -1) {
                        listeners.splice(index, 1);
                        if (listeners.length === 0) {
                            delete this._events[event];
                        }
                        this.emit('removeListener', event, listener);
                    }
                    return this;
                }

                off(event, listener) {
                    return this.removeListener(event, listener);
                }

                removeAllListeners(event) {
                    this._initEvents();
                    if (event !== undefined) {
                        delete this._events[event];
                    } else {
                        this._events = Object.create(null);
                    }
                    return this;
                }

                listeners(event) {
                    this._initEvents();
                    return this._events[event] ? this._events[event].slice() : [];
                }

                rawListeners(event) {
                    this._initEvents();
                    return this._events[event] ? this._events[event].slice() : [];
                }

                listenerCount(event) {
                    this._initEvents();
                    const listeners = this._events[event];
                    return listeners ? listeners.length : 0;
                }

                eventNames() {
                    this._initEvents();
                    return Object.keys(this._events);
                }

                prependListener(event, listener) {
                    this._initEvents();
                    if (!this._events[event]) {
                        this._events[event] = [];
                    }
                    this._events[event].unshift(listener);
                    return this;
                }

                prependOnceListener(event, listener) {
                    listener._once = true;
                    return this.prependListener(event, listener);
                }
            }

            EventEmitter._defaultMaxListeners = 10;
            EventEmitter.EventEmitter = EventEmitter;

            // EventEmitterAsyncResource — subclass with AsyncResource tracking (stub)
            class EventEmitterAsyncResource extends EventEmitter {
                constructor(options) {
                    super();
                    this.asyncResource = {
                        type: options?.name || 'EventEmitterAsyncResource',
                        asyncId: function() { return 0; },
                        triggerAsyncId: function() { return 0; },
                        runInAsyncScope: function(fn, thisArg) {
                            var args = [].slice.call(arguments, 2);
                            return fn.apply(thisArg, args);
                        },
                        emitDestroy: function() {}
                    };
                }
                get asyncId() { return 0; }
                get triggerAsyncId() { return 0; }
                emitDestroy() { return this; }
            }
            EventEmitter.EventEmitterAsyncResource = EventEmitterAsyncResource;

            // once(emitter, name) — returns a promise that resolves on the first event
            EventEmitter.once = function once(emitter, name) {
                return new Promise(function(resolve, reject) {
                    function onEvent() {
                        if (name !== 'error') emitter.removeListener('error', onError);
                        resolve([].slice.call(arguments));
                    }
                    function onError(err) {
                        emitter.removeListener(name, onEvent);
                        reject(err);
                    }
                    emitter.once(name, onEvent);
                    if (name !== 'error') emitter.once('error', onError);
                });
            };

            // on(emitter, event) — returns an AsyncIterator (minimal stub)
            EventEmitter.on = function on(emitter, event) {
                var buffer = [];
                var resolve = null;
                emitter.on(event, function() {
                    var args = [].slice.call(arguments);
                    if (resolve) { var r = resolve; resolve = null; r({ value: args, done: false }); }
                    else buffer.push(args);
                });
                return { next: function() {
                    if (buffer.length > 0) return Promise.resolve({ value: buffer.shift(), done: false });
                    return new Promise(function(r) { resolve = r; });
                }, [Symbol.asyncIterator]: function() { return this; } };
            };

            return EventEmitter;
        })();
        """

        let EventEmitter = context.evaluateScript(script)!

        // Make EventEmitter available globally for other modules to use
        context.setObject(EventEmitter, forKeyedSubscript: "__NoCo_EventEmitter" as NSString)

        return EventEmitter
    }
}
