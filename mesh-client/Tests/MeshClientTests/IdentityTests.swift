import XCTest
@testable import MeshClient

final class IdentityTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-identity-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testFileStorePersistenceAndIdempotency() throws {
        let store = FileMeshIdentityStore(directory: tempDir)
        let first = try MeshIdentity.loadOrCreate(using: store)
        let second = try MeshIdentity.loadOrCreate(using: store)
        XCTAssertEqual(first.publicKeyBase64, second.publicKeyBase64,
                       "loadOrCreate must be idempotent")

        // A fresh store instance over the same directory loads the same key.
        let reloaded = try XCTUnwrap(try FileMeshIdentityStore(directory: tempDir).loadIdentity())
        XCTAssertEqual(reloaded.publicKeyBase64, first.publicKeyBase64)
        XCTAssertEqual(reloaded.rawRepresentation, first.rawRepresentation)
    }

    func testPrivateKeyFilePermissionsAre0600() throws {
        let store = FileMeshIdentityStore(directory: tempDir)
        _ = try MeshIdentity.loadOrCreate(using: store)
        let keyPath = tempDir.appendingPathComponent("identity.key").path
        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        let perms = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "private key file must be mode 0600")
    }

    func testMeshIDPersistence() throws {
        let store = FileMeshIdentityStore(directory: tempDir)
        XCTAssertNil(try store.loadMeshID())
        let id = try MeshID(validating: "123456789")
        try store.saveMeshID(id)
        XCTAssertEqual(try store.loadMeshID(), id)
        XCTAssertEqual(try FileMeshIdentityStore(directory: tempDir).loadMeshID(), id)
    }

    func testInMemoryStoreRoundtrip() throws {
        let store = InMemoryMeshIdentityStore()
        XCTAssertNil(try store.loadIdentity())
        let identity = try MeshIdentity.loadOrCreate(using: store)
        XCTAssertEqual(try store.loadIdentity()?.publicKeyBase64, identity.publicKeyBase64)
        let id = try MeshID(validating: "987654321")
        try store.saveMeshID(id)
        XCTAssertEqual(try store.loadMeshID(), id)
    }

    func testNonceSignatureVerifiesAndTamperingFails() throws {
        let identity = MeshIdentity()
        let nonce = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let signature = try identity.signatureBase64(forNonce: nonce)
        XCTAssertTrue(identity.isValidSignature(signature, forNonce: nonce))
        XCTAssertFalse(identity.isValidSignature(signature, forNonce: nonce + "x"))
        XCTAssertFalse(identity.isValidSignature("AAAA", forNonce: nonce))

        // A different identity must not verify the signature.
        let other = MeshIdentity()
        XCTAssertFalse(other.isValidSignature(signature, forNonce: nonce))
    }

    func testPublicKeyBase64IsStandardEncodingOf32Bytes() throws {
        let identity = MeshIdentity()
        let decoded = Data(base64Encoded: identity.publicKeyBase64)
        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded, identity.publicKeyData)
    }

    func testMeshIDValidationAndFormatting() throws {
        let id = try MeshID(validating: "123456789")
        XCTAssertEqual(id.formatted, "123 456 789")
        XCTAssertEqual(id.description, "123 456 789")
        XCTAssertThrowsError(try MeshID(validating: "12345"))
        XCTAssertThrowsError(try MeshID(validating: "1234567890"))
        XCTAssertThrowsError(try MeshID(validating: "abcdefghi"))
        XCTAssertThrowsError(try MeshID(validating: ""))
    }

    func testPairingRecordsPersist() throws {
        let server = URL(string: "http://127.0.0.1:18734")!
        let fileRecord = FilePairingRecord(directory: tempDir, server: server)
        let a = try MeshID(validating: "111222333")
        let b = try MeshID(validating: "444555666")
        fileRecord.notePaired(b)
        fileRecord.notePaired(a)
        fileRecord.notePaired(a) // duplicate is a no-op
        XCTAssertEqual(fileRecord.pairedDevices(), [a, b])
        // Reloaded from disk by a fresh instance.
        XCTAssertEqual(FilePairingRecord(directory: tempDir, server: server).pairedDevices(), [a, b])

        let memory = InMemoryPairingRecord()
        memory.notePaired(a)
        XCTAssertEqual(memory.pairedDevices(), [a])
    }
}
