import Foundation
@preconcurrency import Crypto

/// A device's Ed25519 identity. The private key never leaves the device;
/// the server stores only the public key (design §7, server README).
///
/// Wraps swift-crypto's `Curve25519.Signing` so the identical code builds
/// on Linux and Apple platforms.
public struct MeshIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Rebuilds an identity from the 32-byte private key seed
    /// (the raw representation persisted by the stores below).
    public init(rawRepresentation seed: Data) throws {
        do {
            self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw MeshError.identityStoreFailure("corrupt private key material")
        }
    }

    /// The 32-byte private key seed. Handle as a secret.
    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// Base64 (standard encoding, padded) of the 32-byte public key —
    /// exactly what `POST /register` expects in its `pubkey` field.
    public var publicKeyBase64: String {
        Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
    }

    public var publicKeyData: Data { Data(privateKey.publicKey.rawRepresentation) }

    /// Signs the server's nonce *string* (its UTF-8 bytes), as
    /// `ed25519.Sign(priv, []byte(nonce))` does server-side, and returns
    /// the signature base64 standard-encoded — the `signature` field of
    /// every authenticated request and of the WebSocket handshake.
    ///
    /// Note: swift-crypto's Ed25519 API represents signatures as plain
    /// 64-byte `Data` and its `signature(for:)` is throwing (unlike
    /// CryptoKit's); failures surface as `.identityStoreFailure`.
    public func signatureBase64(forNonce nonce: String) throws -> String {
        do {
            let signature = try privateKey.signature(for: Data(nonce.utf8))
            return signature.base64EncodedString()
        } catch {
            throw MeshError.identityStoreFailure("signing failed: \(error)")
        }
    }

    /// Verifies a signature produced by `signatureBase64(forNonce:)`.
    public func isValidSignature(_ signatureBase64: String, forNonce nonce: String) -> Bool {
        guard let data = Data(base64Encoded: signatureBase64), data.count == 64 else {
            return false
        }
        return privateKey.publicKey.isValidSignature(data, for: Data(nonce.utf8))
    }
}

// MARK: - Storage

/// Persistence for a device identity and its assigned Mesh ID.
///
/// The app layer will add a Keychain-backed store on macOS later; this
/// package ships a file store (private key file mode 0600) and an
/// in-memory store for tests. No Keychain code lives here by design.
public protocol MeshIdentityStore: Sendable {
    func loadIdentity() throws -> MeshIdentity?
    func saveIdentity(_ identity: MeshIdentity) throws
    func loadMeshID() throws -> MeshID?
    func saveMeshID(_ meshID: MeshID) throws
}

extension MeshIdentity {
    /// Loads the stored identity, or creates, saves and returns a fresh
    /// one. Idempotent: repeated calls return the same keypair.
    public static func loadOrCreate(using store: some MeshIdentityStore) throws -> MeshIdentity {
        if let existing = try store.loadIdentity() {
            return existing
        }
        let fresh = MeshIdentity()
        try store.saveIdentity(fresh)
        return fresh
    }
}

/// File-backed store. Layout inside the directory:
/// - `identity.key` — base64 private key seed, file mode **0600**
/// - `mesh-id.txt`  — the assigned 9-digit Mesh ID (public information)
public final class FileMeshIdentityStore: MeshIdentityStore, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private var keyURL: URL { directory.appendingPathComponent("identity.key") }
    private var meshIDURL: URL { directory.appendingPathComponent("mesh-id.txt") }

    private func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw MeshError.identityStoreFailure("cannot create \(directory.path): \(error)")
            }
        }
    }

    public func loadIdentity() throws -> MeshIdentity? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        let text: String
        do {
            text = try String(contentsOf: keyURL, encoding: .utf8)
        } catch {
            throw MeshError.identityStoreFailure("cannot read \(keyURL.path): \(error)")
        }
        guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seed.count == 32 else {
            throw MeshError.identityStoreFailure("identity.key is not a base64 Ed25519 seed")
        }
        return try MeshIdentity(rawRepresentation: seed)
    }

    public func saveIdentity(_ identity: MeshIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let text = identity.rawRepresentation.base64EncodedString()
        do {
            try text.write(to: keyURL, atomically: true, encoding: .utf8)
            // Enforce 0600 even if the file already existed with wider perms.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        } catch let error as MeshError {
            throw error
        } catch {
            throw MeshError.identityStoreFailure("cannot write \(keyURL.path): \(error)")
        }
    }

    public func loadMeshID() throws -> MeshID? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: meshIDURL.path) else { return nil }
        let text = try String(contentsOf: meshIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try MeshID(validating: text)
    }

    public func saveMeshID(_ meshID: MeshID) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        do {
            try meshID.rawValue.write(to: meshIDURL, atomically: true, encoding: .utf8)
        } catch {
            throw MeshError.identityStoreFailure("cannot write \(meshIDURL.path): \(error)")
        }
    }
}

/// In-memory store for tests and ephemeral clients.
public final class InMemoryMeshIdentityStore: MeshIdentityStore, @unchecked Sendable {
    private var identity: MeshIdentity?
    private var meshID: MeshID?
    private let lock = NSLock()

    public init() {}

    public func loadIdentity() throws -> MeshIdentity? {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    public func saveIdentity(_ identity: MeshIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        self.identity = identity
    }

    public func loadMeshID() throws -> MeshID? {
        lock.lock(); defer { lock.unlock() }
        return meshID
    }

    public func saveMeshID(_ meshID: MeshID) throws {
        lock.lock(); defer { lock.unlock() }
        self.meshID = meshID
    }
}
