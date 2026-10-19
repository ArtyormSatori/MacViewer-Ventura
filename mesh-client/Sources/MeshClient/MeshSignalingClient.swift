import Foundation

/// A server refusal of one of our sends, as published on
/// `MeshSignalingClient.serverRefusals`: the typed error plus the
/// correlation marker the server echoed (`ref` on the error frame).
///
/// The marker is the client-supplied identity inside the refused
/// envelope's app-plane payload — a chat message's `id`, or a
/// session negotiation's `sessionID` — so a consumer with several
/// sends in flight can attribute the refusal to exactly one of
/// them. It is nil when the refused envelope carried no marker
/// (media-plane payloads never do) or when the server predates the
/// field; consumers then fall back to their uncorrelated behavior.
public struct SignalingRefusal: Equatable, Sendable {
    public let error: MeshError
    public let ref: String?

    public init(error: MeshError, ref: String?) {
        self.error = error
        self.ref = ref
    }
}

/// The authenticated WebSocket signaling channel to the mesh server.
///
/// Handshake (server.go `handleSignal`):
/// 1. client → `{type:"auth", mesh_id}`
/// 2. server → `{type:"nonce", nonce}`
/// 3. client → `{type:"auth", signature}` — Ed25519 over the nonce string
/// 4. server → `{type:"auth_ok"}` — from here the device is "online"
///    (presence lease 30 s; this client pings every 10 s).
///
/// After the handshake, peer signals arrive on `signals` and server
/// refusals (not paired, peer offline, ...) on `serverErrors`. The
/// server only forwards signals between devices with a pairing grant.
public final class MeshSignalingClient: @unchecked Sendable {
    public let meshID: MeshID
    private let identity: MeshIdentity
    private let transport: WebSocketTransport
    private let signalURL: URL

    /// Signals forwarded from paired peers.
    public let signals: AsyncStream<SignalEnvelope>
    private let signalsContinuation: AsyncStream<SignalEnvelope>.Continuation
    /// Server-side refusals of our sends, mapped to typed errors.
    public let serverErrors: AsyncStream<MeshError>
    private let errorsContinuation: AsyncStream<MeshError>.Continuation
    /// The same refusals, enriched with the server's correlation
    /// echo (`SignalingRefusal.ref`). Every error frame is yielded
    /// on BOTH streams; consumers that need attribution subscribe
    /// here, consumers that only need the typed error stay on
    /// `serverErrors`. An unconsumed stream buffers its values, so
    /// embedders should consume one stream per refusal consumer,
    /// not leave both dangling.
    public let serverRefusals: AsyncStream<SignalingRefusal>
    private let refusalsContinuation: AsyncStream<SignalingRefusal>.Continuation

    private let stateLock = NSLock()
    private var pumpTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var didConnect = false

    public init(serverBaseURL: URL, identity: MeshIdentity, meshID: MeshID,
                transport: WebSocketTransport = WebSocketTransportFactory.makeDefault()) {
        self.identity = identity
        self.meshID = meshID
        self.transport = transport
        self.signalURL = Self.makeSignalURL(base: serverBaseURL)
        var signalsCont: AsyncStream<SignalEnvelope>.Continuation!
        self.signals = AsyncStream { signalsCont = $0 }
        self.signalsContinuation = signalsCont
        var errorsCont: AsyncStream<MeshError>.Continuation!
        self.serverErrors = AsyncStream { errorsCont = $0 }
        self.errorsContinuation = errorsCont
        var refusalsCont: AsyncStream<SignalingRefusal>.Continuation!
        self.serverRefusals = AsyncStream { refusalsCont = $0 }
        self.refusalsContinuation = refusalsCont
    }

    /// http://host → ws://host/signal, https://host → wss://host/signal
    static func makeSignalURL(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "http": components?.scheme = "ws"
        case "https": components?.scheme = "wss"
        default: break
        }
        let basePath = components?.path ?? ""
        components?.path = basePath + "/signal"
        return components?.url ?? base
    }

    public var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return didConnect
    }

    /// Connects the transport and performs the nonce-signature
    /// handshake. Throws the mapped `MeshError` if the server refuses
    /// (e.g. `.unknownDevice`, `.badSignature`).
    public func connect() async throws {
        stateLock.lock()
        if didConnect {
            stateLock.unlock()
            throw MeshError.protocolViolation("signaling client is already connected")
        }
        stateLock.unlock()

        try await transport.connect(to: signalURL)
        var iterator = transport.incoming.makeAsyncIterator()

        // Step 1-2: hello, then read the server's nonce challenge.
        try await transport.send(text: SignalingEnvelope(type: .auth, meshID: meshID).encodedJSON())
        let challenge = try await nextEnvelope(&iterator)
        if challenge.type == .error {
            throw MeshError(signalingCode: challenge.code ?? "")
        }
        guard challenge.type == .nonce, let nonce = challenge.nonce else {
            throw MeshError.protocolViolation("expected nonce challenge, got \(challenge.type.rawValue)")
        }

        // Step 3-4: sign the nonce string, expect auth_ok.
        let proof = SignalingEnvelope(
            type: .auth, signature: try identity.signatureBase64(forNonce: nonce))
        try await transport.send(text: proof.encodedJSON())
        let verdict = try await nextEnvelope(&iterator)
        if verdict.type == .error {
            throw MeshError(signalingCode: verdict.code ?? "")
        }
        guard verdict.type == .authOK else {
            throw MeshError.protocolViolation("expected auth_ok, got \(verdict.type.rawValue)")
        }

        stateLock.lock()
        didConnect = true
        stateLock.unlock()

        // Hand the same iterator to the long-lived routing pump.
        pumpTask = Task { [weak self] in
            await self?.route(iterator: iterator)
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.isConnected else { return }
                try? await self.transport.send(
                    text: SignalingEnvelope(type: .ping).encodedJSON())
            }
        }
    }

    private func nextEnvelope(
        _ iterator: inout AsyncThrowingStream<String, Error>.Iterator
    ) async throws -> SignalingEnvelope {
        guard let text = try await iterator.next() else {
            throw MeshError.connectionClosed
        }
        return try SignalingEnvelope.decodeJSON(text)
    }

    private func route(iterator: AsyncThrowingStream<String, Error>.Iterator) async {
        var iterator = iterator
        defer {
            stateLock.lock()
            didConnect = false
            stateLock.unlock()
            signalsContinuation.finish()
            errorsContinuation.finish()
            refusalsContinuation.finish()
        }
        while true {
            let text: String?
            do {
                text = try await iterator.next()
            } catch {
                return
            }
            guard let text else { return }
            guard let envelope = try? SignalingEnvelope.decodeJSON(text) else { continue }
            switch envelope.type {
            case .signal:
                if let from = envelope.from, let kind = envelope.kind, let data = envelope.data {
                    signalsContinuation.yield(SignalEnvelope(from: from, kind: kind, data: data))
                }
            case .error:
                let error = MeshError(signalingCode: envelope.code ?? "")
                errorsContinuation.yield(error)
                refusalsContinuation.yield(SignalingRefusal(error: error, ref: envelope.ref))
            case .pong:
                break // heartbeat acknowledgement
            default:
                break // nonce/auth frames after the handshake: ignore
            }
        }
    }

    /// Sends a signaling envelope to a paired peer. Delivery refusals
    /// are reported asynchronously on `serverErrors` (that is how the
    /// server answers); this throws only on transport failure.
    public func sendSignal(to peer: MeshID, kind: SignalKind, data: JSONValue) async throws {
        guard isConnected else { throw MeshError.connectionClosed }
        let envelope = SignalingEnvelope(type: .signal, to: peer, kind: kind, data: data)
        try await transport.send(text: envelope.encodedJSON())
    }

    /// Sends an application-level `{type:"ping"}` (the server replies
    /// `{type:"pong"}` and refreshes our presence lease).
    public func ping() async throws {
        try await transport.send(text: SignalingEnvelope(type: .ping).encodedJSON())
    }

    public func close() async {
        heartbeatTask?.cancel()
        pumpTask?.cancel()
        await transport.close()
        stateLock.lock()
        didConnect = false
        stateLock.unlock()
        signalsContinuation.finish()
        errorsContinuation.finish()
        refusalsContinuation.finish()
    }
}
