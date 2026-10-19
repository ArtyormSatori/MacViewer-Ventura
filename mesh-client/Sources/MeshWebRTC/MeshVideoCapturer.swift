#if os(macOS)
import CoreVideo
import Foundation
import WebRTC

/// A video capturer fed by hand: anything that can produce
/// `CVPixelBuffer`s (ScreenCaptureKit in production, a test
/// pattern in tests) pushes frames in, and the capturer
/// forwards them to its delegate.
///
/// Header basis (M155, verified on this box):
/// `RTCVideoCapturer` is an NSObject with a weak `delegate`
/// and `initWithDelegate:` (RTCVideoCapturer.h), and
/// `RTCVideoSource` itself conforms to
/// `RTCVideoCapturerDelegate` (RTCVideoSource.h) — so the
/// construction is `MeshVideoCapturer(delegate: source)` and
/// frames are delivered by calling the delegate's
/// `capturer(_:didCapture:)` with an
/// `RTCVideoFrame(buffer:rotation:timeStampNs:)` wrapping an
/// `RTCCVPixelBuffer(pixelBuffer:)` (RTCVideoFrame.h,
/// RTCCVPixelBuffer.h). RTCCVPixelBuffer supports the formats
/// the capture paths produce: 32BGRA and NV12
/// (420YpCbCr8BiPlanar, full and video range).
public final class MeshVideoCapturer: RTCVideoCapturer, @unchecked Sendable {

    /// Pushes one frame toward the video source (and from
    /// there to the encoder). May be called from whatever
    /// thread produces frames — ScreenCaptureKit's sample
    /// queue, a test's pacing loop.
    public func push(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64,
                     rotation: RTCVideoRotation = ._0) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: rotation, timeStampNs: timeStampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}

/// The local screen video track of a `MeshPeerSession`: the
/// retained bundle of video source + capturer + track that
/// `MeshPeerSession.addScreenTrack()` creates.
///
/// Retention is the point (run-16 law): the capturer's
/// delegate — the source — is a weak reference inside the
/// framework, and nothing else in the framework retains a
/// locally created track's source chain. The session retains
/// this bundle for its whole life, so the chain stays alive
/// exactly as long as the session can send.
public final class MeshScreenTrack: @unchecked Sendable {
    public let track: RTCVideoTrack
    public let source: RTCVideoSource
    public let capturer: MeshVideoCapturer

    init(track: RTCVideoTrack, source: RTCVideoSource, capturer: MeshVideoCapturer) {
        self.track = track
        self.source = source
        self.capturer = capturer
    }

    /// Pushes one captured frame into the track.
    public func push(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64,
                     rotation: RTCVideoRotation = ._0) {
        capturer.push(pixelBuffer, timeStampNs: timeStampNs, rotation: rotation)
    }
}
#endif
