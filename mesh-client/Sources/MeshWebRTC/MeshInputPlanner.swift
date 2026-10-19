import Foundation

/// The display the host is streaming, in pixels — the target
/// space `MeshInputGeometry` maps normalized input coordinates
/// onto. Matches the width/height `ScreenCaptureSource` is
/// configured with.
public struct MeshDisplaySize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Normalized → pixel mapping for remote input (pure).
public enum MeshInputGeometry {
    /// Maps a normalized 0…1 point onto a display pixel.
    /// Coordinates outside 0…1 clamp to the edge, so 1.0 (or
    /// an overshoot) reaches the LAST pixel — the far edge of
    /// the screen must be reachable, which a plain
    /// `Int(1.0 * width)` would miss by landing one past it.
    /// Non-finite coordinates map to the origin, and a
    /// degenerate display size maps everything to (0, 0):
    /// this function never traps and never emits an
    /// out-of-display point.
    public static func pixelPoint(x: Double, y: Double,
                                  in size: MeshDisplaySize) -> (x: Int, y: Int) {
        (axis(x, extent: size.width), axis(y, extent: size.height))
    }

    private static func axis(_ value: Double, extent: Int) -> Int {
        guard extent > 0 else { return 0 }
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        let scaled = Int((clamped * Double(extent)).rounded(.down))
        return min(max(scaled, 0), extent - 1)
    }
}

/// One concrete host-side post the planner decided on — the
/// pure output of `MeshInputPlanner`, executed by the macOS
/// `MeshInputApplier` through CGEvent. Positions are display
/// pixels (already mapped); flags are the modifier state to
/// stamp on the post, computed the way Mode 1's host
/// controller computes the same state from the same inputs.
public enum MeshInputAction: Equatable, Sendable {
    /// Pointer move to a pixel; `dragButton` is the button
    /// whose drag this is (left wins over right over middle,
    /// as in Mode 1), or nil for a plain move.
    case mouseMove(x: Int, y: Int, dragButton: MeshPointerButton?, flags: MeshInputModifiers)
    case mouseButton(MeshPointerButton, down: Bool, x: Int, y: Int, flags: MeshInputModifiers)
    /// Whole scroll lines (fractional deltas accumulate in
    /// the planner; only whole lines are planned). Posted at
    /// the last known pointer point.
    case wheel(linesX: Int32, linesY: Int32, x: Int, y: Int, flags: MeshInputModifiers)
    /// `isRepeat` marks a key-down for an already-held key
    /// (autorepeat), as Mode 1 flags it.
    case key(code: UInt16, down: Bool, flags: MeshInputModifiers, isRepeat: Bool)
    case textInput(String)
}

/// Turns decoded `MeshInputEvent`s into `MeshInputAction`s:
/// the capability gate, coordinate mapping, held-key/button
/// bookkeeping, and wheel accumulation for one host session.
/// Pure and platform-independent — the macOS
/// `MeshInputApplier` is a thin CGEvent executor over this
/// planner, so everything decided here is unit-tested
/// everywhere.
///
/// Rules (each mirrors Mode 1, noted where it comes from):
/// - The gate: while `controlAllowed` is false, EVERY remote
///   event is dropped and counted (`droppedEventCount`). The
///   planner starts disallowed — control must be granted by
///   the negotiated session capability, never assumed.
/// - Positional events (move / button / wheel) need a
///   display size to map onto; without one they are dropped
///   and counted separately (`unmappedEventCount`). Key,
///   modifier, text and release events plan fine without one.
/// - Duplicate transitions are no-ops (Mode 1's encoder and
///   host controller both refuse them): a button-down for a
///   held button, a button-up for a free button, and a key-up
///   for a free key plan nothing. A repeated key-down plans
///   again, marked `isRepeat`.
/// - A move that changes nothing (same pixel, same drag
///   state, same modifier flags as the last planned move)
///   plans nothing — Mode 1's encoder suppresses the same
///   duplicates on its side.
/// - Effective modifier state = the sender-declared state
///   (latest `flags` on a key event, or a `modifiers` event)
///   ∪ the state derived from physically held modifier keys.
///   A key action carries the state AFTER its own transition,
///   as Mode 1's host controller stamps flags post-update.
/// - releaseAll releases held keys in reverse press order,
///   then held buttons in reverse press order, restamping
///   flags after each release, and keeps Caps Lock (all
///   Mode 1 behaviors). Wheel remainders reset.
public final class MeshInputPlanner: @unchecked Sendable {
    private let lock = NSLock()
    private var controlAllowedStorage: Bool
    private var displaySizeStorage: MeshDisplaySize?
    private var dropped = 0
    private var unmapped = 0
    private var heldButtonOrder: [MeshPointerButton] = []
    private var heldKeyOrder: [UInt16] = []
    private var declaredModifiers: MeshInputModifiers = []
    private var currentPoint: (x: Int, y: Int) = (x: 0, y: 0)
    private var lastMoveSignature: MoveSignature?
    private var wheelRemainderX = 0.0
    private var wheelRemainderY = 0.0

    private struct MoveSignature: Equatable {
        var x: Int
        var y: Int
        var dragButton: MeshPointerButton?
        var flags: MeshInputModifiers
    }

    /// Starts disallowed unless told otherwise: the caller
    /// passes the negotiated session capability.
    public init(controlAllowed: Bool = false, displaySize: MeshDisplaySize? = nil) {
        self.controlAllowedStorage = controlAllowed
        self.displaySizeStorage = displaySize
    }

    /// The capability gate. While false, remote events are
    /// dropped + counted. (Local teardown is NOT gated: see
    /// `releaseAllActions()`.)
    public var controlAllowed: Bool {
        get { lock.withLock { controlAllowedStorage } }
        set { lock.withLock { controlAllowedStorage = newValue } }
    }

    /// The display being streamed, in pixels. Setting a new
    /// size forgets the last planned move (its pixel meaning
    /// changed), so the next move always plans.
    public var displaySize: MeshDisplaySize? {
        get { lock.withLock { displaySizeStorage } }
        set {
            lock.withLock {
                displaySizeStorage = newValue
                lastMoveSignature = nil
            }
        }
    }

    /// Remote events dropped because control was not allowed.
    public var droppedEventCount: Int { lock.withLock { dropped } }

    /// Positional remote events dropped because no display
    /// size was set to map them onto.
    public var unmappedEventCount: Int { lock.withLock { unmapped } }

    /// Buttons currently held, in press order (diagnostics).
    public var currentlyHeldButtons: [MeshPointerButton] {
        lock.withLock { heldButtonOrder }
    }

    /// Key codes currently held, in press order (diagnostics).
    public var currentlyHeldKeyCodes: [UInt16] {
        lock.withLock { heldKeyOrder }
    }

    /// Plans one decoded remote event. Returns the posts to
    /// execute, in order (often empty — see the rules above).
    public func plan(_ event: MeshInputEvent) -> [MeshInputAction] {
        lock.withLock { planLocked(event) }
    }

    /// The release sequence for LOCAL teardown (session end,
    /// control revoked, display geometry replaced — the app /
    /// applier decides when). Deliberately NOT gated: input
    /// the host already took must always be releasable, even
    /// after the capability is gone.
    public func releaseAllActions() -> [MeshInputAction] {
        lock.withLock { releaseAllLocked() }
    }

    // MARK: - Planning (lock held)

    private func planLocked(_ event: MeshInputEvent) -> [MeshInputAction] {
        guard controlAllowedStorage else {
            dropped += 1
            return []
        }
        switch event {
        case let .pointerMove(x, y):
            guard let size = displaySizeStorage else {
                unmapped += 1
                return []
            }
            let point = MeshInputGeometry.pixelPoint(x: x, y: y, in: size)
            let flags = effectiveModifiers()
            let signature = MoveSignature(x: point.x, y: point.y,
                                          dragButton: dragButton(), flags: flags)
            guard signature != lastMoveSignature else { return [] }
            lastMoveSignature = signature
            currentPoint = point
            return [.mouseMove(x: point.x, y: point.y,
                               dragButton: signature.dragButton, flags: flags)]

        case let .pointerButton(button, down, x, y):
            // Duplicate transitions plan nothing (Mode 1),
            // whether or not a display size exists yet.
            if down == heldButtonOrder.contains(button) { return [] }
            guard let size = displaySizeStorage else {
                unmapped += 1
                return []
            }
            let point = MeshInputGeometry.pixelPoint(x: x, y: y, in: size)
            if down { heldButtonOrder.append(button) }
            else { heldButtonOrder.removeAll { $0 == button } }
            currentPoint = point
            let flags = effectiveModifiers()
            // The button's point + post-transition drag state
            // becomes the move baseline, so an identical
            // follow-up move is judged against reality.
            lastMoveSignature = MoveSignature(x: point.x, y: point.y,
                                              dragButton: dragButton(), flags: flags)
            return [.mouseButton(button, down: down, x: point.x, y: point.y, flags: flags)]

        case let .wheel(deltaX, deltaY):
            guard displaySizeStorage != nil else {
                unmapped += 1
                return []
            }
            let linesX = wholeLines(accumulating: deltaX, into: &wheelRemainderX)
            let linesY = wholeLines(accumulating: deltaY, into: &wheelRemainderY)
            guard linesX != 0 || linesY != 0 else { return [] }
            return [.wheel(linesX: linesX, linesY: linesY,
                           x: currentPoint.x, y: currentPoint.y,
                           flags: effectiveModifiers())]

        case let .key(code, down, flags):
            if let flags { declaredModifiers = flags }
            let isRepeat = down && heldKeyOrder.contains(code)
            if down {
                if !isRepeat { heldKeyOrder.append(code) }
            } else {
                guard heldKeyOrder.contains(code) else { return [] }
                heldKeyOrder.removeAll { $0 == code }
            }
            return [.key(code: code, down: down,
                         flags: effectiveModifiers(), isRepeat: isRepeat)]

        case let .modifiers(flags):
            declaredModifiers = flags
            return []

        case let .textInput(text):
            return [.textInput(text)]

        case .releaseAll:
            return releaseAllLocked()
        }
    }

    private func releaseAllLocked() -> [MeshInputAction] {
        var actions: [MeshInputAction] = []
        for code in Array(heldKeyOrder.reversed()) {
            heldKeyOrder.removeAll { $0 == code }
            actions.append(.key(code: code, down: false,
                                flags: effectiveModifiers(), isRepeat: false))
        }
        for button in Array(heldButtonOrder.reversed()) {
            heldButtonOrder.removeAll { $0 == button }
            actions.append(.mouseButton(button, down: false,
                                         x: currentPoint.x, y: currentPoint.y,
                                         flags: effectiveModifiers()))
        }
        declaredModifiers = declaredModifiers.intersection(.capsLock)
        wheelRemainderX = 0
        wheelRemainderY = 0
        lastMoveSignature = nil
        return actions
    }

    // MARK: - State helpers (lock held)

    private func effectiveModifiers() -> MeshInputModifiers {
        var result = declaredModifiers
        for code in heldKeyOrder {
            result.formUnion(MeshInputModifiers.modifier(forKeyCode: code))
        }
        return result
    }

    /// The button a move drags with: left wins over right over
    /// middle (Mode 1's host controller chooses the same way).
    private func dragButton() -> MeshPointerButton? {
        if heldButtonOrder.contains(.left) { return .left }
        if heldButtonOrder.contains(.right) { return .right }
        if heldButtonOrder.contains(.middle) { return .middle }
        return nil
    }

    /// Adds `delta` to a wheel remainder and extracts the
    /// whole lines (toward zero, clamped to Int32), keeping
    /// the fractional rest for the next event — the two-sided
    /// version of Mode 1's 120-units-per-step accumulation.
    private func wholeLines(accumulating delta: Double,
                            into remainder: inout Double) -> Int32 {
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        let clamped = min(max(whole, Double(Int32.min)), Double(Int32.max))
        remainder -= clamped
        return Int32(clamped)
    }
}
