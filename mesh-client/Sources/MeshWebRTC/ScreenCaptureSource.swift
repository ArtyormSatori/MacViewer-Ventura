#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// The display id asked for is not in the shareable
    /// content (unplugged, or permission scope changed).
    case displayUnavailable(CGDirectDisplayID)
}

/// The production host capture path: ScreenCaptureKit →
/// `MeshVideoCapturer`. A thin adapter — it owns one
/// `SCStream` for one display, turns each screen
/// `CMSampleBuffer` into the `CVPixelBuffer` + nanosecond
/// timestamp the capturer wants, and surfaces stream failure
/// as state, never as a crash.
///
/// ScreenCaptureKit surface used (all of it macOS 12.3+; the
/// package floor is 13, so no availability guards are
/// needed): `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`,
/// `SCContentFilter(display:excludingWindows:)`,
/// `SCStreamConfiguration` (width / height /
/// minimumFrameInterval / queueDepth / pixelFormat /
/// showsCursor), `SCStream(filter:configuration:delegate:)`,
/// `addStreamOutput(_:type:sampleHandlerQueue:)`,
/// `startCapture()` / `stopCapture()`, and the
/// `SCStreamOutput` / `SCStreamDelegate` protocols. The
/// framework is a system framework: SwiftPM links it from the
/// import alone (its SDK module carries the autolink entry),
/// so Package.swift needs no linker settings for it.
///
/// Capture format is NV12 full-range
/// (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) — the
/// format the VideoToolbox encoder consumes natively, and one
/// of the formats RTCCVPixelBuffer supports, so frames cross
/// into WebRTC without a conversion hop.
public final class ScreenCaptureSource: NSObject, @unchecked Sendable {

    /// One capturable display, in value form. (SCDisplay
    /// objects themselves are re-resolved at `start` —
    /// displays can come and go between enumeration and
    /// capture.)
    public struct DisplayInfo: Equatable, Sendable {
        public let id: CGDirectDisplayID
        public let width: Int
        public let height: Int

        public init(id: CGDirectDisplayID, width: Int, height: Int) {
            self.id = id
            self.width = width
            self.height = height
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case running
        /// The stream stopped with an error, or start failed
        /// after the stream was created. The string is the
        /// error's description — a state to surface, not a
        /// crash to hide.
        case failed(String)
    }

    private let capturer: MeshVideoCapturer
    private let sampleQueue = DispatchQueue(label: "mesh.screencapture.samples")
    private let lock = NSLock()
    private var stream: SCStream?
    private var currentState: State = .idle

    /// Reported on state transitions, on an arbitrary thread.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(capturer: MeshVideoCapturer) {
        self.capturer = capturer
        super.init()
    }

    public var state: State { lock.withLock { currentState } }

    /// The displays ScreenCaptureKit will let this process
    /// capture. Throws when screen-recording permission is
    /// denied or shareable content is otherwise unavailable —
    /// the caller decides what that means (the app runs its
    /// permission flow; the CI test skips honestly).
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        return content.displays.map {
            DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height)
        }
    }

    /// Starts capturing `displayID` at the requested output
    /// size and frame rate. Any previous capture is stopped
    /// first. Throws on permission failure, on an unknown
    /// display id (`ScreenCaptureError.displayUnavailable`),
    /// and on stream start failure; the state is `.failed`
    /// after a failed start, `.running` after a good one.
    public func start(displayID: CGDirectDisplayID, width: Int, height: Int,
                      framesPerSecond: Int) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw ScreenCaptureError.displayUnavailable(displayID) }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        lock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { self.stream = nil }
            setState(.failed(String(describing: error)))
            throw error
        }
        setState(.running)
    }

    /// Stops the current capture, if any. After a clean stop
    /// the state is `.idle` (a recorded `.failed` is kept —
    /// stopping does not rewrite history).
    public func stop() async {
        let current: SCStream? = lock.withLock {
            let existing = stream
            stream = nil
            return existing
        }
        guard let current else { return }
        try? await current.stopCapture()
        if state == .running { setState(.idle) }
    }

    private func setState(_ newState: State) {
        let changed: Bool = lock.withLock {
            guard currentState != newState else { return false }
            currentState = newState
            return true
        }
        if changed { onStateChange?(newState) }
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureSource: SCStreamOutput {
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        capturer.push(pixelBuffer, timeStampNs: MeshVideoGeometry.nanoseconds(
            value: pts.value, timescale: pts.timescale))
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureSource: SCStreamDelegate {
    /// The stream died on its own (display unplugged,
    /// permission revoked, server error). Record it as state;
    /// the owner decides whether to restart or give up.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            if self.stream === stream { self.stream = nil }
        }
        setState(.failed(String(describing: error)))
    }
}
#endif
