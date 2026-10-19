import AppKit
import MeshWebRTC
import SwiftUI
import WebRTC

/// Modifier-state mapping shared by every key event the
/// surface sends: NSEvent's flags are the sender's declaration
/// of the modifier state, which is exactly what the input
/// codec's `flags` field means (part 3a).
func meshInputModifiers(from flags: NSEvent.ModifierFlags) -> MeshInputModifiers {
    var result: MeshInputModifiers = []
    if flags.contains(.shift) { result.insert(.shift) }
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.capsLock) { result.insert(.capsLock) }
    return result
}

/// SwiftUI wrapper for the viewer's remote-video surface
/// (M1 part 3b). The track, sender, and control grant come
/// from the media coordinator + the negotiated capabilities;
/// the view itself is a plain AppKit view (below).
struct MeshVideoSurfaceView: NSViewRepresentable {
    let track: RTCVideoTrack?
    let inputSender: MeshInputSender?
    let inputEnabled: Bool

    func makeNSView(context: Context) -> MeshRemoteVideoNSView {
        MeshRemoteVideoNSView(frame: .zero)
    }

    func updateNSView(_ view: MeshRemoteVideoNSView, context: Context) {
        view.inputEnabled = inputEnabled
        if view.inputSender !== inputSender { view.inputSender = inputSender }
        if view.track !== track { view.track = track }
    }
}

/// The video surface: a black container that hosts the
/// framework's macOS renderer view — `RTCMTLNSVideoView`, an
/// NSView conforming to RTCVideoRenderer (verified in the
/// cached M155 headers: the macOS slice of the xcframework has
/// no RTCMTLVideoView; that is the iOS class). The renderer
/// view is sized to the aspect-fitted content rect
/// (`MeshLetterbox`), so the bars are this container's own
/// background and the mapping from pointer to normalized
/// coordinates is the same rect — points in the bars are
/// dropped by the letterbox math, never clamped.
///
/// Input: mouse moves/buttons/wheel and, while first
/// responder, key events become MeshInputEvents fed to the
/// coordinator's input sender (coalescing lives there).
/// AppKit delivers every callback below on the main thread,
/// so the @MainActor sender is reached through
/// `MainActor.assumeIsolated` — preserving exact event order
/// with no task hops.
final class MeshRemoteVideoNSView: NSView {
    var inputEnabled = false
    var inputSender: MeshInputSender?

    var track: RTCVideoTrack? {
        didSet {
            guard track !== oldValue else { return }
            if let oldValue { oldValue.remove(videoRendererView) }
            if let track { track.add(videoRendererView) }
        }
    }

    private let videoRendererView = RTCMTLNSVideoView()
    private let videoSizeDelegate = MeshVideoSizeDelegate()
    private var videoSize: CGSize = .zero
    private var flushTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoRendererView.delegate = videoSizeDelegate
        videoSizeDelegate.view = self
        addSubview(videoRendererView)
        setAccessibilityLabel("Remote computer screen")
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { flushTimer?.invalidate() }

    override var acceptsFirstResponder: Bool { inputEnabled }

    override func layout() {
        super.layout()
        let rect = MeshLetterbox.contentRect(viewSize: bounds.size,
                                             contentSize: videoSize)
        // Before the first frame reports its size, fill the
        // surface; the delegate callback corrects the rect as
        // soon as a size is known.
        videoRendererView.frame = rect == .zero ? bounds : rect
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            flushTimer?.invalidate()
            flushTimer = nil
            // The surface is going away: flush + release, the
            // same contract as pointer-leave and session end.
            MainActor.assumeIsolated { inputSender?.pointerLeft() }
        } else if flushTimer == nil {
            flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                              repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.inputSender?.tick() }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    // MARK: Pointer

    private func normalized(_ event: NSEvent) -> (x: Double, y: Double)? {
        let point = convert(event.locationInWindow, from: nil)
        return MeshLetterbox.normalizedPoint(point, viewSize: bounds.size,
                                             contentSize: videoSize)
    }

    private func emitMove(_ event: NSEvent) {
        guard inputEnabled, let point = normalized(event) else { return }
        MainActor.assumeIsolated {
            inputSender?.send(.pointerMove(x: point.x, y: point.y))
        }
    }

    private func emitButton(_ button: MeshPointerButton, down: Bool, _ event: NSEvent) {
        guard inputEnabled, let point = normalized(event) else { return }
        MainActor.assumeIsolated {
            inputSender?.send(.pointerButton(button: button, down: down,
                                             x: point.x, y: point.y))
        }
    }

    override func mouseMoved(with event: NSEvent) { emitMove(event) }
    override func mouseDragged(with event: NSEvent) { emitMove(event) }
    override func rightMouseDragged(with event: NSEvent) { emitMove(event) }
    override func otherMouseDragged(with event: NSEvent) { emitMove(event) }

    override func mouseDown(with event: NSEvent) {
        if inputEnabled { window?.makeFirstResponder(self) }
        emitButton(.left, down: true, event)
    }
    override func mouseUp(with event: NSEvent) { emitButton(.left, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { emitButton(.right, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { emitButton(.right, down: false, event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { emitButton(.middle, down: true, event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { emitButton(.middle, down: false, event) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { inputSender?.pointerLeft() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard inputEnabled else { return }
        // The wire unit is scroll LINES (part 3a): wheel
        // notches already arrive as lines; precise (trackpad)
        // deltas arrive as points and convert at Mode 1's
        // rate — RemoteScroll's 40 points per detent, one
        // detent = 3 lines.
        let factor = event.hasPreciseScrollingDeltas ? 3.0 / 40.0 : 1.0
        let deltaX = Double(event.scrollingDeltaX) * factor
        let deltaY = Double(event.scrollingDeltaY) * factor
        guard deltaX != 0 || deltaY != 0 else { return }
        // A move first (held by the coalescer, flushed ahead
        // of the wheel) so the host applies the wheel at the
        // pointer's current position.
        emitMove(event)
        MainActor.assumeIsolated {
            inputSender?.send(.wheel(deltaX: deltaX, deltaY: deltaY))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { super.keyDown(event); return }
        let flags = meshInputModifiers(from: event.modifierFlags)
        MainActor.assumeIsolated {
            inputSender?.send(.key(code: event.keyCode, down: true, flags: flags))
        }
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { super.keyUp(event); return }
        let flags = meshInputModifiers(from: event.modifierFlags)
        MainActor.assumeIsolated {
            inputSender?.send(.key(code: event.keyCode, down: false, flags: flags))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { super.flagsChanged(event); return }
        let flags = meshInputModifiers(from: event.modifierFlags)
        MainActor.assumeIsolated {
            inputSender?.send(.modifiers(flags))
        }
    }

    /// Frame-size reports from the renderer view's delegate,
    /// hopped onto the main actor: layout state lives here.
    func noteVideoSize(_ size: CGSize) {
        Task { @MainActor [weak self] in
            guard let self, size != self.videoSize else { return }
            self.videoSize = size
            self.needsLayout = true
        }
    }
}

/// The renderer view's delegate is WEAK (framework rule from
/// part 0/1: delegates are never retained), so this tiny object
/// is retained by the surface view and only forwards the frame
/// size. It may be called off the main thread; the surface
/// hops to the main actor itself.
private final class MeshVideoSizeDelegate: NSObject, RTCVideoViewDelegate {
    weak var view: MeshRemoteVideoNSView?

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        view?.noteVideoSize(size)
    }
}
