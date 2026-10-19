import Foundation
import MeshClient

/// One chat message in a conversation, shared by both modes'
/// transports (Phase 3, chunk 3). Mode 2 persists these per peer;
/// Mode 1 will map its session chat onto the same value once its
/// model grows the seam described in PHASE3_NOTES.md.
struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Delivery: String, Equatable, Codable, Sendable {
        /// Recorded locally, handed to the transport, and no
        /// refusal has arrived yet (outgoing only).
        case sending
        /// The relay accepted the message and no refusal followed
        /// within the delivery window (outgoing only). The mesh
        /// protocol has no positive acknowledgement, so this is
        /// "accepted, not refused", never "read".
        case sent
        /// The transport threw, the relay refused delivery, or the
        /// connection dropped while the message was in flight.
        case failed
        /// Received from the peer.
        case received
    }

    let id: UUID
    /// Display name of whoever wrote the message (the local user's
    /// device name for outgoing, the peer's name for incoming).
    let senderName: String
    let text: String
    let timestamp: Date
    let isOutgoing: Bool
    var delivery: Delivery
    /// Per-conversation monotone counter assigned when the message
    /// is recorded. Display order is (timestamp, sequence): the
    /// sequence keeps the order stable and deterministic when two
    /// timestamps tie or an older message arrives out of order.
    let sequence: Int
}

/// One Mode 2 chat message on the signaling channel (Phase 3,
/// chunk 3), carried as an app-layer envelope between paired
/// devices — the same convention chunk 2 set for session messages.
///
/// WIRE CONVENTION (app layer, core untouched): chat rides on kind
/// `.offer` with `data` = an object holding a single `mvChat` key.
/// Session messages use the `mvSession` key and media (M1) uses a
/// string payload, so `init?(data:)` discriminates unambiguously
/// and returns nil for anything that is not a chat message.
struct MeshChatMessage: Equatable, Sendable {
    /// Stable message identity, minted by the sender. Receivers
    /// dedupe on it: a redelivery is displayed and stored once.
    var id: UUID
    /// The sender's display name (the server does not put names in
    /// forwarded signals).
    var fromName: String?
    var text: String
    /// The sender's clock at send time; receivers order by it.
    var timestamp: Date

    /// The signaling kind every chat message is sent with.
    static let transportKind: SignalKind = .offer
    /// The marker key inside the signaling `data` object.
    static let markerKey = "mvChat"

    /// The `data` payload for `MeshSignalingAPI.sendSignal`.
    var signalingData: JSONValue {
        var fields: [String: JSONValue] = [
            "v": .number(1),
            "type": .string("chat"),
            "id": .string(id.uuidString),
            "text": .string(text),
            "ts": .number(timestamp.timeIntervalSince1970),
        ]
        if let fromName { fields["fromName"] = .string(fromName) }
        return .object([Self.markerKey: .object(fields)])
    }

    /// Decodes a chat message from a signaling `data` payload.
    /// Returns nil for session/media signaling and anything
    /// malformed — garbage is ignored, never partially applied.
    init?(data: JSONValue) {
        guard case let .object(top) = data,
              case let .object(fields)? = top[Self.markerKey],
              case let .string(type)? = fields["type"], type == "chat",
              case let .string(idRaw)? = fields["id"],
              let id = UUID(uuidString: idRaw),
              case let .string(text)? = fields["text"], !text.isEmpty,
              case let .number(ts)? = fields["ts"]
        else { return nil }
        self.id = id
        self.text = text
        self.timestamp = Date(timeIntervalSince1970: ts)
        if case let .string(name)? = fields["fromName"] { fromName = name }
    }

    init(id: UUID, fromName: String? = nil, text: String, timestamp: Date) {
        self.id = id
        self.fromName = fromName
        self.text = text
        self.timestamp = timestamp
    }
}
