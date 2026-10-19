import Foundation
import LocalAuthentication
import MeshClient
import Security
import Testing
@testable import MacViewer

struct MeshIdentityStoreTests {
    @Test("Identity and Mesh ID round-trip through the Keychain store")
    func roundTrip() throws {
        let backend = MeshMemoryKeychain()
        let store = KeychainMeshIdentityStore(
            service: "MacViewer.tests.\(UUID().uuidString)", operations: backend.operations)

        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadMeshID() == nil)

        let identity = MeshIdentity()
        try store.saveIdentity(identity)
        let loaded = try #require(try store.loadIdentity())
        #expect(loaded.rawRepresentation == identity.rawRepresentation)
        #expect(loaded.publicKeyBase64 == identity.publicKeyBase64)

        // loadOrCreate is idempotent against the Keychain store: the
        // same keypair comes back, never a fresh one.
        let again = try MeshIdentity.loadOrCreate(using: store)
        #expect(again.publicKeyBase64 == identity.publicKeyBase64)

        let meshID = try MeshID(validating: "482913705")
        try store.saveMeshID(meshID)
        #expect(try store.loadMeshID() == meshID)

        // Saving again replaces in place (update path, not a duplicate).
        let other = MeshIdentity()
        try store.saveIdentity(other)
        #expect(try store.loadIdentity()?.publicKeyBase64 == other.publicKeyBase64)
        #expect(backend.items.count == 2)
    }

    @Test("Every Keychain query stays inside this app's non-synchronized namespace")
    func queryHygiene() throws {
        let backend = MeshMemoryKeychain()
        let service = "MacViewer.tests.\(UUID().uuidString)"
        let store = KeychainMeshIdentityStore(service: service, operations: backend.operations)
        try store.saveIdentity(MeshIdentity())
        try store.saveMeshID(MeshID(validating: "123456789"))
        _ = try store.loadIdentity()
        _ = try store.loadMeshID()

        #expect(!backend.queries.isEmpty)
        for query in backend.queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == service)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
            #expect(context.interactionNotAllowed)
        }
        // Writes carry the hardened accessibility on add and update.
        #expect(!backend.writes.isEmpty)
        for write in backend.writes {
            #expect(write[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
    }

    @Test("A locked Keychain surfaces an error instead of looking like a missing identity")
    func deniedAccess() throws {
        let backend = MeshMemoryKeychain()
        let store = KeychainMeshIdentityStore(
            service: "MacViewer.tests.\(UUID().uuidString)", operations: backend.operations)
        try store.saveIdentity(MeshIdentity())
        backend.failure = errSecInteractionNotAllowed
        #expect(throws: MeshError.self) { try store.loadIdentity() }
        #expect(throws: MeshError.self) { try store.saveIdentity(MeshIdentity()) }
        backend.failure = nil
        #expect(try store.loadIdentity() != nil)
    }

    @Test("Corrupt stored material throws instead of producing a wrong identity")
    func corruptMaterial() throws {
        let backend = MeshMemoryKeychain()
        let service = "MacViewer.tests.\(UUID().uuidString)"
        let store = KeychainMeshIdentityStore(service: service, operations: backend.operations)
        backend.items[.init(service: service, account: "identity-seed", synchronized: false)]
            = Data([0x01, 0x02, 0x03])
        #expect(throws: MeshError.self) { try store.loadIdentity() }
        backend.items[.init(service: service, account: "mesh-id", synchronized: false)]
            = Data("not-digits".utf8)
        #expect(throws: MeshError.self) { try store.loadMeshID() }
    }
}

/// Security API test double only: no SecItem function is called by these tests.
private final class MeshMemoryKeychain {
    struct Key: Hashable {
        let service: String
        let account: String
        let synchronized: Bool
    }
    typealias Query = KeychainMeshIdentityStore.Operations.Query
    var items: [Key: Data] = [:]
    var queries: [Query] = []
    var writes: [Query] = []
    var failure: OSStatus?

    var operations: KeychainMeshIdentityStore.Operations {
        .init(copy: { [self] query in
            queries.append(query)
            if let failure { return (failure, nil) }
            guard let key = matching(query).first, let data = items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as CFData)
        }, add: { [self] query in
            queries.append(query)
            writes.append(query)
            if let failure { return failure }
            guard let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String,
                  let data = query[kSecValueData as String] as? Data else { return errSecParam }
            let key = Key(service: service, account: account,
                          synchronized: query[kSecAttrSynchronizable as String] as? Bool ?? false)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = data
            return errSecSuccess
        }, update: { [self] query, changes in
            queries.append(query)
            writes.append(changes)
            if let failure { return failure }
            let keys = matching(query)
            guard !keys.isEmpty else { return errSecItemNotFound }
            guard let data = changes[kSecValueData as String] as? Data else { return errSecParam }
            for key in keys { items[key] = data }
            return errSecSuccess
        }, delete: { [self] query in
            queries.append(query)
            if let failure { return failure }
            let keys = matching(query)
            for key in keys { items.removeValue(forKey: key) }
            return keys.isEmpty ? errSecItemNotFound : errSecSuccess
        })
    }

    private func matching(_ query: Query) -> [Key] {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let synchronized = query[kSecAttrSynchronizable as String] as? Bool
        return items.keys.filter {
            $0.service == service && (account == nil || $0.account == account)
                && (synchronized == nil || $0.synchronized == synchronized)
        }
    }
}
