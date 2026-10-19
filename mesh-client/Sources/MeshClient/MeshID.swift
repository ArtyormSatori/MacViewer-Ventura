import Foundation

/// A 9-digit Mesh ID as assigned by the mesh server at registration
/// (server.go `newMeshID`: zero-padded 9 digits, range 100000000...999999999).
/// Displayed to users grouped 3-3-3 per the settled 5.0 UI spec.
public struct MeshID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(validating raw: String) throws {
        guard raw.count == 9, raw.allSatisfy({ $0.isNumber && $0.isASCII }) else {
            throw MeshError.invalidMeshID(raw)
        }
        self.rawValue = raw
    }

    /// Skips validation; only for values that came from the server or from
    /// local persistence written by this library.
    public init(unchecked raw: String) {
        self.rawValue = raw
    }

    /// "123456789" -> "123 456 789"
    public var formatted: String {
        let chars = Array(rawValue)
        guard chars.count == 9 else { return rawValue }
        return String(chars[0..<3]) + " " + String(chars[3..<6]) + " " + String(chars[6..<9])
    }

    public var description: String { formatted }
}

extension MeshID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard raw.count == 9, raw.allSatisfy({ $0.isNumber && $0.isASCII }) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "mesh_id must be exactly 9 digits, got \(raw)")
        }
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
