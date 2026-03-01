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

                static get defaultMaxListeners() {
                    return EventEmitter._defaultMaxListeners || 10;
                }

                static set defaultMaxListeners(n) {
                    EventEmitter._defaultMaxListeners = n;
                }

                setMaxListeners(n) {
                    this._maxListeners = n;
                    return this;
                }

                getMaxListeners() {
                    return this._maxListeners;
                }

                emit(event) {
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
                    if (event !== undefined) {
                        delete this._events[event];
                    } else {
                        this._events = Object.create(null);
                    }
                    return this;
                }

                listeners(event) {
                    return this._events[event] ? this._events[event].slice() : [];
                }

                rawListeners(event) {
                    return this._events[event] ? this._events[event].slice() : [];
                }

                listenerCount(event) {
                    const listeners = this._events[event];
                    return listeners ? listeners.length : 0;
                }

                eventNames() {
                    return Object.keys(this._events);
                }

                prependListener(event, listener) {
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

            return EventEmitter;
        })();
        """

        let EventEmitter = context.evaluateScript(script)!

        // Make EventEmitter available globally for other modules to use
        context.setObject(EventEmitter, forKeyedSubscript: "__NoCo_EventEmitter" as NSString)

        return EventEmitter
    }
}
