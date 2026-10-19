import Foundation
import MeshClient

/// The remote-input plane of the mesh peer layer: the wire
/// codec for input events carried as payloads on the
/// `mv-control` data channel (part 1), the sender-side move
/// coalescer, and the modifier vocabulary. Everything in this
/// file is Foundation + MeshClient only, so it compiles and is
/// unit-tested on any platform; the host-side planner
/// (`MeshInputPlanner`) turns decoded events into concrete
/// posts, and the macOS `MeshInputApplier` executes them.
///
/// Event semantics mirror Mode 1's `RemoteInput`
/// (Sources/MacViewer/SessionAdapter.swift) so Mode 2 feels
/// identical to the UltraViewer path:
/// - pointer move / button carry a position; Mode 1 uses
///   pixels of the displayed frame, Mode 2 uses normalized
///   0…1 coordinates (the host maps them onto the display it
///   is streaming — see `MeshInputGeometry`).
/// - buttons are left / right / middle (Mode 1's 0 / 1 / 2).
/// - keys carry the macOS hardware (virtual) key code, as in
///   Mode 1 — both mesh ends are Apple platforms in M1, and
///   the host injects the same code it received.
/// - composed text travels as its own event (Mode 1's
///   equivalent is the `unicodeText` keyboard mode: the
///   composed character instead of a physical key).
/// - `modifiers` and `releaseAll` exist for the same reasons
///   as Mode 1's: modifier-state reconciliation, and the
///   focus-loss / disconnect safety release.

/// A pointer button, in Mode 1's order (0 = left, 1 = right,
/// 2 = middle on the UltraViewer wire).
public enum MeshPointerButton: String, Sendable, Equatable, CaseIterable {
    case left
    case right
    case middle
}

/// Modifier state, with the exact bit layout of Mode 1's
/// `RemoteModifiers` so the two modes' semantics line up bit
/// for bit.
public struct MeshInputModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)

    /// The modifier flag a macOS virtual key code belongs to,
    /// or empty for non-modifier keys. Mirrors Mode 1's
    /// `MacHostKeyMapping.modifier(for:)` (HIToolbox kVK_*
    /// codes: Command 0x37/0x36, Shift 0x38/0x3C, Option
    /// 0x3A/0x3D, Control 0x3B/0x3E, Caps Lock 0x39).
    public static func modifier(forKeyCode code: UInt16) -> MeshInputModifiers {
        switch code {
        case 0x37, 0x36: return .command
        case 0x38, 0x3C: return .shift
        case 0x3A, 0x3D: return .option
        case 0x3B, 0x3E: return .control
        case 0x39: return .capsLock
        default: return []
        }
    }

    /// Whether a macOS virtual key code is a modifier key (its
    /// transitions post as flag changes on the host).
    public static func isModifierKey(_ code: UInt16) -> Bool {
        !modifier(forKeyCode: code).isEmpty
    }
}

/// One remote-input event, as carried on the control channel.
///
/// Wire format (version 1): a compact JSON object with a `v`
/// version field and a `t` discriminator — the same object
/// style as the signaling plane's payloads, and deliberately
/// independent of them (this payload rides the peer-to-peer
/// data channel, not the signaling relay):
///
/// - move:      `{"v":1,"t":"move","x":0.5,"y":0.25}`
/// - button:    `{"v":1,"t":"button","b":"left","down":true,"x":…,"y":…}`
/// - wheel:     `{"v":1,"t":"wheel","dx":0,"dy":-2.5}`
///   (deltaY positive = wheel forward / scroll up — the
///   Windows WHEEL_DELTA sign; deltaX positive = rightward)
/// - key:       `{"v":1,"t":"key","c":36,"down":true}` plus
///   `"f":<modifier bits>` when the sender declares its
///   modifier state (absent = not declared, distinct from
///   `"f":0` = declared empty)
/// - modifiers: `{"v":1,"t":"modifiers","f":<modifier bits>}`
/// - text:      `{"v":1,"t":"text","s":"…"}`
/// - release:   `{"v":1,"t":"releaseAll"}`
///
/// Coordinates are normalized 0…1 doubles. Out-of-range
/// values still decode — clamping is the host geometry's job
/// (`MeshInputGeometry`), so a sender slightly overshooting
/// an edge lands on the edge pixel instead of being dropped.
/// Non-finite values cannot be encoded (JSON has no NaN /
/// infinity) and never decode.
public enum MeshInputEvent: Equatable, Sendable {
    case pointerMove(x: Double, y: Double)
    case pointerButton(button: MeshPointerButton, down: Bool, x: Double, y: Double)
    case wheel(deltaX: Double, deltaY: Double)
    case key(code: UInt16, down: Bool, flags: MeshInputModifiers?)
    case modifiers(MeshInputModifiers)
    case textInput(String)
    case releaseAll

    /// The wire-format version this build speaks.
    public static let wireVersion = 1

    /// Whether the event carries a pointer position (and so
    /// needs a display size to be applied on the host).
    public var isPositional: Bool {
        switch self {
        case .pointerMove, .pointerButton, .wheel: return true
        case .key, .modifiers, .textInput, .releaseAll: return false
        }
    }

    /// Whether the event is discrete — never coalesced, never
    /// reordered, and a flush point for held moves (see
    /// `InputEventCoalescer`). Moves are the only non-discrete
    /// events: a stale move is worthless once a newer one
    /// exists (the 4.0.3 DeskIn rule — never deliver stale
    /// input).
    public var isDiscrete: Bool {
        switch self {
        case .pointerMove: return false
        default: return true
        }
    }

    // MARK: - Wire codec

    public var jsonValue: JSONValue {
        let version: JSONValue = .number(Double(Self.wireVersion))
        switch self {
        case let .pointerMove(x, y):
            return .object(["v": version, "t": .string("move"),
                            "x": .number(x), "y": .number(y)])
        case let .pointerButton(button, down, x, y):
            return .object(["v": version, "t": .string("button"),
                            "b": .string(button.rawValue), "down": .bool(down),
                            "x": .number(x), "y": .number(y)])
        case let .wheel(deltaX, deltaY):
            return .object(["v": version, "t": .string("wheel"),
                            "dx": .number(deltaX), "dy": .number(deltaY)])
        case let .key(code, down, flags):
            var fields: [String: JSONValue] = [
                "v": version, "t": .string("key"),
                "c": .number(Double(code)), "down": .bool(down),
            ]
            if let flags { fields["f"] = .number(Double(flags.rawValue)) }
            return .object(fields)
        case let .modifiers(flags):
            return .object(["v": version, "t": .string("modifiers"),
                            "f": .number(Double(flags.rawValue))])
        case let .textInput(text):
            return .object(["v": version, "t": .string("text"),
                            "s": .string(text)])
        case .releaseAll:
            return .object(["v": version, "t": .string("releaseAll")])
        }
    }

    /// Strict parse of the wire form. Returns nil for anything
    /// that is not exactly a version-`wireVersion` input object
    /// — wrong shape, unknown version, unknown kind, missing or
    /// mistyped fields, out-of-range key codes / modifier bits,
    /// non-finite numbers. Unknown *extra* fields are ignored,
    /// so a same-version sender can add annotations without
    /// breaking this receiver.
    public init?(jsonValue: JSONValue) {
        guard case .object(let fields) = jsonValue,
              case .number(let version)? = fields["v"],
              version == Double(Self.wireVersion),
              case .string(let kind)? = fields["t"]
        else { return nil }

        func coordinate(_ key: String) -> Double? {
            guard case .number(let value)? = fields[key], value.isFinite
            else { return nil }
            return value
        }
        func downFlag() -> Bool? {
            guard case .bool(let value)? = fields["down"] else { return nil }
            return value
        }
        func modifierBits() -> MeshInputModifiers? {
            guard case .number(let bits)? = fields["f"],
                  let value = UInt8(exactly: bits)
            else { return nil }
            return MeshInputModifiers(rawValue: value)
        }

        switch kind {
        case "move":
            guard let x = coordinate("x"), let y = coordinate("y") else { return nil }
            self = .pointerMove(x: x, y: y)
        case "button":
            guard case .string(let rawButton)? = fields["b"],
                  let button = MeshPointerButton(rawValue: rawButton),
                  let down = downFlag(),
                  let x = coordinate("x"), let y = coordinate("y")
            else { return nil }
            self = .pointerButton(button: button, down: down, x: x, y: y)
        case "wheel":
            guard let deltaX = coordinate("dx"), let deltaY = coordinate("dy")
            else { return nil }
            self = .wheel(deltaX: deltaX, deltaY: deltaY)
        case "key":
            guard case .number(let rawCode)? = fields["c"],
                  let code = UInt16(exactly: rawCode),
                  let down = downFlag()
            else { return nil }
            var flags: MeshInputModifiers?
            if fields["f"] != nil {
                guard let parsed = modifierBits() else { return nil }
                flags = parsed
            }
            self = .key(code: code, down: down, flags: flags)
        case "modifiers":
            guard let flags = modifierBits() else { return nil }
            self = .modifiers(flags)
        case "text":
            guard case .string(let text)? = fields["s"] else { return nil }
            self = .textInput(text)
        case "releaseAll":
            self = .releaseAll
        default:
            return nil
        }
    }

    /// Encodes to the exact bytes sent on the control channel.
    /// Throws only for non-finite coordinates/deltas, which
    /// JSON cannot represent.
    public func encodedData() throws -> Data {
        try JSONEncoder().encode(jsonValue)
    }

    /// Decodes one control-channel payload; nil (never a
    /// throw, never a crash) for malformed bytes.
    public init?(data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let event = MeshInputEvent(jsonValue: value)
        else { return nil }
        self = event
    }
}

/// Sender-side pointer-move coalescer (pure value type).
///
/// Contract — the DeskIn rule from the 4.0.3 lag work: never
/// deliver stale input. A pointer move is held, not sent,
/// until a flush point; while held, a newer move REPLACES it
/// (only the latest position matters). Discrete events
/// (button / wheel / key / modifiers / text / release) are
/// never dropped, replaced, or reordered.
///
/// Flush points, concretely:
/// 1. Enqueueing a discrete event flushes immediately: the
///    returned array is the held move (if any) followed by
///    everything queued, in order — so the host's pointer is
///    at the click's position before the click lands, exactly
///    as Mode 1's encoder emits a move ahead of a button.
/// 2. `flush()` drains whatever is held. The consumer calls
///    it on its own cadence (part 3b: per rendered frame, and
///    on pointer-leave / session end) so a trailing move is
///    delivered promptly without waiting for a discrete event.
///
/// Bypassing the coalescer entirely (encode each event and
/// send it directly) is a supported configuration, not an
/// error — it is what deterministic tests use; every event
/// then travels, including every intermediate move.
public struct InputEventCoalescer: Sendable {
    public private(set) var pending: [MeshInputEvent] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var pendingCount: Int { pending.count }

    /// Enqueues one event and returns the events to send now,
    /// in order. Moves return an empty array (held, or
    /// replacing a held move); discrete events return the
    /// drained queue ending with themselves.
    @discardableResult
    public mutating func enqueue(_ event: MeshInputEvent) -> [MeshInputEvent] {
        guard event.isDiscrete else {
            if case .pointerMove? = pending.last {
                pending[pending.count - 1] = event
            } else {
                pending.append(event)
            }
            return []
        }
        pending.append(event)
        return flush()
    }

    /// Drains the held events in order (at most one held move,
    /// by construction) and empties the queue.
    @discardableResult
    public mutating func flush() -> [MeshInputEvent] {
        let drained = pending
        pending = []
        return drained
    }
}
