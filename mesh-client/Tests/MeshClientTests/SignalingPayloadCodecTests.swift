import XCTest
@testable import MeshClient

/// M1 payload pins for the signaling codec: media signaling (SDP and ICE)
/// must travel through the *existing* `SignalingEnvelope` unchanged.
///
/// Chunk 2 established that app-layer envelopes (session, chat) ride on
/// kind `.offer` with `data` = a JSON **object** carrying a marker key,
/// and predicted that M1's SDP — kind `.offer`/`.answer` with `data` =
/// a **string** — cannot collide with them. These tests prove that
/// prediction at the codec level with full-size, real-format payloads:
/// a complete libwebrtc-style datachannel offer/answer (multi-line,
/// CRLF-terminated, with ICE credentials and a DTLS fingerprint) and
/// real `candidate:` attribute strings, all byte-exact after an
/// encode → wire-JSON → decode round trip.
final class SignalingPayloadCodecTests: XCTestCase {

    /// A complete datachannel offer in the exact shape libwebrtc emits:
    /// CRLF line endings, trailing CRLF, ICE ufrag/pwd, DTLS
    /// fingerprint, SCTP datachannel m-line.
    private let offerSDP: String = [
        "v=0",
        "o=- 7047276584701964649 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0",
        "a=extmap-allow-mixed",
        "a=msid-semantic: WMS",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        "c=IN IP4 0.0.0.0",
        "a=ice-ufrag:4dHc",
        "a=ice-pwd:Kj3kLm9Qx2Wz8Rt5Vb7Np1Ys",
        "a=ice-options:trickle",
        "a=fingerprint:sha-256 3A:5F:9C:1D:77:02:BE:44:8D:6A:C0:19:F3:58:2B:94:AD:07:63:DA:51:EE:80:26:B4:19:93:7C:05:FA:62:8D",
        "a=setup:actpass",
        "a=mid:0",
        "a=sctp-port:5000",
        "a=max-message-size:262144",
        "",
    ].joined(separator: "\r\n")

    /// The matching answer: same shape, `a=setup:active`.
    private let answerSDP: String = [
        "v=0",
        "o=- 4611733050430601532 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0",
        "a=extmap-allow-mixed",
        "a=msid-semantic: WMS",
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        "c=IN IP4 0.0.0.0",
        "a=ice-ufrag:Zx81",
        "a=ice-pwd:Qw7Er2Ty5Ui9Op3As6Df4Gh1",
        "a=ice-options:trickle",
        "a=fingerprint:sha-256 B1:04:9E:72:0A:F5:38:CC:61:9D:24:87:FE:50:AB:16:39:D8:42:7B:95:0C:E6:AD:58:21:FA:04:97:33:6E:C9",
        "a=setup:active",
        "a=mid:0",
        "a=sctp-port:5000",
        "a=max-message-size:262144",
        "",
    ].joined(separator: "\r\n")

    /// Host candidate, exactly as `RTCIceCandidate.sdp` renders it.
    private let hostCandidate =
        "candidate:2445164469 1 udp 2122260223 192.168.31.14 53441 typ host generation 0 ufrag 4dHc network-id 1 network-cost 50"

    /// TURN relay candidate (carries raddr/rport), same rendering.
    private let relayCandidate =
        "candidate:3355672270 1 udp 41885439 203.0.113.8 61234 typ relay raddr 192.168.31.14 rport 53441 generation 0 ufrag 4dHc network-id 1 network-cost 50"

    private func roundTrip(_ envelope: SignalingEnvelope) throws -> SignalingEnvelope {
        try SignalingEnvelope.decodeJSON(envelope.encodedJSON())
    }

    private func assertStringPayload(_ value: JSONValue?, equals expected: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard case .string(let actual)? = value else {
            XCTFail("payload is not a JSON string: \(String(describing: value))", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8),
                       "payload must be byte-exact, not just string-equal", file: file, line: line)
    }

    func testOfferSDPStringSurvivesCodecByteExact() throws {
        let envelope = SignalingEnvelope(
            type: .signal, to: try MeshID(validating: "987654321"),
            kind: .offer, data: .string(offerSDP))
        let decoded = try roundTrip(envelope)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .offer)
        assertStringPayload(decoded.data, equals: offerSDP)
        // Re-encoding the decoded envelope reproduces the wire text:
        // the codec is a stable fixed point for string payloads.
        XCTAssertEqual(try decoded.encodedJSON(), try envelope.encodedJSON())
    }

    func testAnswerSDPStringSurvivesCodecByteExact() throws {
        let envelope = SignalingEnvelope(
            type: .signal, to: try MeshID(validating: "123456789"),
            kind: .answer, data: .string(answerSDP))
        let decoded = try roundTrip(envelope)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .answer)
        assertStringPayload(decoded.data, equals: answerSDP)
    }

    func testSDPWireJSONEscapesCRLF() throws {
        let envelope = SignalingEnvelope(
            type: .signal, kind: .offer, data: .string(offerSDP))
        let wire = try envelope.encodedJSON()
        // The multi-line SDP rides inside ONE single-line JSON frame:
        // every CRLF must appear escaped, never literal.
        XCTAssertFalse(wire.contains("\r\n"))
        XCTAssertTrue(wire.contains(#"\r\n"#))
        let decoded = try SignalingEnvelope.decodeJSON(wire)
        assertStringPayload(decoded.data, equals: offerSDP)
        // 17 SDP lines + the empty element after the trailing CRLF.
        XCTAssertEqual(offerSDP.components(separatedBy: "\r\n").count, 18)
    }

    func testICECandidateStringsSurviveCodecByteExact() throws {
        for candidate in [hostCandidate, relayCandidate] {
            let envelope = SignalingEnvelope(
                type: .signal, to: try MeshID(validating: "987654321"),
                kind: .ice, data: .string(candidate))
            let decoded = try roundTrip(envelope)
            XCTAssertEqual(decoded, envelope)
            XCTAssertEqual(decoded.kind, .ice)
            assertStringPayload(decoded.data, equals: candidate)
        }
    }

    /// The mesh server protocol documents ICE as a JSON object
    /// ({candidate, sdpMid, sdpMLineIndex}) because reconstructing an
    /// RTCIceCandidate needs all three fields. That form must also
    /// round-trip intact.
    func testICECandidateObjectFormSurvivesCodec() throws {
        let object: JSONValue = .object([
            "candidate": .string(hostCandidate),
            "sdpMid": .string("0"),
            "sdpMLineIndex": .number(0),
        ])
        let envelope = SignalingEnvelope(
            type: .signal, to: try MeshID(validating: "987654321"),
            kind: .ice, data: object)
        let decoded = try roundTrip(envelope)
        XCTAssertEqual(decoded, envelope)
        guard case .object(let fields)? = decoded.data else {
            return XCTFail("ICE object payload decoded as \(String(describing: decoded.data))")
        }
        XCTAssertEqual(fields["candidate"], .string(hostCandidate))
        XCTAssertEqual(fields["sdpMid"], .string("0"))
        XCTAssertEqual(fields["sdpMLineIndex"], .number(0))
    }

    /// The chunk-2 discrimination pin: `.offer` + string data (media
    /// SDP) and `.offer` + object data (app envelopes) are distinct on
    /// the wire and stay distinct after decoding — neither form can be
    /// mistaken for the other by a receiver switching on `data`.
    func testStringAndObjectPayloadsDoNotCollide() throws {
        let sdpEnvelope = SignalingEnvelope(
            type: .signal, kind: .offer, data: .string(offerSDP))
        let appEnvelope = SignalingEnvelope(
            type: .signal, kind: .offer,
            data: .object(["mvSession": .object(["type": .string("session-request")])]))

        let sdpDecoded = try roundTrip(sdpEnvelope)
        let appDecoded = try roundTrip(appEnvelope)

        XCTAssertEqual(sdpDecoded.kind, appDecoded.kind) // same kind…
        guard case .string = sdpDecoded.data else {
            return XCTFail("SDP payload lost its string form")
        }
        guard case .object = appDecoded.data else {
            return XCTFail("app payload lost its object form")
        }
        XCTAssertNotEqual(sdpDecoded.data, appDecoded.data)
    }
}
