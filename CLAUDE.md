# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                              # Build
swift build -c release                   # Release build
swift test                               # Run all tests
swift test --filter "ConsoleModuleTests" # Run a single test suite
swift run noco <script.js>               # Run a JS file
swift run noco -e "console.log('hi')"    # Evaluate inline JS
```

## Architecture

NoCo is a Node.js-compatible runtime built on Apple's JavaScriptCore framework, written in Swift. It implements CommonJS module resolution and a subset of Node.js built-in modules. Network servers use SwiftNIO (NIOHTTP1 + NIOTransportServices).

### Two Targets

- **NoCoKit** — Library containing the runtime, module loader, event loop, and all built-in modules
- **NoCo** — CLI executable using ArgumentParser that wraps NoCoKit

### Core Runtime (`Sources/NoCoKit/Runtime/`)

- **NodeRuntime** — Central class wrapping `JSContext`. All JS operations go through a serial `DispatchQueue` (`jsQueue`) for thread safety. Use `runtime.perform { context in ... }` to execute JS safely from any thread. Provides `URL` constructor and `URLSearchParams` via `__urlParse` bridge.
- **ModuleLoader** — CommonJS `require()` implementation. Resolution order: builtin → cache → node_modules → filesystem. Wraps file modules in `(function(exports, require, module, __filename, __dirname) { ... })`. Caches by absolute path; handles circular requires by caching before execution.
- **EventLoop** — Manages timers (setTimeout/setInterval), nextTick queue, and I/O handles. Has its own `ioLock` separate from jsQueue to avoid deadlocks. Loop: drain nextTick → drain callbacks → fire timers. Supports `timeout: .infinity` for long-running servers. `onUncaughtException` handler checks and clears JS exceptions after each callback in `drainCallbacks()`, preventing one failed callback from blocking subsequent ones.
- **NodeModule** — Protocol for all modules: `static var moduleName: String` + `static func install(in:runtime:) -> JSValue`.

### Module Types

**Global modules** (installed directly on context): console, process, timers, Buffer, EventEmitter.

**Require-able modules** (loaded via `require()`): path, fs, fs/promises, crypto, util, assert, events, string_decoder, stream, http, net, url, zlib.

### Key Patterns

- **Swift→JS closures**: Use `@convention(block)` + `unsafeBitCast` to `AnyObject`
- **JS arguments**: `JSContext.currentArguments() as? [JSValue] ?? []`
- **No exceptionHandler on JSContext**: Callers check `context.exception` after evaluation to preserve JS try/catch behavior. `NodeRuntime.checkException()` (public) logs and clears uncaught exceptions; also wired to `EventLoop.onUncaughtException` to isolate failures between callbacks.
- **JSValue helpers** in `JSValueExtensions.swift`: `JSValue.object(from:in:)`, `.isNullOrUndefined`, `.callSafe()`
- **Error creation**: `context.createSystemError("msg", code: "ENOENT", syscall: "open", path: "/foo")` for Node.js-style errors

### Server Architecture (SwiftNIO)

`http.createServer()` and `net.createServer()` use NIOTransportServices (Network.framework) for transport and NIOHTTP1 for HTTP codec.

```
NIOTSListenerBootstrap (NIO thread)          NoCo EventLoop (jsQueue)
  └─ ChannelPipeline                         ──────────────────────
       ├─ HTTPRequestDecoder                  drainCallbacks() picks up
       ├─ HTTPResponseEncoder                 JS request handlers
       └─ HTTPBridgeHandler ──enqueueCallback──→ JS callback execution
              ↑                                       │
              └──── channel.write ────────────────────┘
```

Key classes:
- **NIOHTTPServer / NIOTCPServer** — Manages NIOTSEventLoopGroup and listener bootstrap
- **HTTPBridgeHandler / TCPBridgeHandler** — NIO ChannelInboundHandler bridging to JS via `eventLoop.enqueueCallback`
- **HTTPRequestState** — Accumulates request data and sends HTTP response via NIO channel
- **AtomicCounter** — Thread-safe ID generation using DispatchQueue (avoids macOS 15+ Mutex requirement)

### Threading Rules

- **jsQueue**: All JS operations must run on this serial queue. The event loop's `run()` blocks this queue.
- **NIO event loop**: Runs on separate thread. Must NOT call `runtime.perform` (causes deadlock with jsQueue).
- **Async callbacks from background threads**: Must use `runtime.eventLoop.enqueueCallback { ... }` instead of `runtime.perform { ... }`. The callback is picked up by `drainCallbacks()` on the next event loop iteration. Access `runtime.context` directly inside the callback.
- **NIO→JS bridge**: Store `Channel` directly (not `ChannelHandlerContext`) for cross-thread access safety.

### Test Patterns

Tests use Swift Testing framework (`@Test`, `#expect()`). Common pattern: create a `NodeRuntime`, set `runtime.consoleHandler` to capture output, evaluate JS, assert on captured values. File I/O tests create temp files with UUID names and clean up with `defer`. Test fixtures live in `Tests/NoCoKitTests/Fixtures/`.

For server tests, run the event loop on a background thread to avoid blocking Swift concurrency:
```swift
private func runEventLoopInBackground(_ runtime: NodeRuntime, timeout: TimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            runtime.runEventLoop(timeout: timeout)
            continuation.resume()
        }
    }
}
```
Use `runtime.eventLoop.stop()` for cleanup instead of `server.close()` to avoid deadlocks in tests.
