import Foundation
import Darwin

/// Relay session with an optional encrypted LAN candidate. Ordinary partner
/// Login and complete initialization are required on either selected channel.
public actor UltraViewerRelaySession {
    public struct Configuration: Sendable {
        public var registration: ClientRegistration.Request
        public var commandHost: String
        public var listenerPort: UInt16
        public var localScreenWidth: Int32
        public var localScreenHeight: Int32
        public var displayName: String
        public var enableLANDirect: Bool
        /// Development-only private packet capture; the app leaves this nil.
        public var captureDirectory: URL?

        public init(registration: ClientRegistration.Request,
                    commandHost: String = "functions3.ultraviewer.net", listenerPort: UInt16 = 443,
                    localScreenWidth: Int32, localScreenHeight: Int32, displayName: String,
                    captureDirectory: URL? = nil, enableLANDirect: Bool = true) {
            self.registration = registration
            self.commandHost = commandHost
            self.listenerPort = listenerPort
            self.localScreenWidth = localScreenWidth
            self.localScreenHeight = localScreenHeight
            self.displayName = displayName
            self.captureDirectory = captureDirectory
            self.enableLANDirect = enableLANDirect
        }
    }

    public struct Peer: Sendable {
        public let displayName: String?
        public let version: String
        public let width: Int
        public let height: Int
        public let virtualLeft: Int32
        public let virtualTop: Int32
        public let supportsBinaryKeyboard: Bool
        public let allowsRemoteInput: Bool
        public let monitors: [RemoteMonitor]
    }

    public enum Event: Sendable {
        case status(String)
        case accepted(Peer)
        case screenChanged(Peer)
        case frame(ModernScreenBitmap)
        case inputPermission(Bool)
        case chat(String)
        case typing(Bool)
        case clipboard(String)
        case computerAudio(Data)
        case cursor(CursorMessage)
        case sideSwitchRequested(RemoteControlCommands.SideSwitchRequest)
    }

    public struct Diagnostics: Sendable, Encodable {
        public var registrationAccepted = false
        public var lookupStatus: Int32?
        public var peerTransportOpened = false
        public var loginSent = false
        public var peerAccepted = false
        public var decodedFrames = 0
        public var receivedCommands: [UInt8] = []
        public var latestPartLengths: [Int] = []
        public var ignoredSources = 0
        public var relayKeepalivesSent = 0
        public var commandKeepalivesSent = 0
        public var relayPongsReceived = 0
        public var screenRefreshes = 0
        /// Auto-reconnect episodes started after a mid-session network death.
        public var reconnects = 0
        public var lastScreenFailure: String?
        public var chatMessagesSent = 0
        public var chatMessagesReceived = 0
        public var clipboardMessagesSent = 0
        public var clipboardMessagesReceived = 0
        public var relayRoundTripMilliseconds: Double?
        public var peerRoundTripMilliseconds: Double?
        public var decodeNanoseconds: UInt64 = 0
        public var maximumDecodeNanoseconds: UInt64 = 0
        public var screenPayloadBytes: UInt64 = 0
        public var lanDirectAdvertised = false
        public var lanDirectCandidates = 0
        public var lanDirectLoginSent = false
        public var lanDirectActive = false
        public var lanDirectFallbacks = 0
    }

    public enum Failure: Swift.Error, LocalizedError {
        case alreadyOpen, invalidPartner, notConnected, timedOut, closed
        case wrongPassword, lookupRejected(Int32), invalidLookupRoute, partnerBlocked
        case unsupportedVersion, malformedInitialization, consumerTooSlow, viewOnly

        public var errorDescription: String? {
            switch self {
            case .alreadyOpen: "A remote session is already open."
            case .invalidPartner: "Enter the Windows computer's UltraViewer ID and password."
            case .notConnected: "The Windows session is not connected."
            case .timedOut: "The Windows connection timed out."
            case .closed: "The remote computer disconnected."
            case .wrongPassword: "UltraViewer rejected the partner password."
            case let .lookupRejected(code): "UltraViewer declined the partner lookup (code \(code))."
            case .invalidLookupRoute: "UltraViewer returned an incomplete partner address."
            case .partnerBlocked: "The Windows computer blocked this connection."
            case .unsupportedVersion: "This Windows UltraViewer version is not supported yet."
            case .malformedInitialization: "The Windows computer returned incomplete screen information."
            case .consumerTooSlow: "The remote session could not deliver its status updates."
            case .viewOnly: "The Windows computer has enabled view-only access."
            }
        }
    }

    private enum Phase { case closed, registering, lookup, login, active }
    private var phase = Phase.closed
    private var generation = UUID()
    private var configuration: Configuration?
    private var commandTransport: FramedTCPTransport?
    private var peerTransport: FramedTCPTransport?
    private var directTransport: TCPDirectPeerTransport?
    private var directTask: Task<Void, Never>?
    private var directLoginTask: Task<Void, Never>?
    private var directDeadline: Task<Void, Never>?
    private var directWindow: Task<Void, Never>?
    private var directState = LANDirectUpgradeState()
    private var directPendingInitialization: (id: UUID, payload: Data)?
    private var relayReady = false
    private var relayFailed = false
    private var relayInitializationSuspended = false
    private var pendingRelayInitialization: (payload: Data, parts: [Data], address: RelayIPv4Address, port: UInt16)?
    private enum PeerSource: Equatable { case relay, direct(UUID) }
    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var events: AsyncThrowingStream<Event, any Swift.Error>.Continuation?
    private var renderer: ModernScreenRenderer?
    private var registrationReply: ClientRegistration.Reply?
    private var peerInfo: PeerLookup.PeerInfo?
    private var targetAddress: RelayIPv4Address?
    private var targetPort: UInt16?
    private var targetID = ""
    private var password = ""
    private var connectionHash = ""
    private var correlation: Int32 = 0
    private var remoteViewOnly = false
    private var clipboardAllowed = false
    private var peerVersion = ""
    private var audioDecoder: G722Decoder?
    private var audioEnabled = false
    private var relayPingStarted: UInt64?
    private var peerPingStarted: UInt64?
    private var capturedCommands: Set<UInt8> = []
    // Disconnect resilience (4.1): per-leg liveness replaces the single
    // shared heartbeat-failure counter, a reply watchdog catches silently
    // dead legs, and network-class deaths of an established session are
    // retried through a bounded reconnect episode instead of ending it.
    private var relayLeg = RelayLegLiveness()
    private var peerLeg = RelayLegLiveness()
    private var commandLeg = RelayLegLiveness()
    /// Set when the host itself ends the session (commands 27/41/54), so a
    /// resulting `Failure.closed` is not mistaken for a network death.
    private var hostEndedSession = false
    private var zstdTolerance = ScreenDecodeTolerance()
    private var reconnectInProgress = false
    private var reconnectTask: Task<Void, Never>?
    private var attemptFailed = false
    private var attemptError: (any Swift.Error)?
    /// Identifies the current connection attempt's consume loops. Teardown
    /// clears it, so a dying loop's late failure report can never tear
    /// down (or falsely fail) the attempt that replaced it.
    private var activeLoopID: UUID?
    /// True while `teardownConnection` runs; failure reports arriving in
    /// that window come from the connection being dismantled and are
    /// ignored by `connectionFailed`.
    private var tearingDown = false
    /// The next partner lookup is a reconnect of an established session.
    private var reconnectLookup = false
    /// A reconnect episode is waiting for its first successful
    /// initialization, which must surface as `.accepted` (full app-layer
    /// resume) rather than `.screenChanged`.
    private var resumePending = false
    /// Inbound-silence window for the reply watchdog: keepalive pings go
    /// out every 10 s and replies normally land in well under a second, so
    /// 35 s of total inbound silence on the peer path — three missed
    /// cycles plus slack — means the leg is dead even if sends still
    /// appear to succeed locally.
    private static let peerStaleWindowNanoseconds: UInt64 = 35_000_000_000
    public private(set) var diagnostics = Diagnostics()

    public init() {}

    public func connect(configuration: Configuration, partnerID: String, password: String)
        throws -> AsyncThrowingStream<Event, any Swift.Error> {
        guard phase == .closed else { throw Failure.alreadyOpen }
        guard !partnerID.isEmpty, partnerID.utf8.count <= 64,
              partnerID.utf8.allSatisfy({ (48...57).contains($0) }), !password.isEmpty else {
            throw Failure.invalidPartner
        }
        _ = try configuration.registration.encode()
        guard !configuration.registration.usesProxy else { throw Failure.invalidLookupRoute }
        self.configuration = configuration
        self.targetID = partnerID
        self.password = password
        self.connectionHash = Self.randomString(count: 16, alphabet: Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"))
        self.correlation = Int32.random(in: 1...Int32.max)
        self.diagnostics = Diagnostics()
        self.remoteViewOnly = false
        self.clipboardAllowed = false
        self.audioDecoder = nil
        self.audioEnabled = false
        self.directState = LANDirectUpgradeState()
        self.relayReady = false
        self.relayFailed = false
        self.relayInitializationSuspended = false
        self.pendingRelayInitialization = nil
        self.relayPingStarted = nil; self.peerPingStarted = nil
        self.capturedCommands = []
        self.relayLeg = RelayLegLiveness()
        self.peerLeg = RelayLegLiveness()
        self.commandLeg = RelayLegLiveness()
        self.hostEndedSession = false
        self.zstdTolerance = ScreenDecodeTolerance()
        self.reconnectInProgress = false
        self.attemptFailed = false
        self.attemptError = nil
        self.reconnectLookup = false
        self.resumePending = false
        let token = UUID()
        generation = token
        phase = .registering
        // Unbounded: a slow consumer can no longer kill the session by
        // filling a fixed buffer (the pre-4.1 emit() turned one dropped
        // status event into a fatal consumerTooSlow). Supersedable screen
        // frames are shed at the transport layer instead, where the drop
        // is counted; event ordering here stays a single strict FIFO.
        let pair = AsyncThrowingStream<Event, any Swift.Error>.makeStream(bufferingPolicy: .unbounded)
        events = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.close(ifGeneration: token) } }
        let loop = UUID()
        activeLoopID = loop
        commandTask = Task { [weak self] in await self?.begin(configuration, token: token, loop: loop) }
        return pair.stream
    }

    public func send(_ applicationPayload: Data) async throws {
        // During an authenticated screen refresh the adapter must still be able
        // to release held input, after its control permission has been suspended.
        guard diagnostics.peerAccepted, phase == .active || phase == .login else {
            throw Failure.notConnected
        }
        try await sendToPeer(applicationPayload)
    }

    /// Renegotiate a complete screen using the established clear-mode Login path.
    /// Retain the authenticated identity, but suspend control until initialization.
    public func refreshScreen() async throws {
        guard phase == .active else { throw Failure.notConnected }
        let token = generation
        diagnostics.screenRefreshes += 1
        renderer = nil
        phase = .login
        try emit(.inputPermission(false))
        try emit(.status("Refreshing the Windows screen…"))
        armDeadline(token)
        try await login(controlMode: -1, clearControlMode: true, token: token)
    }

    /// Tells an active host that this viewer is leaving, then closes.
    public func close() async {
        if phase == .active {
            let message = RemoteControlCommands.endSession
            try? await sendToPeer(message.payload, formatFlag: message.formatFlag)
        }
        await finish(nil)
    }

    public func sendChat(_ text: String) async throws {
        guard phase == .active else { throw Failure.notConnected }
        let message = try ChatProtocol.viewerToHost(text: text)
        try await sendToPeer(message.payload, formatFlag: message.formatFlag)
        diagnostics.chatMessagesSent += 1
    }

    public func sendTyping(_ typing: Bool) async throws {
        guard phase == .active else { throw Failure.notConnected }
        let message = ChatProtocol.viewerToHostTyping(typing)
        try await sendToPeer(message.payload, formatFlag: message.formatFlag)
    }

    public func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        guard phase == .active else { throw Failure.notConnected }
        guard !requiresControl || !remoteViewOnly else { throw Failure.viewOnly }
        try await sendToPeer(message.payload, formatFlag: message.formatFlag)
    }

    public func setComputerAudioEnabled(_ enabled: Bool) async throws {
        guard phase == .active else { throw Failure.notConnected }
        let token = generation
        let message = RemoteControlCommands.computerSound(enabled: enabled)
        let previous = audioEnabled
        audioEnabled = enabled
        do { try await sendToPeer(message.payload, formatFlag: message.formatFlag) }
        catch {
            if generation == token { audioEnabled = previous }
            throw error
        }
        guard generation == token, phase == .active else { throw CancellationError() }
    }

    public func setClipboardSharing(_ enabled: Bool) throws {
        guard diagnostics.peerAccepted, phase == .active || phase == .login else { throw Failure.notConnected }
        clipboardAllowed = enabled
    }

    public func sendClipboard(_ text: String) async throws {
        guard phase == .active, clipboardAllowed else { throw Failure.notConnected }
        let message = try ClipboardProtocol.viewerToHost(text, hostVersion: peerVersion)
        try await sendToPeer(message.payload, formatFlag: message.formatFlag)
        diagnostics.clipboardMessagesSent += 1
    }

    private func close(ifGeneration token: UUID) async {
        guard token == generation else { return }
        await finish(nil)
    }

    private func begin(_ config: Configuration, token: UUID, loop: UUID) async {
        guard generation == token, phase == .registering else { return }
        do {
            try emit(.status("Registering this Mac…"))
            let opened = try await RelayCommandConnection.open(host: config.commandHost, port: config.listenerPort,
                security: .tls(serverName: "ultraviewer", certificateName: "functions3.ultraviewer.net"),
                initialRequest: RelayHTTPPreamble.request(host: "functions3.ultraviewer.net"),
                expectsHTTPResponse: true)
            let transport = opened.transport, stream = opened.stream
            guard generation == token, phase != .closed else { await transport.close(); return }
            commandTransport = transport
            armDeadline(token)
            try await transport.send(config.registration.relayEnvelope(cipher: .desktopServerCommands))
            for try await frame in stream {
                try Task.checkCancellation()
                guard generation == token, phase != .closed else { return }
                try await consumeCommand(frame, token: token, loop: loop)
            }
            if generation == token, phase != .closed {
                await connectionFailed(Failure.closed, token: token, loop: loop)
            }
        } catch {
            if generation == token { await connectionFailed(error, token: token, loop: loop) }
        }
    }

    private func consumeCommand(_ bytes: Data, token: UUID, loop: UUID) async throws {
        guard case let .system(payload) = try RelayEnvelope.decode(bytes),
              let config = configuration else { return }
        if phase == .registering, payload.starts(with: Data("3:".utf8)) {
            let reply = try ClientRegistration.Reply.parse(payload)
            registrationReply = reply
            diagnostics.registrationAccepted = true
            phase = .lookup
            try emit(.status("Finding the Windows computer…"))
            let directDetails = await prepareLANDirect(config, registration: reply, token: token)
            guard generation == token, phase == .lookup else { return }
            let lookup = PeerLookup.Request(targetID: targetID, credential: .password(password),
                clientVersion: config.registration.clientVersion,
                licenseContext: config.registration.licenseContext1,
                additionalLicenseContext: config.registration.licenseContext2,
                localID: reply.assignedIDText, localPassword: config.registration.password,
                targetSessionID: -1, correlationNumber: correlation, isReconnect: reconnectLookup,
                referralIDText: "0", paymentTypeText: "0",
                dateTimeOffsetMinutes: Int32(TimeZone.current.secondsFromGMT() / 60),
                objectDictionaryCount: 1, fixedPingList: "", directDetails: directDetails)
            let encrypted = try LegacyCommandCipher.desktopServerCommands.encrypt(lookup.encode())
            armDeadline(token)
            try await commandTransport?.send(RelayEnvelope.encodeSystem(payload: encrypted, formatFlag: false))
        } else if phase == .lookup, payload.starts(with: Data("8:".utf8)) {
            let reply = try PeerLookup.Reply(plaintext: payload)
            guard reply.correlationNumber == correlation else { return }
            diagnostics.lookupStatus = reply.status
            if reply.status == 2 { throw Failure.wrongPassword }
            guard let info = try reply.peerInfo() else { throw Failure.lookupRejected(reply.status) }
            guard let address = try? RelayIPv4Address(info.publicIP),
                  let port = UInt16(exactly: info.targetTCPPort), port != 0,
                  !info.relayIP.isEmpty else { throw Failure.invalidLookupRoute }
            peerInfo = info
            targetAddress = address
            targetPort = port
            phase = .login
            deadline?.cancel()
            await configureLANDirect(info, token: token)
            guard generation == token, phase != .closed else { return }
            peerTask = Task { [weak self] in await self?.beginPeer(info, config: config, token: token, loop: loop) }
        }
    }

    private func prepareLANDirect(_ config: Configuration, registration: ClientRegistration.Reply,
                                  token: UUID) async -> PeerLookup.DirectDetails? {
        guard config.enableLANDirect, TCPDirectPeerTransport.isLANAddress(config.registration.localAddress) else {
            return nil
        }
        let transport = TCPDirectPeerTransport()
        directTransport = transport
        // Independently generated per-session transport key, carried only in the
        // already encrypted command lookup. Never log/capture it or a Login.
        let key = Self.randomString(count: 14, alphabet: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"))
        do {
            let opened = try await transport.startListener(localAddress: config.registration.localAddress, encryptionKey: key)
            guard token == generation, phase == .lookup else { await transport.close(); return nil }
            diagnostics.lanDirectAdvertised = true
            directTask = Task { [weak self] in
                do {
                    for try await event in opened.stream {
                        try Task.checkCancellation()
                        guard let self else { return }
                        await self.consumeDirect(event, token: token)
                    }
                    await self?.directListenerEnded(token: token)
                } catch { await self?.directListenerEnded(token: token) }
            }
            return PeerLookup.DirectDetails(commandPublicIP: registration.publicAddress.description,
                commandPublicSourcePort: Int32(registration.publicPort),
                localIP: opened.advertisement.localAddress.description,
                localPort: Int32(opened.advertisement.port), encryptionKey: key)
        } catch {
            if token == generation { directTransport = nil }
            await transport.close()
            return nil // A LAN optimization cannot make relay registration fail.
        }
    }

    private func configureLANDirect(_ peer: PeerLookup.PeerInfo, token: UUID) async {
        guard token == generation, let registrationReply, let transport = directTransport else { return }
        guard let address = LANDirectUpgradeState.peerLANAddress(publicAddress: peer.publicIP,
            ownPublicAddress: registrationReply.publicAddress, details: peer.directDetailsField,
            fallbackAddress: peer.lanIP) else {
            directTransport = nil
            directTask?.cancel(); directTask = nil
            directState = LANDirectUpgradeState()
            await transport.close()
            return
        }
        let rejected = directState.expect(address)
        for id in rejected { await transport.closeCandidate(id) }
        guard token == generation else { return }
        directWindow?.cancel()
        directWindow = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                await self?.directWindowExpired(token: token)
            } catch {}
        }
        beginDirectLoginIfPossible(token: token)
    }

    private func directWindowExpired(token: UUID) async {
        guard token == generation, phase != .closed, directState.selected == nil else { return }
        // LAN discovery is an initial optimization, not a permanently exposed
        // listener. Stream termination performs scoped candidate fallback.
        await directTransport?.close()
    }

    private func consumeDirect(_ event: TCPDirectPeerTransport.Event, token: UUID) async {
        guard token == generation, phase != .closed, let transport = directTransport else { return }
        switch event {
        case let .connected(id, address):
            diagnostics.lanDirectCandidates += 1
            guard diagnostics.lanDirectCandidates <= 4, directState.connected(id, address: address) else {
                await transport.closeCandidate(id); return
            }
            beginDirectLoginIfPossible(token: token)
        case let .message(id, envelope):
            if directState.loginCandidate == id, !directState.loginSent {
                // A response can race Network's send-completion callback. Hold
                // one small init, but never select it before Login was written.
                if directPendingInitialization == nil, envelope.payload.count <= 65_536,
                   let parts = try? MultipartPayload.decode(envelope.payload), parts.first == Data([0]) {
                    directPendingInitialization = (id, envelope.payload)
                }
                return
            }
            guard directState.selected == id || directState.permitsInitialization(from: id) else { return }
            do {
                try await consumeApplication(envelope.payload, source: .direct(id), token: token)
            } catch {
                guard token == generation else { return }
                if directState.selected == id, let failure = error as? Failure {
                    switch failure {
                    case .closed, .partnerBlocked, .wrongPassword:
                        await connectionFailed(error, token: token, loop: nil)
                    default: await directCandidateEnded(id, token: token)
                    }
                } else { await directCandidateEnded(id, token: token) }
            }
        case let .disconnected(id):
            await directCandidateEnded(id, token: token)
        }
    }

    private func beginDirectLoginIfPossible(token: UUID) {
        guard token == generation, phase == .login || phase == .active,
              peerInfo != nil, directTransport != nil, let id = directState.beginLogin() else { return }
        let previouslyAccepted = diagnostics.peerAccepted
        directLoginTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.login(controlMode: previouslyAccepted ? -1 : 0,
                    clearControlMode: false, token: token, source: .direct(id))
                await self.directLoginWasSent(id, token: token)
            } catch { await self.directCandidateEnded(id, token: token) }
        }
        directDeadline?.cancel()
        directDeadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                await self?.directCandidateExpired(id, token: token)
            } catch {}
        }
    }

    private func directLoginWasSent(_ id: UUID, token: UUID) async {
        guard token == generation, directState.markLoginSent(id) else { return }
        diagnostics.lanDirectLoginSent = true
        if let pending = directPendingInitialization, pending.id == id {
            directPendingInitialization = nil
            do { try await consumeApplication(pending.payload, source: .direct(id), token: token) }
            catch { await directCandidateEnded(id, token: token) }
        }
    }

    private func directCandidateExpired(_ id: UUID, token: UUID) async {
        guard token == generation, directState.selected != id else { return }
        await directCandidateEnded(id, token: token)
    }

    private func directCandidateEnded(_ id: UUID, token: UUID) async {
        guard token == generation, directState.candidates[id] != nil else { return }
        let wasLogin = directState.loginCandidate == id
        let wasSelected = directState.remove(id)
        if wasSelected {
            // This state transition must precede the first actor hop below.
            // Otherwise the old relay can re-enter against the direct cache.
            renderer = nil
            phase = .login
            relayInitializationSuspended = true
            pendingRelayInitialization = nil
            do { try emit(.inputPermission(false)) }
            catch { await finish(error); return }
        }
        if wasLogin || wasSelected {
            directDeadline?.cancel(); directDeadline = nil
            directLoginTask?.cancel(); directLoginTask = nil
        }
        if directPendingInitialization?.id == id { directPendingInitialization = nil }
        await directTransport?.closeCandidate(id)
        guard token == generation, phase != .closed else { return }
        if wasSelected {
            diagnostics.lanDirectActive = false
            diagnostics.lanDirectFallbacks += 1
            guard relayReady else { await connectionFailed(Failure.closed, token: token, loop: nil); return }
            // A failed selected direct channel needs a fresh relay Login/init,
            // not plaintext retry or reuse of a partial direct frame cache.
            do {
                try emit(.status("Restoring the Windows relay connection…"))
                armDeadline(token)
                try await login(controlMode: -1, clearControlMode: true, token: token, source: .relay)
            } catch { if token == generation { await connectionFailed(error, token: token, loop: nil) } }
        } else {
            if !relayReady, relayFailed { await connectionFailed(Failure.closed, token: token, loop: nil); return }
            // If direct Login retargeted the native host, restore its relay
            // route without throwing away a still healthy relay renderer.
            if wasLogin, relayReady {
                do {
                    if phase == .login { armDeadline(token) }
                    try await login(controlMode: diagnostics.peerAccepted ? -1 : 0,
                        clearControlMode: false, token: token, source: .relay)
                } catch { if token == generation { await relayEnded(error, token: token, loop: nil) } }
            }
            guard token == generation, phase != .closed else { return }
            beginDirectLoginIfPossible(token: token)
        }
    }

    private func directListenerEnded(token: UUID) async {
        guard token == generation, phase != .closed else { return }
        directTransport = nil
        directTask = nil
        directWindow?.cancel(); directWindow = nil
        let ids = Array(directState.candidates.keys)
        for id in ids { await directCandidateEnded(id, token: token) }
        guard token == generation else { return }
    }

    private func relayEnded(_ error: any Swift.Error, token: UUID, loop: UUID?) async {
        guard token == generation, phase != .closed else { return }
        relayReady = false
        relayFailed = true
        let transport = peerTransport; peerTransport = nil
        let task = peerTask; peerTask = nil
        task?.cancel()
        await transport?.close()
        guard token == generation, phase != .closed else { return }
        if directState.selected != nil || directState.loginCandidate != nil { return }
        await connectionFailed(error, token: token, loop: loop)
    }

    private func beginPeer(_ info: PeerLookup.PeerInfo, config: Configuration, token: UUID, loop: UUID) async {
        guard generation == token, phase != .closed else { return }
        // The peer leg carries supersedable screen frames: when the
        // consumer falls behind, shed frames (counted on the transport)
        // instead of tearing down the session. Corruption stays fatal.
        let transport = FramedTCPTransport(frameDeliveryPolicy: .dropOnConsumerTooSlow)
        peerTransport = transport
        do {
            try emit(.status("Connecting to the Windows computer…"))
            let hostname = info.relayHostname.isEmpty ? "functions3.ultraviewer.net" : info.relayHostname
            let stream = try await transport.open(host: info.relayIP, port: config.listenerPort,
                security: .tls(serverName: "ultraviewer", certificateName: hostname),
                initialRequest: RelayHTTPPreamble.request(host: hostname), expectsHTTPResponse: true)
            guard generation == token, phase != .closed else { await transport.close(); return }
            relayReady = true
            relayFailed = false
            diagnostics.peerTransportOpened = true
            if directState.selected == nil, directState.loginCandidate == nil {
                try emit(.status("Waiting for Windows to accept the session…"))
                if phase != .active { armDeadline(token) }
                try await login(controlMode: 0, clearControlMode: false, token: token, source: .relay)
            }
            for try await frame in stream {
                try Task.checkCancellation()
                guard generation == token, phase != .closed else { return }
                try await consumePeer(frame, token: token)
            }
            if generation == token, phase != .closed { await relayEnded(Failure.closed, token: token, loop: loop) }
        } catch {
            if generation == token { await relayEnded(error, token: token, loop: loop) }
        }
    }

    private func login(controlMode: Int16, clearControlMode: Bool, token: UUID,
                       source: PeerSource? = nil) async throws {
        guard token == generation, phase != .closed,
              let config = configuration, let reply = registrationReply, let peer = peerInfo else {
            throw Failure.notConnected
        }
        let context = PartnerLoginMessage.Context(screenPixelWidth: config.localScreenWidth,
            screenPixelHeight: config.localScreenHeight, desktopMetric: 0,
            screenTwipsPerPixelXText: "15", screenTwipsPerPixelYText: "15",
            formVerticalInset: 0, formHorizontalInset: 0, localID: reply.assignedIDText,
            displayName: config.displayName, controlMode: controlMode, clearControlMode: clearControlMode,
            localUserSID: "", connectionHashKey: connectionHash,
            displayColors: 2, displayQuality: 45, remoteWallpaperDisabled: 0,
            hasDesktopToken: false, partnerSecretToken: peer.partnerSecretToken ?? "",
            clientVersion: config.registration.clientVersion, desktopCounter: 0)
        let nonce = Self.randomString(count: 8, alphabet: Array("0123456789"))
        let message = PartnerLoginMessage(credential: .password(value: password, nonce: nonce), context: context)
        let destination = source ?? directState.selected.map(PeerSource.direct) ?? .relay
        try await sendToPeer(message.encode(), source: destination)
        guard generation == token, phase != .closed else { throw CancellationError() }
        if destination == .relay, relayInitializationSuspended {
            relayInitializationSuspended = false
            if let pending = pendingRelayInitialization {
                pendingRelayInitialization = nil
                try await consumeApplication(pending.payload, parts: pending.parts, source: .relay,
                    relayAddress: pending.address, relayPort: pending.port, token: token)
                guard generation == token, phase != .closed else { throw CancellationError() }
            }
        }
        diagnostics.loginSent = true
    }

    private func consumePeer(_ bytes: Data, token: UUID) async throws {
        // Any bytes on the relay leg — pong, forwarded host traffic — prove
        // the leg is alive for the reply watchdog.
        relayLeg.noteInbound(at: DispatchTime.now().uptimeNanoseconds)
        let envelope = try RelayEnvelope.decode(bytes)
        if case let .system(payload) = envelope {
            if payload == Data("pong".utf8) {
                diagnostics.relayPongsReceived += 1
                if let started = relayPingStarted {
                    diagnostics.relayRoundTripMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    relayPingStarted = nil
                }
            }
            return
        }
        guard case let .forward(address, port, _, payload) = envelope else { return }
        // The old relay stays alive as fallback, but it cannot overwrite the
        // renderer, permissions or input ACK state of an initialized direct peer.
        guard directState.selected == nil else { return }
        let knownSource = address == targetAddress && port == targetPort
        let parts: [Data]
        do { parts = try MultipartPayload.decode(payload) }
        catch {
            if !knownSource { diagnostics.ignoredSources += 1; return }
            throw error
        }
        guard let command = parts.first?.first else {
            if !knownSource { diagnostics.ignoredSources += 1; return }
            throw Failure.malformedInitialization
        }
        guard knownSource || (command == 26 && parts.count > 1 && parts[1] == Data(connectionHash.utf8)) else {
            diagnostics.ignoredSources += 1
            return
        }
        if relayInitializationSuspended {
            // Preserve only one bounded response that races the fallback Login
            // write. No relay screen/permission change is applied before it.
            if knownSource, command == 0, payload.count <= 65_536, pendingRelayInitialization == nil {
                pendingRelayInitialization = (payload, parts, address, port)
            }
            return
        }
        try await consumeApplication(payload, parts: parts, source: .relay,
            relayAddress: address, relayPort: port, token: token)
    }

    private func consumeApplication(_ payload: Data, parts suppliedParts: [Data]? = nil,
                                    source: PeerSource, relayAddress: RelayIPv4Address? = nil,
                                    relayPort: UInt16? = nil, token: UUID) async throws {
        guard token == generation, phase != .closed else { return }
        // Application traffic on whichever channel is selected (relay or
        // LAN direct) is the peer path's liveness signal.
        peerLeg.noteInbound(at: DispatchTime.now().uptimeNanoseconds)
        let parts: [Data]
        if let suppliedParts { parts = suppliedParts }
        else { parts = try MultipartPayload.decode(payload) }
        guard let command = parts.first?.first else { throw Failure.malformedInitialization }
        var upgradingID: UUID?
        if case let .direct(id) = source {
            if directState.selected != id {
                guard directState.permitsInitialization(from: id) else { return }
                // A pending direct candidate can prove acceptance only through
                // a complete ordinary Login initialization. Ignore all screen,
                // permission, chat and input traffic until that point.
                guard command == 0 else {
                    if [22, 27, 39, 41, 54].contains(command) {
                        if [27, 41, 54].contains(command) { hostEndedSession = true }
                        throw Failure.closed
                    }
                    return
                }
                guard parts.count >= 11 else { throw Failure.malformedInitialization }
                upgradingID = id
            }
        } else if directState.selected != nil { return }
        if diagnostics.receivedCommands.count < 128 { diagnostics.receivedCommands.append(command) }
        diagnostics.latestPartLengths = Array(parts.prefix(32)).map(\.count)
        if command == 0 || command == 1 { try capture(payload, command: command) }
        switch command {
        case 3, 4, 28:
            guard phase == .active, let cursor = try? CursorMessage.decode(parts: parts) else { return }
            try emit(.cursor(cursor))
        case 42, 43:
            guard phase == .active, let message = try? ComputerAudioMessage.decode(parts: parts) else { return }
            switch message {
            case let .encoded(encoded):
                if audioDecoder == nil { audioDecoder = try G722Decoder() }
                // Preserve the predictor state while paused once initialized.
                if let audioDecoder {
                    let pcm = try audioDecoder.decode(encoded)
                    if audioEnabled { try emit(.computerAudio(pcm)) }
                }
            case let .silence(count):
                if audioEnabled { try emit(.computerAudio(Data(repeating: 0, count: count))) }
            }
        case 5, 33:
            guard phase == .active, clipboardAllowed,
                  let text = try? ClipboardProtocol.decodeHostToViewer(parts: parts) else { return }
            diagnostics.clipboardMessagesReceived += 1
            try emit(.clipboard(text))
        case 12, 29, 30:
            guard phase == .active, let event = try? ChatProtocol.decodeViewerParts(parts) else { return }
            switch event {
            case let .message(text): diagnostics.chatMessagesReceived += 1; try emit(.chat(text))
            case let .typing(typing): try emit(.typing(typing))
            }
        case 0:
            guard phase == .login || phase == .active else { return }
            let initialization = try ModernScreenInitialization.decode(parts: parts)
            let geometryChanged = upgradingID != nil || renderer?.width != initialization.width || renderer?.height != initialization.height
            if geometryChanged, parts.count > 13, parts[13].isEmpty { throw Failure.malformedInitialization }
            let version = initialization.targetVersionBytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard Self.version(version, atLeast: [6, 0, 0]) else { throw Failure.unsupportedVersion }
            peerVersion = version
            if geometryChanged {
                let fresh = try ModernScreenRenderer(width: initialization.width, height: initialization.height,
                    tileSize: initialization.tileSize, displayColors: 2,
                    lastFrameNumber: upgradingID == nil ? (renderer?.lastFrameNumber ?? ModernScreenRenderer.resetFrameNumber) : ModernScreenRenderer.resetFrameNumber,
                    dictionary: UltraViewerScreenDictionary.load())
                if let upgradingID {
                    guard directState.selectInitialized(upgradingID) else { return }
                    diagnostics.lanDirectActive = true
                    relayInitializationSuspended = false
                    pendingRelayInitialization = nil
                    directDeadline?.cancel(); directDeadline = nil
                    directWindow?.cancel(); directWindow = nil
                }
                renderer = fresh
            } else {
                try renderer?.setTileSize(parts: [Data([48]), Data([UInt8(initialization.tileSize)])])
            }
            phase = .active
            deadline?.cancel()
            zstdTolerance.noteSuccess()
            let previouslyAccepted = diagnostics.peerAccepted
            diagnostics.peerAccepted = true
            if heartbeat == nil {
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(10))
                            await self?.sendHeartbeat(token)
                        } catch { return }
                    }
                }
            }
            let name = peerInfo.flatMap { Data(base64Encoded: $0.computerNameField) }
                .flatMap { String(data: $0, encoding: .utf8) }
            let peer = Peer(displayName: name, version: version,
                width: initialization.width, height: initialization.height,
                virtualLeft: initialization.virtualLeft ?? 0, virtualTop: initialization.virtualTop ?? 0,
                supportsBinaryKeyboard: Self.version(version, atLeast: [6, 2, 13]),
                allowsRemoteInput: !remoteViewOnly,
                monitors: (try? RemoteControlCommands.monitors(from: initialization.monitorInformationBytes ?? Data())) ?? [])
            // A reconnect episode's first successful initialization must
            // surface as a fresh `.accepted`, not `.screenChanged`: the app
            // layer re-runs its full session setup (input, control posture,
            // quality preset) on `.accepted`, and a resumed session needs
            // exactly that. A plain screen refresh keeps `.screenChanged`.
            let resumed = resumePending
            resumePending = false
            try emit(previouslyAccepted && !resumed ? .screenChanged(peer) : .accepted(peer))
            if upgradingID != nil { try emit(.status("Connected directly over the local network.")) }
            else if resumed { try emit(.status("Reconnected to the Windows computer.")) }
            else if previouslyAccepted { try emit(.status("Windows screen refreshed.")) }
            if let upgradingID { await directTransport?.selectCandidate(upgradingID) }
            guard token == generation, phase == .active else { return }
            // TCP ConnectionType1: source sends ASCII17 after initialization.
            try await sendToPeer(Data("17".utf8))
        case 1:
            guard phase == .active, let renderer else { return }
            diagnostics.screenPayloadBytes += UInt64(payload.count)
            let decodingStarted = DispatchTime.now().uptimeNanoseconds
            do {
                let bitmap = try renderer.apply(ModernScreenFrameMessage.decode(parts: parts))
                let elapsed = DispatchTime.now().uptimeNanoseconds - decodingStarted
                diagnostics.decodeNanoseconds += elapsed
                diagnostics.maximumDecodeNanoseconds = max(diagnostics.maximumDecodeNanoseconds, elapsed)
                diagnostics.decodedFrames += 1
                zstdTolerance.noteSuccess()
                try emit(.frame(bitmap))
                // Backpressure follows successful decoding, so a slow client
                // cannot acknowledge a growing queue of stale screen updates.
                // A lost ACK is recoverable — the next frame re-syncs — and
                // must not kill the session; a dead socket still surfaces
                // through the read loop.
                try? await sendToPeer(Data("18".utf8))
            } catch let error as ModernScreenMessageError {
                diagnostics.lastScreenFailure = String(describing: error)
                try? await sendToPeer(Data("18".utf8))
                // A malformed drawing mission must not immediately tear down an
                // authenticated connection. A new full initialization resets the
                // decoder and tile cache together; never continue a damaged cache.
                guard diagnostics.screenRefreshes < 2 else { throw error }
                try await refreshScreen()
            } catch let error as ZstdScreenDecoder.Error {
                // A corrupt zstd payload used to escape the typed catch
                // above and kill the session on its first occurrence. Give
                // it the same shape of tolerance: ACK, count it, refresh —
                // and only fail after a bounded run of consecutive bad
                // frames (a successful decode resets the budget).
                diagnostics.lastScreenFailure = String(describing: error)
                try? await sendToPeer(Data("18".utf8))
                guard !zstdTolerance.noteFailure() else { throw error }
                try await refreshScreen()
            }
        case 20:
            if let started = peerPingStarted {
                diagnostics.peerRoundTripMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                peerPingStarted = nil
            }
        case 23:
            guard phase == .active else { return }
            phase = .login
            armDeadline(token)
            try await login(controlMode: -1, clearControlMode: false, token: token)
        case 26:
            guard parts.count > 1, parts[1] == Data(connectionHash.utf8) else { return }
            guard source == .relay, let relayAddress, let relayPort else { return }
            targetAddress = relayAddress
            targetPort = relayPort
            renderer = nil
            if phase == .active {
                phase = .login
                armDeadline(token)
                try await login(controlMode: -1, clearControlMode: true, token: token)
            }
        case 27, 41, 54:
            // The host ended this session on purpose. The resulting
            // Failure.closed must not be mistaken for a network death and
            // "reconnected" against the host's explicit close.
            hostEndedSession = true
            throw Failure.closed
        case 39: throw Failure.partnerBlocked
        case 48:
            if phase == .active { try renderer?.setTileSize(parts: parts) }
        case 49:
            guard parts.count > 1, let value = parts[1].first else {
                throw Failure.malformedInitialization
            }
            remoteViewOnly = value != 0
            if phase == .active { try emit(.inputPermission(!remoteViewOnly)) }
        default: break
        }
    }

    private func sendToPeer(_ payload: Data, formatFlag: Bool = false, source: PeerSource? = nil) async throws {
        let destination = source ?? directState.selected.map(PeerSource.direct) ?? .relay
        switch destination {
        case let .direct(id):
            guard directState.selected == id || directState.loginCandidate == id,
                  let transport = directTransport else { throw Failure.notConnected }
            try await transport.send(payload, formatFlag: formatFlag, to: id)
        case .relay:
            guard relayReady, let transport = peerTransport,
                  let address = targetAddress, let port = targetPort else { throw Failure.notConnected }
            try await transport.send(RelayEnvelope.forward(address: address, port: port,
                formatFlag: formatFlag, payload: payload).encode())
        }
    }

    private func armDeadline(_ token: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
                guard let self else { return }
                await self.expired(token)
            } catch {}
        }
    }

    /// One heartbeat tick: the reply watchdog first, then one keepalive
    /// per leg, each in its own failure domain with its own counter and a
    /// bounded send. A single lost keepalive still must not tear down a
    /// healthy session — residential links drop individual sends — but
    /// three failures in a row on one leg, a send that hangs past its
    /// bound, or a full window with no inbound traffic at all each mean
    /// the leg is dead, and `connectionFailed` then decides between a
    /// reconnect episode and finishing.
    private func sendHeartbeat(_ token: UUID) async {
        guard token == generation, phase == .active else { return }
        let now = DispatchTime.now().uptimeNanoseconds

        // Reply watchdog: pings leave every 10 s and their answers are
        // inbound frames like any other, so a peer path with no inbound
        // frame of any kind for a full 35 s window is dead — even though
        // every send still "succeeds" locally. NAT reaping, a relay
        // restart and Wi-Fi roaming all die this silent way; the old
        // send-failure counter could never see it.
        if peerLeg.isStale(at: now, window: Self.peerStaleWindowNanoseconds) {
            await connectionFailed(Failure.timedOut, token: token, loop: nil)
            return
        }
        // While a direct channel carries the session, the relay leg is a
        // fallback. If it silently died, record that in state — a later
        // direct failure then finishes honestly instead of restoring
        // onto a corpse — but never disturb the healthy direct stream.
        if directState.selected != nil, relayReady,
           relayLeg.isStale(at: now, window: Self.peerStaleWindowNanoseconds) {
            relayReady = false
            relayFailed = true
        }

        // Preserve an available relay while direct is selected: a
        // relay-only heartbeat failure must not tear down an authenticated
        // direct stream (relayEnded marks the leg and returns there).
        if relayReady, let transport = peerTransport {
            do {
                relayPingStarted = DispatchTime.now().uptimeNanoseconds
                try await sendWithTimeout { try await transport.send(RelayKeepalive.relayEnvelope) }
                guard token == generation else { return }
                relayLeg.noteSendSucceeded()
                diagnostics.relayKeepalivesSent += 1
            } catch {
                guard token == generation else { return }
                if relayLeg.noteSendFailed() {
                    await relayEnded(error, token: token, loop: nil)
                    return
                }
            }
        }
        guard token == generation, phase == .active else { return }
        do {
            peerPingStarted = DispatchTime.now().uptimeNanoseconds
            try await sendWithTimeout { try await self.sendToPeer(Data("20".utf8)) }
            guard token == generation, phase == .active else { return }
            peerLeg.noteSendSucceeded()
        } catch {
            guard token == generation else { return }
            if let id = directState.selected {
                await directCandidateEnded(id, token: token)
                return
            }
            if peerLeg.noteSendFailed() {
                await connectionFailed(error, token: token, loop: nil)
                return
            }
        }
        guard token == generation, phase == .active else { return }
        // The command leg now pings every tick in its own do/catch. The
        // recovered native cadence was 60 s (frmMain.tmPingServer), which
        // left a quiet leg at the mercy of NAT idle timeouts, and a failed
        // peer "20" in the same tick used to skip the command ping too.
        if let commandTransport {
            do {
                let envelope = try RelayKeepalive.commandEnvelope()
                try await sendWithTimeout { try await commandTransport.send(envelope) }
                guard token == generation else { return }
                commandLeg.noteSendSucceeded()
                diagnostics.commandKeepalivesSent += 1
            } catch {
                guard token == generation else { return }
                if commandLeg.noteSendFailed() {
                    await connectionFailed(error, token: token, loop: nil)
                    return
                }
            }
        }
    }

    /// A heartbeat send with a hard bound of one heartbeat period: an
    /// NWConnection send parked on a half-open connection can otherwise
    /// freeze the sequential heartbeat loop forever, leaving a zombie
    /// session with no ticks and no failure counting. A timed-out send
    /// surfaces as `Failure.timedOut`, so a leg that dies by timeouts
    /// reports the honest cause if the reconnect episode is exhausted.
    private func sendWithTimeout(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        do { try await SessionSendRace.run(timeout: .seconds(10), operation: operation) }
        catch is SessionSendTimeout { throw Failure.timedOut }
    }

    private func expired(_ token: UUID) async {
        guard token == generation, phase != .closed, phase != .active else { return }
        // During a first connect this finishes (nothing was ever accepted);
        // inside a reconnect attempt it fails the attempt and the
        // supervisor applies backoff.
        await connectionFailed(Failure.timedOut, token: token, loop: nil)
    }

    private func emit(_ event: Event) throws {
        // The event stream is unbounded (see `connect`), so this yield can
        // never report `.dropped`: the pre-4.1 stream filled at eight
        // buffered events and turned one dropped status event into a fatal
        // consumerTooSlow that ended the session. Backpressure is shed at
        // the transport layer instead, where supersedable frames are
        // dropped and counted; everything emitted here keeps a single
        // strict FIFO order, control events included.
        switch events?.yield(event) {
        case .terminated: throw CancellationError()
        default: break
        }
    }

    private func finish(_ error: (any Swift.Error)?) async {
        guard phase != .closed else { return }
        phase = .closed
        generation = UUID()
        deadline?.cancel(); deadline = nil
        heartbeat?.cancel(); heartbeat = nil
        commandTask?.cancel(); commandTask = nil
        peerTask?.cancel(); peerTask = nil
        directTask?.cancel(); directTask = nil
        directLoginTask?.cancel(); directLoginTask = nil
        directDeadline?.cancel(); directDeadline = nil
        directWindow?.cancel(); directWindow = nil
        let command = commandTransport; commandTransport = nil
        let peer = peerTransport; peerTransport = nil
        let direct = directTransport; directTransport = nil
        directState = LANDirectUpgradeState()
        directPendingInitialization = nil
        relayReady = false; relayFailed = false
        relayInitializationSuspended = false; pendingRelayInitialization = nil
        diagnostics.lanDirectActive = false
        password = ""; targetID = ""; connectionHash = ""
        clipboardAllowed = false
        peerVersion = ""
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectInProgress = false
        attemptFailed = false; attemptError = nil
        activeLoopID = nil
        reconnectLookup = false
        resumePending = false
        hostEndedSession = false
        relayLeg = RelayLegLiveness(); peerLeg = RelayLegLiveness(); commandLeg = RelayLegLiveness()
        zstdTolerance = ScreenDecodeTolerance()
        audioEnabled = false; audioDecoder = nil
        relayPingStarted = nil; peerPingStarted = nil
        renderer = nil; configuration = nil; peerInfo = nil; registrationReply = nil
        targetAddress = nil; targetPort = nil
        let output = events; events = nil
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        await command?.close()
        await peer?.close()
        await direct?.close()
    }

    /// The single funnel for connection-class failures after `connect`:
    /// heartbeat thresholds, the reply watchdog, transport stream ends and
    /// expired deadlines all land here. A death of an *established* session
    /// with a network-class cause starts a bounded reconnect episode; the
    /// event stream is deliberately NOT finished, so the app layer keeps
    /// its session and simply sees status updates plus a fresh `.accepted`
    /// when the reconnect lands. Anything else — first-connect failures,
    /// wrong password, partner-blocked, a host that ended the session
    /// itself — finishes exactly as it always did.
    private func connectionFailed(_ error: any Swift.Error, token: UUID, loop: UUID?) async {
        guard token == generation, phase != .closed, !tearingDown else { return }
        if let loop, loop != activeLoopID { return }
        if reconnectInProgress {
            // A reconnect attempt just failed; record it for the
            // supervisor instead of finishing or recursing.
            attemptFailed = true
            attemptError = error
            return
        }
        guard SessionReconnectPolicy.isEligibleForReconnect(error,
                                                             hostEndedSession: hostEndedSession,
                                                             wasAccepted: diagnostics.peerAccepted) else {
            await finish(error)
            return
        }
        reconnectInProgress = true
        attemptFailed = false
        attemptError = nil
        reconnectLookup = true
        resumePending = true
        diagnostics.reconnects += 1
        await teardownConnection()
        guard token == generation, phase != .closed else { reconnectInProgress = false; return }
        phase = .registering
        try? emit(.status("Connection lost. Reconnecting…"))
        reconnectTask = Task { [weak self] in await self?.superviseReconnect(token: token) }
    }

    /// Dismantles the current attempt's transports and per-connection
    /// state while preserving everything a reconnect needs: the session
    /// identity (`configuration`, target, password, `connectionHash`,
    /// `correlation`), the diagnostics (whose `peerAccepted` marks that a
    /// session was established), and the event stream itself. Task `.value`s
    /// are deliberately never awaited here — `connectionFailed` can be
    /// executing on one of those very tasks; the `tearingDown` flag plus
    /// the loop-ID guard make their late reports harmless instead.
    private func teardownConnection() async {
        tearingDown = true
        activeLoopID = nil
        deadline?.cancel(); deadline = nil
        heartbeat?.cancel(); heartbeat = nil
        commandTask?.cancel(); commandTask = nil
        peerTask?.cancel(); peerTask = nil
        directTask?.cancel(); directTask = nil
        directLoginTask?.cancel(); directLoginTask = nil
        directDeadline?.cancel(); directDeadline = nil
        directWindow?.cancel(); directWindow = nil
        let command = commandTransport; commandTransport = nil
        let peer = peerTransport; peerTransport = nil
        let direct = directTransport; directTransport = nil
        directState = LANDirectUpgradeState()
        directPendingInitialization = nil
        relayReady = false; relayFailed = false
        relayInitializationSuspended = false; pendingRelayInitialization = nil
        diagnostics.lanDirectActive = false
        relayPingStarted = nil; peerPingStarted = nil
        renderer = nil; peerInfo = nil; registrationReply = nil
        targetAddress = nil; targetPort = nil
        clipboardAllowed = false
        peerVersion = ""
        relayLeg = RelayLegLiveness(); peerLeg = RelayLegLiveness(); commandLeg = RelayLegLiveness()
        zstdTolerance = ScreenDecodeTolerance()
        hostEndedSession = false
        await command?.close()
        await peer?.close()
        await direct?.close()
        tearingDown = false
    }

    /// Drives one reconnect episode: re-run the normal connect flow (with
    /// `isReconnect: true` in the lookup) for the same partner, with
    /// bounded attempts and backoff. Success is the new attempt reaching
    /// the initialization message, which re-emits `.accepted`; the app
    /// layer treats that as a resumed session and re-sends its control
    /// posture and quality preset. Exhaustion finishes with the last real
    /// error so the user sees the true cause, not a synthetic one.
    private func superviseReconnect(token: UUID) async {
        let policy = SessionReconnectPolicy()
        let started = DispatchTime.now().uptimeNanoseconds
        var lastError: (any Swift.Error)? = attemptError
        var attempt = 0
        while token == generation, reconnectInProgress, phase != .closed {
            guard let config = configuration else { break }
            attempt += 1
            attemptFailed = false
            attemptError = nil
            phase = .registering
            let loop = UUID()
            activeLoopID = loop
            try? emit(.status("Reconnecting to the Windows computer… (attempt \(attempt))"))
            commandTask = Task { [weak self] in await self?.begin(config, token: token, loop: loop) }
            // Wait for this attempt to succeed, fail, or run out of window.
            var windowExpired = false
            while token == generation, reconnectInProgress, !attemptFailed, phase != .active {
                if DispatchTime.now().uptimeNanoseconds - started > policy.totalWindowUptimeNanoseconds {
                    windowExpired = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !attemptFailed, !windowExpired, phase == .active, token == generation {
                reconnectInProgress = false
                reconnectTask = nil
                return
            }
            if let attemptError { lastError = attemptError }
            if windowExpired { lastError = lastError ?? Failure.timedOut }
            guard token == generation, reconnectInProgress, phase != .closed else { return }
            await teardownConnection()
            guard token == generation, reconnectInProgress, phase != .closed else { return }
            phase = .registering
            let elapsed = Duration.nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds - started))
            guard policy.shouldContinue(afterAttempt: attempt, elapsed: elapsed),
                  let delay = policy.delay(beforeAttempt: attempt + 1) else { break }
            try? await Task.sleep(for: delay)
        }
        guard token == generation, phase != .closed else { return }
        reconnectInProgress = false
        reconnectTask = nil
        await finish(lastError ?? Failure.timedOut)
    }

    private static func randomString(count: Int, alphabet: [Character]) -> String {
        String((0..<count).map { _ in alphabet.randomElement()! })
    }

    private func capture(_ payload: Data, command: UInt8) throws {
        guard let directory = configuration?.captureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let first = !capturedCommands.contains(command)
        let name = first ? "command-\(command).multipart" : "latest-command-\(command).multipart"
        let path = directory.appendingPathComponent(name).path
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | (first ? O_EXCL : O_TRUNC)
        let descriptor = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: payload)
        capturedCommands.insert(command)
    }

    private static func version(_ text: String, atLeast required: [Int]) -> Bool {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return false }
        let values = fields.compactMap { Int($0) }
        guard values.count == 3, values.allSatisfy({ $0 >= 0 }) else { return false }
        return !values.lexicographicallyPrecedes(required)
    }
}
