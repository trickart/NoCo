import Testing
import JavaScriptCore
@testable import NoCoKit

@Test func readlineCreateInterfaceReturnsObject() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('readline').createInterface")
    #expect(result?.toString() == "function")
}

@Test func readlineNodePrefix() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('node:readline').createInterface")
    #expect(result?.toString() == "function")
}

@Test func readlineInterfaceConstructorExported() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("typeof require('readline').Interface")
    #expect(result?.toString() == "function")
}

@Test func readlineSetPromptAndPrompt() async throws {
    let runtime = NodeRuntime()
    var output = ""
    runtime.stdoutHandler = { output += $0 }
    runtime.evaluate("""
        var rl = require('readline');
        var iface = rl.createInterface({ input: process.stdin, output: process.stdout });
        iface.setPrompt('test> ');
        iface.prompt();
    """)
    #expect(output == "test> ")
}

@Test func readlineCloseEmitsCloseEvent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var closed = false;
        var iface = rl.createInterface({ input: input });
        iface.on('close', function() { closed = true; });
        iface.close();
        closed;
    """)
    #expect(result?.toBool() == true)
}

@Test func readlineCloseIsIdempotent() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var count = 0;
        var iface = rl.createInterface({ input: input });
        iface.on('close', function() { count++; });
        iface.close();
        iface.close();
        iface.close();
        count;
    """)
    #expect(result?.toInt32() == 1)
}

@Test func readlineLineEventFromData() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var lines = [];
        var iface = rl.createInterface({ input: input });
        iface.on('line', function(line) { lines.push(line); });
        input.emit('data', 'hello\\n');
        JSON.stringify(lines);
    """)
    #expect(result?.toString() == "[\"hello\"]")
}

@Test func readlineMultipleLinesSplit() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var lines = [];
        var iface = rl.createInterface({ input: input });
        iface.on('line', function(line) { lines.push(line); });
        input.emit('data', 'line1\\nline2\\nline3\\n');
        JSON.stringify(lines);
    """)
    #expect(result?.toString() == "[\"line1\",\"line2\",\"line3\"]")
}

@Test func readlineLineBuffering() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var lines = [];
        var iface = rl.createInterface({ input: input });
        iface.on('line', function(line) { lines.push(line); });
        input.emit('data', 'hel');
        input.emit('data', 'lo\\n');
        JSON.stringify(lines);
    """)
    #expect(result?.toString() == "[\"hello\"]")
}

@Test func readlineQuestionCallbackAndOutput() async throws {
    let runtime = NodeRuntime()
    var output = ""
    runtime.stdoutHandler = { output += $0 }
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var answer = null;
        var iface = rl.createInterface({ input: input, output: process.stdout });
        iface.question('Name? ', function(a) { answer = a; });
        input.emit('data', 'Alice\\n');
        answer;
    """)
    #expect(output == "Name? ")
    #expect(result?.toString() == "Alice")
}

@Test func readlinePromisesCreateInterface() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        typeof rl.promises.createInterface;
    """)
    #expect(result?.toString() == "function")
}

@Test func readlineCRLFHandling() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var lines = [];
        var iface = rl.createInterface({ input: input });
        iface.on('line', function(line) { lines.push(line); });
        input.emit('data', 'hello\\r\\n');
        JSON.stringify(lines);
    """)
    #expect(result?.toString() == "[\"hello\"]")
}

@Test func readlineTwoArgForm() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var iface = rl.createInterface(input, process.stdout);
        var lines = [];
        iface.on('line', function(line) { lines.push(line); });
        input.emit('data', 'test\\n');
        JSON.stringify(lines);
    """)
    #expect(result?.toString() == "[\"test\"]")
}

@Test func readlineInputEndClosesInterface() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        var EventEmitter = require('events');
        var input = new EventEmitter();
        var closed = false;
        var iface = rl.createInterface({ input: input });
        iface.on('close', function() { closed = true; });
        input.emit('end');
        closed;
    """)
    #expect(result?.toBool() == true)
}

@Test func readlineStubFunctions() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        var rl = require('readline');
        JSON.stringify({
            clearLine: typeof rl.clearLine,
            clearScreenDown: typeof rl.clearScreenDown,
            cursorTo: typeof rl.cursorTo,
            moveCursor: typeof rl.moveCursor,
            emitKeypressEvents: typeof rl.emitKeypressEvents
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"clearLine\":\"function\""))
    #expect(json.contains("\"cursorTo\":\"function\""))
}

@Test func readlineProcessStdinProperty() async throws {
    let runtime = NodeRuntime()
    let result = runtime.evaluate("""
        JSON.stringify({
            hasOn: typeof process.stdin.on === 'function',
            hasResume: typeof process.stdin.resume === 'function',
            hasPause: typeof process.stdin.pause === 'function',
            hasSetEncoding: typeof process.stdin.setEncoding === 'function',
            fd: process.stdin.fd,
            readable: process.stdin.readable
        });
    """)
    let json = result?.toString() ?? ""
    #expect(json.contains("\"hasOn\":true"))
    #expect(json.contains("\"hasResume\":true"))
    #expect(json.contains("\"fd\":0"))
    #expect(json.contains("\"readable\":true"))
}
