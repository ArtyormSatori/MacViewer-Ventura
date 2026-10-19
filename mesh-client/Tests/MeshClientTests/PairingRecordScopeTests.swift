import XCTest
@testable import MeshClient

/// Server scoping of the file-backed pairing record: pairings are
/// grants on ONE server and must never leak into another server's
/// list when the client switches servers (PHASE3_NOTES chunk 1,
/// friction #2 — fixed in the core-fixes part).
final class PairingRecordScopeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-scope-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private let serverA = URL(string: "http://127.0.0.1:18734")!
    private let serverB = URL(string: "https://mesh.example.com")!

    private func id(_ raw: String) throws -> MeshID { try MeshID(validating: raw) }

    // MARK: Server-key normalization

    func testServerKeyNormalization() {
        let key = FilePairingRecord.serverKey(for:)
        XCTAssertEqual(key(URL(string: "http://127.0.0.1:18734")!), "http://127.0.0.1:18734")
        // Default port explicit or implicit: same server.
        XCTAssertEqual(key(URL(string: "http://example.com")!), "http://example.com")
        XCTAssertEqual(key(URL(string: "http://example.com:80")!), "http://example.com")
        XCTAssertEqual(key(URL(string: "https://example.com:443")!), "https://example.com")
        // Scheme/host case and trailing slash are not identity.
        XCTAssertEqual(key(URL(string: "HTTP://EXAMPLE.COM/")!), "http://example.com")
        XCTAssertEqual(key(URL(string: "http://example.com/")!), key(URL(string: "http://example.com")!))
        // Path is not identity either (no path-variance games).
        XCTAssertEqual(key(URL(string: "http://example.com/some/path?x=1")!), "http://example.com")
        // Non-default port and scheme ARE identity.
        XCTAssertEqual(key(URL(string: "http://example.com:8080")!), "http://example.com:8080")
        XCTAssertNotEqual(key(URL(string: "https://example.com")!),
                          key(URL(string: "http://example.com")!))
        XCTAssertNotEqual(key(URL(string: "http://example.com:18734")!),
                          key(URL(string: "http://example.com:18735")!))
        // IPv6 literals keep their brackets in the key.
        XCTAssertEqual(key(URL(string: "http://[::1]:18734")!), "http://[::1]:18734")
    }

    // MARK: Scoping behavior

    func testPairingsDoNotLeakAcrossServers() throws {
        let peer = try id("111222333")
        FilePairingRecord(directory: tempDir, server: serverA).notePaired(peer)

        // A record for another server, same directory: nothing.
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverB).pairedDevices(), [])
        // The owning server still sees its pairing.
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverA).pairedDevices(), [peer])
    }

    func testEquivalentSpellingsShareOneBucket() throws {
        let peer = try id("111222333")
        FilePairingRecord(directory: tempDir, server: URL(string: "HTTP://Example.COM:80/")!)
            .notePaired(peer)
        XCTAssertEqual(
            FilePairingRecord(directory: tempDir, server: URL(string: "http://example.com")!)
                .pairedDevices(),
            [peer])
    }

    func testBothServersBucketsCoexistInOneFile() throws {
        let a = try id("111222333")
        let b = try id("444555666")
        FilePairingRecord(directory: tempDir, server: serverA).notePaired(a)
        FilePairingRecord(directory: tempDir, server: serverB).notePaired(b)

        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverA).pairedDevices(), [a])
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverB).pairedDevices(), [b])

        // The file really is the v2 per-server envelope.
        let data = try Data(contentsOf: tempDir.appendingPathComponent("paired-peers.json"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        let servers = try XCTUnwrap(object["servers"] as? [String: [String]])
        XCTAssertEqual(Set(servers.keys), [
            FilePairingRecord.serverKey(for: serverA),
            FilePairingRecord.serverKey(for: serverB),
        ])
    }

    // MARK: Migration from the v1 bare-array shape

    func testLegacyV1FileIsNotAttributedToAnyServer() throws {
        let legacy = try id("999888777")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Exactly what the pre-scoping record wrote.
        let v1 = try JSONEncoder().encode([legacy.rawValue])
        try v1.write(to: tempDir.appendingPathComponent("paired-peers.json"))

        // The legacy pairing is invisible under every server...
        let recordA = FilePairingRecord(directory: tempDir, server: serverA)
        XCTAssertEqual(recordA.pairedDevices(), [])
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverB).pairedDevices(), [])

        // ...and the first scoped write upgrades the file to v2
        // without resurrecting the legacy entry anywhere.
        let fresh = try id("111222333")
        recordA.notePaired(fresh)
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverA).pairedDevices(), [fresh])
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverB).pairedDevices(), [])
        let data = try Data(contentsOf: tempDir.appendingPathComponent("paired-peers.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x7B]).write(
            to: tempDir.appendingPathComponent("paired-peers.json"))
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: serverA).pairedDevices(), [])
    }
}
