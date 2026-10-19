import Foundation
import MeshClient

/// The pure, WebRTC-independent half of the mesh peer layer:
/// wire forms, inbound routing decisions, remote-candidate
/// buffering order, and selected-pair interpretation of getStats
/// output. Everything in this file is Foundation + MeshClient
/// only, so it compiles and is unit-tested on any platform; the
/// macOS-only `MeshPeerSession` builds all of its signaling
/// behavior on top of it.
///
/// Wire forms (pinned by SignalingPayloadCodecTests and by
/// mode2-phase3/M1_WEBRTC_DECISION.md):
/// - SDP: kind `.offer` / `.answer`, `data` = `.string(sdp)`.
/// - ICE: kind `.ice`, `data` = `.object` with `candidate`
///   (string), `sdpMid` (string), `sdpMLineIndex` (number) —
///   an RTCIceCandidate cannot be rebuilt from its `sdp` string
///   alone, so ICE never uses the string form.

/// Which side of a negotiation a peer session is on. The
/// initiator creates the control data channel and sends the
/// offer; the responder waits for the offer and answers.
public enum MeshPeerRole: String, Sendable {
    case initiator
    case responder
}

/// One ICE candidate in wire form — the platform-neutral twin of
/// `RTCIceCandidate` (same three fields the signaling protocol
/// carries).
public struct MeshICECandidate: Equatable, Sendable {
    public var sdp: String
    public var sdpMid: String
    public var sdpMLineIndex: Int32

    public init(sdp: String, sdpMid: String, sdpMLineIndex: Int32) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    /// The pinned object form: `{candidate, sdpMid, sdpMLineIndex}`.
    public var jsonValue: JSONValue {
        .object([
            "candidate": .string(sdp),
            "sdpMid": .string(sdpMid),
            "sdpMLineIndex": .number(Double(sdpMLineIndex)),
        ])
    }

    /// Parses the pinned object form; nil for anything else
    /// (string payloads, missing fields, wrong field types).
    public init?(jsonValue: JSONValue) {
        guard case .object(let fields) = jsonValue,
              case .string(let candidate)? = fields["candidate"],
              case .string(let mid)? = fields["sdpMid"],
              case .number(let index)? = fields["sdpMLineIndex"],
              let lineIndex = Int32(exactly: index)
        else { return nil }
        self.init(sdp: candidate, sdpMid: mid, sdpMLineIndex: lineIndex)
    }
}

/// Buffers remote ICE candidates until the remote description has
/// been applied — libwebrtc rejects candidates added earlier
/// (spike-proven). Arrival order is preserved across the drain:
/// candidates come out exactly in the order they went in.
public struct ICECandidateBuffer: Sendable {
    public private(set) var isRemoteDescriptionSet = false
    private var pending: [MeshICECandidate] = []

    public init() {}

    public var pendingCount: Int { pending.count }

    /// Adds one candidate. Returns the candidates to apply to the
    /// peer connection now: empty while the remote description is
    /// not set yet (the candidate is buffered), otherwise just the
    /// candidate itself.
    public mutating func add(_ candidate: MeshICECandidate) -> [MeshICECandidate] {
        guard isRemoteDescriptionSet else {
            pending.append(candidate)
            return []
        }
        return [candidate]
    }

    /// Marks the remote description as applied and drains the
    /// buffered candidates in arrival order. Later calls return
    /// an empty array.
    public mutating func remoteDescriptionSet() -> [MeshICECandidate] {
        isRemoteDescriptionSet = true
        let drained = pending
        pending = []
        return drained
    }
}

/// Why a routed signal was not applied to the session.
public enum PeerSignalIgnoreReason: Equatable, Sendable {
    /// `from` is not the peer this session is bound to.
    case wrongPeer
    /// The kind does not fit this session's role (an offer sent
    /// to the initiator, an answer sent to the responder). Mutual
    /// offers (glare) also land here — perfect-negotiation glare
    /// resolution is not part of M1 part 1.
    case wrongRoleForKind
    /// The payload does not match the pinned wire form for its
    /// kind (e.g. an app-plane object payload under `.offer`, or
    /// an ICE object with missing fields).
    case malformedPayload
}

/// The routing decision for one inbound signal.
public enum PeerSignalEvent: Equatable, Sendable {
    /// Apply this SDP as the remote description; kind is
    /// `.offer` (we are the responder) or `.answer` (initiator).
    case remoteDescription(kind: SignalKind, sdp: String)
    /// One remote ICE candidate, in wire form.
    case remoteCandidate(MeshICECandidate)
    /// Not for this session's state machine; nothing changes.
    case ignored(PeerSignalIgnoreReason)
}

/// Signaling identity and routing for one peer session: builds
/// the outbound envelopes and classifies the inbound ones. Pure
/// value type — the session owns one and the tests exercise it
/// directly.
public struct MeshPeerSignaling: Sendable {
    public let localID: MeshID
    public let remoteID: MeshID
    public let role: MeshPeerRole

    public init(localID: MeshID, remoteID: MeshID, role: MeshPeerRole) {
        self.localID = localID
        self.remoteID = remoteID
        self.role = role
    }

    // MARK: Outbound envelopes

    public func offerEnvelope(sdp: String) -> SignalingEnvelope {
        SignalingEnvelope(type: .signal, to: remoteID, from: localID,
                          kind: .offer, data: .string(sdp))
    }

    public func answerEnvelope(sdp: String) -> SignalingEnvelope {
        SignalingEnvelope(type: .signal, to: remoteID, from: localID,
                          kind: .answer, data: .string(sdp))
    }

    public func iceEnvelope(_ candidate: MeshICECandidate) -> SignalingEnvelope {
        SignalingEnvelope(type: .signal, to: remoteID, from: localID,
                          kind: .ice, data: candidate.jsonValue)
    }

    // MARK: Inbound routing

    /// Classifies one signal as yielded by
    /// `MeshSignalingClient.signals`. A session only reacts to
    /// its own peer's media-plane payloads: app-plane envelopes
    /// (session/chat objects under `.offer`) are ignored here —
    /// they belong to the app's session/chat planes, not to the
    /// peer connection.
    public func route(_ signal: SignalEnvelope) -> PeerSignalEvent {
        guard signal.from == remoteID else { return .ignored(.wrongPeer) }
        switch signal.kind {
        case .offer:
            guard role == .responder else { return .ignored(.wrongRoleForKind) }
            guard case .string(let sdp) = signal.data, !sdp.isEmpty else {
                return .ignored(.malformedPayload)
            }
            return .remoteDescription(kind: .offer, sdp: sdp)
        case .answer:
            guard role == .initiator else { return .ignored(.wrongRoleForKind) }
            guard case .string(let sdp) = signal.data, !sdp.isEmpty else {
                return .ignored(.malformedPayload)
            }
            return .remoteDescription(kind: .answer, sdp: sdp)
        case .ice:
            guard let candidate = MeshICECandidate(jsonValue: signal.data) else {
                return .ignored(.malformedPayload)
            }
            return .remoteCandidate(candidate)
        }
    }
}

/// The candidate type of a selected pair's local candidate, in
/// the vocabulary of the W3C stats model. The UI's Direct/Relay
/// badge reads this: `relay` means traffic flows through a TURN
/// server; anything else is a direct path of some flavor.
public enum MeshCandidateType: String, Sendable {
    case host
    case srflx
    case relay
    case prflx
    /// A value this build does not know (future stats models).
    case unknown

    public init(parsing rawValue: String) {
        self = MeshCandidateType(rawValue: rawValue) ?? .unknown
    }
}

/// One getStats entry flattened to pure values, so the selection
/// algorithm below runs (and is tested) without WebRTC types.
/// The macOS session converts `RTCStatistics` values into this
/// shape; the conversion is the only platform-bound step.
public struct MeshStatsEntry: Equatable, Sendable {
    public var id: String
    public var type: String
    public var values: [String: JSONValue]

    public init(id: String, type: String, values: [String: JSONValue]) {
        self.id = id
        self.type = type
        self.values = values
    }
}

/// Selected-candidate-pair interpretation over flattened stats.
public enum MeshStatsSelection {
    /// The local candidate type of the pair currently carrying
    /// traffic, or nil when the stats hold no usable pair yet.
    ///
    /// Selection follows the W3C getStats model: a transport
    /// entry's `selectedCandidatePairId` wins when present;
    /// otherwise the nominated, succeeded candidate-pair;
    /// otherwise any succeeded candidate-pair. The pair's
    /// `localCandidateId` resolves to a local-candidate entry
    /// whose `candidateType` is the answer.
    public static func selectedLocalCandidateType(
        in stats: [MeshStatsEntry]
    ) -> MeshCandidateType? {
        let pairs = stats.filter { $0.type == "candidate-pair" }
        guard !pairs.isEmpty else { return nil }

        let selected: MeshStatsEntry?
        if let transport = stats.first(where: { $0.type == "transport" }),
           case .string(let pairID)? = transport.values["selectedCandidatePairId"] {
            selected = pairs.first(where: { $0.id == pairID })
        } else {
            selected = nil
        }
        let pair = selected
            ?? pairs.first(where: { isSucceeded($0) && isTruthy($0.values["nominated"]) })
            ?? pairs.first(where: isSucceeded)
        guard let pair,
              case .string(let localID)? = pair.values["localCandidateId"],
              let local = stats.first(where: { $0.id == localID && $0.type == "local-candidate" }),
              case .string(let rawType)? = local.values["candidateType"]
        else { return nil }
        return MeshCandidateType(parsing: rawType)
    }

    private static func isSucceeded(_ entry: MeshStatsEntry) -> Bool {
        if case .string("succeeded")? = entry.values["state"] { return true }
        return false
    }

    private static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(true): return true
        case .number(let number): return number != 0
        default: return false
        }
    }
}
