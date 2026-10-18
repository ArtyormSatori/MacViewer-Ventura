import Foundation

/// Minimal arbitrary-JSON value, used for the signaling envelope's
/// opaque `data` field: an SDP string for offer/answer, a candidate
/// JSON object for ice (server README §Signaling protocol).
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The kind of a WebRTC signaling payload.
public enum SignalKind: String, Codable, Sendable {
    case offer
    case answer
    case ice
}

/// A signal envelope received from a paired peer (the server adds
/// `from` when forwarding).
public struct SignalEnvelope: Equatable, Sendable {
    public let from: MeshID
    public let kind: SignalKind
    public let data: JSONValue

    public init(from: MeshID, kind: SignalKind, data: JSONValue) {
        self.from = from
        self.kind = kind
        self.data = data
    }
}

/// The WebSocket wire message, mirroring `wsMessage` in server.go
/// field for field. Optional fields are omitted when nil, matching
/// the server's `omitempty` encoding.
public struct SignalingEnvelope: Codable, Equatable, Sendable {
    public enum MessageType: String, Codable, Sendable {
        case auth
        case nonce
        case authOK = "auth_ok"
        case signal
        case ping
        case pong
        case error
    }

    public var type: MessageType
    public var meshID: MeshID?
    public var nonce: String?
    public var signature: String?
    public var to: MeshID?
    public var from: MeshID?
    public var kind: SignalKind?
    public var data: JSONValue?
    public var code: String?

    public init(type: MessageType, meshID: MeshID? = nil, nonce: String? = nil,
                signature: String? = nil, to: MeshID? = nil, from: MeshID? = nil,
                kind: SignalKind? = nil, data: JSONValue? = nil, code: String? = nil) {
        self.type = type
        self.meshID = meshID
        self.nonce = nonce
        self.signature = signature
        self.to = to
        self.from = from
        self.kind = kind
        self.data = data
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case meshID = "mesh_id"
        case nonce
        case signature
        case to
        case from
        case kind
        case data
        case code
    }

    /// Encodes to the exact JSON text sent on the wire.
    public func encodedJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MeshError.decoding("envelope did not encode as UTF-8")
        }
        return text
    }

    /// Decodes one wire text frame.
    public static func decodeJSON(_ text: String) throws -> SignalingEnvelope {
        do {
            return try JSONDecoder().decode(SignalingEnvelope.self, from: Data(text.utf8))
        } catch let error as MeshError {
            throw error
        } catch {
            throw MeshError.decoding("envelope: \(error)")
        }
    }
}
