import Foundation
import MeshClient
import Testing
@testable import MacViewer

@MainActor
struct MeshSessionModelTests {
    private func makeModel(store: InMemoryMeshIdentityStore = InMemoryMeshIdentityStore(),
                           server: FakeMeshServer) -> MeshSessionModel {
        MeshSessionModel(identityStore: store,
                         makeClient: { _ in server },
                         makeSignaling: { _, _, _ in nil })
    }

    @Test("First run without a Keychain identity asks to create one")
    func firstRunNeedsIdentity() async {
        let model = makeModel(server: FakeMeshServer())
        await model.start()
        #expect(model.phase == .needsIdentity)
        #expect(model.meshID == nil)
    }

    @Test("Creating an identity registers it and persists identity + Mesh ID")
    func createIdentityRegisters() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        let model = makeModel(store: store, server: server)
        await model.start()
        await model.createIdentity(name: "Test Mac", invite: "INVITE-1")
        #expect(model.phase == .ready)
        #expect(model.meshID == FakeMeshServer.assignedID)
        #expect(server.registerCalls == 1)
        #expect(server.lastInvite == "INVITE-1")
        #expect(server.lastName == "Test Mac")
        #expect(try store.loadIdentity() != nil)
        #expect(try store.loadMeshID() == FakeMeshServer.assignedID)
    }

    @Test("A registration failure keeps the local identity and reports offline")
    func createIdentityOffline() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        server.registerError = .inviteRequired
        let model = makeModel(store: store, server: server)
        await model.createIdentity(name: "Test Mac", invite: "")
        guard case .offline = model.phase else {
            Issue.record("expected offline phase, got \(model.phase)")
            return
        }
        #expect(try store.loadIdentity() != nil)
    }

    @Test("Start with a stored identity re-registers and becomes ready")
    func startWithStoredIdentity() async throws {
        let store = InMemoryMeshIdentityStore()
        try store.saveIdentity(MeshIdentity())
        let server = FakeMeshServer()
        let model = makeModel(store: store, server: server)
        await model.start()
        #expect(model.phase == .ready)
        #expect(model.meshID == FakeMeshServer.assignedID)
    }

    @Test("Connect validates the Mesh ID before touching the network")
    func connectValidatesInput() async {
        let server = FakeMeshServer()
        let model = makeModel(server: server)
        await model.createIdentity(name: "Test Mac", invite: "")
        await model.connect(toRawID: "12345")
        #expect(model.errorMessage != nil)
        #expect(server.pairRequestCalls == 0)
        await model.connect(toRawID: FakeMeshServer.assignedID.rawValue)
        #expect(model.errorMessage != nil)
        #expect(server.pairRequestCalls == 0)
    }

    @Test("Connect sends a pairing request and reports the wait")
    func connectSendsRequest() async {
        let server = FakeMeshServer()
        let model = makeModel(server: server)
        await model.createIdentity(name: "Test Mac", invite: "")
        await model.connect(toRawID: "111 222 333")
        #expect(server.pairRequestCalls == 1)
        #expect(server.lastPairPeer == MeshID(unchecked: "111222333"))
        #expect(model.statusMessage != nil)
        #expect(model.errorMessage == nil)
    }

    @Test("Connect to an already-paired device refreshes the paired list")
    func connectAlreadyPaired() async throws {
        let server = FakeMeshServer()
        let peer = MeshID(unchecked: "111222333")
        server.pairResult = .alreadyPaired
        server.paired = [peer]
        // The fake cannot fabricate a core `Presence` (no public
        // initializer), so presence lookup fails and the row keeps
        // an unknown presence — the model must tolerate that.
        let model = makeModel(server: server)
        await model.createIdentity(name: "Test Mac", invite: "")
        await model.connect(toRawID: peer.rawValue)
        #expect(model.pairedDevices.map(\.id) == [peer])
    }

    @Test("Approve and reject drain the pending list; approve pairs the device")
    func approveAndReject() async {
        let server = FakeMeshServer()
        let first = MeshID(unchecked: "111222333")
        let second = MeshID(unchecked: "444555666")
        server.pending = [first, second]
        let model = makeModel(server: server)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(model.pendingRequests == [first, second])
        await model.approve(first)
        #expect(server.approvedPeers == [first])
        #expect(model.pendingRequests == [second])
        #expect(model.pairedDevices.map(\.id) == [first])
        await model.reject(second)
        #expect(server.rejectedPeers == [second])
        #expect(model.pendingRequests.isEmpty)
    }
}

/// In-memory `MeshServerAPI` double: no network, no signaling.
private final class FakeMeshServer: MeshServerAPI, @unchecked Sendable {
    static let assignedID = MeshID(unchecked: "482913705")

    private let lock = NSLock()
    var registerError: MeshError?
    var registerCalls = 0
    var lastInvite: String?
    var lastName: String?
    var pairResult: PairingRequestResult = .requested
    var pairRequestCalls = 0
    var lastPairPeer: MeshID?
    var pending: [MeshID] = []
    var paired: [MeshID] = []
    var approvedPeers: [MeshID] = []
    var rejectedPeers: [MeshID] = []

    func register(identity: MeshIdentity, name: String, invite: String) async throws -> MeshID {
        try lock.withLock {
            registerCalls += 1
            lastInvite = invite
            lastName = name
            if let registerError { throw registerError }
            return Self.assignedID
        }
    }

    func requestPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws -> PairingRequestResult {
        lock.withLock {
            pairRequestCalls += 1
            lastPairPeer = peer
            if pairResult == .alreadyPaired && !paired.contains(peer) { paired.append(peer) }
            return pairResult
        }
    }

    func listPendingPairings(identity: MeshIdentity, meshID: MeshID) async throws -> [MeshID] {
        lock.withLock { pending }
    }

    func approvePairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws {
        lock.withLock {
            approvedPeers.append(peer)
            pending.removeAll { $0 == peer }
            if !paired.contains(peer) { paired.append(peer) }
        }
    }

    func rejectPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws {
        lock.withLock {
            rejectedPeers.append(peer)
            pending.removeAll { $0 == peer }
        }
    }

    func listPairedDevices() async -> [MeshID] {
        lock.withLock { paired }
    }

    func presence(of meshID: MeshID) async throws -> Presence {
        // `Presence` has no public initializer in MeshClient, so a fake
        // cannot fabricate one; throwing exercises the model's
        // tolerance for a failed presence lookup instead.
        throw MeshError.transport("fake has no presence")
    }
}
