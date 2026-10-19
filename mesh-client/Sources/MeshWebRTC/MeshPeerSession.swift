#if os(macOS)
import Foundation
import MeshClient
import WebRTC

/// Connection state of a `MeshPeerSession` — a 1:1 mapping of
/// the framework's `RTCPeerConnectionState`.
public enum MeshPeerConnectionState: String, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed

    init(_ state: RTCPeerConnectionState) {
        switch state {
        case .new: self = .new
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .failed: self = .failed
        case .closed: self = .closed
        @unknown default: self = .closed
        }
    }
}

extension MeshICECandidate {
    /// The framework candidate in wire form. A missing `sdpMid`
    /// becomes "0", matching the spike's convention.
    init(_ candidate: RTCIceCandidate) {
        self.init(sdp: candidate.sdp,
                  sdpMid: candidate.sdpMid ?? "0",
                  sdpMLineIndex: candidate.sdpMLineIndex)
    }

    var rtcCandidate: RTCIceCandidate {
        RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}

/// Retained owner of one end of the control data channel.
///
/// Carries the run-15/16 lessons (M1_WEBRTC_DECISION.md
/// addendum): `RTCDataChannel.delegate` is weak and nothing in
/// the framework retains a remotely opened channel wrapper, so
/// the channel is retained HERE for the session's lifetime; and
/// a send is never assumed to land just because it was issued —
/// payloads queue until this end reports `.open`, then flush in
/// order. A rejected `sendData` leaves the payload queued for
/// the next flush trigger (state change, buffered-amount
/// change, or the next send) instead of dropping it.
private final class ControlChannelEnd: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var channel: RTCDataChannel?
    private var pending: [Data] = []
    private var flushing = false

    var onMessage: (@Sendable (Data) -> Void)?

    /// Takes ownership of a channel (locally created on the
    /// initiator, remotely opened on the responder) and becomes
    /// its delegate.
    func attach(_ channel: RTCDataChannel) {
        lock.withLock { self.channel = channel }
        channel.delegate = self
        flush()
    }

    func send(_ data: Data) {
        lock.withLock { pending.append(data) }
        flush()
    }

    func close() {
        let target: RTCDataChannel? = lock.withLock {
            let current = channel
            channel = nil
            pending = []
            return current
        }
        target?.close()
    }

    private func flush() {
        let shouldRun: Bool = lock.withLock {
            if flushing { return false }
            flushing = true
            return true
        }
        guard shouldRun else { return }
        defer { lock.withLock { flushing = false } }
        while true {
            let snapshot: (RTCDataChannel?, Data?) = lock.withLock {
                (channel, pending.first)
            }
            guard let channel = snapshot.0, let head = snapshot.1,
                  channel.readyState == .open else { return }
            guard channel.sendData(RTCDataBuffer(data: head, isBinary: true)) else { return }
            lock.withLock {
                if pending.first == head { pending.removeFirst() }
            }
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open { flush() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        flush()
    }
}

/// One WebRTC peer session with one paired peer: an
/// `RTCPeerConnection`, its negotiation over the mesh signaling
/// codec, and the `mv-control` data channel.
///
/// The session does NOT own the signaling stream. The caller
/// (the app, today the single consumer of
/// `MeshSignalingClient.signals`) feeds inbound signals to
/// `handleSignal(_:)` and wires the `sendSignal` sink given at
/// init to `MeshSignalingClient.sendSignal`. All wire forms and
/// routing decisions live in the pure `MeshPeerSignaling` glue.
///
/// Lifetime discipline (run-16 law): the session retains the
/// factory, the peer connection, and the control-channel owner
/// for its whole life; both delegates (the session itself for
/// the peer connection, the retained `ControlChannelEnd` for
/// the channel) are therefore never left dangling by the
/// framework's weak delegate references. Delegate callbacks
/// arrive on WebRTC threads; every state mutation goes through
/// the lock (with `withLock`, never lock/unlock by hand), and
/// description operations are serialized on `opQueue`.
public final class MeshPeerSession: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {

    /// Label of the control data channel created by the
    /// initiator before offering.
    public static let controlChannelLabel = "mv-control"

    /// Track / stream ids of the local screen video track
    /// (`addScreenTrack()`).
    public static let screenTrackID = "mv-screen"
    public static let screenStreamID = "mv-stream"

    public let signaling: MeshPeerSignaling
    public var localID: MeshID { signaling.localID }
    public var remoteID: MeshID { signaling.remoteID }
    public var role: MeshPeerRole { signaling.role }

    /// Called (on an arbitrary thread) when an inbound signal
    /// was routed to `.ignored` — wrong peer, wrong role for its
    /// kind, or a malformed / app-plane payload. Set before
    /// `start()`; useful for diagnostics and tests.
    public var onIgnoredSignal: (@Sendable (SignalEnvelope, PeerSignalIgnoreReason) -> Void)?

    /// Connection states as they change; the current value is
    /// also readable synchronously via `state`.
    public let states: AsyncStream<MeshPeerConnectionState>
    /// Payloads received on the control channel, in order.
    public let controlMessages: AsyncStream<Data>

    /// Called (on an arbitrary WebRTC thread) when a remote
    /// video track arrives — the surface part 3 renders from.
    /// Set before `start()`; tracks are also retained by the
    /// session (`remoteVideoTracks`).
    public var onRemoteVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?

    private let sendSignal: @Sendable (SignalingEnvelope) -> Void
    private let factory: RTCPeerConnectionFactory
    private let pc: RTCPeerConnection
    private let control = ControlChannelEnd()
    private var screenTrackStorage: MeshScreenTrack?
    private var remoteVideoTrackStorage: [RTCVideoTrack] = []
    private let opQueue = DispatchQueue(label: "mesh.peersession.ops")
    private let lock = NSLock()
    private var currentState: MeshPeerConnectionState = .new
    private var candidateBuffer = ICECandidateBuffer()
    private var isClosed = false
    private let statesContinuation: AsyncStream<MeshPeerConnectionState>.Continuation
    private let controlContinuation: AsyncStream<Data>.Continuation

    private static let sslInitialized: Bool = RTCInitializeSSL()

    public init(localID: MeshID, remoteID: MeshID, role: MeshPeerRole,
                iceServers: [RTCIceServer] = [],
                sendSignal: @escaping @Sendable (SignalingEnvelope) -> Void) {
        _ = Self.sslInitialized
        self.signaling = MeshPeerSignaling(localID: localID, remoteID: remoteID, role: role)
        self.sendSignal = sendSignal
        let factory = RTCPeerConnectionFactory()
        self.factory = factory
        let config = RTCConfiguration()
        config.iceServers = iceServers
        guard let pc = factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil,
                                             optionalConstraints: nil),
            delegate: nil)
        else { fatalError("RTCPeerConnectionFactory returned no peer connection") }
        self.pc = pc
        var statesCont: AsyncStream<MeshPeerConnectionState>.Continuation!
        self.states = AsyncStream { statesCont = $0 }
        self.statesContinuation = statesCont
        var controlCont: AsyncStream<Data>.Continuation!
        self.controlMessages = AsyncStream { controlCont = $0 }
        self.controlContinuation = controlCont
        super.init()
        pc.delegate = self
        control.onMessage = { data in controlCont.yield(data) }
        if role == .initiator,
           let channel = pc.dataChannel(forLabel: Self.controlChannelLabel,
                                        configuration: RTCDataChannelConfiguration()) {
            control.attach(channel)
        }
        statesContinuation.yield(.new)
    }

    /// The current connection state, synchronously.
    public var state: MeshPeerConnectionState {
        lock.withLock { currentState }
    }

    // MARK: - Negotiation

    /// Initiator only: creates the offer and sends it through
    /// the sink. The control channel was already created in
    /// `init`, so it is part of this offer. The responder never
    /// calls this — it answers from `handleSignal(_:)`.
    public func start() async throws {
        guard role == .initiator else {
            throw MeshError.protocolViolation(
                "only the initiator starts negotiation; the responder waits for the offer")
        }
        guard lock.withLock({ !isClosed }) else { throw MeshError.connectionClosed }
        let pc = self.pc
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            opQueue.async {
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                      optionalConstraints: nil)
                pc.offer(for: constraints) { offer, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let offer else {
                        continuation.resume(throwing: MeshError.protocolViolation(
                            "offer creation returned no description"))
                        return
                    }
                    pc.setLocalDescription(offer) { setError in
                        if let setError {
                            continuation.resume(throwing: setError)
                            return
                        }
                        continuation.resume(returning: offer)
                    }
                }
            }
        }
        sendSignal(signaling.offerEnvelope(sdp: offer.sdp))
    }

    /// Feeds one inbound signal (as yielded by
    /// `MeshSignalingClient.signals`) to the session. Signals
    /// from other peers, for the wrong role, or with app-plane /
    /// malformed payloads are ignored without touching the
    /// session's state (and reported via `onIgnoredSignal`).
    public func handleSignal(_ signal: SignalEnvelope) {
        guard lock.withLock({ !isClosed }) else { return }
        switch signaling.route(signal) {
        case .ignored(let reason):
            onIgnoredSignal?(signal, reason)
        case .remoteDescription(let kind, let sdp):
            applyRemoteDescription(kind: kind, sdp: sdp)
        case .remoteCandidate(let candidate):
            let toApply = lock.withLock { candidateBuffer.add(candidate) }
            applyCandidates(toApply)
        }
    }

    private func applyRemoteDescription(kind: SignalKind, sdp: String) {
        let description = RTCSessionDescription(type: kind == .offer ? .offer : .answer,
                                                sdp: sdp)
        let pc = self.pc
        opQueue.async { [self] in
            pc.setRemoteDescription(description) { [self] error in
                guard error == nil else { return }
                let drained = lock.withLock { candidateBuffer.remoteDescriptionSet() }
                applyCandidates(drained)
                guard kind == .offer else { return }
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                                      optionalConstraints: nil)
                pc.answer(for: constraints) { [self] answer, _ in
                    guard let answer else { return }
                    pc.setLocalDescription(answer) { [self] setError in
                        guard setError == nil else { return }
                        sendSignal(signaling.answerEnvelope(sdp: answer.sdp))
                    }
                }
            }
        }
    }

    private func applyCandidates(_ candidates: [MeshICECandidate]) {
        for candidate in candidates {
            pc.add(candidate.rtcCandidate) { _ in }
        }
    }

    // MARK: - Control channel

    /// Sends one payload on the control channel. Sends issued
    /// before the channel opens are queued and flushed in order
    /// when it opens — never dropped, never a crash. Sends after
    /// `close()` are discarded (the session is over).
    public func sendControl(_ data: Data) {
        guard lock.withLock({ !isClosed }) else { return }
        control.send(data)
    }

    // MARK: - Video track

    /// The local screen video track, once `addScreenTrack()`
    /// has run; nil before that.
    public var screenTrack: MeshScreenTrack? {
        lock.withLock { screenTrackStorage }
    }

    /// Remote video tracks received so far, retained for the
    /// session's lifetime (run-16 law: never hand out an object
    /// whose survival depends on the framework's internal
    /// retention).
    public var remoteVideoTracks: [RTCVideoTrack] {
        lock.withLock { remoteVideoTrackStorage }
    }

    /// Creates the local screen video track — a
    /// `videoSource(forScreenCast:)` source, a
    /// `MeshVideoCapturer` feeding it, and the track — and adds
    /// it to the peer connection. Idempotent: later calls
    /// return the existing track.
    ///
    /// ORDERING: call before negotiation for the track to be
    /// part of the initial SDP — before `start()` on the
    /// initiator, before the offer is fed to `handleSignal(_:)`
    /// on the responder. This layer has no renegotiation yet
    /// (`peerConnectionShouldNegotiate` stays a no-op), so a
    /// track added after the answer would exist locally but
    /// never be negotiated.
    ///
    /// Encoding is the framework's default codec factory — for
    /// the default `RTCPeerConnectionFactory` that is
    /// `RTCDefaultVideoEncoderFactory`, VideoToolbox-backed
    /// (hardware H.264). On top of that default this method
    /// applies an H.264-first codec preference on the video
    /// transceiver (best effort; see `applyH264Preference`).
    @discardableResult
    public func addScreenTrack() -> MeshScreenTrack {
        if let existing = lock.withLock({ screenTrackStorage }) { return existing }
        let source = factory.videoSource(forScreenCast: true)
        let capturer = MeshVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: Self.screenTrackID)
        let bundle = MeshScreenTrack(track: track, source: source, capturer: capturer)
        lock.withLock { screenTrackStorage = bundle }
        if let sender = pc.add(track, streamIds: [Self.screenStreamID]) {
            applyH264Preference(to: sender)
        }
        return bundle
    }

    /// H.264-first codec preference for the transceiver owning
    /// `sender`, reordering (never removing) the sender codec
    /// capabilities from
    /// `RTCPeerConnectionFactory.rtpSenderCapabilities(forKind:)`.
    /// Best effort by design: a failure leaves the framework
    /// default order in place. The framework surface also
    /// exposes a factory-wide knob —
    /// `RTCDefaultVideoEncoderFactory.preferredCodec` — but the
    /// default factory init this session uses does not hand
    /// that instance out, so the transceiver's
    /// `setCodecPreferences(_:)` (RTCRtpTransceiver.h) is the
    /// reachable expression of the preference.
    private func applyH264Preference(to sender: RTCRtpSender) {
        guard let transceiver = pc.transceivers.first(where: { $0.sender === sender })
        else { return }
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let reordered = capabilities.codecs.sorted { a, b in
            a.mimeType == "video/H264" && b.mimeType != "video/H264"
        }
        try? transceiver.setCodecPreferences(reordered)
    }

    private func noteRemoteVideoTrack(_ track: RTCVideoTrack) {
        let isNew: Bool = lock.withLock {
            guard !remoteVideoTrackStorage.contains(where: { $0.trackId == track.trackId })
            else { return false }
            remoteVideoTrackStorage.append(track)
            return true
        }
        if isNew { onRemoteVideoTrack?(track) }
    }

    // MARK: - Stats

    /// All current getStats entries, flattened to
    /// `MeshStatsEntry` — the raw material for
    /// `MeshStatsSelection` and for part 3's stats loop (RTT,
    /// jitter, frames, the Direct/Relay badge).
    public func fetchStatisticsEntries() async -> [MeshStatsEntry] {
        await withCheckedContinuation { continuation in
            pc.statistics { report in
                let entries = report.statistics.values.map { stat in
                    MeshStatsEntry(id: stat.id, type: stat.type,
                                   values: stat.values.mapValues(Self.jsonValue(from:)))
                }
                continuation.resume(returning: entries)
            }
        }
    }

    /// The local candidate type of the currently selected pair
    /// (`host` / `srflx` / `relay` / `prflx`), or nil when no
    /// pair is carrying traffic yet. This is the distinction
    /// behind the UI's Direct/Relay badge.
    public func fetchSelectedCandidatePairType() async -> MeshCandidateType? {
        MeshStatsSelection.selectedLocalCandidateType(
            in: await fetchStatisticsEntries())
    }

    /// NSObject → JSONValue for stats values (NSString / NSNumber
    /// / NSArray / NSDictionary / NSNull); anything exotic is
    /// stringified — stats values never decide by identity, only
    /// by the documented keys.
    private static func jsonValue(from value: NSObject) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let array as [NSObject]:
            return .array(array.map { jsonValue(from: $0) })
        case let dictionary as [String: NSObject]:
            return .object(dictionary.mapValues { jsonValue(from: $0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    // MARK: - Close

    /// Closes the channel and the peer connection and finishes
    /// both streams. Idempotent.
    public func close() {
        let shouldClose: Bool = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        control.close()
        pc.close()
        publish(.closed)
        statesContinuation.finish()
        controlContinuation.finish()
    }

    private func publish(_ newState: MeshPeerConnectionState) {
        let changed: Bool = lock.withLock {
            guard currentState != newState else { return false }
            currentState = newState
            return true
        }
        if changed { statesContinuation.yield(newState) }
    }

    // MARK: - RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didAdd stream: RTCMediaStream) {
        // Legacy stream callback (RTCPeerConnection.h): the
        // same tracks also arrive per-receiver below; the
        // trackId dedupe in noteRemoteVideoTrack makes the
        // double delivery harmless.
        for track in stream.videoTracks { noteRemoteVideoTrack(track) }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didGenerate candidate: RTCIceCandidate) {
        sendSignal(signaling.iceEnvelope(MeshICECandidate(candidate)))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didChange newState: RTCPeerConnectionState) {
        publish(MeshPeerConnectionState(newState))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didOpen dataChannel: RTCDataChannel) {
        if dataChannel.label == Self.controlChannelLabel {
            control.attach(dataChannel)
        }
    }

    /// The unified-plan remote-track surface
    /// (`RTCPeerConnectionDelegate` in RTCPeerConnection.h):
    /// a receiver whose track is a video track is a remote
    /// screen arriving.
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                               didAdd rtpReceiver: RTCRtpReceiver,
                               streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            noteRemoteVideoTrack(track)
        }
    }
}
#endif
