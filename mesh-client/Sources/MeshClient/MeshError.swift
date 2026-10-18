import Foundation

/// Typed errors for the mesh control plane.
///
/// Two families, matching how the server actually reports failures:
///
/// - REST endpoints return `{"error": "<message>"}` with an HTTP status;
///   `MeshServerClient` maps each (status, message) pair the server can
///   produce to a case below. Anything unrecognized lands in
///   `.server(status:message:)` with the raw values preserved.
/// - The signaling WebSocket returns `{type:"error", code:"..."}`;
///   those codes map to the dedicated cases (`.notPaired`, `.peerOffline`,
///   ...) via `init(signalingCode:)`.
public enum MeshError: Error, Equatable, Sendable {
    // MARK: Local validation
    case invalidMeshID(String)
    case invalidPublicKeyData
    case identityStoreFailure(String)

    // MARK: REST errors (server.go writeErr call sites)
    /// 403 on /register: "a valid invite code is required"
    case inviteRequired
    /// 400 on /register: "pubkey must be a base64 Ed25519 public key"
    case invalidPublicKey
    /// 400 on /register: "name is required"
    case nameRequired
    /// 404: "unknown device" (/nonce, /presence)
    case unknownDevice
    /// 401 on any signed endpoint: "authentication failed"
    case authenticationFailed
    /// 400 on /pair/request: "peer must be another device's Mesh ID"
    case invalidPeer
    /// 404 on /pair/request: "unknown peer"
    case unknownPeer
    /// 404 on /pair/approve: "no pending request from that peer"
    case noPendingRequest
    /// 400: "invalid JSON body" (the server could not decode our request)
    case invalidRequestBody
    /// Any other server error response, preserved verbatim.
    case server(status: Int, message: String)

    // MARK: Signaling (WebSocket) error codes
    /// Server expected an auth hello as the first frame.
    case expectedAuth
    /// Server expected the signature frame during the handshake.
    case expectedSignature
    /// Handshake signature did not verify.
    case badSignature
    /// Signal target is not paired with us (no grant) — relay refused.
    case notPaired
    /// Paired peer holds no live signaling connection within the lease.
    case peerOffline
    /// Signal envelope had an empty or self recipient.
    case badRecipient
    /// Server did not recognize the envelope `type`.
    case unknownEnvelopeType
    /// Server-side internal error while forwarding.
    case signalingInternal
    /// A signaling error code this client version does not know.
    case unrecognizedSignalingCode(String)

    // MARK: Transport / protocol
    case transport(String)
    case connectionClosed
    case protocolViolation(String)
    case decoding(String)

    /// Maps a WebSocket `{type:"error", code}` value to a typed case.
    public init(signalingCode code: String) {
        switch code {
        case "expected_auth": self = .expectedAuth
        case "expected_signature": self = .expectedSignature
        case "bad_signature": self = .badSignature
        case "unknown_device": self = .unknownDevice
        case "not_paired": self = .notPaired
        case "peer_offline": self = .peerOffline
        case "bad_recipient": self = .badRecipient
        case "unknown_type": self = .unknownEnvelopeType
        case "internal": self = .signalingInternal
        default: self = .unrecognizedSignalingCode(code)
        }
    }
}

extension MeshError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidMeshID(let s): return "invalid Mesh ID: \(s)"
        case .invalidPublicKeyData: return "invalid public key data"
        case .identityStoreFailure(let m): return "identity store failure: \(m)"
        case .inviteRequired: return "a valid invite code is required"
        case .invalidPublicKey: return "pubkey must be a base64 Ed25519 public key"
        case .nameRequired: return "name is required"
        case .unknownDevice: return "unknown device"
        case .authenticationFailed: return "authentication failed"
        case .invalidPeer: return "peer must be another device's Mesh ID"
        case .unknownPeer: return "unknown peer"
        case .noPendingRequest: return "no pending request from that peer"
        case .invalidRequestBody: return "invalid JSON body"
        case .server(let status, let message): return "server error \(status): \(message)"
        case .expectedAuth: return "server expected an auth hello"
        case .expectedSignature: return "server expected a signature"
        case .badSignature: return "bad signature"
        case .notPaired: return "not paired with that device"
        case .peerOffline: return "peer is offline"
        case .badRecipient: return "bad signal recipient"
        case .unknownEnvelopeType: return "unknown envelope type"
        case .signalingInternal: return "signaling server internal error"
        case .unrecognizedSignalingCode(let c): return "unrecognized signaling error code: \(c)"
        case .transport(let m): return "transport error: \(m)"
        case .connectionClosed: return "connection closed"
        case .protocolViolation(let m): return "protocol violation: \(m)"
        case .decoding(let m): return "decoding error: \(m)"
        }
    }
}
