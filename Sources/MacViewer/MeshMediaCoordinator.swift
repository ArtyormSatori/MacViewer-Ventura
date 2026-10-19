import Combine
import CoreGraphics
import Foundation
import MeshClient
import MeshWebRTC
import WebRTC

/// Lock-protected hand-off of the size actually being streamed,
/// written on the main actor when capture starts and read from
/// the applier's `@Sendable` display-size provider (which runs
/// on WebRTC threads, where the coordinator's main-actor state
/// is unreachable).

/// Single-value hand-off for a remote video track: RTCVideoTrack
/// is not Sendable, but the session retains it for its own
/// lifetime (run-16 law), so carrying the reference across the
/// main-actor hop in an @unchecked Sendable box is sound.
private final class RemoteTrackBox: @unchecked Sendable {
    let track: RTCVideoTrack
    init(_ track: RTCVideoTrack) { self.track = track }
}

private final class StreamedSizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var size: MeshDisplaySize?
    func update(_ newValue: MeshDisplaySize?) { lock.withLock { size = newValue } }
    func read() -> MeshDisplaySize? { lock.withLock { size } }
}

/// How the current media path reaches the peer, for the session
/// window's badge. Driven by the selected candidate pair's
/// local candidate type: a host / server-reflexive /
/// peer-reflexive candidate means the media flows directly
/// between the two devices; a relay candidate means it flows
/// through a TURN relay. Nil (no badge) until a pair is
/// selected — never guessed.
enum MeshLinkKind: Equatable {
    case direct
    case relay

    init?(candidateType: MeshCandidateType?) {
        switch candidateType {
        case .host, .srflx, .prflx: self = .direct
        case .relay: self = .relay
        case .unknown, nil: return nil
        }
    }
}

/// The small link readout shown next to the badge: round-trip
/// time and received frame rate, read from the flattened
/// getStats entries the core exposes (`fetchStatisticsEntries`).
/// Only fields actually present in the stats are reported —
/// absent stays nil, never invented.
struct MeshLinkStats: Equatable {
    var roundTripMilliseconds: Int?
    var receivedFramesPerSecond: Int?

    static func read(from entries: [MeshStatsEntry]) -> MeshLinkStats {
        var stats = MeshLinkStats()
        // The selected pair, chosen exactly the way the core's
        // MeshStatsSelection chooses it for the badge: the
        // transport's selectedCandidatePairId wins, otherwise
        // the nominated succeeded pair, otherwise any succeeded
        // pair.
        let pairs = entries.filter { $0.type == "candidate-pair" }
        var pair: MeshStatsEntry?
        if let transport = entries.first(where: { $0.type == "transport" }),
           case .string(let pairID)? = transport.values["selectedCandidatePairId"] {
            pair = pairs.first(where: { $0.id == pairID })
        }
        if pair == nil {
            pair = pairs.first(where: { isSucceeded($0) && isTruthy($0.values["nominated"]) })
                ?? pairs.first(where: isSucceeded)
        }
        if let pair, case .number(let seconds)? = pair.values["currentRoundTripTime"],
           seconds.isFinite {
            stats.roundTripMilliseconds = Int((seconds * 1000).rounded())
        }
        // Received video rate: the video inbound-rtp entry's
        // framesPerSecond (W3C getStats).
        for entry in entries where entry.type == "inbound-rtp" {
            let kind = entry.values["kind"] ?? entry.values["mediaType"]
            guard case .string("video")? = kind else { continue }
            if case .number(let fps)? = entry.values["framesPerSecond"], fps.isFinite {
                stats.receivedFramesPerSecond = Int(fps.rounded())
            }
            break
        }
        return stats
    }

    private static func isSucceeded(_ entry: MeshStatsEntry) -> Bool {
        if case .string("succeeded")? = entry.values["state"] { return true }
        return false
    }

    private static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(true): return true
        case .number(let number): return number != 0
        default: return false
        }
    }
}

/// Wires chunk-2 sessions to the WebRTC media plane (M1 part
/// 3b). Owned by `MeshSessionModel` next to the session
/// controller and the chat center.
///
/// Lifecycle: the coordinator follows the controller's phase.
/// When a session becomes ACTIVE it builds the peer session —
/// the session REQUESTER is the WebRTC initiator, the ACCEPTER
/// is the responder — and when the phase leaves active for ANY
/// reason (rejected never reaches active; ended by either side,
/// timeout, local end, controller stop) the peer session is
/// closed, capture stopped, held host input released, and the
/// viewer's input sender sealed with a final `releaseAll`.
///
/// Demux: the signaling stream still has exactly one consumer
/// (the session controller). Envelopes the controller does not
/// claim arrive here through the same `onUnhandledSignal`
/// fan-out the chat center uses. Before anything reaches the
/// peer session it is checked with the core's own pure router
/// (`MeshPeerSignaling.route`): app-plane payloads (the
/// mvSession / mvChat object envelopes), envelopes from the
/// wrong peer, and kinds this role must not receive are
/// `.ignored` there and never forwarded — the chat center sees
/// the same fan-out independently and applies its own codec,
/// so neither plane can starve the other.
///
/// Race cover: the controller can pump a media envelope in the
/// same moments the phase flips to active, before this
/// coordinator's phase sink has run. While the controller says
/// a session is active but no peer session exists yet,
/// media-shaped envelopes (SDP strings, the pinned ICE object
/// form) are buffered (bounded) and replayed — through the
/// same router check — the moment the peer session is created.
@MainActor
final class MeshMediaCoordinator: ObservableObject {
    // Viewer-side published state (session window).
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var inputSender: MeshInputSender?
    @Published private(set) var linkKind: MeshLinkKind?
    @Published private(set) var linkStats: MeshLinkStats?
    @Published private(set) var mediaFailed = false
    // Host-side published state (This-device status strip).
    @Published private(set) var isSharingScreen = false
    @Published private(set) var hostCaptureError: String?

    private let localID: MeshID
    private let makePeerSession: (MeshPeerRole, MeshID) -> MeshPeerSessioning
    private let makeApplier: (Bool, @escaping @Sendable () -> MeshDisplaySize?) -> MeshInputApplying
    private let streamedSizeBox = StreamedSizeBox()

    private weak var controller: MeshSessionController?
    private var phaseCancellable: AnyCancellable?
    private var mediaSessionID: String?
    private var peerSession: MeshPeerSessioning?
    private var router: MeshPeerSignaling?
    private var capture: MeshScreenCapturing?
    private var applier: MeshInputApplying?
    private var inboundBuffer: [SignalEnvelope] = []
    private var controlPump: Task<Void, Never>?
    private var statePump: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    private static let inboundBufferLimit = 64

    init(localID: MeshID,
         makePeerSession: @escaping (MeshPeerRole, MeshID) -> MeshPeerSessioning,
         makeApplier: @escaping (Bool, @escaping @Sendable () -> MeshDisplaySize?) -> MeshInputApplying) {
        self.localID = localID
        self.makePeerSession = makePeerSession
        self.makeApplier = makeApplier
    }

    // MARK: Factories for the real wiring (used by MeshSessionModel)

    /// The real peer-session factory: a `MeshPeerSession` whose
    /// outbound envelopes go through the signaling client.
    static func realPeerSessionFactory(signaling: MeshSignalingAPI,
                                       localID: MeshID) -> (MeshPeerRole, MeshID) -> MeshPeerSessioning {
        { role, peer in
            MeshPeerSession(localID: localID, remoteID: peer, role: role) { envelope in
                guard let to = envelope.to, let kind = envelope.kind,
                      let data = envelope.data else { return }
                Task { try? await signaling.sendSignal(to: to, kind: kind, data: data) }
            }
        }
    }

    /// The real applier factory: the CGEvent executor from the
    /// MeshWebRTC target.
    static var realApplierFactory: (Bool, @escaping @Sendable () -> MeshDisplaySize?) -> MeshInputApplying {
        { controlAllowed, sizeProvider in
            MeshInputApplier(controlAllowed: controlAllowed,
                             displaySizeProvider: sizeProvider)
        }
    }

    // MARK: Binding

    func bind(to controller: MeshSessionController) {
        phaseCancellable?.cancel()
        self.controller = controller
        phaseCancellable = controller.$phase.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.phaseChanged() }
        }
        // A bind can land when a session is already active
        // (the model builds both objects together, but a late
        // bind must not miss the activation).
        phaseChanged()
    }

    func unbind() {
        phaseCancellable?.cancel()
        phaseCancellable = nil
        controller = nil
        endMedia()
    }

    // MARK: Inbound demux (called from the model's fan-out)

    func routeInbound(_ envelope: SignalEnvelope) {
        if let session = peerSession {
            routeToSession(envelope, session: session)
            return
        }
        guard let controller, case .active = controller.phase else { return }
        switch (envelope.kind, envelope.data) {
        case (.offer, .string), (.answer, .string), (.ice, .object):
            if inboundBuffer.count < Self.inboundBufferLimit {
                inboundBuffer.append(envelope)
            }
        default:
            break
        }
    }

    private func routeToSession(_ envelope: SignalEnvelope, session: MeshPeerSessioning) {
        guard let router else { return }
        if case .ignored = router.route(envelope) { return }
        session.handleSignal(envelope)
    }

    // MARK: Phase following

    private func phaseChanged() {
        guard let controller else { return }
        switch controller.phase {
        case let .active(sessionID, peer, _, role, capabilities, _):
            guard mediaSessionID != sessionID else { return }
            // Envelopes that raced ahead of this activation are
            // buffered for the NEW session, but the teardown of
            // any previous session clears the buffer — carry the
            // racing envelopes across the reset. (The replay in
            // beginMedia still filters them by peer.)
            let racingEnvelopes = inboundBuffer
            endMedia()
            inboundBuffer = racingEnvelopes
            mediaSessionID = sessionID
            beginMedia(peer: peer, role: role, capabilities: capabilities)
        default:
            if mediaSessionID != nil { endMedia() }
        }
    }

    private func beginMedia(peer: MeshID, role: MeshSessionController.Role,
                            capabilities: Set<MeshSessionCapability>) {
        // The requester drives negotiation; the accepter
        // answers. This mapping is the session's core contract.
        let peerRole: MeshPeerRole = role == .viewer ? .initiator : .responder
        let session = makePeerSession(peerRole, peer)
        peerSession = session
        router = MeshPeerSignaling(localID: localID, remoteID: peer, role: peerRole)

        statePump = Task { [weak self, session] in
            for await state in session.states {
                guard let self, self.peerSession === session else { return }
                self.mediaFailed = state == .failed
            }
        }

        if role == .viewer {
            session.onRemoteVideoTrack = { [weak self] track in
                let box = RemoteTrackBox(track)
                Task { @MainActor [weak self] in
                    guard let self, self.peerSession != nil else { return }
                    self.remoteVideoTrack = box.track
                }
            }
            inputSender = MeshInputSender { [session] data in
                session.sendControl(data)
            }
            Task { try? await session.start() }
            startStatsLoop()
        } else {
            // Host. The applier's display size tracks the size
            // actually being streamed; before capture starts (or
            // in a control-only session, where nothing is
            // streamed) it falls back to the main display's real
            // size, which is what the viewer's normalized input
            // describes.
            let sizeBox = streamedSizeBox
            let applier = makeApplier(capabilities.contains(.control)) {
                sizeBox.read() ?? Self.mainDisplaySize()
            }
            self.applier = applier
            controlPump = Task { [session, applier] in
                for await data in session.controlMessages {
                    applier.apply(data: data)
                }
            }
            if capabilities.contains(.view) {
                // Responder ordering contract (part 2): the
                // screen track must exist BEFORE the offer is
                // fed to handleSignal — so capture is created
                // here, synchronously at activation, ahead of
                // the buffered-envelope replay below.
                if let capture = session.makeScreenCapture() {
                    self.capture = capture
                    capture.onFailure = { [weak self] message in
                        self?.hostCaptureError = message
                        self?.isSharingScreen = false
                    }
                    Task { [weak self, capture] in
                        do {
                            try await capture.startMainDisplay()
                            self?.streamedSizeBox.update(capture.streamedSize)
                            self?.isSharingScreen = true
                        } catch {
                            self?.hostCaptureError = String(describing: error)
                        }
                    }
                }
            }
            // Control-only session: no view capability means no
            // capture, honestly — the peer session still
            // negotiates (its control channel carries the
            // input), and the applier above is live.
        }

        // Replay anything that raced ahead of activation,
        // through the same router check as live traffic.
        let buffered = inboundBuffer
        inboundBuffer = []
        for envelope in buffered where envelope.from == peer {
            routeToSession(envelope, session: session)
        }
    }

    private func endMedia() {
        statsTask?.cancel()
        statsTask = nil
        controlPump?.cancel()
        controlPump = nil
        statePump?.cancel()
        statePump = nil
        // The viewer seals its input first, while the control
        // channel is still open: flush + releaseAll, so the
        // host is never left holding this side's input.
        inputSender?.endSession()
        inputSender = nil
        // The host likewise releases whatever the viewer left
        // held on this machine.
        applier?.releaseAll()
        applier = nil
        if let capture {
            Task { await capture.stop() }
        }
        capture = nil
        streamedSizeBox.update(nil)
        peerSession?.close()
        peerSession = nil
        router = nil
        mediaSessionID = nil
        inboundBuffer = []
        remoteVideoTrack = nil
        linkKind = nil
        linkStats = nil
        mediaFailed = false
        isSharingScreen = false
        hostCaptureError = nil
    }

    // MARK: Link stats (viewer)

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollLinkStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One stats refresh: badge kind + RTT/fps readout. The
    /// loop calls it once a second (spec §5.6); tests call it
    /// directly.
    func pollLinkStats() async {
        guard let session = peerSession else { return }
        async let type = session.fetchSelectedCandidatePairType()
        async let entries = session.fetchStatisticsEntries()
        let (candidateType, statsEntries) = await (type, entries)
        guard let current = peerSession, current === session else { return }
        linkKind = MeshLinkKind(candidateType: candidateType)
        linkStats = MeshLinkStats.read(from: statsEntries)
    }

    private nonisolated static func mainDisplaySize() -> MeshDisplaySize? {
        let displayID = CGMainDisplayID()
        let width = CGDisplayPixelsWide(displayID)
        let height = CGDisplayPixelsHigh(displayID)
        guard width > 0, height > 0 else { return nil }
        return MeshDisplaySize(width: width, height: height)
    }
}
