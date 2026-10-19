import XCTest
@testable import MeshClient

/// Pins the (HTTP status, server message) -> MeshError mapping against
/// every error string the Go server can emit (server.go writeErr sites).
final class ErrorMappingTests: XCTestCase {

    private func map(_ status: Int, _ body: String) -> MeshError {
        MeshServerClient.mapError(status: status, data: Data(body.utf8))
    }

    func testRegisterErrors() {
        XCTAssertEqual(map(400, #"{"error":"pubkey must be a base64 Ed25519 public key"}"#),
                       .invalidPublicKey)
        XCTAssertEqual(map(400, #"{"error":"name is required"}"#), .nameRequired)
        XCTAssertEqual(map(403, #"{"error":"a valid invite code is required"}"#),
                       .inviteRequired)
    }

    func testAuthAndPairingErrors() {
        XCTAssertEqual(map(401, #"{"error":"authentication failed"}"#), .authenticationFailed)
        XCTAssertEqual(map(400, #"{"error":"peer must be another device's Mesh ID"}"#), .invalidPeer)
        XCTAssertEqual(map(404, #"{"error":"unknown peer"}"#), .unknownPeer)
        XCTAssertEqual(map(404, #"{"error":"no pending request from that peer"}"#), .noPendingRequest)
        XCTAssertEqual(map(400, #"{"error":"invalid JSON body"}"#), .invalidRequestBody)
    }

    func testUnknownDeviceErrors() {
        XCTAssertEqual(map(404, #"{"error":"unknown device"}"#), .unknownDevice)
    }

    func testUnmappedErrorsKeepRawValues() {
        XCTAssertEqual(map(500, #"{"error":"registry lookup failed"}"#),
                       .server(status: 500, message: "registry lookup failed"))
        XCTAssertEqual(map(500, "internal boom"),
                       .server(status: 500, message: "internal boom"))
        // Same message with a different status must not be remapped.
        XCTAssertEqual(map(400, #"{"error":"unknown device"}"#),
                       .server(status: 400, message: "unknown device"))
    }

    func testSignalingErrorCodes() {
        XCTAssertEqual(MeshError(signalingCode: "not_paired"), .notPaired)
        XCTAssertEqual(MeshError(signalingCode: "peer_offline"), .peerOffline)
        XCTAssertEqual(MeshError(signalingCode: "bad_signature"), .badSignature)
        XCTAssertEqual(MeshError(signalingCode: "expected_auth"), .expectedAuth)
        XCTAssertEqual(MeshError(signalingCode: "expected_signature"), .expectedSignature)
        XCTAssertEqual(MeshError(signalingCode: "unknown_device"), .unknownDevice)
        XCTAssertEqual(MeshError(signalingCode: "bad_recipient"), .badRecipient)
        XCTAssertEqual(MeshError(signalingCode: "unknown_type"), .unknownEnvelopeType)
        XCTAssertEqual(MeshError(signalingCode: "internal"), .signalingInternal)
        XCTAssertEqual(MeshError(signalingCode: "some_future_code"),
                       .unrecognizedSignalingCode("some_future_code"))
    }
}
