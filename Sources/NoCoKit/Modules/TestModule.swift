import JavaScriptCore

/// Implements the Node.js `node:test` built-in test runner (Phase 1).
public struct TestModule: NodeModule {
    public static let moduleName = "test"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var assertModule = require('assert');

            // ---------- TestContext ----------
            function TestContext(name, parent) {
                this.name = name;
                this._parent = parent || null;
                this._skipped = false;
                this._todo = false;
                this._skipReason = '';
                this._todoReason = '';
                this._diagnostics = [];
                this._subtests = [];
                this.assert = assertModule;
            }

            TestContext.prototype.skip = function(reason) {
                this._skipped = true;
                this._skipReason = reason || '';
            };

            TestContext.prototype.todo = function(reason) {
                this._todo = true;
                this._todoReason = reason || '';
            };

            TestContext.prototype.diagnostic = function(msg) {
                this._diagnostics.push(String(msg));
            };

            TestContext.prototype.test = function(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                var entry = { name: name, fn: fn, options: options };
                this._subtests.push(entry);
            };

            // ---------- Suite ----------
            function Suite(name, options) {
                this.name = name;
                this.options = options || {};
                this.tests = [];
                this.suites = [];
                this.before = [];
                this.after = [];
                this.beforeEach = [];
                this.afterEach = [];
            }

            // ---------- Runner state ----------
            var rootSuite = new Suite('__root__');
            var currentSuite = rootSuite;
            var scheduled = false;
            var tapIndex = 0;
            var totalPass = 0;
            var totalFail = 0;
            var totalSkip = 0;
            var totalTodo = 0;

            function writeTAP(line) {
                process.stdout.write(line + '\\n');
            }

            // ---------- Test execution ----------
            function runTest(entry, parentBeforeEach, parentAfterEach) {
                return new Promise(function(resolve) {
                    var t = new TestContext(entry.name);
                    var opts = entry.options || {};
                    var isSkip = opts.skip === true || typeof opts.skip === 'string';
                    var isTodo = opts.todo === true || typeof opts.todo === 'string';
                    tapIndex++;
                    var idx = tapIndex;

                    if (isSkip || !entry.fn) {
                        var reason = typeof opts.skip === 'string' ? opts.skip : '';
                        if (!entry.fn && !isSkip && !isTodo) {
                            // test with no fn is treated as todo
                            isTodo = true;
                        }
                        if (isSkip) {
                            totalSkip++;
                            writeTAP('ok ' + idx + ' - ' + entry.name + ' # SKIP' + (reason ? ' ' + reason : ''));
                        } else {
                            totalTodo++;
                            var todoReason = typeof opts.todo === 'string' ? opts.todo : '';
                            writeTAP('ok ' + idx + ' - ' + entry.name + ' # TODO' + (todoReason ? ' ' + todoReason : ''));
                        }
                        resolve();
                        return;
                    }

                    if (isTodo) {
                        t._todo = true;
                        t._todoReason = typeof opts.todo === 'string' ? opts.todo : '';
                    }

                    // Execute beforeEach hooks
                    var hookChain = Promise.resolve();
                    var allBeforeEach = parentBeforeEach.concat([]);
                    var allAfterEach = parentAfterEach.concat([]);
                    for (var bi = 0; bi < allBeforeEach.length; bi++) {
                        (function(hook) {
                            hookChain = hookChain.then(function() { return hook(); });
                        })(allBeforeEach[bi]);
                    }

                    hookChain.then(function() {
                        return entry.fn(t);
                    }).then(function() {
                        // Run subtests
                        var subChain = Promise.resolve();
                        for (var si = 0; si < t._subtests.length; si++) {
                            (function(sub) {
                                subChain = subChain.then(function() {
                                    return runTest(sub, allBeforeEach, allAfterEach);
                                });
                            })(t._subtests[si]);
                        }
                        return subChain;
                    }).then(function() {
                        // Execute afterEach hooks
                        var aeChain = Promise.resolve();
                        for (var ai = 0; ai < allAfterEach.length; ai++) {
                            (function(hook) {
                                aeChain = aeChain.then(function() { return hook(); });
                            })(allAfterEach[ai]);
                        }
                        return aeChain;
                    }).then(function() {
                        if (t._skipped) {
                            totalSkip++;
                            writeTAP('ok ' + idx + ' - ' + entry.name + ' # SKIP' + (t._skipReason ? ' ' + t._skipReason : ''));
                        } else if (t._todo) {
                            totalTodo++;
                            writeTAP('ok ' + idx + ' - ' + entry.name + ' # TODO' + (t._todoReason ? ' ' + t._todoReason : ''));
                        } else {
                            totalPass++;
                            writeTAP('ok ' + idx + ' - ' + entry.name);
                        }
                        for (var d = 0; d < t._diagnostics.length; d++) {
                            writeTAP('# ' + t._diagnostics[d]);
                        }
                        resolve();
                    })['catch'](function(err) {
                        // Execute afterEach hooks even on failure
                        var aeChain = Promise.resolve();
                        for (var ai = 0; ai < allAfterEach.length; ai++) {
                            (function(hook) {
                                aeChain = aeChain.then(function() { return hook(); });
                            })(allAfterEach[ai]);
                        }
                        aeChain.then(function() {
                            if (t._skipped) {
                                totalSkip++;
                                writeTAP('ok ' + idx + ' - ' + entry.name + ' # SKIP' + (t._skipReason ? ' ' + t._skipReason : ''));
                            } else if (t._todo) {
                                totalTodo++;
                                writeTAP('not ok ' + idx + ' - ' + entry.name + ' # TODO' + (t._todoReason ? ' ' + t._todoReason : ''));
                            } else {
                                totalFail++;
                                writeTAP('not ok ' + idx + ' - ' + entry.name);
                                writeTAP('  ---');
                                writeTAP('  error: ' + String(err && err.message ? err.message : err));
                                writeTAP('  ...');
                            }
                            for (var d = 0; d < t._diagnostics.length; d++) {
                                writeTAP('# ' + t._diagnostics[d]);
                            }
                            resolve();
                        });
                    });
                });
            }

            function countTests(suite) {
                var count = suite.tests.length;
                for (var i = 0; i < suite.suites.length; i++) {
                    count += countTests(suite.suites[i]);
                }
                return count;
            }

            function runSuite(suite, parentBeforeEach, parentAfterEach) {
                return new Promise(function(resolve) {
                    var isRoot = suite.name === '__root__';
                    var beforeEach = parentBeforeEach.concat(suite.beforeEach);
                    var afterEach = parentAfterEach.concat(suite.afterEach);

                    // Check skip/todo at suite level
                    if (suite.options.skip === true || typeof suite.options.skip === 'string') {
                        // Skip all tests in suite
                        var skipCount = countTests(suite);
                        for (var si = 0; si < skipCount; si++) {
                            tapIndex++;
                            totalSkip++;
                            var reason = typeof suite.options.skip === 'string' ? suite.options.skip : '';
                            writeTAP('ok ' + tapIndex + ' - ' + suite.name + ' # SKIP' + (reason ? ' ' + reason : ''));
                        }
                        resolve();
                        return;
                    }

                    if (suite.options.todo === true || typeof suite.options.todo === 'string') {
                        var todoCount = countTests(suite);
                        for (var ti = 0; ti < todoCount; ti++) {
                            tapIndex++;
                            totalTodo++;
                            var todoReason = typeof suite.options.todo === 'string' ? suite.options.todo : '';
                            writeTAP('ok ' + tapIndex + ' - ' + suite.name + ' # TODO' + (todoReason ? ' ' + todoReason : ''));
                        }
                        resolve();
                        return;
                    }

                    if (!isRoot) {
                        writeTAP('# Subtest: ' + suite.name);
                    }

                    // Run before hooks
                    var chain = Promise.resolve();
                    for (var bi = 0; bi < suite.before.length; bi++) {
                        (function(hook) {
                            chain = chain.then(function() { return hook(); });
                        })(suite.before[bi]);
                    }

                    // Run tests
                    for (var i = 0; i < suite.tests.length; i++) {
                        (function(entry) {
                            chain = chain.then(function() {
                                return runTest(entry, beforeEach, afterEach);
                            });
                        })(suite.tests[i]);
                    }

                    // Run child suites
                    for (var j = 0; j < suite.suites.length; j++) {
                        (function(childSuite) {
                            chain = chain.then(function() {
                                return runSuite(childSuite, beforeEach, afterEach);
                            });
                        })(suite.suites[j]);
                    }

                    // Run after hooks
                    for (var ai = 0; ai < suite.after.length; ai++) {
                        (function(hook) {
                            chain = chain.then(function() { return hook(); });
                        })(suite.after[ai]);
                    }

                    chain.then(resolve);
                });
            }

            function scheduleRun() {
                if (scheduled) return;
                scheduled = true;
                process.nextTick(function() {
                    var totalCount = countTests(rootSuite);
                    writeTAP('TAP version 13');
                    writeTAP('1..' + totalCount);

                    runSuite(rootSuite, [], []).then(function() {
                        writeTAP('');
                        writeTAP('# pass ' + totalPass);
                        writeTAP('# fail ' + totalFail);
                        writeTAP('# skip ' + totalSkip);
                        writeTAP('# todo ' + totalTodo);

                        if (totalFail > 0) {
                            process.exitCode = 1;
                        }
                    });
                });
            }

            // ---------- Public API ----------
            function test(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                    if (typeof fn === 'undefined' && typeof optionsOrFn !== 'function') {
                        fn = undefined;
                    }
                }
                currentSuite.tests.push({ name: name, fn: fn, options: options });
                scheduleRun();
            }

            test.skip = function(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                options.skip = true;
                currentSuite.tests.push({ name: name, fn: fn, options: options });
                scheduleRun();
            };

            test.todo = function(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                options.todo = true;
                currentSuite.tests.push({ name: name, fn: fn, options: options });
                scheduleRun();
            };

            function describe(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                var suite = new Suite(name, options);
                var parent = currentSuite;
                parent.suites.push(suite);
                currentSuite = suite;
                if (typeof fn === 'function') {
                    fn();
                }
                currentSuite = parent;
                scheduleRun();
            }

            describe.skip = function(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                options.skip = true;
                describe(name, options, fn);
            };

            describe.todo = function(name, optionsOrFn, fn) {
                var options = {};
                if (typeof optionsOrFn === 'function') {
                    fn = optionsOrFn;
                } else if (typeof optionsOrFn === 'object' && optionsOrFn !== null) {
                    options = optionsOrFn;
                }
                options.todo = true;
                describe(name, options, fn);
            };

            var it = test;
            var suite = describe;

            function before(fn) {
                currentSuite.before.push(fn);
            }

            function after(fn) {
                currentSuite.after.push(fn);
            }

            function beforeEach(fn) {
                currentSuite.beforeEach.push(fn);
            }

            function afterEach(fn) {
                currentSuite.afterEach.push(fn);
            }

            // ---------- Module exports ----------
            var mod = test;
            mod.test = test;
            mod.describe = describe;
            mod.suite = suite;
            mod.it = it;
            mod.before = before;
            mod.after = after;
            mod.beforeEach = beforeEach;
            mod.afterEach = afterEach;

            return mod;
        })();
        """

        return context.evaluateScript(script)!
    }
}
