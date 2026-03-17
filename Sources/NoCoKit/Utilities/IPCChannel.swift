#if os(macOS)
import Foundation
import Synchronization

/// Manages IPC communication over a Unix domain socket.
/// Used for parent-child process communication via `child_process.fork()`.
/// Messages are newline-delimited JSON strings.
final class IPCChannel: Sendable {
    private struct State: Sendable {
        var buffer: Data = Data()
        var closed: Bool = false
    }

    private let state: Mutex<State>
    private let fileHandle: FileHandle
    private let eventLoop: EventLoop

    init(fileDescriptor: Int32, eventLoop: EventLoop) {
        self.state = Mutex(State())
        self.fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        self.eventLoop = eventLoop
    }

    /// Start reading from the socket. Calls `onMessage` with each complete JSON line.
    /// Calls `onDisconnect` when the remote end closes the connection.
    func startReading(
        onMessage: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                // EOF — remote end closed
                self.fileHandle.readabilityHandler = nil
                self.state.withLock { $0.closed = true }
                self.eventLoop.enqueueCallback {
                    onDisconnect()
                }
                return
            }
            self.state.withLock { $0.buffer.append(data) }
            // Process complete lines
            while true {
                let line: String? = self.state.withLock { state in
                    guard let newlineIndex = state.buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                        return nil
                    }
                    let lineData = state.buffer[state.buffer.startIndex..<newlineIndex]
                    state.buffer = Data(state.buffer[(newlineIndex + 1)...])
                    return String(data: lineData, encoding: .utf8)
                }
                guard let line else { break }
                let captured = line
                self.eventLoop.enqueueCallback {
                    onMessage(captured)
                }
            }
        }
    }

    /// Write a JSON string followed by a newline to the socket.
    func write(_ jsonString: String) {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else { return }
        if var data = jsonString.data(using: .utf8) {
            data.append(UInt8(ascii: "\n"))
            fileHandle.write(data)
        }
    }

    /// Close the socket and stop reading.
    func close() {
        let wasClosed = state.withLock { state in
            let was = state.closed
            state.closed = true
            return was
        }
        guard !wasClosed else { return }
        fileHandle.readabilityHandler = nil
        Darwin.close(fileHandle.fileDescriptor)
    }

    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    // MARK: - Unix Domain Socket Helpers

    /// Create a server socket at the given path, listen, and return (serverFD, path).
    static func createServer(at path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            return nil
        }

        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            unlink(path)
            return nil
        }

        return fd
    }

    /// Accept a connection on a server socket (blocking).
    static func acceptConnection(serverFD: Int32) -> Int32? {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(serverFD, sockaddrPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return nil }
        return clientFD
    }

    /// Connect to a Unix domain socket at the given path.
    static func connectTo(path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            return nil
        }

        return fd
    }
}
#endif
