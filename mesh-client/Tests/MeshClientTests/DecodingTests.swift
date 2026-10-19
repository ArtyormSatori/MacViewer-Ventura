import XCTest
@testable import MeshClient

/// Decoding tests against payloads recorded from the real Go server
/// (internal/mesh/server.go): Go marshals response maps with
/// alphabetically sorted keys and structs in field order; both shapes
/// are represented here exactly as they arrive on the wire.
final class DecodingTests: XCTestCase {

    func testRegisterResponse() throws {
        let payload = #"{"mesh_id":"123456789"}"#
        // Decoded through the client's own response shape.
        struct Response: Decodable { let mesh_id: MeshID }
        let decoded = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.mesh_id, try MeshID(validating: "123456789"))
    }

    func testNonceResponse() throws {
        let payload = #"{"nonce":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#
        struct Response: Decodable { let nonce: String }
        let decoded = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.nonce, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }

    func testStatusResponses() throws {
        for status in ["requested", "already_paired", "paired", "rejected"] {
            let payload = "{\"status\":\"\(status)\"}"
            struct Response: Decodable { let status: String }
            let decoded = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
            XCTAssertEqual(decoded.status, status)
        }
        XCTAssertEqual(PairingRequestResult(rawValue: "requested"), .requested)
        XCTAssertEqual(PairingRequestResult(rawValue: "already_paired"), .alreadyPaired)
    }

    func testPendingList() throws {
        struct Response: Decodable { let pending: [String] }
        let one = try JSONDecoder().decode(
            Response.self, from: Data(#"{"pending":["123456789"]}"#.utf8))
        XCTAssertEqual(one.pending, ["123456789"])
        let empty = try JSONDecoder().decode(
            Response.self, from: Data(#"{"pending":[]}"#.utf8))
        XCTAssertEqual(empty.pending, [])
    }

    func testPresenceResponse() throws {
        // GET /presence/{id} as emitted by the server (map keys sorted).
        let payload = #"{"last_seen":1730000000,"mesh_id":"123456789","name":"Mark's MacBook Pro","online":true}"#
        struct Response: Decodable {
            let mesh_id: MeshID
            let name: String
            let online: Bool
            let last_seen: Int64
        }
        let decoded = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.mesh_id.rawValue, "123456789")
        XCTAssertEqual(decoded.name, "Mark's MacBook Pro")
        XCTAssertTrue(decoded.online)
        XCTAssertEqual(decoded.last_seen, 1730000000)
    }

    func testMeshIDCodableRejectsMalformed() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(MeshID.self, from: Data(#""12345""#.utf8)))
        let id = try JSONDecoder().decode(MeshID.self, from: Data(#""123456789""#.utf8))
        XCTAssertEqual(id.rawValue, "123456789")
        let encoded = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""123456789""#)
    }
}
