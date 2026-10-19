#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// The macOS executor for the input planner: turns
/// `MeshInputAction`s into CGEvents posted at the HID tap —
/// the same call patterns Mode 1's `MacHostInputController`
/// (the UltraViewer host path) uses, so both modes inject
/// input identically.
///
/// Division of labor: `MeshInputPlanner` (pure, tested
/// everywhere) makes every decision — the capability gate,
/// coordinate mapping, held state, wheel accumulation. This
/// class only executes, plus the two pieces of Mode 1 host
/// behavior that are inherently about the live machine:
/// - Display-geometry changes release held input first (a
///   pixel's meaning changed; Mode 1's
///   `MacHostInputController.setGeometry` does the same).
///   The size comes from an injected provider — in
///   production, the size `ScreenCaptureSource` is streaming
///   — consulted on every apply, so a mid-session display
///   switch is picked up here, once.
/// - Without Accessibility trust, CGEvent posts would go
///   nowhere; planned actions are then counted
///   (`accessibilityDroppedCount`) and dropped, never
///   attempted-and-pretended. Planner state still advances,
///   so when trust is granted mid-session the held-state
///   bookkeeping is consistent. Prompting for the permission
///   is the app's job (its existing permissions flow), not
///   the core's.
///
/// What CI can and cannot prove here: posting real events
/// needs Accessibility trust AND a live desktop session, so
/// end-to-end on-screen effect is a field proof (with the
/// part-3b app wiring), stated plainly. What IS proven in
/// tests is everything upstream of this class — the planner's
/// mapping math, gating, and state machine. CGEvent creation
/// failures (nil) are tolerated per event, never fatal.
public final class MeshInputApplier: @unchecked Sendable {
    /// The planner making the decisions (exposed for
    /// diagnostics: drop counters, held state).
    public let planner: MeshInputPlanner

    private let displaySizeProvider: @Sendable () -> MeshDisplaySize?
    private let source = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var accessibilityDropped = 0

    /// - Parameters:
    ///   - controlAllowed: the negotiated session capability;
    ///     the planner starts with this gate.
    ///   - displaySizeProvider: the display size currently
    ///     being streamed (the mapping target). Consulted per
    ///     apply; a change releases held input first.
    public init(controlAllowed: Bool,
                displaySizeProvider: @escaping @Sendable () -> MeshDisplaySize?) {
        self.planner = MeshInputPlanner(controlAllowed: controlAllowed,
                                        displaySize: displaySizeProvider())
        self.displaySizeProvider = displaySizeProvider
    }

    /// The capability gate (forwards to the planner).
    /// Revoking control (true → false) releases held input
    /// immediately — the Mode 1 rule that a control toggle
    /// must never leave keys or buttons stuck down on the
    /// host.
    public var controlAllowed: Bool {
        get { planner.controlAllowed }
        set {
            lock.withLock {
                let wasAllowed = planner.controlAllowed
                planner.controlAllowed = newValue
                if wasAllowed && !newValue {
                    execute(planner.releaseAllActions())
                }
            }
        }
    }

    /// Apply calls whose planned actions were dropped because
    /// the process lacks Accessibility trust.
    public var accessibilityDroppedCount: Int {
        lock.withLock { accessibilityDropped }
    }

    /// Plans and executes one decoded remote event; returns
    /// the actions that were planned (and executed, unless
    /// Accessibility trust was missing), for diagnostics.
    @discardableResult
    public func apply(_ event: MeshInputEvent) -> [MeshInputAction] {
        lock.withLock {
            syncDisplaySize()
            let actions = planner.plan(event)
            execute(actions)
            return actions
        }
    }

    /// Decodes one control-channel payload and applies it.
    /// Returns false for a malformed payload (decoded to nil
    /// by the codec — counted nowhere, it never was an event).
    @discardableResult
    public func apply(data: Data) -> Bool {
        guard let event = MeshInputEvent(data: data) else { return false }
        apply(event)
        return true
    }

    /// Local teardown: release everything the host is holding
    /// (session end, app shutdown), regardless of the gate.
    public func releaseAll() {
        lock.withLock {
            syncDisplaySize()
            execute(planner.releaseAllActions())
        }
    }

    // MARK: - Execution (lock held)

    /// Picks up display-size changes from the provider. A
    /// real change releases held input BEFORE the size swaps
    /// (Mode 1 geometry rule); the planner forgets its move
    /// baseline via its displaySize setter.
    private func syncDisplaySize() {
        let size = displaySizeProvider()
        guard size != planner.displaySize else { return }
        execute(planner.releaseAllActions())
        planner.displaySize = size
    }

    private func execute(_ actions: [MeshInputAction]) {
        guard !actions.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            accessibilityDropped += 1
            return
        }
        for action in actions { executeOne(action) }
    }

    private func executeOne(_ action: MeshInputAction) {
        switch action {
        case let .mouseMove(x, y, dragButton, flags):
            let type: CGEventType
            switch dragButton {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case .middle: type = .otherMouseDragged
            case nil: type = .mouseMoved
            }
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: x, y: y),
                                      mouseButton: dragButton?.cgButton ?? .center)
            else { return }
            event.flags = CGEventFlags(meshInput: flags)
            event.post(tap: .cghidEventTap)

        case let .mouseButton(button, down, x, y, flags):
            let type: CGEventType
            switch (button, down) {
            case (.left, true): type = .leftMouseDown
            case (.left, false): type = .leftMouseUp
            case (.right, true): type = .rightMouseDown
            case (.right, false): type = .rightMouseUp
            case (.middle, true): type = .otherMouseDown
            case (.middle, false): type = .otherMouseUp
            }
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: x, y: y),
                                      mouseButton: button.cgButton)
            else { return }
            event.flags = CGEventFlags(meshInput: flags)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)

        case let .wheel(linesX, linesY, x, y, flags):
            // The wheel wire convention (deltaY positive =
            // scroll up, deltaX positive = rightward) maps
            // onto Quartz's axis signs directly for axis 1;
            // axis 2 is positive-leftward in Quartz, hence
            // the negation. The sign choice for horizontal is
            // the one piece of this file CI cannot check (no
            // live desktop) — it is pinned here, in one place,
            // for the part-3b field check.
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                      wheelCount: 2, wheel1: linesY, wheel2: -linesX,
                                      wheel3: 0)
            else { return }
            event.location = CGPoint(x: x, y: y)
            event.flags = CGEventFlags(meshInput: flags)
            event.post(tap: .cghidEventTap)

        case let .key(code, down, flags, isRepeat):
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(code), keyDown: down)
            else { return }
            event.flags = CGEventFlags(meshInput: flags)
            if MeshInputModifiers.isModifierKey(code) {
                // Modifier transitions post as flag changes
                // (Mode 1: any modifier code, Caps Lock
                // included — it is in the modifier map).
                event.type = .flagsChanged
            }
            if isRepeat {
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            event.post(tap: .cghidEventTap)

        case let .textInput(text):
            postText(text)
        }
    }

    /// Composed text, the Mode 1 VK_PACKET pattern: a
    /// key-down on virtual key 0 whose Unicode string is the
    /// text, so the host's layout/IME never reinterprets it,
    /// followed by the matching key-up.
    private func postText(_ text: String) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            var mutableUnits = units
            down.keyboardSetUnicodeString(stringLength: units.count,
                                          unicodeString: &mutableUnits)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }
}

private extension MeshPointerButton {
    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

private extension CGEventFlags {
    init(meshInput modifiers: MeshInputModifiers) {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        self = flags
    }
}
#endif
