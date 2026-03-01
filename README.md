# NoCo (Node.js on JavaScriptCore)

A Node.js-compatible JavaScript runtime built on Apple's [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) framework, written in Swift.

The name "NoCo" comes from the Japanese word "鋸" (nokogiri), meaning "saw" — a sharp tool that cuts through complexity.

NoCo implements CommonJS module resolution and a subset of Node.js built-in modules, allowing you to run many Node.js scripts and npm packages natively on Apple platforms — without embedding V8 or Node.js itself.

## Features

- **JavaScriptCore-powered** — Uses Apple's built-in JS engine; no V8 dependency
- **CommonJS `require()`** — Full module resolution: built-in modules → cache → `node_modules` → filesystem
- **Node.js built-in modules** — `fs`, `path`, `crypto`, `http`, `stream`, `net`, `url`, `zlib`, and more
- **Event loop** — `setTimeout`, `setInterval`, `process.nextTick`, and async I/O
- **npm compatibility** — Works with real-world npm packages (tested with `pngjs`, `receiptline`, `iconv-lite`, etc.)
- **Embeddable** — Use `NoCoKit` as a library in your own Swift apps

## Requirements

- Swift 6.2+
- macOS 13+ / iOS 16+

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

### Embed in a Swift app

```swift
import NoCoKit

let runtime = NodeRuntime()
runtime.evaluate("console.log('Hello from NoCoKit')")
runtime.runEventLoop()
```

## Built-in Modules

### Global (available without `require()`)

| Module | Description |
|--------|-------------|
| `console` | `log`, `warn`, `error`, `info`, `debug`, `dir`, `assert`, `time`/`timeEnd` |
| `process` | `argv`, `env`, `cwd()`, `pid`, `platform`, `arch`, `hrtime()`, `nextTick()`, `stdout`, `exit()` |
| `timers` | `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` |
| `Buffer` | Node.js-compatible Buffer class (Uint8Array-based) |
| `EventEmitter` | Event emitter class |

### Require-able

| Module | Key APIs |
|--------|----------|
| `path` | `join`, `resolve`, `basename`, `dirname`, `extname`, `relative`, `normalize`, `parse`, `format`, `isAbsolute`, `sep`, `delimiter` |
| `fs` | `readFileSync`, `writeFileSync`, `existsSync`, `statSync`, `readdirSync`, `mkdirSync`, `unlinkSync`, `renameSync`, `appendFileSync`, and async variants |
| `fs/promises` | Promise-based versions of `fs` methods |
| `crypto` | `createHash`, `createHmac`, `randomBytes`, `randomUUID` (SHA-1, SHA-256, SHA-512, MD5) |
| `stream` | `Readable`, `Writable`, `Transform`, `Duplex`, `PassThrough` |
| `http` | `http.request`, `http.get` (backed by URLSession) |
| `net` | `net.connect`, `Socket` (backed by NWConnection) |
| `url` | `parse`, `format`, `resolve` |
| `zlib` | `gzip`, `gunzip`, `deflate`, `inflate`, `deflateRaw`, `inflateRaw` |
| `util` | `inherits`, `deprecate`, `format` |
| `assert` | `ok`, `equal`, `strictEqual`, `notEqual`, `deepStrictEqual`, `throws`, `fail` |
| `events` | `EventEmitter` |
| `string_decoder` | `StringDecoder` |
| `buffer` | `Buffer` |
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

All JS operations go through `NodeRuntime.perform { context in ... }` to ensure thread safety via a serial `DispatchQueue`.

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
