import Foundation
import MeshClient
import Testing
@testable import MacViewer

@MainActor
struct MeshSessionModelTests {
    private func makeModel(store: InMemoryMeshIdentityStore = InMemoryMeshIdentityStore(),
                           server: FakeMeshServer,
                           serverTarget: (@Sendable () -> (url: URL, isCustom: Bool))? = nil,
                           resetServerOverride: (@Sendable () -> Void)? = nil) -> MeshSessionModel {
        MeshSessionModel(identityStore: store,
                         makeClient: { _ in server },
                         makeSignaling: { _, _, _ in nil },
                         serverTarget: serverTarget,
                         resetServerOverride: resetServerOverride)
    }

    private static let defaultTarget: @Sendable () -> (url: URL, isCustom: Bool) = {
        (MeshDefaults.serverURL, false)
    }
    private static let customTarget: @Sendable () -> (url: URL, isCustom: Bool) = {
        (URL(string: "http://vega.lan:8734")!, true)
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
        // Pinned to a custom server: under decision D2 the default
        // server never receives an invite from the client, so the
        // invite-passthrough this test pins lives on the custom path.
        let model = makeModel(store: store, server: server, serverTarget: Self.customTarget)
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

    // MARK: Server foundation (redesign Part 1)

    @Test("Default server down: no blind registration, local identity and Mesh ID stay, honest state, no error")
    func defaultServerNotAvailable() async throws {
        let store = InMemoryMeshIdentityStore()
        try store.saveIdentity(MeshIdentity())
        try store.saveMeshID(FakeMeshServer.assignedID)
        let server = FakeMeshServer()
        server.healthResult = false
        let model = makeModel(store: store, server: server, serverTarget: Self.defaultTarget)
        await model.start()
        #expect(model.phase == .serverUnavailable)
        #expect(model.serverAvailability == .defaultNotAvailable)
        #expect(server.healthCalls == 1)
        #expect(server.registerCalls == 0)
        #expect(model.meshID == FakeMeshServer.assignedID)
        #expect(model.errorMessage == nil)
        #expect(try store.loadIdentity() != nil)
    }

    @Test("Creating an identity while the default server is down still creates it locally")
    func createIdentityWhileDefaultDown() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        server.healthResult = false
        let model = makeModel(store: store, server: server, serverTarget: Self.defaultTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(try store.loadIdentity() != nil)
        #expect(model.phase == .serverUnavailable)
        #expect(model.serverAvailability == .defaultNotAvailable)
        #expect(server.registerCalls == 0)
    }

    @Test("Registration against the default server never sends an invite (decision D2)")
    func defaultServerGetsNoInvite() async {
        let server = FakeMeshServer()
        let model = makeModel(server: server, serverTarget: Self.defaultTarget)
        await model.createIdentity(name: "Test Mac", invite: "MUST-NOT-BE-SENT")
        #expect(model.phase == .ready)
        #expect(server.lastInvite == "")
    }

    @Test("A custom server that refuses registration for an invite reports inviteRequired")
    func customServerInviteRequired() async {
        let server = FakeMeshServer()
        server.registerError = .inviteRequired
        let model = makeModel(server: server, serverTarget: Self.customTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(model.serverAvailability == .inviteRequired)
        #expect(server.healthCalls == 0)
        guard case .offline = model.phase else {
            Issue.record("expected offline phase, got \(model.phase)")
            return
        }
    }

    @Test("A custom server consumes the pending invite saved by the personal-server frame, once")
    func customServerConsumesPendingInvite() async {
        UserDefaults.standard.removeObject(forKey: MeshDefaults.pendingInviteKey)
        defer { UserDefaults.standard.removeObject(forKey: MeshDefaults.pendingInviteKey) }
        UserDefaults.standard.set("PEND-1", forKey: MeshDefaults.pendingInviteKey)
        let server = FakeMeshServer()
        let model = makeModel(server: server, serverTarget: Self.customTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(server.lastInvite == "PEND-1")
        #expect(UserDefaults.standard.string(forKey: MeshDefaults.pendingInviteKey) == nil)
    }

    @Test("Default server healthy but registration fails on transport: unreachable, offline phase")
    func defaultHealthyButRegisterFails() async {
        let server = FakeMeshServer()
        server.registerError = .transport("connection reset")
        let model = makeModel(server: server, serverTarget: Self.defaultTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(server.healthCalls == 1)
        #expect(server.registerCalls == 1)
        #expect(model.serverAvailability == .unreachable)
        guard case .offline = model.phase else {
            Issue.record("expected offline phase, got \(model.phase)")
            return
        }
    }

    @Test("Switching servers mid-state: refresh after the switch re-registers against the new target")
    func switchServerMidState() async throws {
        let store = InMemoryMeshIdentityStore()
        try store.saveIdentity(MeshIdentity())
        let server = FakeMeshServer()
        server.healthResult = false
        let box = TargetBox(target: (MeshDefaults.serverURL, false))
        let model = makeModel(store: store, server: server, serverTarget: { box.target })
        await model.start()
        #expect(model.phase == .serverUnavailable)
        #expect(server.registerCalls == 0)
        // The user saves a working custom server in Settings; the
        // same model instance refreshes against the new target.
        box.target = (URL(string: "http://vega.lan:8734")!, true)
        server.healthResult = true
        await model.refresh()
        #expect(model.phase == .ready)
        #expect(model.serverAvailability == .online)
        #expect(server.registerCalls == 1)
        #expect(model.meshID == FakeMeshServer.assignedID)
    }

    // MARK: Part 3 — first-run branches, invite sheet, in-place switch

    @Test("First run with no network: identity is created locally and the phase is offline")
    func firstRunNoNetworkKeepsLocalIdentity() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        server.registerError = .transport("no route to host")
        let model = makeModel(store: store, server: server, serverTarget: Self.customTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(try store.loadIdentity() != nil)
        #expect(model.meshID == nil)
        #expect(model.serverAvailability == .unreachable)
        guard case .offline = model.phase else {
            Issue.record("expected offline phase, got \(model.phase)")
            return
        }
    }

    @Test("Invite sheet: presenting twice keeps the half-typed code")
    func inviteSheetPresentIsIdempotent() async {
        let sheet = MeshInviteSheetModel()
        sheet.present()
        sheet.code = "ABCDE"
        #expect(sheet.code == "ABCD-E")
        sheet.present()
        #expect(sheet.isPresented)
        #expect(sheet.code == "ABCD-E")
    }

    @Test("Invite sheet: an empty code cannot submit and never reaches the server")
    func inviteSheetEmptyCodeCannotSubmit() async {
        let server = FakeMeshServer()
        let model = makeModel(server: server, serverTarget: Self.customTarget)
        let sheet = MeshInviteSheetModel()
        sheet.present()
        #expect(!sheet.canSubmit)
        await sheet.submit(mesh: model)
        #expect(server.registerCalls == 0)
        #expect(sheet.isPresented)
    }

    @Test("Invite sheet: a refused code keeps the sheet open with the specific error and the code intact")
    func inviteSheetWrongCodeStaysOpen() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        server.registerError = .inviteRequired
        let model = makeModel(store: store, server: server, serverTarget: Self.customTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(model.serverAvailability == .inviteRequired)
        let sheet = MeshInviteSheetModel()
        sheet.present()
        sheet.code = "WRONG123"
        #expect(sheet.code == "WRON-G123")
        await sheet.submit(mesh: model)
        #expect(sheet.isPresented)
        #expect(sheet.errorMessage == "That invite code was not accepted. Check the code and try again.")
        #expect(sheet.code == "WRON-G123")
        #expect(model.meshID == nil)
        guard case .offline = model.phase else {
            Issue.record("expected offline phase, got \(model.phase)")
            return
        }
        // Editing the code clears the error for the next attempt.
        sheet.code = "NEWCODE1"
        #expect(sheet.errorMessage == nil)
    }

    @Test("Invite sheet: an accepted code closes the sheet and the model shows the Mesh ID")
    func inviteSheetSuccessClosesWithMeshID() async {
        let server = FakeMeshServer()
        server.registerError = .inviteRequired
        let model = makeModel(server: server, serverTarget: Self.customTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(model.meshID == nil)
        server.registerError = nil
        let sheet = MeshInviteSheetModel()
        sheet.present()
        sheet.code = "GOODCODE"
        await sheet.submit(mesh: model)
        #expect(server.lastInvite == "GOODCODE")
        #expect(!sheet.isPresented)
        #expect(sheet.code == "")
        #expect(sheet.errorMessage == nil)
        #expect(model.phase == .ready)
        #expect(model.meshID == FakeMeshServer.assignedID)
    }

    @Test("Invite sheet: cancel clears the code and the error")
    func inviteSheetCancelClears() async {
        let sheet = MeshInviteSheetModel()
        sheet.present()
        sheet.code = "ABCD"
        sheet.cancel()
        #expect(!sheet.isPresented)
        #expect(sheet.code == "")
        #expect(sheet.errorMessage == nil)
    }

    @Test("Use default server switches in place: override reset, re-registered, ready")
    func switchToDefaultServerInPlace() async throws {
        let store = InMemoryMeshIdentityStore()
        let server = FakeMeshServer()
        let box = TargetBox(target: (URL(string: "http://vega.lan:8734")!, true))
        let model = makeModel(store: store, server: server,
                              serverTarget: { box.target },
                              resetServerOverride: { box.target = (MeshDefaults.serverURL, false) })
        await model.createIdentity(name: "Test Mac", invite: "")
        #expect(model.isUsingCustomServer)
        let callsBefore = server.registerCalls
        await model.switchToDefaultServer()
        #expect(!model.isUsingCustomServer)
        #expect(server.registerCalls == callsBefore + 1)
        #expect(model.phase == .ready)
        #expect(model.serverAvailability == .online)
        #expect(model.meshID == FakeMeshServer.assignedID)
    }

    @Test("Use default server is a no-op when the default is already in use")
    func switchToDefaultServerNoOpOnDefault() async {
        let server = FakeMeshServer()
        let model = makeModel(server: server, serverTarget: Self.defaultTarget)
        await model.createIdentity(name: "Test Mac", invite: "")
        let callsBefore = server.registerCalls
        await model.switchToDefaultServer()
        #expect(server.registerCalls == callsBefore)
        #expect(model.phase == .ready)
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

/// Mutable server target for the mid-state switch test: the model's
/// target closure reads whatever the box currently holds, exactly
/// like the production closure reads the current MeshDefaults.
private final class TargetBox: @unchecked Sendable {
    var target: (url: URL, isCustom: Bool)
    init(target: (url: URL, isCustom: Bool)) { self.target = target }
}

/// In-memory `MeshServerAPI` double: no network, no signaling.
private final class FakeMeshServer: MeshServerAPI, @unchecked Sendable {
    static let assignedID = MeshID(unchecked: "482913705")

    private let lock = NSLock()
    var healthResult = true
    var healthCalls = 0
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

    func checkHealth() async -> Bool {
        lock.withLock {
            healthCalls += 1
            return healthResult
        }
    }

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
