import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A record of the devices this device is paired with.
///
/// Why this exists: the Phase-1 server API deliberately exposes **no
/// "list my pairing grants" endpoint** (see `internal/mesh/server.go` —
/// only request/list-pending/approve/reject exist; the grant table is
/// consulted internally by the signaling relay). A client can therefore
/// only *learn* pairings from its own successful operations:
/// approving a request, a `requestPairing` that comes back
/// `.alreadyPaired`, or a signal envelope that could only have arrived
/// through the grant-gated relay. This record persists those learned
/// pairings locally. It is a cache of observations, not a server truth.
public protocol PairingRecord: Sendable {
    func pairedDevices() -> [MeshID]
    func notePaired(_ peer: MeshID)
}

/// JSON-file-backed pairing record (`paired-peers.json` in a directory).
public final class FilePairingRecord: PairingRecord, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var peers: Set<String>

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("paired-peers.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.peers = Set(decoded)
        } else {
            self.peers = []
        }
    }

    public func pairedDevices() -> [MeshID] {
        lock.lock(); defer { lock.unlock() }
        return peers.sorted().map { MeshID(unchecked: $0) }
    }

    public func notePaired(_ peer: MeshID) {
        lock.lock(); defer { lock.unlock() }
        guard !peers.contains(peer.rawValue) else { return }
        peers.insert(peer.rawValue)
        if let data = try? JSONEncoder().encode(peers.sorted()) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// In-memory pairing record for tests.
public final class InMemoryPairingRecord: PairingRecord, @unchecked Sendable {
    private var peers: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public func pairedDevices() -> [MeshID] {
        lock.lock(); defer { lock.unlock() }
        return peers.sorted().map { MeshID(unchecked: $0) }
    }

    public func notePaired(_ peer: MeshID) {
        lock.lock(); defer { lock.unlock() }
        peers.insert(peer.rawValue)
    }
}

/// Result of `POST /pair/request`.
public enum PairingRequestResult: String, Sendable {
    case requested
    case alreadyPaired = "already_paired"
}

/// A device's presence as reported by `GET /presence/{mesh_id}`.
/// `lastSeen` is Unix seconds; 0 means the server has not seen the
/// device on a signaling connection since it started.
public struct Presence: Equatable, Sendable {
    public let meshID: MeshID
    public let name: String
    public let online: Bool
    public let lastSeen: Int64
}

/// Async REST client for the mesh server's control plane.
///
/// Authentication follows the server exactly: every signed call first
/// fetches a fresh single-use nonce from `POST /nonce` and signs the
/// nonce string with the device key. This client is an actor so its
/// own calls can never race each other's nonces (the server keeps a
/// single outstanding nonce per device).
public actor MeshServerClient {
    public let baseURL: URL
    private let session: URLSession
    private let pairingRecord: PairingRecord?

    public init(baseURL: URL, session: URLSession = .shared, pairingRecord: PairingRecord? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.pairingRecord = pairingRecord
    }

    // MARK: Wire shapes (field names match server.go exactly)

    private struct RegisterRequest: Encodable {
        let pubkey: String
        let name: String
        let invite: String
    }

    private struct RegisterResponse: Decodable {
        let mesh_id: MeshID
    }

    private struct NonceRequest: Encodable {
        let mesh_id: String
    }

    private struct NonceResponse: Decodable {
        let nonce: String
    }

    private struct AuthedRequest: Encodable {
        let mesh_id: String
        let nonce: String
        let signature: String
        let peer: String?
    }

    private struct StatusResponse: Decodable {
        let status: String
    }

    private struct PendingResponse: Decodable {
        let pending: [String]
    }

    private struct PresenceResponse: Decodable {
        let mesh_id: MeshID
        let name: String
        let online: Bool
        let last_seen: Int64
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    // MARK: Transport + error mapping

    /// Maps a server error response to a typed `MeshError`. Internal so
    /// tests can pin the mapping against recorded payloads.
    static func mapError(status: Int, data: Data) -> MeshError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            ?? String(decoding: data, as: UTF8.self)
        switch (status, message) {
        case (400, "pubkey must be a base64 Ed25519 public key"): return .invalidPublicKey
        case (400, "name is required"): return .nameRequired
        case (403, "a valid invite code is required"): return .inviteRequired
        case (404, "unknown device"): return .unknownDevice
        case (401, "authentication failed"): return .authenticationFailed
        case (400, "peer must be another device's Mesh ID"): return .invalidPeer
        case (404, "unknown peer"): return .unknownPeer
        case (404, "no pending request from that peer"): return .noPendingRequest
        case (400, "invalid JSON body"): return .invalidRequestBody
        default: return .server(status: status, message: message)
        }
    }

    private func post<Response: Decodable>(_ path: String, body: some Encodable) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw MeshError.decoding("encoding request for \(path): \(error)")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MeshError.transport("\(path): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MeshError.transport("\(path): non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Self.mapError(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MeshError.decoding("\(path) response: \(error)")
        }
    }

    /// Fetches a fresh nonce and builds a signed request body.
    private func authedBody(identity: MeshIdentity, meshID: MeshID, peer: MeshID?) async throws -> AuthedRequest {
        let nonceResponse: NonceResponse = try await post(
            "nonce", body: NonceRequest(mesh_id: meshID.rawValue))
        return AuthedRequest(
            mesh_id: meshID.rawValue,
            nonce: nonceResponse.nonce,
            signature: try identity.signatureBase64(forNonce: nonceResponse.nonce),
            peer: peer?.rawValue)
    }

    // MARK: Public API

    /// `GET /healthz` — true when the server answers `{"status":"ok"}`.
    public func health() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok"
        else { return false }
        return true
    }

    /// `POST /register` — registers the identity's public key and
    /// returns the assigned Mesh ID. Re-registering a known key is
    /// idempotent on the server and needs no invite (pass "").
    @discardableResult
    public func register(identity: MeshIdentity, name: String, invite: String) async throws -> MeshID {
        let response: RegisterResponse = try await post(
            "register",
            body: RegisterRequest(pubkey: identity.publicKeyBase64, name: name, invite: invite))
        return response.mesh_id
    }

    /// `POST /pair/request` — asks `peer` to pair with this device.
    @discardableResult
    public func requestPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws -> PairingRequestResult {
        let body = try await authedBody(identity: identity, meshID: meshID, peer: peer)
        let response: StatusResponse = try await post("pair/request", body: body)
        guard let result = PairingRequestResult(rawValue: response.status) else {
            throw MeshError.decoding("pair/request: unexpected status \(response.status)")
        }
        if result == .alreadyPaired {
            pairingRecord?.notePaired(peer)
        }
        return result
    }

    /// `POST /pair/list` — Mesh IDs with a pending inbound pairing
    /// request for this device.
    public func listPendingPairings(identity: MeshIdentity, meshID: MeshID) async throws -> [MeshID] {
        let body = try await authedBody(identity: identity, meshID: meshID, peer: nil)
        let response: PendingResponse = try await post("pair/list", body: body)
        return response.pending.map { MeshID(unchecked: $0) }
    }

    /// `POST /pair/approve` — approves `peer`'s pending request,
    /// creating the pairing grant that authorizes signaling.
    public func approvePairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws {
        let body = try await authedBody(identity: identity, meshID: meshID, peer: peer)
        let response: StatusResponse = try await post("pair/approve", body: body)
        guard response.status == "paired" else {
            throw MeshError.decoding("pair/approve: unexpected status \(response.status)")
        }
        pairingRecord?.notePaired(peer)
    }

    /// `POST /pair/reject` — drops `peer`'s pending request.
    public func rejectPairing(identity: MeshIdentity, meshID: MeshID, peer: MeshID) async throws {
        let body = try await authedBody(identity: identity, meshID: meshID, peer: peer)
        let response: StatusResponse = try await post("pair/reject", body: body)
        guard response.status == "rejected" else {
            throw MeshError.decoding("pair/reject: unexpected status \(response.status)")
        }
    }

    /// Devices this client has learned it is paired with, from its
    /// local `PairingRecord`. The server exposes no equivalent query —
    /// see the note on `PairingRecord`.
    public func listPairedDevices() -> [MeshID] {
        pairingRecord?.pairedDevices() ?? []
    }

    /// `GET /presence/{mesh_id}` — unauthenticated presence lookup.
    public func presence(of meshID: MeshID) async throws -> Presence {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path ?? ""
        components?.path = basePath + "/presence/" + meshID.rawValue
        guard let url = components?.url else {
            throw MeshError.transport("cannot build presence URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MeshError.transport("presence: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MeshError.transport("presence: non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Self.mapError(status: http.statusCode, data: data)
        }
        do {
            let decoded = try JSONDecoder().decode(PresenceResponse.self, from: data)
            return Presence(meshID: decoded.mesh_id, name: decoded.name,
                            online: decoded.online, lastSeen: decoded.last_seen)
        } catch {
            throw MeshError.decoding("presence response: \(error)")
        }
    }
}
