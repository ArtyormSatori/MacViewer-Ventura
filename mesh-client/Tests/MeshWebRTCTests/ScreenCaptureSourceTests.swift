#if os(macOS)
import CoreVideo
import XCTest
import MeshClient
import MeshWebRTC
import WebRTC

/// ScreenCaptureKit adapter tests. A CI runner is a hostile
/// place for screen capture — it may expose no display at all,
/// and screen-recording permission is a TCC grant no one is
/// there to approve. So the honest outcomes are: PASS when
/// capture genuinely works end to end, SKIP (with the reason
/// in the message) when the runner cannot capture, and FAIL
/// only when capture started and then misbehaved. A skip is a
/// truthful report about the runner, not a hidden pass.
///
/// CI-only: ScreenCaptureKit and the WebRTC capturer surface
/// are macOS-only.
final class ScreenCaptureSourceTests: XCTestCase {

    /// Counts the frames ScreenCaptureSource pushes through a
    /// real `MeshVideoCapturer` (the capturer's delegate is
    /// the framework surface the production source feeds).
    private final class CapturerProbe: NSObject, RTCVideoCapturerDelegate,
                                       @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [(width: Int, height: Int)] = []

        var count: Int { lock.withLock { sizes.count } }
        var frameSizes: [(width: Int, height: Int)] { lock.withLock { sizes } }

        func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
            lock.withLock { sizes.append((Int(frame.width), Int(frame.height))) }
        }
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    func testEnumerateDisplaysOrSkipWhenUnavailable() async throws {
        let displays: [ScreenCaptureSource.DisplayInfo]
        do {
            displays = try await ScreenCaptureSource.availableDisplays()
        } catch {
            throw XCTSkip("shareable content unavailable on this runner: \(error)")
        }
        try XCTSkipIf(displays.isEmpty,
                      "this runner exposes no capturable display")
        XCTAssertTrue(displays.allSatisfy { $0.width > 0 && $0.height > 0 },
                      "every enumerated display must report real geometry: \(displays)")
    }

    func testCaptureDeliversARealFrameOrSkipWhenCaptureImpossible() async throws {
        let displays = (try? await ScreenCaptureSource.availableDisplays()) ?? []
        try XCTSkipIf(displays.isEmpty,
                      "no capturable display on this runner (or permission denied)")
        let display = displays[0]

        let probe = CapturerProbe()
        let capturer = MeshVideoCapturer(delegate: probe)
        let source = ScreenCaptureSource(capturer: capturer)
        do {
            try await source.start(displayID: display.id,
                                   width: 640, height: 360, framesPerSecond: 10)
        } catch {
            throw XCTSkip("capture could not start on this runner "
                + "(screen-recording permission?): \(error)")
        }
        XCTAssertEqual(source.state, .running)

        await waitUntil("first captured frame") { probe.count >= 1 }
        await source.stop()

        XCTAssertGreaterThanOrEqual(probe.count, 1,
                                    "a running capture must deliver real frames")
        XCTAssertTrue(probe.frameSizes.allSatisfy { $0.width > 0 && $0.height > 0 },
                      "captured frames must have real dimensions: \(probe.frameSizes)")
        XCTAssertEqual(source.state, .idle)
    }
}
#endif
