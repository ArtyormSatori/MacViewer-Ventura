import XCTest
import MeshClient
import MeshWebRTC

/// Tests for the pure, WebRTC-independent half of the peer layer
/// (`MeshPeerSignaling`, `ICECandidateBuffer`, `MeshICECandidate`,
/// `MeshStatsSelection`). These run on every platform, including
/// this Linux box — they pin the wire forms and routing rules
/// the macOS `MeshPeerSession` is built on.
final class PeerSignalGlueTests: XCTestCase {

    private let aID = MeshID(unchecked: "111111111")
    private let bID = MeshID(unchecked: "222222222")
    private let cID = MeshID(unchecked: "333333333")

    private var initiator: MeshPeerSignaling {
        MeshPeerSignaling(localID: aID, remoteID: bID, role: .initiator)
    }
    private var responder: MeshPeerSignaling {
        MeshPeerSignaling(localID: bID, remoteID: aID, role: .responder)
    }

    private func candidate(_ n: Int) -> MeshICECandidate {
        MeshICECandidate(
            sdp: "candidate:\(n) 1 udp 2130706431 192.0.2.\(n) 5000\(n) typ host",
            sdpMid: "0", sdpMLineIndex: 0)
    }

    // MARK: - Outbound envelope forms

    func testOfferEnvelopeForm() {
        let envelope = initiator.offerEnvelope(sdp: "v=0 sdp-body")
        XCTAssertEqual(envelope.type, .signal)
        XCTAssertEqual(envelope.to, bID)
        XCTAssertEqual(envelope.from, aID)
        XCTAssertEqual(envelope.kind, .offer)
        XCTAssertEqual(envelope.data, .string("v=0 sdp-body"))
    }

    func testAnswerEnvelopeForm() {
        let envelope = responder.answerEnvelope(sdp: "v=0 answer-body")
        XCTAssertEqual(envelope.type, .signal)
        XCTAssertEqual(envelope.to, aID)
        XCTAssertEqual(envelope.from, bID)
        XCTAssertEqual(envelope.kind, .answer)
        XCTAssertEqual(envelope.data, .string("v=0 answer-body"))
    }

    func testICEEnvelopeForm() {
        let envelope = initiator.iceEnvelope(candidate(7))
        XCTAssertEqual(envelope.type, .signal)
        XCTAssertEqual(envelope.to, bID)
        XCTAssertEqual(envelope.from, aID)
        XCTAssertEqual(envelope.kind, .ice)
        XCTAssertEqual(envelope.data, .object([
            "candidate": .string("candidate:7 1 udp 2130706431 192.0.2.7 50007 typ host"),
            "sdpMid": .string("0"),
            "sdpMLineIndex": .number(0),
        ]))
    }

    // MARK: - MeshICECandidate JSON form

    func testICECandidateJSONRoundTrip() {
        let original = MeshICECandidate(
            sdp: "candidate:9 1 udp 1677729535 203.0.113.5 4444 typ relay",
            sdpMid: "1", sdpMLineIndex: 1)
        XCTAssertEqual(MeshICECandidate(jsonValue: original.jsonValue), original)
    }

    func testICECandidateRejectsMalformed() {
        // String payload (the SDP form) is not a candidate.
        XCTAssertNil(MeshICECandidate(jsonValue: .string("candidate:1 1 udp 1 192.0.2.1 9 typ host")))
        // Missing fields.
        XCTAssertNil(MeshICECandidate(jsonValue: .object(["candidate": .string("c")])))
        XCTAssertNil(MeshICECandidate(jsonValue: .object([
            "candidate": .string("c"), "sdpMid": .string("0")])))
        // Wrong field types: index as string, candidate as number.
        XCTAssertNil(MeshICECandidate(jsonValue: .object([
            "candidate": .string("c"), "sdpMid": .string("0"),
            "sdpMLineIndex": .string("0")])))
        XCTAssertNil(MeshICECandidate(jsonValue: .object([
            "candidate": .number(3), "sdpMid": .string("0"),
            "sdpMLineIndex": .number(0)])))
        // Non-integral line index.
        XCTAssertNil(MeshICECandidate(jsonValue: .object([
            "candidate": .string("c"), "sdpMid": .string("0"),
            "sdpMLineIndex": .number(0.5)])))
        // Not an object at all.
        XCTAssertNil(MeshICECandidate(jsonValue: .array([])))
        XCTAssertNil(MeshICECandidate(jsonValue: .null))
    }

    // MARK: - Routing

    func testRouterAcceptsOfferForResponder() {
        let signal = SignalEnvelope(from: aID, kind: .offer, data: .string("v=0 offer"))
        XCTAssertEqual(responder.route(signal),
                       .remoteDescription(kind: .offer, sdp: "v=0 offer"))
    }

    func testRouterIgnoresOfferForInitiator() {
        // Glare / wrong role: the initiator never consumes offers.
        let signal = SignalEnvelope(from: bID, kind: .offer, data: .string("v=0 offer"))
        XCTAssertEqual(initiator.route(signal), .ignored(.wrongRoleForKind))
    }

    func testRouterAcceptsAnswerForInitiator() {
        let signal = SignalEnvelope(from: bID, kind: .answer, data: .string("v=0 answer"))
        XCTAssertEqual(initiator.route(signal),
                       .remoteDescription(kind: .answer, sdp: "v=0 answer"))
    }

    func testRouterIgnoresAnswerForResponder() {
        let signal = SignalEnvelope(from: aID, kind: .answer, data: .string("v=0 answer"))
        XCTAssertEqual(responder.route(signal), .ignored(.wrongRoleForKind))
    }

    func testRouterAcceptsICEForBothRoles() {
        let fromB = SignalEnvelope(from: bID, kind: .ice, data: candidate(1).jsonValue)
        XCTAssertEqual(initiator.route(fromB), .remoteCandidate(candidate(1)))
        let fromA = SignalEnvelope(from: aID, kind: .ice, data: candidate(2).jsonValue)
        XCTAssertEqual(responder.route(fromA), .remoteCandidate(candidate(2)))
    }

    func testRouterIgnoresWrongPeer() {
        for kind in [SignalKind.offer, .answer, .ice] {
            let data: JSONValue = kind == .ice ? candidate(1).jsonValue : .string("v=0 x")
            let signal = SignalEnvelope(from: cID, kind: kind, data: data)
            XCTAssertEqual(initiator.route(signal), .ignored(.wrongPeer), "initiator, \(kind)")
            XCTAssertEqual(responder.route(signal), .ignored(.wrongPeer), "responder, \(kind)")
        }
    }

    func testRouterIgnoresAppPlaneObjectOffer() {
        // Chunk-2/3 plane: session/chat envelopes ride kind .offer
        // with an OBJECT payload. The media plane must not treat
        // them as SDP — from the right peer, in the right role.
        let sessionObject = SignalEnvelope(
            from: aID, kind: .offer,
            data: .object(["mvSession": .object(["type": .string("session-request")])]))
        XCTAssertEqual(responder.route(sessionObject), .ignored(.malformedPayload))
        // An empty SDP string is likewise not a description.
        let empty = SignalEnvelope(from: aID, kind: .offer, data: .string(""))
        XCTAssertEqual(responder.route(empty), .ignored(.malformedPayload))
    }

    func testRouterIgnoresMalformedICE() {
        // ICE in the string form is not acceptable (mid/index lost).
        let stringForm = SignalEnvelope(from: bID, kind: .ice,
                                        data: .string("candidate:1 1 udp 1 192.0.2.1 9 typ host"))
        XCTAssertEqual(initiator.route(stringForm), .ignored(.malformedPayload))
        // Object missing sdpMid.
        let missingMid = SignalEnvelope(from: bID, kind: .ice, data: .object([
            "candidate": .string("c"), "sdpMLineIndex": .number(0)]))
        XCTAssertEqual(initiator.route(missingMid), .ignored(.malformedPayload))
    }

    // MARK: - ICECandidateBuffer

    func testBufferHoldsUntilRemoteDescription() {
        var buffer = ICECandidateBuffer()
        XCTAssertFalse(buffer.isRemoteDescriptionSet)
        XCTAssertEqual(buffer.add(candidate(1)), [])
        XCTAssertEqual(buffer.add(candidate(2)), [])
        XCTAssertEqual(buffer.pendingCount, 2)
        XCTAssertFalse(buffer.isRemoteDescriptionSet)
    }

    func testBufferDrainsInArrivalOrder() {
        var buffer = ICECandidateBuffer()
        _ = buffer.add(candidate(3))
        _ = buffer.add(candidate(1))
        _ = buffer.add(candidate(2))
        XCTAssertEqual(buffer.remoteDescriptionSet(),
                       [candidate(3), candidate(1), candidate(2)])
        XCTAssertTrue(buffer.isRemoteDescriptionSet)
        XCTAssertEqual(buffer.pendingCount, 0)
        // A second drain has nothing left.
        XCTAssertEqual(buffer.remoteDescriptionSet(), [])
    }

    func testBufferPassesThroughAfterSet() {
        var buffer = ICECandidateBuffer()
        _ = buffer.remoteDescriptionSet()
        XCTAssertEqual(buffer.add(candidate(5)), [candidate(5)])
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    // MARK: - Stats selection

    private func statsEntry(_ id: String, _ type: String,
                            _ values: [String: JSONValue]) -> MeshStatsEntry {
        MeshStatsEntry(id: id, type: type, values: values)
    }

    func testStatsSelectionUsesTransportSelectedPair() {
        // Two succeeded pairs; the transport names the relay one.
        let stats = [
            statsEntry("T1", "transport", ["selectedCandidatePairId": .string("CP2")]),
            statsEntry("CP1", "candidate-pair", [
                "state": .string("succeeded"), "nominated": .bool(true),
                "localCandidateId": .string("L1"), "remoteCandidateId": .string("R1")]),
            statsEntry("CP2", "candidate-pair", [
                "state": .string("succeeded"), "nominated": .bool(true),
                "localCandidateId": .string("L2"), "remoteCandidateId": .string("R2")]),
            statsEntry("L1", "local-candidate", ["candidateType": .string("host")]),
            statsEntry("L2", "local-candidate", ["candidateType": .string("relay")]),
        ]
        XCTAssertEqual(MeshStatsSelection.selectedLocalCandidateType(in: stats), .relay)
    }

    func testStatsSelectionFallsBackToNominatedSucceededPair() {
        // No transport entry: an in-progress pair and a failed
        // nominated pair must not win over the succeeded one.
        let stats = [
            statsEntry("CP1", "candidate-pair", [
                "state": .string("in-progress"), "nominated": .bool(true),
                "localCandidateId": .string("L1")]),
            statsEntry("CP2", "candidate-pair", [
                "state": .string("failed"), "nominated": .bool(true),
                "localCandidateId": .string("L2")]),
            statsEntry("CP3", "candidate-pair", [
                "state": .string("succeeded"), "nominated": .bool(true),
                "localCandidateId": .string("L3")]),
            statsEntry("L1", "local-candidate", ["candidateType": .string("relay")]),
            statsEntry("L2", "local-candidate", ["candidateType": .string("relay")]),
            statsEntry("L3", "local-candidate", ["candidateType": .string("srflx")]),
        ]
        XCTAssertEqual(MeshStatsSelection.selectedLocalCandidateType(in: stats), .srflx)
    }

    func testStatsSelectionSucceededUnnominatedPair() {
        // nominated arrives as NSNumber 1 (not a JSON bool) in
        // some stats shapes; and an unnamed succeeded pair still
        // resolves when it is the only one.
        let stats = [
            statsEntry("CP1", "candidate-pair", [
                "state": .string("succeeded"),
                "localCandidateId": .string("L1")]),
            statsEntry("L1", "local-candidate", ["candidateType": .string("host")]),
        ]
        XCTAssertEqual(MeshStatsSelection.selectedLocalCandidateType(in: stats), .host)
    }

    func testStatsSelectionNilWithoutUsablePair() {
        XCTAssertNil(MeshStatsSelection.selectedLocalCandidateType(in: []))
        // Pair exists but never succeeded.
        let inProgress = [
            statsEntry("CP1", "candidate-pair", [
                "state": .string("in-progress"), "nominated": .bool(true),
                "localCandidateId": .string("L1")]),
            statsEntry("L1", "local-candidate", ["candidateType": .string("host")]),
        ]
        XCTAssertNil(MeshStatsSelection.selectedLocalCandidateType(in: inProgress))
        // Succeeded pair whose local candidate entry is missing.
        let orphan = [
            statsEntry("CP1", "candidate-pair", [
                "state": .string("succeeded"), "nominated": .bool(true),
                "localCandidateId": .string("LX")]),
        ]
        XCTAssertNil(MeshStatsSelection.selectedLocalCandidateType(in: orphan))
    }

    func testCandidateTypeParsing() {
        XCTAssertEqual(MeshCandidateType(parsing: "host"), .host)
        XCTAssertEqual(MeshCandidateType(parsing: "srflx"), .srflx)
        XCTAssertEqual(MeshCandidateType(parsing: "relay"), .relay)
        XCTAssertEqual(MeshCandidateType(parsing: "prflx"), .prflx)
        XCTAssertEqual(MeshCandidateType(parsing: "future-kind"), .unknown)
        XCTAssertEqual(MeshCandidateType(parsing: ""), .unknown)
    }
}
