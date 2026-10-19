import Combine
import Foundation
import MeshClient

/// App-layer seam over the mesh server's REST control plane. The core's
/// `MeshServerClient` is a concrete actor; the session model depends on
/// this protocol instead so unit tests can drive it with a fake. The
/// core package is untouched — conformance is declared here.
protocol MeshServerAPI: Sendable {
    func register(identity: MeshIdentity, name: String, invite: String) async throws -> MeshID
    func requestPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws -> PairingRequestResult
    func listPendingPairings(identity: MeshIdentity, meshID: MeshID) async throws -> [MeshID]
    func approvePairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws
    func rejectPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws
    func listPairedDevices() async -> [MeshID]
    func presence(of meshID: MeshID) async throws -> Presence
}

extension MeshServerClient: MeshServerAPI {}

/// Mode 2 (self-hosted mesh) state for the main window: this device's
/// identity and presence, incoming pairing requests, and the paired
/// list (UI spec §5.2). Wraps `MeshServerClient` for the control plane
/// and a `MeshSignalingClient` for presence — the server counts a
/// device as online only while its signaling connection is live.
///
/// Session negotiation lives in `MeshSessionController` (Phase 3,
/// chunk 2): once signaling is live the model builds one and publishes
/// it as `sessionController`; views and the session windows bind to
/// it. Media itself (WebRTC) is still milestone M1.
@MainActor
final class MeshSessionModel: ObservableObject {
    enum Phase: Equatable {
        /// No Keychain identity yet — first run in Mode 2 (spec §6.1).
        case needsIdentity
        case working
        /// Registered with the configured server; `meshID` is valid.
        case ready
        /// Identity exists locally but the server could not register
        /// us just now (unreachable, or an invite is required). The
        /// card stays usable and registration retries on refresh.
        case offline(String)
    }

    struct PairedDevice: Identifiable, Equatable {
        let id: MeshID
        var name: String?
        var online: Bool?
        var lastSeen: Int64?
    }

    @Published private(set) var phase: Phase = .working
    @Published private(set) var meshID: MeshID?
    /// True while the signaling connection is live (presence lease).
    @Published private(set) var isOnline = false
    @Published private(set) var pendingRequests: [MeshID] = []
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published var deviceName: String
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    /// The session-negotiation controller bound to the live signaling
    /// connection, if any. Rebuilt whenever signaling reconnects.
    @Published private(set) var sessionController: MeshSessionController?
    /// The Mode 2 chat center bound to the same signaling
    /// connection (Phase 3, chunk 3). Rebuilt with the controller.
    @Published private(set) var chatCenter: MeshChatCenter?
    private var chatForwardSink: AnyCancellable?
    /// The WebRTC media coordinator bound to the same signaling
    /// connection (M1 part 3b). Rebuilt with the controller.
    @Published private(set) var mediaCoordinator: MeshMediaCoordinator?
    private var mediaForwardSink: AnyCancellable?

    private let identityStore: any MeshIdentityStore
    private let makeClient: (URL) -> any MeshServerAPI
    private let makeSignaling: (URL, MeshIdentity, MeshID) -> MeshSignalingClient?
    private var identity: MeshIdentity?
    private var client: (url: URL, api: any MeshServerAPI)?
    private var signaling: MeshSignalingClient?

    init(identityStore: any MeshIdentityStore = KeychainMeshIdentityStore(),
         makeClient: ((URL) -> any MeshServerAPI)? = nil,
         makeSignaling: ((URL, MeshIdentity, MeshID) -> MeshSignalingClient?)? = nil) {
        self.identityStore = identityStore
        self.makeClient = makeClient ?? { url in
            MeshServerClient(baseURL: url, pairingRecord: FilePairingRecord(directory: Self.supportDirectory))
        }
        self.makeSignaling = makeSignaling ?? { url, identity, meshID in
            MeshSignalingClient(serverBaseURL: url, identity: identity, meshID: meshID)
        }
        self.deviceName = MeshDefaults.deviceName
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacViewer", isDirectory: true)
    }

    /// The server the next client build will use (Settings override wins).
    var serverURL: URL { MeshDefaults.currentServerURL }
    var isUsingCustomServer: Bool { MeshDefaults.isUsingCustomServer }

    // MARK: Lifecycle

    /// Loads the stored identity, if any. With an identity, registers
    /// (idempotently) and connects signaling; without one, the first-run
    /// surface takes over. Safe to call on every Mode 2 appearance.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            identity = try identityStore.loadIdentity()
            meshID = try identityStore.loadMeshID()
        } catch {
            phase = .offline(String(describing: error))
            return
        }
        guard identity != nil else {
            phase = .needsIdentity
            return
        }
        await registerAndRefresh(invite: "")
    }

    /// First run (spec §6.1): creates the keypair locally, then
    /// registers. A network failure never blocks creation — the
    /// identity exists and registration retries on the next refresh.
    func createIdentity(name: String, invite: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { rename(to: trimmed) }
        do {
            identity = try MeshIdentity.loadOrCreate(using: identityStore)
        } catch {
            errorMessage = String(describing: error)
            phase = .needsIdentity
            return
        }
        await registerAndRefresh(invite: invite.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Re-registers (refreshing our name and Mesh ID), reconnects
    /// signaling if needed, and reloads the lists.
    func refresh() async {
        guard identity != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await registerAndRefresh(invite: "")
    }

    /// Reloads pending requests and the paired list (with presence)
    /// without re-registering. Called periodically while Mode 2 shows.
    func refreshLists() async {
        guard let identity, let meshID, phase == .ready else { return }
        let api = clientForCurrentServer()
        do {
            pendingRequests = try await api.listPendingPairings(identity: identity, meshID: meshID)
        } catch {
            // A list failure is transient; keep the last known state.
        }
        let paired = await api.listPairedDevices()
        var devices: [PairedDevice] = []
        for peer in paired {
            var device = PairedDevice(id: peer)
            if let presence = try? await api.presence(of: peer) {
                device.name = presence.name
                device.online = presence.online
                device.lastSeen = presence.lastSeen
            }
            devices.append(device)
        }
        pairedDevices = devices
        if let chatCenter {
            for device in devices {
                chatCenter.updatePresence(peer: device.id,
                                          online: device.online == true,
                                          name: device.name)
            }
        }
    }

    /// Tears down presence. The identity and pairings persist.
    func stop() async {
        mediaCoordinator?.unbind()
        mediaCoordinator = nil
        mediaForwardSink = nil
        chatCenter?.disconnect()
        chatCenter = nil
        chatForwardSink = nil
        sessionController?.stop()
        sessionController = nil
        await signaling?.close()
        signaling = nil
        isOnline = false
    }

    /// Called after the Settings server address changes: presence and
    /// registration belong to the server in use (spec §6.4), so the
    /// old connection drops and the next refresh re-registers.
    func serverChanged() async {
        await stop()
        client = nil
        if identity != nil { await refresh() }
    }

    // MARK: Pairing actions

    /// The Mode 2 connect-by-ID action (spec §5.2/§6.3): sends a
    /// pairing request to the entered Mesh ID. Sessions to devices
    /// that are already paired start from their Paired-list row.
    func connect(toRawID raw: String) async {
        guard let identity, let meshID, phase == .ready else { return }
        errorMessage = nil
        statusMessage = nil
        let digits = raw.filter { !$0.isWhitespace }
        guard let peer = try? MeshID(validating: digits) else {
            errorMessage = L("Enter a valid 9-digit Mesh ID.")
            return
        }
        guard peer != meshID else {
            errorMessage = L("That is this device's own Mesh ID.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await clientForCurrentServer()
                .requestPairing(identity: identity, meshID: meshID, peer: peer)
            switch result {
            case .requested:
                statusMessage = L("Pairing request sent. Waiting for the other device to approve.")
            case .alreadyPaired:
                statusMessage = L("Already paired with this device.")
                await refreshLists()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func approve(_ peer: MeshID) async {
        guard let identity, let meshID else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await clientForCurrentServer().approvePairing(identity: identity, meshID: meshID, peer: peer)
            pendingRequests.removeAll { $0 == peer }
            statusMessage = L("Pairing approved.")
            await refreshLists()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reject(_ peer: MeshID) async {
        guard let identity, let meshID else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await clientForCurrentServer().rejectPairing(identity: identity, meshID: meshID, peer: peer)
            pendingRequests.removeAll { $0 == peer }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Device name

    /// Persists the display name. It reaches the server on the next
    /// registration (refresh), which is also what peers see.
    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        UserDefaults.standard.set(trimmed, forKey: MeshDefaults.deviceNameKey)
    }

    func saveDeviceNameAndRefresh() async {
        rename(to: deviceName)
        await refresh()
    }

    // MARK: Internals

    private func clientForCurrentServer() -> any MeshServerAPI {
        let url = MeshDefaults.currentServerURL
        if let client, client.url == url { return client.api }
        let api = makeClient(url)
        client = (url, api)
        return api
    }

    private func registerAndRefresh(invite: String) async {
        guard let identity else { return }
        phase = .working
        errorMessage = nil
        let api = clientForCurrentServer()
        do {
            let assigned = try await api.register(identity: identity, name: deviceName, invite: invite)
            if assigned != meshID {
                meshID = assigned
                try? identityStore.saveMeshID(assigned)
            }
            phase = .ready
        } catch {
            phase = .offline(String(describing: error))
            return
        }
        await connectSignalingIfNeeded()
        await refreshLists()
    }

    private func connectSignalingIfNeeded() async {
        guard let identity, let meshID else { return }
        if let signaling, signaling.meshID == meshID, signaling.isConnected {
            isOnline = true
            return
        }
        mediaCoordinator?.unbind()
        mediaCoordinator = nil
        mediaForwardSink = nil
        chatCenter?.disconnect()
        chatCenter = nil
        chatForwardSink = nil
        sessionController?.stop()
        sessionController = nil
        await signaling?.close()
        signaling = nil
        isOnline = false
        guard let fresh = makeSignaling(serverURL, identity, meshID) else { return }
        do {
            try await fresh.connect()
            signaling = fresh
            isOnline = fresh.isConnected
            if fresh.isConnected {
                // Negotiation and chat ride the same connection: the
                // controller consumes its signal stream from here on
                // and fans chat traffic out to the chat center.
                let isPaired: @MainActor (MeshID) -> Bool = { [weak self] peer in
                    self?.pairedDevices.contains { $0.id == peer } ?? false
                }
                let controller = MeshSessionController(
                    signaling: fresh,
                    isPaired: isPaired,
                    localName: { [weak self] in self?.deviceName ?? "Mac" })
                let center = MeshChatCenter(
                    signaling: fresh,
                    isPaired: isPaired,
                    localName: { [weak self] in self?.deviceName ?? "Mac" },
                    historyDirectory: Self.supportDirectory
                        .appendingPathComponent("chat", isDirectory: true))
                let coordinator = MeshMediaCoordinator(
                    localID: meshID,
                    makePeerSession: MeshMediaCoordinator.realPeerSessionFactory(
                        signaling: fresh, localID: meshID),
                    makeApplier: MeshMediaCoordinator.realApplierFactory)
                // One fan-out, three planes: the controller has
                // already claimed session traffic; what remains
                // is offered to BOTH the media coordinator and
                // the chat center. Each applies its own codec /
                // router, so the planes cannot starve each other
                // (the media router provably ignores app-plane
                // payloads, the chat codec requires its marker).
                controller.onUnhandledSignal = { [weak center, weak coordinator] envelope in
                    coordinator?.routeInbound(envelope)
                    center?.handle(envelope)
                }
                controller.onServerError = { [weak center] error in
                    center?.handleServerError(error)
                }
                sessionController = controller
                chatCenter = center
                mediaCoordinator = coordinator
                // Views observe this model, not the center: forward
                // its changes (unread badges, transcripts) upward.
                chatForwardSink = center.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.objectWillChange.send() }
                }
                mediaForwardSink = coordinator.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.objectWillChange.send() }
                }
                coordinator.bind(to: controller)
                controller.start()
            }
        } catch {
            // Presence stays offline; the REST control plane still
            // works and the next refresh retries the connection.
            signaling = nil
            isOnline = false
        }
    }
}
