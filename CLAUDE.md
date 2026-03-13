# CLAUDE.md

## Build & Test

```bash
swift build                              # Build
swift build -c release                   # Release build
swift test                               # Run all tests
swift test --filter "ConsoleModuleTests" # Run a single test suite
swift run noco <script.js>               # Run a JS file
swift run noco -e "console.log('hi')"    # Evaluate inline JS
```

## Architecture

NoCo is a Node.js-compatible runtime built on JavaScriptCore (Swift). CommonJS + ESM module resolution. SwiftNIO (NIOHTTP1 + NIOTransportServices + swift-nio-http2) for networking.

### Targets

- **NoCoKit** — Library: runtime, module loader, event loop, all built-in modules
- **NoCo** — CLI executable (ArgumentParser)

### Core Runtime (`Sources/NoCoKit/Runtime/`)

- **NodeRuntime** — `JSContext` wrapper. All JS ops run on `jsQueue` (serial DispatchQueue). `runtime.perform { context in ... }` for thread-safe access.
- **ModuleLoader** — CommonJS `require()`. Resolution: builtin → cache → node_modules → filesystem. Supports `node:` prefix and wildcard exports. Circular requires handled via cache-before-execute.
- **ESMDetector / ESMTransformer / ESMRuntime** — ESM (`import`/`export`) support. Detects ESM syntax and `.mjs` files, transforms to CommonJS for execution.
- **EventLoop** — Timers, nextTick, I/O callbacks. `DispatchSemaphore` idle wait (no polling). `enqueueCallback()` for instant wakeup. `onUncaughtException` isolates failed callbacks.
- **NodeModule** — Protocol: `static var moduleName` + `static func install(in:runtime:) -> JSValue`

### Built-in Modules (`Sources/NoCoKit/Modules/`)

| Type | Modules |
|------|---------|
| Global | console, process, timers, Buffer, EventEmitter |
| require() | path, fs, fs/promises, crypto, util, assert, events, string_decoder, stream, http, https, http2, net, url, querystring, os, zlib, async_hooks, child_process, constants, module, readline, tty |
| Web API | fetch, URL, URLSearchParams, Headers, Request, Response, Blob, File, FormData, ReadableStream, WritableStream, TransformStream, CompressionStream/DecompressionStream, crypto.subtle (WebCrypto) |

### Key Patterns

- **Swift→JS**: `@convention(block)` + `unsafeBitCast` to `AnyObject`
- **JS arguments**: `JSContext.currentArguments() as? [JSValue] ?? []`
- **Exceptions**: Manual `context.exception` check (no exceptionHandler, preserves try/catch)
- **JSValue helpers** (`JSValueExtensions.swift`): `.isNullOrUndefined`, `.callSafe()`, `JSValue.object(from:in:)`
- **Error creation**: `context.createSystemError("msg", code: "ENOENT", syscall: "open", path: "/foo")`

### Threading Rules

- **jsQueue**: All JS operations. EventLoop `run()` blocks this queue.
- **NIO→JS**: Never call `runtime.perform` (deadlock). Use `eventLoop.enqueueCallback { ... }` and access `runtime.context` directly inside.
- **Channel safety**: Store `Channel` (not `ChannelHandlerContext`) for cross-thread access.

### Test Patterns

Swift Testing (`@Test`, `#expect()`). Capture output via `runtime.consoleHandler`. Server tests run event loop on `DispatchQueue.global().async`. Cleanup with `runtime.eventLoop.stop()`. Fixtures in `Tests/NoCoKitTests/Fixtures/`.
