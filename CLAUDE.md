# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                              # Build
swift build -c release                   # Release build
swift test                               # Run all tests
swift test --filter "ConsoleModuleTests" # Run a single test suite
swift run noco <script.js>               # Run a JS file
```

## Architecture

NoCo is a Node.js-compatible runtime built on Apple's JavaScriptCore framework, written in Swift. It implements CommonJS module resolution and a subset of Node.js built-in modules.

### Two Targets

- **NoCoKit** — Library containing the runtime, module loader, event loop, and all built-in modules
- **NoCo** — CLI executable using ArgumentParser that wraps NoCoKit

### Core Runtime (`Sources/NoCoKit/Runtime/`)

- **NodeRuntime** — Central class wrapping `JSContext`. All JS operations go through a serial `DispatchQueue` (`jsQueue`) for thread safety. Use `runtime.perform { context in ... }` to execute JS safely from any thread.
- **ModuleLoader** — CommonJS `require()` implementation. Resolution order: builtin → cache → node_modules → filesystem. Wraps file modules in `(function(exports, require, module, __filename, __dirname) { ... })`. Caches by absolute path; handles circular requires by caching before execution.
- **EventLoop** — Manages timers (setTimeout/setInterval), nextTick queue, and I/O handles. Has its own `ioLock` separate from jsQueue to avoid deadlocks. Loop: drain nextTick → drain callbacks → fire timers.
- **NodeModule** — Protocol for all modules: `static var moduleName: String` + `static func install(in:runtime:) -> JSValue`.

### Module Types

**Global modules** (installed directly on context): console, process, timers, Buffer, EventEmitter.

**Require-able modules** (loaded via `require()`): path, fs, fs/promises, crypto, util, assert, events, string_decoder, stream, http, net, url, zlib.

### Key Patterns

- **Swift→JS closures**: Use `@convention(block)` + `unsafeBitCast` to `AnyObject`
- **JS arguments**: `JSContext.currentArguments() as? [JSValue] ?? []`
- **No exceptionHandler on JSContext**: Callers check `context.exception` after evaluation to preserve JS try/catch behavior
- **JSValue helpers** in `JSValueExtensions.swift`: `JSValue.object(from:in:)`, `.isNullOrUndefined`, `.callSafe()`
- **Error creation**: `context.createSystemError("msg", code: "ENOENT", syscall: "open", path: "/foo")` for Node.js-style errors

### Test Patterns

Tests use Swift Testing framework (`@Test`, `#expect()`). Common pattern: create a `NodeRuntime`, set `runtime.consoleHandler` to capture output, evaluate JS, assert on captured values. File I/O tests create temp files with UUID names and clean up with `defer`. Test fixtures live in `Tests/NoCoKitTests/Fixtures/`.
