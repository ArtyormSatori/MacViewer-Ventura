import Foundation
import MeshClient

/// App-layer seam over the mesh signaling channel (Phase 3, chunk 2).
/// The core's `MeshSignalingClient` is a concrete class; the session
/// controller depends on this protocol instead so unit tests can drive
/// it with a fake — the same pattern chunk 1 used for `MeshServerAPI`.
/// The core package is untouched; conformance is declared here.
protocol MeshSignalingAPI: Sendable {
    var isConnected: Bool { get }
    /// Signals forwarded from paired peers.
    var signals: AsyncStream<SignalEnvelope> { get }
    /// Server-side refusals of our sends (e.g. peer offline).
    var serverErrors: AsyncStream<MeshError> { get }
    /// The same refusals with the server's correlation echo
    /// (core-fixes part): a refusal whose envelope carried an
    /// app-plane marker arrives with `ref` set, so the consumer
    /// can attribute it to the exact send. Test doubles use the
    /// default (a stream that never yields); the real
    /// `MeshSignalingClient` provides the live stream.
    var serverRefusals: AsyncStream<SignalingRefusal> { get }
    func sendSignal(to peer: MeshID, kind: SignalKind, data: JSONValue) async throws
}

extension MeshSignalingAPI {
    var serverRefusals: AsyncStream<SignalingRefusal> {
        AsyncStream { $0.finish() }
    }
}

extension MeshSignalingClient: MeshSignalingAPI {}

/// A capability a viewer asks for in a session request. The pairing
/// grant already decided *whether* two devices may talk; a session
/// request decides *what* this session may do.
enum MeshSessionCapability: String, Equatable, Hashable, Sendable {
    case view
    case control
}

/// One app-layer session-negotiation message (Phase 3, chunk 2):
/// session-request / session-accept / session-reject / session-end
/// between paired devices, carried as a signaling payload.
///
/// WIRE CONVENTION (app layer, core untouched): the core's
/// `SignalKind` is a closed enum (offer/answer/ice) with no generic
/// control kind, so session messages ride on kind `.offer` with
/// `data` = an object holding a single `mvSession` key. Media
/// signaling (M1) uses the same kinds with `data` = an SDP *string*
/// (offer/answer) or a candidate object without this key, so the two
/// planes can never be confused: `init?(data:)` returns nil for
/// anything that is not a session message.
struct MeshSessionMessage: Equatable, Sendable {
    enum Kind: String, Sendable {
        case request = "session-request"
        case accept = "session-accept"
        case reject = "session-reject"
        case end = "session-end"
    }

    /// Why a request was refused or a session/attempt ended. Sent on
    /// reject and end messages; absent on request and accept.
    enum Reason: String, Sendable {
        case rejected
        case busy
        case timeout
        case cancelled
        case ended
    }

    var kind: Kind
    /// Correlates every message of one negotiation. Minted by the
    /// requester; echoed by the host and by both sides on end.
    var sessionID: String
    /// Request only: the requester's display name, for the consent
    /// prompt (the server does not put names in forwarded signals).
    var fromName: String?
    /// Request: asked for. Accept: granted (may be a subset).
    var capabilities: Set<MeshSessionCapability>
    var reason: Reason?

    /// The signaling kind every session message is sent with.
    static let transportKind: SignalKind = .offer
    /// The marker key inside the signaling `data` object.
    static let markerKey = "mvSession"

    /// The `data` payload for `MeshSignalingAPI.sendSignal`.
    var signalingData: JSONValue {
        var fields: [String: JSONValue] = [
            "v": .number(1),
            "type": .string(kind.rawValue),
            "sessionID": .string(sessionID),
            "capabilities": .array(capabilities.map(\.rawValue).sorted().map(JSONValue.string)),
        ]
        if let fromName { fields["fromName"] = .string(fromName) }
        if let reason { fields["reason"] = .string(reason.rawValue) }
        return .object([Self.markerKey: .object(fields)])
    }

    /// Decodes a session message from a signaling `data` payload.
    /// Returns nil for media signaling and anything malformed.
    init?(data: JSONValue) {
        guard case let .object(top) = data,
              case let .object(fields)? = top[Self.markerKey],
              case let .string(typeRaw)? = fields["type"],
              let kind = Kind(rawValue: typeRaw),
              case let .string(sessionID)? = fields["sessionID"],
              !sessionID.isEmpty
        else { return nil }
        self.kind = kind
        self.sessionID = sessionID
        if case let .string(name)? = fields["fromName"] { fromName = name }
        var caps: Set<MeshSessionCapability> = []
        if case let .array(items)? = fields["capabilities"] {
            for item in items {
                if case let .string(raw) = item, let cap = MeshSessionCapability(rawValue: raw) {
                    caps.insert(cap)
                }
            }
        }
        capabilities = caps
        if case let .string(raw)? = fields["reason"] { reason = Reason(rawValue: raw) }
    }

    init(kind: Kind, sessionID: String, fromName: String? = nil,
         capabilities: Set<MeshSessionCapability> = [], reason: Reason? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.fromName = fromName
        self.capabilities = capabilities
        self.reason = reason
    }
}
