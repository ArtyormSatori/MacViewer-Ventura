import Foundation
import Crypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A text-frame WebSocket connection, abstracted so the signaling
/// client does not care which stack carries it.
///
/// Implementations:
/// - `URLSessionWebSocketTransport` (Darwin only): wraps
///   `URLSessionWebSocketTask`; this is what the future macOS app uses.
/// - `RFC6455WebSocketTransport`: a minimal, dependency-free RFC 6455
///   client over POSIX sockets. It is the default everywhere else and
///   the transport exercised by the Linux tests and the smoke run.
///
/// Why hand-rolled instead of websocket-kit/NIO: the signaling surface
/// is tiny (text frames, ping/pong, close), and pulling in all of
/// swift-nio for it adds version friction with Swift 6.0 for no
/// protocol gain — the gorilla/websocket server cannot tell the
/// difference, and the end-to-end smoke proves interop. The RFC 6455
/// transport speaks `ws://` only; `wss://` deployments use the Darwin
/// adapter (or a future TLS transport) — the mesh pilot runs the
/// server on loopback/LAN or behind a tunnel in this phase.
public protocol WebSocketTransport: AnyObject, Sendable {
    /// Incoming text messages. Finishes when the connection closes;
    /// finishes throwing on a transport failure.
    var incoming: AsyncThrowingStream<String, Error> { get }
    func connect(to url: URL) async throws
    func send(text: String) async throws
    func close() async
}

// POSIX calls qualified through these helpers: inside the transport
// class, unqualified `connect`/`send`/`close` resolve to the class's
// own methods instead of the libc functions.
#if canImport(Glibc)
private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    Glibc.connect(fd, address, length)
}
private func posixSend(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int, _ flags: Int32) -> Int {
    Glibc.send(fd, buffer, length, flags)
}
private func posixClose(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#elseif canImport(Darwin)
private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    Darwin.connect(fd, address, length)
}
private func posixSend(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int, _ flags: Int32) -> Int {
    Darwin.send(fd, buffer, length, flags)
}
private func posixClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif

public enum WebSocketTransportFactory {
    public static func makeDefault() -> WebSocketTransport {
        #if canImport(Darwin)
        return URLSessionWebSocketTransport()
        #else
        return RFC6455WebSocketTransport()
        #endif
    }
}

// MARK: - RFC 6455 codec (pure, unit-tested)

public enum RFC6455 {
    public struct Frame: Equatable, Sendable {
        public var fin: Bool
        public var opcode: UInt8
        public var payload: Data
        public init(fin: Bool, opcode: UInt8, payload: Data) {
            self.fin = fin
            self.opcode = opcode
            self.payload = payload
        }
    }

    public static let opContinuation: UInt8 = 0x0
    public static let opText: UInt8 = 0x1
    public static let opBinary: UInt8 = 0x2
    public static let opClose: UInt8 = 0x8
    public static let opPing: UInt8 = 0x9
    public static let opPong: UInt8 = 0xA

    /// Encodes one frame. Client frames are masked (RFC 6455 §5.3);
    /// pass a zero mask key only in tests.
    public static func encodeFrame(opcode: UInt8, payload: Data, maskKey: [UInt8]) -> Data {
        precondition(maskKey.count == 4)
        var out = Data()
        out.append(0x80 | opcode)
        let length = payload.count
        if length < 126 {
            out.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(0x80 | 127)
            let wide = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((wide >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(contentsOf: maskKey)
        for (index, byte) in payload.enumerated() {
            out.append(byte ^ maskKey[index % 4])
        }
        return out
    }

    public static func encodeText(_ text: String, maskKey: [UInt8]) -> Data {
        encodeFrame(opcode: opText, payload: Data(text.utf8), maskKey: maskKey)
    }

    /// Incremental frame parser. Feed bytes as they arrive; complete
    /// frames come back out. Handles masked and unmasked frames,
    /// 16/64-bit lengths, and frames split across feeds.
    public struct Parser {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func feed(_ data: Data) -> [Frame] {
            buffer.append(contentsOf: data)
            var frames: [Frame] = []
            while let (frame, consumed) = parseOne() {
                frames.append(frame)
                buffer.removeFirst(consumed)
            }
            return frames
        }

        private func parseOne() -> (Frame, Int)? {
            guard buffer.count >= 2 else { return nil }
            let fin = buffer[0] & 0x80 != 0
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = UInt64(buffer[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= offset + 2 else { return nil }
                length = UInt64(buffer[offset]) << 8 | UInt64(buffer[offset + 1])
                offset += 2
            } else if length == 127 {
                guard buffer.count >= offset + 8 else { return nil }
                length = 0
                for i in 0..<8 {
                    length = length << 8 | UInt64(buffer[offset + i])
                }
                offset += 8
            }
            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { return nil }
                maskKey = Array(buffer[offset..<offset + 4])
                offset += 4
            }
            guard buffer.count >= offset + Int(length) else { return nil }
            var payload = Array(buffer[offset..<offset + Int(length)])
            if masked {
                for i in payload.indices {
                    payload[i] ^= maskKey[i % 4]
                }
            }
            return (Frame(fin: fin, opcode: opcode, payload: Data(payload)), offset + Int(length))
        }
    }
}

// MARK: - RFC 6455 transport over POSIX sockets

public final class RFC6455WebSocketTransport: WebSocketTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<String, Error>
    private let incomingContinuation: AsyncThrowingStream<String, Error>.Continuation

    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private var socketFD: Int32 = -1
    private var streamFinished = false

    public init() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        self.incoming = AsyncThrowingStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    // MARK: connect + handshake

    public func connect(to url: URL) async throws {
        guard url.scheme == "ws" else {
            throw MeshError.transport(
                "RFC6455WebSocketTransport supports ws:// only (got \(url.scheme ?? "nil"))")
        }
        guard let host = url.host, !host.isEmpty else {
            throw MeshError.transport("WebSocket URL has no host")
        }
        let port = url.port ?? 80
        let path = url.path.isEmpty ? "/" : url.path

        let fd = try Self.openConnection(host: host, port: port)
        stateLock.lock()
        socketFD = fd
        stateLock.unlock()

        do {
            try performHandshake(fd: fd, host: host, port: port, path: path)
        } catch {
            closeSocket(fd)
            stateLock.lock()
            socketFD = -1
            stateLock.unlock()
            throw error
        }

        // The read loop blocks on recv(); give it a dedicated queue so
        // it never occupies a cooperative-concurrency thread.
        readerQueue.async { [weak self] in
            self?.readLoop(fd: fd)
        }
    }

    private static func openConnection(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var results: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &results)
        guard rc == 0, let results else {
            throw MeshError.transport("getaddrinfo(\(host)) failed: \(rc)")
        }
        defer { freeaddrinfo(results) }
        var current: UnsafeMutablePointer<addrinfo>? = results
        var lastError: Int32 = 0
        while let info = current {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if posixConnect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var noDelay: Int32 = 1
                    setsockopt(fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY),
                               &noDelay, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                lastError = errno
                _ = posixClose(fd)
            }
            current = info.pointee.ai_next
        }
        throw MeshError.transport("connect to \(host):\(port) failed (errno \(lastError))")
    }

    private func performHandshake(fd: Int32, host: String, port: Int, path: String) throws {
        var rng = SystemRandomNumberGenerator()
        let keyBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let key = Data(keyBytes).base64EncodedString()
        let request = """
        GET \(path) HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        try sendAll(fd: fd, bytes: [UInt8](request.utf8))

        // Read the response headers one byte at a time so no frame
        // bytes past the header terminator can be swallowed.
        var header = [UInt8]()
        var single: UInt8 = 0
        while !headerEnds(header) {
            let n = recv(fd, &single, 1, 0)
            if n <= 0 {
                throw MeshError.transport("handshake: connection closed by server")
            }
            header.append(single)
            if header.count > 16384 {
                throw MeshError.transport("handshake: response headers too large")
            }
        }
        let text = String(decoding: header, as: UTF8.self)
        guard let statusLine = text.components(separatedBy: "\r\n").first,
              statusLine.contains(" 101") else {
            throw MeshError.transport("handshake: unexpected response: \(text.prefix(120))")
        }
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        let expectedAccept = Data(Array(digest)).base64EncodedString()
        let lowered = text.lowercased()
        guard lowered.contains("sec-websocket-accept: \(expectedAccept.lowercased())") else {
            throw MeshError.transport("handshake: Sec-WebSocket-Accept mismatch")
        }
    }

    private func headerEnds(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.suffix(4)) == [0x0D, 0x0A, 0x0D, 0x0A]
    }

    // MARK: read loop (dedicated queue; recv is blocking)

    private let readerQueue = DispatchQueue(label: "mesh.rfc6455.reader", qos: .userInitiated)

    private func readLoop(fd: Int32) {
        var parser = RFC6455.Parser()
        var chunk = [UInt8](repeating: 0, count: 16384)
        var fragments = Data()
        var fragmentOpcode: UInt8 = RFC6455.opText

        func emit(_ payload: Data) {
            incomingContinuation.yield(String(decoding: payload, as: UTF8.self))
        }

        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 {
                finishStream(error: MeshError.connectionClosed)
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                finishStream(error: MeshError.connectionClosed)
                return
            }
            for frame in parser.feed(Data(chunk[0..<n])) {
                switch frame.opcode {
                case RFC6455.opText, RFC6455.opBinary:
                    if frame.fin {
                        emit(frame.payload)
                    } else {
                        fragments = frame.payload
                        fragmentOpcode = frame.opcode
                    }
                case RFC6455.opContinuation:
                    fragments.append(frame.payload)
                    if frame.fin {
                        emit(fragments)
                        fragments = Data()
                        _ = fragmentOpcode
                    }
                case RFC6455.opPing:
                    try? sendFrame(opcode: RFC6455.opPong, payload: frame.payload)
                case RFC6455.opPong:
                    break
                case RFC6455.opClose:
                    finishStream(error: nil)
                    close()
                    return
                default:
                    break
                }
            }
        }
    }

    // MARK: send / close

    public func send(text: String) async throws {
        try sendFrame(opcode: RFC6455.opText, payload: Data(text.utf8))
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        var rng = SystemRandomNumberGenerator()
        let maskValue = UInt32.random(in: .min ... .max, using: &rng)
        let maskKey = [UInt8(maskValue & 0xFF), UInt8((maskValue >> 8) & 0xFF),
                       UInt8((maskValue >> 16) & 0xFF), UInt8((maskValue >> 24) & 0xFF)]
        let bytes = [UInt8](RFC6455.encodeFrame(opcode: opcode, payload: payload, maskKey: maskKey))
        sendLock.lock()
        defer { sendLock.unlock() }
        stateLock.lock()
        let fd = socketFD
        stateLock.unlock()
        guard fd >= 0 else { throw MeshError.connectionClosed }
        try sendAll(fd: fd, bytes: bytes)
    }

    private func sendAll(fd: Int32, bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buffer in
                posixSend(fd, buffer.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw MeshError.transport("send failed (errno \(errno))")
            }
            if n == 0 {
                throw MeshError.connectionClosed
            }
            sent += n
        }
    }

    public func close() {
        stateLock.lock()
        let fd = socketFD
        socketFD = -1
        stateLock.unlock()
        if fd >= 0 {
            closeSocket(fd)
        }
        finishStream(error: nil)
    }

    private func closeSocket(_ fd: Int32) {
        shutdown(fd, 2) // SHUT_RDWR on both Linux and Darwin
        _ = posixClose(fd)
    }

    private func finishStream(error: Error?) {
        stateLock.lock()
        if streamFinished {
            stateLock.unlock()
            return
        }
        streamFinished = true
        stateLock.unlock()
        if let error {
            incomingContinuation.finish(throwing: error)
        } else {
            incomingContinuation.finish()
        }
    }
}

// MARK: - URLSession adapter (Darwin)

#if canImport(Darwin)
/// `URLSessionWebSocketTask` adapter for the future macOS app.
public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<String, Error>
    private let incomingContinuation: AsyncThrowingStream<String, Error>.Continuation
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let lock = NSLock()

    public init(session: URLSession = .shared) {
        self.session = session
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        self.incoming = AsyncThrowingStream { continuation = $0 }
        self.incomingContinuation = continuation
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.pump(task)
        }
    }

    private func pump(_ task: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    incomingContinuation.yield(text)
                case .data(let data):
                    incomingContinuation.yield(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                incomingContinuation.finish(throwing: MeshError.connectionClosed)
                return
            }
        }
    }

    public func send(text: String) async throws {
        lock.lock()
        let task = self.task
        lock.unlock()
        guard let task else { throw MeshError.connectionClosed }
        do {
            try await task.send(.string(text))
        } catch {
            throw MeshError.transport("websocket send: \(error.localizedDescription)")
        }
    }

    public func close() async {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        incomingContinuation.finish()
    }
}
#endif
