# NoCo (Node.js on JavaScriptCore)

A Node.js-compatible JavaScript runtime built on Apple's [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) framework, written in Swift.

The name "NoCo" comes from the Japanese word "鋸" (nokogiri), meaning "saw" — a sharp tool that cuts through complexity.

NoCo implements CommonJS module resolution and a subset of Node.js built-in modules, allowing you to run many Node.js scripts and npm packages natively on Apple platforms — without embedding V8 or Node.js itself.

## Features

- **JavaScriptCore-powered** — Uses Apple's built-in JS engine; no V8 dependency
- **CommonJS `require()`** — Full module resolution: built-in modules → cache → `node_modules` → filesystem
- **Node.js built-in modules** — `fs`, `path`, `crypto`, `http`, `http2`, `stream`, `net`, `url`, `zlib`, and more
- **Web Platform APIs** — `Headers`, `Request`, `Response`, `ReadableStream`, `AbortController` etc. for Fetch API compatibility
- **HTTP/TCP servers** — `http.createServer()`, `http2.createServer()`, and `net.createServer()` powered by [SwiftNIO](https://github.com/apple/swift-nio)
- **Event loop** — `setTimeout`, `setInterval`, `process.nextTick`, and async I/O
- **Web framework support** — Run frameworks like [Hono](https://hono.dev/) on NoCo
- **npm compatibility** — Works with real-world npm packages (tested with `pngjs`, `receiptline`, `iconv-lite`, etc.)
- **Embeddable** — Use `NoCoKit` as a library in your own Swift apps

## Requirements

- Swift 6.2+
- macOS 15+ / iOS 18+

## Installation

### Homebrew

```bash
brew install  trickart/tap/noco
```

### Build from source

```bash
git clone https://github.com/trickart/NoCo.git
cd NoCo
swift build -c release
```

## Usage

### Run a JavaScript file

```bash
noco script.js
```

### Evaluate a string

```bash
noco -e "console.log('hello')"
noco -e "const path = require('path'); console.log(path.join('a', 'b'))"
```

### Pass arguments to scripts

Arguments after `--` are passed to `process.argv`:

```bash
noco script.js -- --port 3000 foo
# process.argv => [execPath, "script.js", "--port", "3000", "foo"]

noco -e "console.log(process.argv)" -- hello world
# process.argv => [execPath, "[eval]", "hello", "world"]
```

### Run an HTTP server

```javascript
// server.js
const http = require('http');
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Hello from NoCo!');
});
server.listen(8080, () => {
    console.log('Server running at http://127.0.0.1:8080/');
});
```

```bash
noco server.js
```

### Run Hono

```javascript
// app.js
const { Hono } = require('hono');
const { serve } = require('@hono/node-server');

const app = new Hono();
app.get('/', (c) => c.text('Hello from Hono on NoCo!'));
app.get('/json', (c) => c.json({ runtime: 'NoCo', engine: 'JavaScriptCore' }));

serve({ fetch: app.fetch, port: 3000 }, (info) => {
    console.log('Listening on http://localhost:' + info.port);
});
```

```bash
npm install hono @hono/node-server
noco app.js
```

### Embed in a Swift app

```swift
import NoCoKit

let runtime = NodeRuntime()
runtime.evaluate("console.log('Hello from NoCoKit')")
runtime.runEventLoop(timeout: .infinity)
```

## Built-in Modules

### Global (available without `require()`)

| Module | Description |
|--------|-------------|
| `console` | `log`, `warn`, `error`, `info`, `debug`, `dir`, `assert`, `time`/`timeEnd` |
| `process` | `argv`, `env`, `cwd()`, `pid`, `platform`, `arch`, `version`, `versions`, `hrtime()`, `nextTick()`, `stdout`, `exit()` |
| `timers` | `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` |
| `Buffer` | Node.js-compatible Buffer class (Uint8Array-based) |
| `EventEmitter` | Event emitter class |
| `URL` / `URLSearchParams` | WHATWG URL API |

### Web Platform APIs (available as globals)

| API | Description |
|-----|-------------|
| `fetch` | Fetch API (`GET`, `POST`, etc.) backed by URLSession |
| `Headers` | HTTP headers manipulation (Fetch API) |
| `Request` | HTTP request representation (Fetch API) |
| `Response` | HTTP response representation, including `Response.json()`, `Response.redirect()` |
| `Blob` / `File` | Binary data and file representation |
| `FormData` | Multipart form data |
| `ReadableStream` | WHATWG Streams API readable stream |
| `WritableStream` | WHATWG Streams API writable stream |
| `TransformStream` | WHATWG Streams API transform stream |
| `CompressionStream` / `DecompressionStream` | Streaming compression (gzip, deflate, deflate-raw) |
| `crypto.subtle` | Web Crypto API (AES, RSA, ECDSA, Ed25519, HMAC, HKDF, PBKDF2, SHA) |
| `AbortController` / `AbortSignal` | Request cancellation API |
| `DOMException` | Web standard exception |
| `TextEncoder` / `TextDecoder` | Text encoding/decoding API |
| `atob` / `btoa` | Base64 encoding/decoding |
| `crypto.getRandomValues` | Cryptographically secure random values |
| `structuredClone` | Deep clone objects |
| `queueMicrotask` | Schedule microtask |
| `caches` | Web Cache API (in-memory `CacheStorage`) |

### Require-able

| Module | Key APIs |
|--------|----------|
| `path` | `join`, `resolve`, `basename`, `dirname`, `extname`, `relative`, `normalize`, `parse`, `format`, `isAbsolute`, `sep`, `delimiter` |
| `fs` | `readFileSync`, `writeFileSync`, `existsSync`, `statSync`, `readdirSync`, `mkdirSync`, `unlinkSync`, `renameSync`, `appendFileSync`, `copyFileSync`, `accessSync`, `chmodSync`, and async variants |
| `fs/promises` | Promise-based versions of `fs` methods |
| `crypto` | `createHash`, `createHmac`, `randomBytes`, `randomUUID` (SHA-1, SHA-256, SHA-384, SHA-512, MD5) |
| `stream` | `Readable`, `Writable`, `Transform`, `Duplex`, `PassThrough`, `Readable.toWeb()` |
| `http` | `createServer`, `request`, `get`, `Server`, `IncomingMessage`, `ServerResponse` (server: SwiftNIO, client: URLSession) |
| `http2` | `createServer`, `createSecureServer`, `connect`, `getDefaultSettings`, `constants` (server: SwiftNIO + NIOHTTP2) |
| `net` | `createServer`, `connect`, `Socket`, `Server`, `isIP`, `isIPv4`, `isIPv6` (server: SwiftNIO, client: NWConnection) |
| `url` | `parse`, `format`, `resolve` |
| `zlib` | `gzip`, `gunzip`, `deflate`, `inflate`, `deflateRaw`, `inflateRaw` |
| `util` | `inherits`, `deprecate`, `format` |
| `assert` | `ok`, `equal`, `strictEqual`, `notEqual`, `deepStrictEqual`, `throws`, `fail` |
| `events` | `EventEmitter` |
| `string_decoder` | `StringDecoder` |
| `buffer` | `Buffer` |
| `os` | `arch`, `platform`, `type`, `release`, `version`, `hostname`, `homedir`, `tmpdir`, `totalmem`, `freemem`, `cpus`, `loadavg`, `uptime`, `endianness`, `networkInterfaces`, `userInfo`, `EOL`, `constants` |
| `querystring` | `parse`/`decode`, `stringify`/`encode`, `escape`, `unescape` |
| `async_hooks` | `AsyncLocalStorage` |
| `timers` | `setTimeout`, `setInterval` |

## Architecture

```
NoCo
├── NoCo          CLI executable (Swift ArgumentParser)
└── NoCoKit       Library
    ├── Runtime
    │   ├── NodeRuntime      JSContext wrapper with serial DispatchQueue for thread safety
    │   ├── ModuleLoader     CommonJS require() with circular dependency handling
    │   ├── EventLoop        Timers, nextTick queue, I/O handle tracking
    │   └── NodeModule       Protocol for built-in modules
    ├── Modules              All built-in module implementations
    └── Utilities            JSValue extensions, error handling
```

All JS operations go through a serial `DispatchQueue` (`jsQueue`) for thread safety. HTTP/TCP servers use [SwiftNIO](https://github.com/apple/swift-nio) with [NIOTransportServices](https://github.com/apple/swift-nio-transport-services) (Network.framework) for the transport layer, NIOHTTP1 for HTTP/1.1, and NIOHTTP2 for HTTP/2 codec. NIO events are bridged to the JS event loop via `eventLoop.enqueueCallback`.

## Testing

```bash
# Run all tests
swift test

# Run a specific test suite
swift test --filter "PathModuleTests"
swift test --filter "ConsoleModuleTests"
```

Tests use the Swift Testing framework (`@Test`, `#expect()`). The test suite includes unit tests for each module, integration tests, and npm package compatibility tests.

## License

MIT
