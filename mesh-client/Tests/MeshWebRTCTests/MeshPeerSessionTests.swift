#if os(macOS)
import XCTest
import MeshClient
import MeshWebRTC

/// End-to-end tests for `MeshPeerSession`, mirroring the M1
/// part-0 spike but driven through the product layer: two
/// sessions (initiator + responder) wired back-to-back with
/// `SignalingEnvelope` JSON as the ONLY transport — encode to
/// the wire string, decode, hand the resulting `SignalEnvelope`
/// to the other session, exactly the path
/// `MeshSignalingClient.signals` feeds in production.
///
/// These tests can only RUN on macOS (the WebRTC binary target
/// has no Linux slice), i.e. in CI. On Linux the file compiles
/// to nothing; the Linux coverage of this layer is
/// PeerSignalGlueTests.
final class MeshPeerSessionTests: XCTestCase {

    private let aID = MeshID(unchecked: "111111111")
    private let bID = MeshID(unchecked: "222222222")
    private let cID = MeshID(unchecked: "333333333")

    /// Mutable slot so the two sessions' sinks can reference
    /// each other before both exist.
    private final class SessionSlot: @unchecked Sendable {
        var session: MeshPeerSession?
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func with<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// One wired pair of sessions plus their control-message
    /// collectors.
    private struct Pair {
        let a: MeshPeerSession
        let b: MeshPeerSession
        let aMessages: Locked<[Data]>
        let bMessages: Locked<[Data]>
        let tasks: [Task<Void, Never>]
    }

    private func makePair() -> Pair {
        let hop = DispatchQueue(label: "mesh.peersession.testbus",
                                attributes: .concurrent)
        func deliver(_ envelope: SignalingEnvelope, to slot: SessionSlot) {
            guard let json = try? envelope.encodedJSON() else { return }
            hop.async {
                guard let decoded = try? SignalingEnvelope.decodeJSON(json),
                      let from = decoded.from, let kind = decoded.kind,
                      let data = decoded.data,
                      let session = slot.session
                else { return }
                session.handleSignal(SignalEnvelope(from: from, kind: kind, data: data))
            }
        }
        let slotA = SessionSlot()
        let slotB = SessionSlot()
        let a = MeshPeerSession(localID: aID, remoteID: bID, role: .initiator) { envelope in
            deliver(envelope, to: slotB)
        }
        let b = MeshPeerSession(localID: bID, remoteID: aID, role: .responder) { envelope in
            deliver(envelope, to: slotA)
        }
        slotA.session = a
        slotB.session = b

        let aMessages = Locked<[Data]>([])
        let bMessages = Locked<[Data]>([])
        let taskA = Task { for await message in a.controlMessages { aMessages.with { $0.append(message) } } }
        let taskB = Task { for await message in b.controlMessages { bMessages.with { $0.append(message) } } }
        return Pair(a: a, b: b, aMessages: aMessages, bMessages: bMessages,
                    tasks: [taskA, taskB])
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 15,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    // MARK: - End-to-end

    func testTwoSessionsNegotiateAndExchangeControlBothWays() async throws {
        let pair = makePair()
        defer {
            pair.a.close()
            pair.b.close()
            pair.tasks.forEach { $0.cancel() }
        }

        let queuedPayload = Data([0x00, 0xFF, 0x10]) + Data("queued before open ✓".utf8)
        let livePayload = Data((0...255).map(UInt8.init)) + Data("-live".utf8)
        let replyPayload = Data("reply ✓".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF])

        // Sent before negotiation even starts: the session must
        // queue it and deliver it first once the channel opens
        // (run-16 discipline at the product layer).
        pair.a.sendControl(queuedPayload)

        try await pair.a.start()
        await waitUntil("A connected") { pair.a.state == .connected }
        await waitUntil("B connected") { pair.b.state == .connected }

        pair.a.sendControl(livePayload)
        pair.b.sendControl(replyPayload)

        await waitUntil("B received 2 messages") { pair.bMessages.with { $0.count } >= 2 }
        await waitUntil("A received the reply") { pair.aMessages.with { $0.count } >= 1 }

        XCTAssertEqual(pair.bMessages.with { $0 }, [queuedPayload, livePayload],
                       "B must receive the queued payload first, then the live one, byte-exact")
        XCTAssertEqual(pair.aMessages.with { $0 }, [replyPayload],
                       "A must receive B's reply byte-exact")

        // Loopback: the selected pair's local candidate is a
        // host candidate on both ends — the Direct badge fact.
        let aPairType = await pair.a.fetchSelectedCandidatePairType()
        XCTAssertEqual(aPairType, .host)
        let bPairType = await pair.b.fetchSelectedCandidatePairType()
        XCTAssertEqual(bPairType, .host)
    }

    // MARK: - Negative: foreign / app-plane signals

    func testForeignAndAppPlaneSignalsDoNotDisturbSession() async throws {
        let pair = makePair()
        defer {
            pair.a.close()
            pair.b.close()
            pair.tasks.forEach { $0.cancel() }
        }
        let aIgnored = Locked<[PeerSignalIgnoreReason]>([])
        let bIgnored = Locked<[PeerSignalIgnoreReason]>([])
        pair.a.onIgnoredSignal = { _, reason in aIgnored.with { $0.append(reason) } }
        pair.b.onIgnoredSignal = { _, reason in bIgnored.with { $0.append(reason) } }

        // A third device offers to B: not B's peer for this session.
        pair.b.handleSignal(SignalEnvelope(
            from: cID, kind: .offer, data: .string("v=0 foreign-offer")))
        // The actual peer, but an app-plane (chunk-2 session)
        // payload under .offer: not SDP, not media's business.
        pair.b.handleSignal(SignalEnvelope(
            from: aID, kind: .offer,
            data: .object(["mvSession": .object(["type": .string("session-request")])])))
        // An offer aimed at the initiator (glare): wrong role.
        pair.a.handleSignal(SignalEnvelope(
            from: bID, kind: .offer, data: .string("v=0 glare-offer")))

        // Routing decisions are synchronous: the ignores have
        // already been reported and nothing has moved.
        XCTAssertEqual(bIgnored.with { $0 }, [.wrongPeer, .malformedPayload])
        XCTAssertEqual(aIgnored.with { $0 }, [.wrongRoleForKind])
        XCTAssertEqual(pair.a.state, .new)
        XCTAssertEqual(pair.b.state, .new)

        // And the garbage did not poison anything: the pair
        // still negotiates and exchanges control data.
        try await pair.a.start()
        await waitUntil("A connected after garbage") { pair.a.state == .connected }
        await waitUntil("B connected after garbage") { pair.b.state == .connected }
        let payload = Data("still alive ✓".utf8)
        pair.a.sendControl(payload)
        await waitUntil("B received after garbage") { pair.bMessages.with { $0.count } >= 1 }
        XCTAssertEqual(pair.bMessages.with { $0 }, [payload])
    }
}
#endif
