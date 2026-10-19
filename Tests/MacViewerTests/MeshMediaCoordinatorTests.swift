import Foundation
import MeshClient
import MeshWebRTC
import Testing
import WebRTC
@testable import MacViewer

/// M1 part 3b: the media coordinator — role assignment, demux,
/// host capture/applier wiring, teardown, badge/stats — driven
/// through the real session controller with fake signaling, a
/// fake peer session, a fake capture, and a fake applier. The
/// WebRTC objects themselves are CI-proven in the mesh-client
/// suites; here only the app-layer wiring is under test.
@MainActor
struct MeshMediaCoordinatorTests {
    private let host = MeshID(unchecked: "444555666")
    private let viewer = MeshID(unchecked: "111222333")
    private let stranger = MeshID(unchecked: "777888999")

    /// Wires a controller + coordinator pair the way the model
    /// does, with the factories recording everything they build.
    @MainActor
    private final class Rig {
        let signaling = FakeMediaSignaling()
        let peerBox = FakePeerSessionBox()
        let applierBox = FakeApplierBox()
        let controller: MeshSessionController
        let coordinator: MeshMediaCoordinator

        init(localID: MeshID, paired: Set<MeshID>) {
            controller = MeshSessionController(
                signaling: signaling,
                isPaired: { paired.contains($0) },
                localName: { "Test Mac" },
                timeout: 30)
            let peerBox = peerBox
            let applierBox = applierBox
            coordinator = MeshMediaCoordinator(
                localID: localID,
                makePeerSession: { role, peer in
                    let fake = FakePeerSession(role: role, peer: peer)
                    fake.capture = peerBox.captureToReturn
                    fake.candidateType = peerBox.candidateType
                    fake.statsEntries = peerBox.statsEntries
                    peerBox.created.append(fake)
                    return fake
                },
                makeApplier: { controlAllowed, provider in
                    let fake = FakeApplier(controlAllowed: controlAllowed)
                    applierBox.created.append(fake)
                    applierBox.providers.append(provider)
                    return fake
                })
            coordinator.bind(to: controller)
            controller.start()
        }
    }

    private func settle(_ description: String,
                        _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting: \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isActive(_ controller: MeshSessionController) -> Bool {
        if case .active = controller.phase { return true }
        return false
    }

    /// Drives the rig to an active VIEWER session (this device
    /// requested; the host accepted with `capabilities`).
    /// Returns the session ID the controller minted.
    @discardableResult
    private func activateViewer(_ rig: Rig,
                                capabilities: Set<MeshSessionCapability> = [.view, .control]) async -> String {
        rig.controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { rig.signaling.sentSessionMessages.count == 1 }
        let sessionID = rig.signaling.sentSessionMessages.first?.sessionID ?? ""
        rig.signaling.inject(MeshSessionMessage(kind: .accept, sessionID: sessionID,
                                                capabilities: capabilities),
                             from: host)
        await settle("active") { isActive(rig.controller) }
        await settle("peer session created") { rig.peerBox.created.count == 1 }
        return sessionID
    }

    /// Drives the rig to an active HOST session (the viewer
    /// requested; this device approved).
    private func activateHost(_ rig: Rig,
                              capabilities: Set<MeshSessionCapability> = [.view, .control]) async {
        rig.signaling.inject(MeshSessionMessage(kind: .request, sessionID: "S-host",
                                                fromName: "Viewer PC",
                                                capabilities: capabilities),
                             from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = rig.controller.phase { return true }
            return false
        }
        rig.controller.approveIncoming()
        await settle("active") { isActive(rig.controller) }
        await settle("peer session created") { rig.peerBox.created.count == 1 }
    }

    // MARK: Role assignment

    @Test("Viewer activation creates an INITIATOR peer session and starts negotiation")
    func viewerCreatesInitiator() async {
        let rig = Rig(localID: viewer, paired: [host])
        await activateViewer(rig)
        let fake = rig.peerBox.created.first
        #expect(fake?.role == .initiator)
        #expect(fake?.peer == host)
        await settle("start called") { fake?.startCalls == 1 }
        #expect(fake?.onRemoteVideoTrack != nil)
        #expect(rig.coordinator.inputSender != nil)
    }

    @Test("Host activation creates a RESPONDER peer session (no start call)")
    func hostCreatesResponder() async {
        let rig = Rig(localID: host, paired: [viewer])
        await activateHost(rig)
        let fake = rig.peerBox.created.first
        #expect(fake?.role == .responder)
        #expect(fake?.peer == viewer)
        #expect(fake?.startCalls == 0)
    }

    // MARK: Demux routing

    @Test("Demux: media envelopes reach the peer session; app planes and foreign envelopes do not")
    func demuxRouting() async {
        let rig = Rig(localID: viewer, paired: [host])
        await activateViewer(rig)
        let fake = rig.peerBox.created.first
        let coordinator = rig.coordinator

        // A chat envelope (mvChat object under .offer) is not media.
        let chatData: JSONValue = .object(["mvChat": .number(1), "text": .string("hi")])
        coordinator.routeInbound(SignalEnvelope(from: host, kind: .offer, data: chatData))
        // A session envelope is not media either.
        let sessionMessage = MeshSessionMessage(kind: .accept, sessionID: "Sx",
                                                capabilities: [.view])
        coordinator.routeInbound(SignalEnvelope(from: host,
                                                kind: MeshSessionMessage.transportKind,
                                                data: sessionMessage.signalingData))
        // Media from a stranger is not this session's media.
        coordinator.routeInbound(SignalEnvelope(from: stranger, kind: .answer,
                                                data: .string("v=0 stranger")))
        // An offer to the INITIATOR is the wrong role for the kind.
        coordinator.routeInbound(SignalEnvelope(from: host, kind: .offer,
                                                data: .string("v=0 offer")))
        #expect(fake?.handledSignals.isEmpty == true)

        // The real media flow: answer + ICE from the session peer.
        coordinator.routeInbound(SignalEnvelope(from: host, kind: .answer,
                                                data: .string("v=0 answer")))
        let ice: JSONValue = .object(["candidate": .string("candidate:1 1 udp 1 192.0.2.1 9 typ host"),
                                      "sdpMid": .string("0"), "sdpMLineIndex": .number(0)])
        coordinator.routeInbound(SignalEnvelope(from: host, kind: .ice, data: ice))
        #expect(fake?.handledSignals.count == 2)
        #expect(fake?.handledSignals.first?.kind == .answer)
        #expect(fake?.handledSignals.last?.kind == .ice)
    }

    @Test("Demux on the host: the offer is routed, an answer is not")
    func demuxHostSide() async {
        let rig = Rig(localID: host, paired: [viewer])
        await activateHost(rig)
        let fake = rig.peerBox.created.first
        rig.coordinator.routeInbound(SignalEnvelope(from: viewer, kind: .answer,
                                                     data: .string("v=0 answer")))
        #expect(fake?.handledSignals.isEmpty == true)
        rig.coordinator.routeInbound(SignalEnvelope(from: viewer, kind: .offer,
                                                     data: .string("v=0 offer")))
        #expect(fake?.handledSignals.count == 1)
    }

    @Test("A media envelope racing activation is buffered and replayed on creation")
    func bufferedReplay() async {
        let rig = Rig(localID: host, paired: [viewer])
        // Drive the controller to active WITHOUT any await
        // between approve and routeInbound: the coordinator's
        // phase sink hops through a Task, so in this same turn
        // the phase is active but no peer session exists yet —
        // exactly the production race.
        rig.signaling.inject(MeshSessionMessage(kind: .request, sessionID: "S-race",
                                                 fromName: "Viewer PC",
                                                 capabilities: [.view, .control]),
                             from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = rig.controller.phase { return true }
            return false
        }
        #expect(rig.peerBox.created.isEmpty)
        rig.controller.approveIncoming()
        rig.coordinator.routeInbound(SignalEnvelope(from: viewer, kind: .offer,
                                                    data: .string("v=0 early offer")))
        await settle("peer session created") { rig.peerBox.created.count == 1 }
        let fake = rig.peerBox.created.first
        await settle("offer replayed") { fake?.handledSignals.count == 1 }
        #expect(fake?.handledSignals.first?.kind == .offer)
        // Host ordering held even for the replay: the screen
        // capture was created before the offer was fed in.
        #expect(fake?.captureCreatedBeforeFirstSignal == true)
    }

    // MARK: Host wiring

    @Test("Host: capture starts with view capability, applier gated by control, control data flows")
    func hostFullWiring() async {
        let rig = Rig(localID: host, paired: [viewer])
        let capture = FakeScreenCapture()
        rig.peerBox.captureToReturn = capture
        await activateHost(rig)
        let fake = rig.peerBox.created.first
        #expect(fake?.makeScreenCaptureCalls == 1)
        await settle("capture started") { capture.startCalls == 1 }
        await settle("sharing published") { rig.coordinator.isSharingScreen }
        let applier = rig.applierBox.created.first
        #expect(applier?.controlAllowed == true)
        // The applier's size provider tracks the streamed size.
        #expect(rig.applierBox.providers.first?() == MeshDisplaySize(width: 1920, height: 1080))
        // Control-channel payloads reach the applier untouched.
        let payload = Data([0x7B, 0x22, 0x76, 0x22, 0x7D])
        fake?.emitControl(payload)
        await settle("applier received control data") { applier?.appliedData == [payload] }
    }

    @Test("Host control-only session: no capture at all, applier still live")
    func hostControlOnly() async {
        let rig = Rig(localID: host, paired: [viewer])
        await activateHost(rig, capabilities: [.control])
        let fake = rig.peerBox.created.first
        #expect(fake?.makeScreenCaptureCalls == 0)
        #expect(rig.coordinator.isSharingScreen == false)
        #expect(rig.applierBox.created.first?.controlAllowed == true)
    }

    @Test("Host view-only session: capture starts, applier gate closed")
    func hostViewOnly() async {
        let rig = Rig(localID: host, paired: [viewer])
        rig.peerBox.captureToReturn = FakeScreenCapture()
        await activateHost(rig, capabilities: [.view])
        #expect(rig.peerBox.created.first?.makeScreenCaptureCalls == 1)
        #expect(rig.applierBox.created.first?.controlAllowed == false)
    }

    @Test("Host capture failure surfaces as coordinator state (the strip's error line)")
    func hostCaptureFailureSurfaces() async {
        let rig = Rig(localID: host, paired: [viewer])
        let capture = FakeScreenCapture()
        capture.startError = FakeCaptureError.boom
        rig.peerBox.captureToReturn = capture
        await activateHost(rig)
        await settle("error published") { rig.coordinator.hostCaptureError != nil }
        #expect(rig.coordinator.isSharingScreen == false)
    }

    // MARK: Teardown on every end reason

    @Test("Teardown: viewer ends locally — peer closed, sender sealed with releaseAll")
    func teardownViewerLocalEnd() async {
        let rig = Rig(localID: viewer, paired: [host])
        await activateViewer(rig)
        let fake = rig.peerBox.created.first
        rig.controller.endSession()
        await settle("peer closed") { fake?.closeCalls == 1 }
        #expect(rig.coordinator.inputSender == nil)
        #expect(rig.coordinator.remoteVideoTrack == nil)
        let sentEvents = (fake?.sentControl ?? []).compactMap { MeshInputEvent(data: $0) }
        #expect(sentEvents.last == .releaseAll)
    }

    @Test("Teardown: peer ends the session — same full teardown")
    func teardownPeerEnd() async {
        let rig = Rig(localID: viewer, paired: [host])
        let sessionID = await activateViewer(rig)
        let fake = rig.peerBox.created.first
        rig.signaling.inject(MeshSessionMessage(kind: .end, sessionID: sessionID,
                                                reason: .ended),
                             from: host)
        await settle("peer closed") { fake?.closeCalls == 1 }
        #expect(rig.coordinator.inputSender == nil)
    }

    @Test("Teardown: host side — capture stopped, held input released, peer closed")
    func teardownHostEnd() async {
        let rig = Rig(localID: host, paired: [viewer])
        let capture = FakeScreenCapture()
        rig.peerBox.captureToReturn = capture
        await activateHost(rig)
        await settle("capture started") { capture.startCalls == 1 }
        rig.signaling.inject(MeshSessionMessage(kind: .end, sessionID: "S-host",
                                                reason: .ended),
                             from: viewer)
        let fake = rig.peerBox.created.first
        await settle("peer closed") { fake?.closeCalls == 1 }
        await settle("capture stopped") { capture.stopCalls == 1 }
        #expect((rig.applierBox.created.first?.releaseAllCalls ?? 0) >= 1)
        #expect(rig.coordinator.isSharingScreen == false)
        #expect(rig.coordinator.hostCaptureError == nil)
    }

    @Test("Teardown: controller stop mid-session closes the media plane")
    func teardownControllerStop() async {
        let rig = Rig(localID: viewer, paired: [host])
        await activateViewer(rig)
        let fake = rig.peerBox.created.first
        rig.controller.stop()
        await settle("peer closed") { fake?.closeCalls == 1 }
        #expect(rig.coordinator.inputSender == nil)
    }

    // MARK: Badge + stats

    @Test("Badge mapping: host/srflx/prflx are Direct, relay is Relay, unknown/nil hide")
    func badgeMapping() {
        #expect(MeshLinkKind(candidateType: .host) == .direct)
        #expect(MeshLinkKind(candidateType: .srflx) == .direct)
        #expect(MeshLinkKind(candidateType: .prflx) == .direct)
        #expect(MeshLinkKind(candidateType: .relay) == .relay)
        #expect(MeshLinkKind(candidateType: .unknown) == nil)
        #expect(MeshLinkKind(candidateType: nil) == nil)
    }

    @Test("Stats poll publishes the badge kind and the RTT/fps readout")
    func statsPoll() async {
        let rig = Rig(localID: viewer, paired: [host])
        rig.peerBox.candidateType = .relay
        rig.peerBox.statsEntries = [
            MeshStatsEntry(id: "T1", type: "transport",
                           values: ["selectedCandidatePairId": .string("P1")]),
            MeshStatsEntry(id: "P1", type: "candidate-pair",
                           values: ["state": .string("succeeded"),
                                    "currentRoundTripTime": .number(0.0123)]),
            MeshStatsEntry(id: "I1", type: "inbound-rtp",
                           values: ["kind": .string("video"),
                                    "framesPerSecond": .number(59.94)]),
        ]
        await activateViewer(rig)
        await rig.coordinator.pollLinkStats()
        #expect(rig.coordinator.linkKind == .relay)
        #expect(rig.coordinator.linkStats?.roundTripMilliseconds == 12)
        #expect(rig.coordinator.linkStats?.receivedFramesPerSecond == 60)
    }

    @Test("Link stats: the transport-selected pair wins; absent fields stay nil")
    func linkStatsReading() {
        let entries = [
            MeshStatsEntry(id: "T1", type: "transport",
                           values: ["selectedCandidatePairId": .string("P2")]),
            MeshStatsEntry(id: "P1", type: "candidate-pair",
                           values: ["state": .string("succeeded"), "nominated": .bool(true),
                                    "currentRoundTripTime": .number(0.5)]),
            MeshStatsEntry(id: "P2", type: "candidate-pair",
                           values: ["state": .string("succeeded"),
                                    "currentRoundTripTime": .number(0.008)]),
            MeshStatsEntry(id: "I1", type: "inbound-rtp",
                           values: ["kind": .string("audio"),
                                    "framesPerSecond": .number(50)]),
        ]
        let stats = MeshLinkStats.read(from: entries)
        #expect(stats.roundTripMilliseconds == 8)
        #expect(stats.receivedFramesPerSecond == nil)
        #expect(MeshLinkStats.read(from: []) == MeshLinkStats())
    }
}

/// The viewer's input sender: coalescing, flush points, and
/// the releaseAll seal, asserted as the exact decoded event
/// sequence arriving at the (fake) control channel.
@MainActor
struct MeshInputSenderTests {
    @Test("Moves coalesce latest-wins; discrete events flush in order; end seals with releaseAll")
    func coalescingSequence() {
        var sent: [Data] = []
        let sender = MeshInputSender { sent.append($0) }
        func events() -> [MeshInputEvent] { sent.compactMap { MeshInputEvent(data: $0) } }

        sender.send(.pointerMove(x: 0.1, y: 0.1))
        sender.send(.pointerMove(x: 0.2, y: 0.25))
        #expect(sent.isEmpty)  // held, latest-wins
        sender.send(.pointerButton(button: .left, down: true, x: 0.2, y: 0.25))
        #expect(events() == [
            .pointerMove(x: 0.2, y: 0.25),
            .pointerButton(button: .left, down: true, x: 0.2, y: 0.25),
        ])
        sender.send(.pointerMove(x: 0.5, y: 0.5))
        #expect(sent.count == 2)  // held again
        sender.tick()
        #expect(events().last == .pointerMove(x: 0.5, y: 0.5))
        sender.send(.key(code: 0, down: true, flags: []))
        #expect(events().last == .key(code: 0, down: true, flags: []))
        sender.send(.pointerMove(x: 0.9, y: 0.9))
        sender.endSession()
        #expect(Array(events().suffix(2)) == [.pointerMove(x: 0.9, y: 0.9), .releaseAll])
        let countAfterEnd = sent.count
        sender.send(.pointerMove(x: 0.0, y: 0.0))
        sender.tick()
        #expect(sent.count == countAfterEnd)  // sealed
    }

    @Test("Pointer-left flushes the held move and releases")
    func pointerLeftReleases() {
        var sent: [Data] = []
        let sender = MeshInputSender { sent.append($0) }
        sender.send(.pointerMove(x: 0.3, y: 0.3))
        sender.pointerLeft()
        let events = sent.compactMap { MeshInputEvent(data: $0) }
        #expect(events == [.pointerMove(x: 0.3, y: 0.3), .releaseAll])
    }
}

// MARK: - Fakes

private enum FakeCaptureError: Error { case boom }

private final class FakePeerSessionBox: @unchecked Sendable {
    var created: [FakePeerSession] = []
    var captureToReturn: FakeScreenCapture?
    var candidateType: MeshCandidateType?
    var statsEntries: [MeshStatsEntry] = []
}

private final class FakeApplierBox: @unchecked Sendable {
    var created: [FakeApplier] = []
    var providers: [() -> MeshDisplaySize?] = []
}

private final class FakePeerSession: MeshPeerSessioning {
    let role: MeshPeerRole
    let peer: MeshID
    private(set) var startCalls = 0
    private(set) var closeCalls = 0
    private(set) var makeScreenCaptureCalls = 0
    private(set) var handledSignals: [SignalEnvelope] = []
    private(set) var sentControl: [Data] = []
    private(set) var captureCreatedBeforeFirstSignal = false
    var capture: FakeScreenCapture?
    var candidateType: MeshCandidateType?
    var statsEntries: [MeshStatsEntry] = []
    var onRemoteVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?

    let states: AsyncStream<MeshPeerConnectionState>
    let controlMessages: AsyncStream<Data>
    private let controlContinuation: AsyncStream<Data>.Continuation

    init(role: MeshPeerRole, peer: MeshID) {
        self.role = role
        self.peer = peer
        states = AsyncStream { _ in }
        var cc: AsyncStream<Data>.Continuation!
        controlMessages = AsyncStream { cc = $0 }
        controlContinuation = cc
    }

    var state: MeshPeerConnectionState { .new }

    func start() async throws { startCalls += 1 }

    func handleSignal(_ signal: SignalEnvelope) {
        if handledSignals.isEmpty {
            captureCreatedBeforeFirstSignal = makeScreenCaptureCalls > 0
        }
        handledSignals.append(signal)
    }

    func sendControl(_ data: Data) { sentControl.append(data) }

    func makeScreenCapture() -> MeshScreenCapturing? {
        makeScreenCaptureCalls += 1
        return capture
    }

    func fetchSelectedCandidatePairType() async -> MeshCandidateType? { candidateType }
    func fetchStatisticsEntries() async -> [MeshStatsEntry] { statsEntries }
    func close() { closeCalls += 1 }

    func emitControl(_ data: Data) { controlContinuation.yield(data) }
}

private final class FakeScreenCapture: MeshScreenCapturing {
    var streamedSize: MeshDisplaySize?
    var onFailure: ((String) -> Void)?
    var startError: Error?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func startMainDisplay() async throws {
        startCalls += 1
        if let startError { throw startError }
        streamedSize = MeshDisplaySize(width: 1920, height: 1080)
    }

    func stop() async { stopCalls += 1 }
}

private final class FakeApplier: MeshInputApplying {
    var controlAllowed: Bool
    private(set) var appliedData: [Data] = []
    private(set) var releaseAllCalls = 0

    init(controlAllowed: Bool) { self.controlAllowed = controlAllowed }

    func apply(data: Data) -> Bool {
        appliedData.append(data)
        return true
    }

    func releaseAll() { releaseAllCalls += 1 }
}

private final class FakeMediaSignaling: MeshSignalingAPI, @unchecked Sendable {
    struct Sent: Equatable {
        let peer: MeshID
        let kind: SignalKind
        let data: JSONValue
    }

    private let lock = NSLock()
    private var sentStorage: [Sent] = []

    let signals: AsyncStream<SignalEnvelope>
    let serverErrors: AsyncStream<MeshError>
    private let signalContinuation: AsyncStream<SignalEnvelope>.Continuation

    init() {
        var sc: AsyncStream<SignalEnvelope>.Continuation!
        signals = AsyncStream { sc = $0 }
        signalContinuation = sc
        serverErrors = AsyncStream { _ in }
    }

    var isConnected: Bool { true }

    func sendSignal(to peer: MeshID, kind: SignalKind, data: JSONValue) async throws {
        lock.withLock { sentStorage.append(Sent(peer: peer, kind: kind, data: data)) }
    }

    var sentSessionMessages: [MeshSessionMessage] {
        lock.withLock { sentStorage }.compactMap { MeshSessionMessage(data: $0.data) }
    }

    func inject(_ envelope: SignalEnvelope) { signalContinuation.yield(envelope) }

    func inject(_ message: MeshSessionMessage, from peer: MeshID) {
        inject(SignalEnvelope(from: peer, kind: MeshSessionMessage.transportKind,
                              data: message.signalingData))
    }
}
