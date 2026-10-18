import AppKit
import Foundation
import UltraViewerProtocol

/// Main-actor UI bridge; networking and software decoding run on the session actor.
@MainActor
final class NativeUltraViewerAdapter: MacViewerSessionAdapter {
    let availability = SessionAvailability.available
    private var engine: UltraViewerRelaySession?
    private var reader: Task<Void, Never>?
    private var output: AsyncThrowingStream<RemoteSessionEvent, Error>.Continuation?
    private var encoder: MacRemoteInputEncoder?
    private var peer: UltraViewerRelaySession.Peer?
    private var allowsInput = false
    private var generation = UUID()
    private var closing: Task<Void, Never>?
    /// Latest-wins frame hand-off at the presentation boundary (FX-1):
    /// decoded frames no longer pile into an unbounded FIFO ahead of
    /// the screen; at most one awaits presentation and one queues
    /// behind it, and anything older is superseded and counted.
    private let frameCoalescer = LatestFrameCoalescer<RemoteScreenFrame>()
    /// Frames superseded before they could be presented; together with
    /// the session's decoded count and the model's presented count this
    /// is the field discriminator for a display-path backlog.
    var coalescedFrameDrops: Int { frameCoalescer.coalescedDrops }

    func connect(partnerID: String, password: String) async throws
        -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        disconnect()
        let token = UUID()
        generation = token
        let profile = try MacRegistrationProfile.loadOrCreate()
        let display = CGMainDisplayID()
        var configuration = UltraViewerRelaySession.Configuration(registration: profile,
            localScreenWidth: Int32(clamping: CGDisplayPixelsWide(display)),
            localScreenHeight: Int32(clamping: CGDisplayPixelsHigh(display)), displayName: "MacViewer")
        // Explicit developer opt-in only. Screens stay in a private local folder.
        if UserDefaults.standard.bool(forKey: "MacViewer.captureProtocolFrames"),
           let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first {
            configuration.captureDirectory = support.appendingPathComponent("MacViewer/Development")
                .appendingPathComponent("gui-capture-\(UUID().uuidString)")
        }
        let session = UltraViewerRelaySession()
        engine = session
        let incoming = try await session.connect(configuration: configuration,
            partnerID: partnerID, password: password)
        guard generation == token else { await session.close(); throw CancellationError() }
        let pair = AsyncThrowingStream<RemoteSessionEvent, Error>.makeStream()
        output = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.disconnect()
            }
        }
        reader = Task { [weak self] in
            do {
                for try await event in incoming {
                    guard let self else { break }
                    // Keep an old stream alive until disconnect's ordered input
                    // release completes, while suppressing its stale UI events.
                    guard self.generation == token else { continue }
                    switch event {
                    case let .status(message): pair.continuation.yield(.status(message))
                    case let .accepted(info):
                        // An `.accepted` arriving with a peer already
                        // known is a resumed session (auto-reconnect).
                        // The encoder's held state describes the dead
                        // connection — a button it believes is still
                        // down would silently eat the user's next real
                        // click (LAG_AUDIT H5) — so release what it
                        // holds over the new connection, then rebuild
                        // the encoder from scratch (FX-7).
                        let resumed = self.peer != nil
                        self.peer = info
                        self.allowsInput = info.allowsRemoteInput
                        if resumed, var staleEncoder = self.encoder {
                            self.encoder = nil
                            for payload in staleEncoder.encode(.releaseAll) {
                                guard self.generation == token else { break }
                                try? await session.send(payload)
                            }
                        }
                        if self.encoder == nil {
                            self.encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: info.supportsBinaryKeyboard,
                                                                 mode: KeyboardInputMode.current,
                                                                 commandAsControl: CommandKeyMapping.current == .control)
                        }
                        pair.continuation.yield(.connected(RemoteSessionInfo(partnerID: partnerID,
                            displayName: info.displayName, allowsRemoteInput: info.allowsRemoteInput,
                            monitors: info.monitors, virtualLeft: info.virtualLeft, virtualTop: info.virtualTop)))
                    case let .frame(bitmap):
                        guard let image = bitmap.makeCGImage() else {
                            // The session counted this frame as decoded;
                            // an unrenderable bitmap still leaves the
                            // pipeline here, so release its pacing credit
                            // instead of letting ACK pacing stall on it.
                            self.signalFrameConsumed()
                            continue
                        }
                        // FX-1: offer the frame to the coalescer; only
                        // a frame with a free presentation slot is
                        // yielded downstream. Queued/coalesced frames
                        // wait for (or are superseded before) the
                        // model's consumption signal — they are never
                        // stacked into the output stream.
                        switch self.frameCoalescer.offer(RemoteScreenFrame(image: image)) {
                        case let .present(frame): pair.continuation.yield(.frame(frame))
                        case .queued, .coalesced: break
                        }
                    case let .screenChanged(info):
                        self.peer = info
                        self.allowsInput = info.allowsRemoteInput
                        pair.continuation.yield(.screenGeometryChanged(RemoteSessionInfo(partnerID: partnerID,
                            displayName: info.displayName, allowsRemoteInput: info.allowsRemoteInput,
                            monitors: info.monitors, virtualLeft: info.virtualLeft, virtualTop: info.virtualTop)))
                        pair.continuation.yield(.inputPermissionChanged(info.allowsRemoteInput))
                    case let .chat(text): pair.continuation.yield(.chat(text))
                    case let .typing(typing): pair.continuation.yield(.typing(typing))
                    case let .clipboard(text): pair.continuation.yield(.clipboard(text))
                    case let .computerAudio(pcm): pair.continuation.yield(.computerAudio(pcm))
                    case let .cursor(cursor): pair.continuation.yield(.cursor(cursor))
                    case .sideSwitchRequested: break
                    case let .inputPermission(allowed):
                        self.allowsInput = allowed
                        pair.continuation.yield(.inputPermissionChanged(allowed))
                        if !allowed {
                            for payload in self.encoder?.encode(.releaseAll) ?? [] {
                                guard self.generation == token else { break }
                                try? await session.send(payload)
                            }
                        }
                    }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        return pair.stream
    }

    /// The app took one frame off the event stream: promote the
    /// coalescer's pending frame (if any) into the freed presentation
    /// slot, and release one pacing credit in the session (FX-1/FX-2).
    func noteFrameConsumed() {
        if let next = frameCoalescer.consume() {
            output?.yield(.frame(next))
        }
        signalFrameConsumed()
    }

    /// Releases one decoded-but-unpresented credit in the session.
    /// Fire-and-forget: consumption signals are commutative decrements
    /// (floored at zero in the session), so their delivery order
    /// against each other does not matter, and each is causally after
    /// the decode increment of the frame it releases.
    private func signalFrameConsumed() {
        guard let engine else { return }
        Task { await engine.noteFrameConsumed() }
    }

    func send(_ input: RemoteInput) async throws {
        guard let engine, let peer else { throw UltraViewerRelaySession.Failure.notConnected }
        let token = generation
        guard allowsInput || input == .releaseAll else { throw UltraViewerRelaySession.Failure.viewOnly }
        let translated: RemoteInput
        switch input {
        case let .pointerMoved(x, y):
            translated = .pointerMoved(x: min(max(0, x), peer.width - 1) + Int(peer.virtualLeft),
                                       y: min(max(0, y), peer.height - 1) + Int(peer.virtualTop))
        case let .pointerButton(button, pressed, x, y):
            translated = .pointerButton(button: button, pressed: pressed,
                x: min(max(0, x), peer.width - 1) + Int(peer.virtualLeft),
                y: min(max(0, y), peer.height - 1) + Int(peer.virtualTop))
        default: translated = input
        }
        for payload in encoder?.encode(translated) ?? [] {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard allowsInput || input == .releaseAll else { throw UltraViewerRelaySession.Failure.viewOnly }
            try await engine.send(payload)
        }
    }

    func sendChat(_ text: String) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendChat(text)
    }

    func sendTyping(_ typing: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendTyping(typing)
    }

    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendCommand(message, requiresControl: requiresControl)
    }

    func setClipboardSharing(_ enabled: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.setClipboardSharing(enabled)
    }

    func setComputerAudioEnabled(_ enabled: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.setComputerAudioEnabled(enabled)
    }

    func sendClipboard(_ text: String) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendClipboard(text)
    }

    func disconnect() {
        generation = UUID()
        let oldEngine = engine
        let oldReader = reader
        let releases = encoder?.encode(.releaseAll) ?? []
        engine = nil; reader = nil; encoder = nil; peer = nil; allowsInput = false
        frameCoalescer.reset()
        output?.finish(); output = nil
        let previous = closing
        closing = Task {
            await previous?.value
            if let oldEngine {
                for payload in releases { try? await oldEngine.send(payload) }
                await oldEngine.close()
            }
            oldReader?.cancel()
        }
    }

    func waitUntilClosed() async { await closing?.value }
}
