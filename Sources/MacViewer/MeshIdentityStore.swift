import Foundation
import LocalAuthentication
import MeshClient
import Security

/// Keychain-backed `MeshIdentityStore` for the app (UI spec §3.2 / 5.0
/// design: credentials live only in Keychain). The mesh core package
/// deliberately ships no Keychain code; this is the app-layer store its
/// `MeshIdentityStore` protocol anticipates.
///
/// Two generic-password items under one service:
/// - account `identity-seed` — the 32-byte Ed25519 private key seed
/// - account `mesh-id` — the server-assigned Mesh ID (public, but kept
///   beside the identity so the pair is loaded atomically)
///
/// Both items are `WhenUnlockedThisDeviceOnly` and non-synchronizable,
/// the same hardening the partner-password store applies. All failures
/// surface as `MeshError.identityStoreFailure`, the core's vocabulary.
///
/// The `Operations` boundary mirrors `KeychainPartnerCredentialStore`
/// (duplicated, not shared: that store is `@MainActor`-isolated while
/// the core protocol requires a plain `Sendable` store). Tests inject
/// an in-memory backend and never touch the user's real Keychain.
final class KeychainMeshIdentityStore: MeshIdentityStore, @unchecked Sendable {
    struct Operations {
        typealias Query = [String: Any]
        var copy: (Query) -> (OSStatus, CFTypeRef?)
        var add: (Query) -> OSStatus
        var update: (Query, Query) -> OSStatus
        var delete: (Query) -> OSStatus

        static var system: Self {
            Self(copy: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            }, add: { SecItemAdd($0 as CFDictionary, nil) },
                 update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
                 delete: { SecItemDelete($0 as CFDictionary) })
        }
    }

    static let service = "dev.macviewer.mesh"
    private static let seedAccount = "identity-seed"
    private static let meshIDAccount = "mesh-id"

    private let serviceName: String
    private let operations: Operations
    private let lock = NSLock()

    init() {
        serviceName = Self.service
        operations = .system
    }

    /// Tests supply an in-memory backend and a unique namespace.
    init(service: String, operations: Operations) {
        precondition(!service.isEmpty)
        serviceName = service
        self.operations = operations
    }

    // MARK: MeshIdentityStore

    func loadIdentity() throws -> MeshIdentity? {
        lock.lock(); defer { lock.unlock() }
        guard let seed = try readItem(account: Self.seedAccount) else { return nil }
        return try MeshIdentity(rawRepresentation: seed)
    }

    func saveIdentity(_ identity: MeshIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        try writeItem(account: Self.seedAccount, data: identity.rawRepresentation,
                      label: "MacViewer Ventura mesh identity")
    }

    func loadMeshID() throws -> MeshID? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try readItem(account: Self.meshIDAccount) else { return nil }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw MeshError.identityStoreFailure("stored Mesh ID is not UTF-8")
        }
        return try MeshID(validating: raw)
    }

    func saveMeshID(_ meshID: MeshID) throws {
        lock.lock(); defer { lock.unlock() }
        try writeItem(account: Self.meshIDAccount, data: Data(meshID.rawValue.utf8),
                      label: "MacViewer Ventura Mesh ID")
    }

    // MARK: Keychain plumbing

    private func readItem(account: String) throws -> Data? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        try check(status, account: account)
        guard let data = result as? Data else {
            throw MeshError.identityStoreFailure("Keychain item \(account) is not data")
        }
        return data
    }

    private func writeItem(account: String, data: Data, label: String) throws {
        let query = itemQuery(account: account)
        // Set the accessibility on both add and update so items written
        // by an older build migrate to the hardened level.
        let changes: Operations.Query = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = operations.update(query, changes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw MeshError.identityStoreFailure("Keychain update for \(account) failed (\(status))")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = operations.add(item)
        if added == errSecDuplicateItem {
            try check(operations.update(query, changes), account: account)
        } else {
            try check(added, account: account)
        }
    }

    private func itemQuery(account: String) -> Operations.Query {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private func baseQuery() -> Operations.Query {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private func check(_ status: OSStatus, account: String) throws {
        guard status == errSecSuccess else {
            throw MeshError.identityStoreFailure("Keychain access for \(account) failed (\(status))")
        }
    }
}
