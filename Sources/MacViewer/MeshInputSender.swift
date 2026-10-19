import Foundation
import MeshWebRTC

/// Viewer-side input pipeline for one Mode-2 session (M1 part
/// 3b): view events → `InputEventCoalescer` → encoded
/// `MeshInputEvent` payloads on the peer session's `mv-control`
/// channel.
///
/// The coalescer contract (part 3a) is honored exactly: pointer
/// moves are held latest-wins and flushed (a) ahead of any
/// discrete event, and (b) on the consumer's cadence — the
/// video surface calls `tick()` per frame, and session
/// teardown / pointer-leave go through `endSession()` /
/// `pointerLeft()`, which flush and then send `releaseAll` so
/// the host can never be left holding a key or button this side
/// has let go of.
///
/// Deliberately key events only: text input is NOT synthesized
/// here. The codec and the host both support `textInput` events
/// (part 3a), but Mode 1's unicode-text path is a per-session
/// tools setting with no clean seam into this surface yet, so
/// 3b sends physical key codes — the same default Mode 1 uses —
/// and text mode joins when that seam does (see PHASE3_NOTES).
@MainActor
final class MeshInputSender {
    private let sendData: (Data) -> Void
    private var coalescer = InputEventCoalescer()
    private var ended = false

    init(sendData: @escaping (Data) -> Void) {
        self.sendData = sendData
    }

    /// Feed one event from the video surface. Discrete events
    /// flush immediately (with any held move ahead of them);
    /// moves are held until the next flush point.
    func send(_ event: MeshInputEvent) {
        guard !ended else { return }
        for flushed in coalescer.enqueue(event) { emit(flushed) }
    }

    /// The per-frame flush point: delivers a held move promptly
    /// instead of letting it wait for the next discrete event.
    func tick() {
        guard !ended else { return }
        for flushed in coalescer.flush() { emit(flushed) }
    }

    /// The pointer left the video surface: flush, then release
    /// — a drag that ends outside the window must not leave the
    /// host's button held down (the Mode-1 focus-loss rule).
    func pointerLeft() {
        send(.releaseAll)
    }

    /// Session end (window close, peer ended, any reason):
    /// flush whatever is held, send `releaseAll`, and seal the
    /// sender — late view events after teardown go nowhere.
    func endSession() {
        guard !ended else { return }
        send(.releaseAll)
        ended = true
    }

    private func emit(_ event: MeshInputEvent) {
        // Encoding only throws for non-finite coordinates; the
        // letterbox layer never produces those (it drops the
        // event instead), so a failure here is dropped silently
        // rather than crashing the input path.
        guard let data = try? event.encodedData() else { return }
        sendData(data)
    }
}
