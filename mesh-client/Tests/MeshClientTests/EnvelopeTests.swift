import XCTest
@testable import MeshClient

/// Envelope coding tests against the WebSocket wire format in
/// server.go's `wsMessage`, plus the RFC 6455 frame codec.
final class EnvelopeTests: XCTestCase {

    func testAuthHelloEncoding() throws {
        let envelope = SignalingEnvelope(type: .auth, meshID: try MeshID(validating: "123456789"))
        let json = try envelope.encodedJSON()
        XCTAssertTrue(json.contains(#""type":"auth""#))
        XCTAssertTrue(json.contains(#""mesh_id":"123456789""#))
        XCTAssertFalse(json.contains("signature"))
        XCTAssertFalse(json.contains("nonce"))
    }

    func testSignalEncodingWithSDPStringData() throws {
        let envelope = SignalingEnvelope(
            type: .signal, to: try MeshID(validating: "987654321"),
            kind: .offer, data: .string("v=0 fake-sdp"))
        let json = try envelope.encodedJSON()
        XCTAssertTrue(json.contains(#""type":"signal""#))
        XCTAssertTrue(json.contains(#""to":"987654321""#))
        XCTAssertTrue(json.contains(#""kind":"offer""#))
        XCTAssertTrue(json.contains(#""data":"v=0 fake-sdp""#))
    }

    func testServerNonceChallengeDecoding() throws {
        let wire = #"{"type":"nonce","nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#
        let envelope = try SignalingEnvelope.decodeJSON(wire)
        XCTAssertEqual(envelope.type, .nonce)
        XCTAssertEqual(envelope.nonce, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }

    func testServerAuthOKDecoding() throws {
        let envelope = try SignalingEnvelope.decodeJSON(#"{"type":"auth_ok","mesh_id":"123456789"}"#)
        XCTAssertEqual(envelope.type, .authOK)
        XCTAssertEqual(envelope.meshID?.rawValue, "123456789")
    }

    func testForwardedOfferDecoding() throws {
        let wire = #"{"type":"signal","from":"123456789","kind":"offer","data":"v=0 fake-sdp"}"#
        let envelope = try SignalingEnvelope.decodeJSON(wire)
        XCTAssertEqual(envelope.type, .signal)
        XCTAssertEqual(envelope.from?.rawValue, "123456789")
        XCTAssertEqual(envelope.kind, .offer)
        XCTAssertEqual(envelope.data, .string("v=0 fake-sdp"))
    }

    func testForwardedICEDecoding() throws {
        let wire = #"{"type":"signal","from":"123456789","kind":"ice","data":{"candidate":"candidate:1 1 udp 2113937151 192.168.1.10 53400 typ host","sdpMid":"0","sdpMLineIndex":0}}"#
        let envelope = try SignalingEnvelope.decodeJSON(wire)
        XCTAssertEqual(envelope.kind, .ice)
        guard case .object(let candidate)? = envelope.data else {
            return XCTFail("ice data must decode as a JSON object, got \(String(describing: envelope.data))")
        }
        XCTAssertEqual(candidate["sdpMid"], .string("0"))
        XCTAssertEqual(candidate["sdpMLineIndex"], .number(0))
        if case .string(let text)? = candidate["candidate"] {
            XCTAssertTrue(text.hasPrefix("candidate:1 1 udp"))
        } else {
            XCTFail("candidate field must be a string")
        }
    }

    func testServerErrorDecoding() throws {
        let wire = #"{"type":"error","to":"987654321","code":"not_paired"}"#
        let envelope = try SignalingEnvelope.decodeJSON(wire)
        XCTAssertEqual(envelope.type, .error)
        XCTAssertEqual(envelope.code, "not_paired")
        XCTAssertEqual(envelope.to?.rawValue, "987654321")
        XCTAssertEqual(MeshError(signalingCode: envelope.code!), .notPaired)
    }

    func testEnvelopeRoundtrip() throws {
        let original = SignalingEnvelope(
            type: .signal, to: try MeshID(validating: "987654321"), kind: .ice,
            data: .object(["candidate": .string("candidate:x"), "sdpMLineIndex": .number(2)]))
        let decoded = try SignalingEnvelope.decodeJSON(original.encodedJSON())
        XCTAssertEqual(decoded, original)
    }

    func testJSONValueRoundtrip() throws {
        let value: JSONValue = .object([
            "a": .array([.number(1), .bool(true), .null, .string("x")]),
            "b": .object(["nested": .number(2.5)]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    // MARK: RFC 6455 codec

    func testMaskedTextFrameRoundtrip() {
        let frame = RFC6455.encodeText("hi", maskKey: [1, 2, 3, 4])
        XCTAssertEqual([UInt8](frame), [0x81, 0x82, 1, 2, 3, 4, UInt8(ascii: "h") ^ 1, UInt8(ascii: "i") ^ 2])
        var parser = RFC6455.Parser()
        let frames = parser.feed(frame)
        XCTAssertEqual(frames, [RFC6455.Frame(fin: true, opcode: RFC6455.opText, payload: Data("hi".utf8))])
    }

    func testUnmaskedServerFrameParsing() {
        var parser = RFC6455.Parser()
        let frames = parser.feed(Data([0x81, 0x02, UInt8(ascii: "h"), UInt8(ascii: "i")]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, Data("hi".utf8))
    }

    func testExtendedLengthAndSplitFeeds() {
        let payload = Data(repeating: 0x61, count: 200) // 'a' x 200 -> 126-length form
        let frame = RFC6455.encodeFrame(opcode: RFC6455.opText, payload: payload, maskKey: [9, 9, 9, 9])
        XCTAssertEqual(frame[1], 0x80 | 126)
        var parser = RFC6455.Parser()
        XCTAssertEqual(parser.feed(frame.prefix(3)).count, 0, "incomplete frame must not be emitted")
        let frames = parser.feed(frame.dropFirst(3))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, payload)
    }

    func test64BitLengthForm() {
        let payload = Data(repeating: 0x62, count: 70_000)
        let frame = RFC6455.encodeFrame(opcode: RFC6455.opBinary, payload: payload, maskKey: [0, 0, 0, 0])
        XCTAssertEqual(frame[1], 0x80 | 127)
        var parser = RFC6455.Parser()
        let frames = parser.feed(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload.count, 70_000)
    }

    func testSignalURLDerivation() throws {
        let http = MeshSignalingClient.makeSignalURL(base: URL(string: "http://127.0.0.1:8734")!)
        XCTAssertEqual(http.absoluteString, "ws://127.0.0.1:8734/signal")
        let https = MeshSignalingClient.makeSignalURL(base: URL(string: "https://mesh.example.com")!)
        XCTAssertEqual(https.absoluteString, "wss://mesh.example.com/signal")
    }
}
