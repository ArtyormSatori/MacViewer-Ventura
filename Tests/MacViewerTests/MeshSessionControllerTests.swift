import Foundation
import MeshClient
import Testing
@testable import MacViewer

@MainActor
struct MeshSessionControllerTests {
    private let host = MeshID(unchecked: "444555666")
    private let viewer = MeshID(unchecked: "111222333")
    private let stranger = MeshID(unchecked: "777888999")

    private func makeController(signaling: FakeSignaling,
                                paired: Set<MeshID>,
                                timeout: TimeInterval = 30) -> MeshSessionController {
        let controller = MeshSessionController(
            signaling: signaling,
            isPaired: { paired.contains($0) },
            localName: { "Test Mac" },
            timeout: timeout)
        controller.start()
        return controller
    }

    /// Polls a condition that becomes true once the controller's
    /// signaling pump (or a fire-and-forget send) has run.
    private func settle(_ description: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting: \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Outgoing (viewer side)

    @Test("Request → accept activates the session as viewer with the granted capabilities")
    func outgoingAcceptActivates() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host])
        controller.requestSession(to: host, peerName: "Host PC")
        guard case let .outgoingPending(sessionID, peer, _, requested) = controller.phase else {
            Issue.record("expected outgoingPending, got \(controller.phase)")
            return
        }
        #expect(peer == host)
        #expect(requested == [.view, .control])
        #expect(!controller.canStartSession)
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        let sent = fake.sentSessionMessages.first
        #expect(sent?.kind == .request)
        #expect(sent?.sessionID == sessionID)
        #expect(sent?.fromName == "Test Mac")
        #expect(sent?.capabilities == [.view, .control])

        fake.inject(MeshSessionMessage(kind: .accept, sessionID: sessionID,
                                       capabilities: [.view]),
                    from: host)
        await settle("active") {
            if case .active = controller.phase { return true }
            return false
        }
        guard case let .active(_, activePeer, _, role, granted, _) = controller.phase else { return }
        #expect(activePeer == host)
        #expect(role == .viewer)
        #expect(granted == [.view])
    }

    @Test("Request → reject ends the attempt as rejected")
    func outgoingRejectEnds() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host])
        controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        let sessionID = fake.sentSessionMessages.first?.sessionID ?? ""
        fake.inject(MeshSessionMessage(kind: .reject, sessionID: sessionID,
                                       reason: .rejected),
                    from: host)
        await settle("ended") { controller.phase == .ended(reason: .rejected) }
        #expect(controller.statusMessage?.contains("Host PC") == true)
        #expect(controller.canStartSession)
    }

    @Test("An unanswered request times out and withdraws itself at the host")
    func outgoingTimeoutEnds() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host], timeout: 0.15)
        controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        await settle("timed out") { controller.phase == .ended(reason: .timeout) }
        await settle("withdrawal sent") { fake.sentSessionMessages.count == 2 }
        let withdrawal = fake.sentSessionMessages.last
        #expect(withdrawal?.kind == .end)
        #expect(withdrawal?.reason == .timeout)
    }

    @Test("Cancelling an outgoing request ends it and notifies the host")
    func cancelOutgoingEnds() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host])
        controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        controller.cancelOutgoing()
        #expect(controller.phase == .ended(reason: .cancelled))
        await settle("cancel sent") { fake.sentSessionMessages.count == 2 }
        #expect(fake.sentSessionMessages.last?.kind == .end)
        #expect(fake.sentSessionMessages.last?.reason == .cancelled)
    }

    @Test("Ending an active session from the viewer side notifies the host")
    func endSessionFromViewer() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host])
        controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        let sessionID = fake.sentSessionMessages.first?.sessionID ?? ""
        fake.inject(MeshSessionMessage(kind: .accept, sessionID: sessionID,
                                       capabilities: [.view, .control]),
                    from: host)
        await settle("active") {
            if case .active = controller.phase { return true }
            return false
        }
        controller.endSession()
        #expect(controller.phase == .ended(reason: .endedLocally))
        await settle("end sent") { fake.sentSessionMessages.count == 2 }
        #expect(fake.sentSessionMessages.last?.kind == .end)
        #expect(fake.sentSessionMessages.last?.reason == .ended)
    }

    @Test("A server refusal while the request is unanswered ends it as unreachable")
    func serverErrorEndsOutgoing() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [host])
        controller.requestSession(to: host, peerName: "Host PC")
        await settle("request sent") { fake.sentSessionMessages.count == 1 }
        fake.emitError(.connectionClosed)
        await settle("ended") { controller.phase == .ended(reason: .peerUnreachable) }
    }

    // MARK: Incoming (host side)

    @Test("A paired peer's request waits for consent; approving activates as host and answers accept")
    func incomingApproveActivatesHost() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S1",
                                       fromName: "Living room PC",
                                       capabilities: [.view, .control]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        guard case let .incomingPending(sessionID, peer, peerName, capabilities) = controller.phase else { return }
        #expect(sessionID == "S1")
        #expect(peer == viewer)
        #expect(peerName == "Living room PC")
        #expect(capabilities == [.view, .control])

        controller.approveIncoming()
        guard case let .active(_, activePeer, _, role, granted, _) = controller.phase else {
            Issue.record("expected active, got \(controller.phase)")
            return
        }
        #expect(activePeer == viewer)
        #expect(role == .host)
        #expect(granted == [.view, .control])
        await settle("accept sent") { fake.sentSessionMessages.count == 1 }
        #expect(fake.sentSessionMessages.first?.kind == .accept)
        #expect(fake.sentSessionMessages.first?.sessionID == "S1")
    }

    @Test("Rejecting an incoming request answers reject immediately")
    func incomingRejectNotifies() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S2",
                                       fromName: "Living room PC",
                                       capabilities: [.view]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        controller.rejectIncoming()
        #expect(controller.phase == .ended(reason: .rejected))
        await settle("reject sent") { fake.sentSessionMessages.count == 1 }
        #expect(fake.sentSessionMessages.first?.kind == .reject)
        #expect(fake.sentSessionMessages.first?.reason == .rejected)
    }

    @Test("Unanswered consent times out and tells the requester")
    func incomingTimeoutAutoRejects() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer], timeout: 0.15)
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S3",
                                       fromName: "Living room PC",
                                       capabilities: [.view, .control]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        await settle("timed out") { controller.phase == .ended(reason: .timeout) }
        await settle("timeout notice sent") { fake.sentSessionMessages.count == 1 }
        #expect(fake.sentSessionMessages.first?.kind == .end)
        #expect(fake.sentSessionMessages.first?.reason == .timeout)
    }

    @Test("The requester cancelling withdraws the pending consent prompt")
    func requesterCancelsIncoming() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S4",
                                       fromName: "Living room PC",
                                       capabilities: [.view]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        fake.inject(MeshSessionMessage(kind: .end, sessionID: "S4", reason: .cancelled),
                    from: viewer)
        await settle("back to idle") { controller.phase == .idle }
        #expect(controller.statusMessage != nil)
    }

    @Test("The peer ending an active host session lands in ended-by-peer")
    func peerEndsActiveSession() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S5",
                                       fromName: "Living room PC",
                                       capabilities: [.view, .control]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        controller.approveIncoming()
        fake.inject(MeshSessionMessage(kind: .end, sessionID: "S5", reason: .ended),
                    from: viewer)
        await settle("ended") { controller.phase == .ended(reason: .endedByPeer) }
    }

    // MARK: Guards

    @Test("A request from an unpaired device is ignored entirely")
    func unpairedRequestIgnored() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S6",
                                       fromName: "Stranger",
                                       capabilities: [.view, .control]),
                    from: stranger)
        // Give the pump a chance to (not) act, then assert silence.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(controller.phase == .idle)
        #expect(fake.sentSessionMessages.isEmpty)
    }

    @Test("Media signaling payloads and stray answers are ignored")
    func nonSessionSignalsIgnored() async {
        let fake = FakeSignaling()
        let controller = makeController(signaling: fake, paired: [viewer])
        // An SDP offer (M1 traffic) shares kind .offer but its data
        // is a string, not a session object.
        fake.inject(SignalEnvelope(from: viewer, kind: .offer,
                                   data: .string("v=0 o=- 1 2 IN IP4 127.0.0.1")))
        fake.inject(MeshSessionMessage(kind: .accept, sessionID: "nope",
                                       capabilities: [.view]),
                    from: viewer)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(controller.phase == .idle)
        #expect(fake.sentSessionMessages.isEmpty)
    }

    @Test("A second request while consent is pending is refused as busy, the first is untouched")
    func secondRequestGetsBusyReject() async {
        let fake = FakeSignaling()
        let other = MeshID(unchecked: "222333444")
        let controller = makeController(signaling: fake, paired: [viewer, other])
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S7",
                                       fromName: "First", capabilities: [.view]),
                    from: viewer)
        await settle("incoming pending") {
            if case .incomingPending = controller.phase { return true }
            return false
        }
        fake.inject(MeshSessionMessage(kind: .request, sessionID: "S8",
                                       fromName: "Second", capabilities: [.view]),
                    from: other)
        await settle("busy reject sent") { fake.sentSessionMessages.count == 1 }
        let refusal = fake.sentSessionMessages.first
        #expect(refusal?.kind == .reject)
        #expect(refusal?.reason == .busy)
        #expect(refusal?.sessionID == "S8")
        #expect(fake.sent.first?.peer == other)
        guard case let .incomingPending(sessionID, peer, _, _) = controller.phase else {
            Issue.record("first request lost, phase is \(controller.phase)")
            return
        }
        #expect(sessionID == "S7")
        #expect(peer == viewer)
    }
}

/// In-memory `MeshSignalingAPI` double: records sends, lets tests
/// inject peer signals and server errors. All mutable state sits
/// behind `withLock` (Swift 6 forbids lock/unlock in async contexts).
private final class FakeSignaling: MeshSignalingAPI, @unchecked Sendable {
    struct Sent: Equatable {
        let peer: MeshID
        let kind: SignalKind
        let data: JSONValue
    }

    private let lock = NSLock()
    private var connected = true
    private var sentStorage: [Sent] = []

    let signals: AsyncStream<SignalEnvelope>
    let serverErrors: AsyncStream<MeshError>
    private let signalContinuation: AsyncStream<SignalEnvelope>.Continuation
    private let errorContinuation: AsyncStream<MeshError>.Continuation

    init() {
        var sc: AsyncStream<SignalEnvelope>.Continuation!
        signals = AsyncStream { sc = $0 }
        signalContinuation = sc
        var ec: AsyncStream<MeshError>.Continuation!
        serverErrors = AsyncStream { ec = $0 }
        errorContinuation = ec
    }

    var isConnected: Bool { lock.withLock { connected } }

    func sendSignal(to peer: MeshID, kind: SignalKind, data: JSONValue) async throws {
        lock.withLock { sentStorage.append(Sent(peer: peer, kind: kind, data: data)) }
        if !isConnected { throw MeshError.connectionClosed }
    }

    var sent: [Sent] { lock.withLock { sentStorage } }

    var sentSessionMessages: [MeshSessionMessage] {
        sent.compactMap { MeshSessionMessage(data: $0.data) }
    }

    func inject(_ envelope: SignalEnvelope) {
        signalContinuation.yield(envelope)
    }

    func inject(_ message: MeshSessionMessage, from peer: MeshID) {
        inject(SignalEnvelope(from: peer, kind: MeshSessionMessage.transportKind,
                              data: message.signalingData))
    }

    func emitError(_ error: MeshError) {
        errorContinuation.yield(error)
    }
}
