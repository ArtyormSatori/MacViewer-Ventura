import Foundation

/// Adaptive delay between host screen captures.
///
/// The original cadence was a fixed 250 ms poll, which caps a hosted
/// session at about 4 frames per second no matter how fast the network
/// is. This policy halves the delay whenever a captured frame actually
/// changed (down to 50 ms, so an active screen is polled up to twenty
/// times a second, still serialized by the viewer's frame ACK) and
/// doubles it whenever a frame was unchanged (up to 1000 ms), so an
/// idle screen costs about one capture a second and a change is picked
/// up within a second, then ramps back to full speed within a few frames.
struct HostCapturePacing: Equatable, Sendable {
    static let minimumMilliseconds = 50
    static let maximumMilliseconds = 1000
    static let initialMilliseconds = 250

    private(set) var milliseconds = initialMilliseconds

    mutating func frameChanged() {
        milliseconds = max(Self.minimumMilliseconds, milliseconds / 2)
    }

    mutating func frameUnchanged() {
        milliseconds = min(Self.maximumMilliseconds, milliseconds * 2)
    }
}
