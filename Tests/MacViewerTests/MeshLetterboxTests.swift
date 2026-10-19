import AppKit
import CoreGraphics
import Testing
@testable import MacViewer

/// M1 part 3b: the video surface's letterbox geometry and the
/// host's capture-size cap — pure math, pinned exactly.
///
/// Coordinate convention (MeshLetterbox): points are in the
/// container view's bounds space, AppKit-style with the origin
/// at the BOTTOM-left; normalized output has (0, 0) at the
/// content's TOP-left. The pinned product decision: points in
/// the letterbox bars map to nil and the event is DROPPED,
/// never clamped onto a screen edge the user did not point at.
struct MeshLetterboxTests {
    private func expectNear(_ actual: (x: Double, y: Double)?,
                            _ x: Double, _ y: Double,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual else {
            Issue.record("expected a mapped point, got nil", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual.x - x) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(actual.y - y) < 0.001, sourceLocation: sourceLocation)
    }

    @Test("Wide content in a square view: bars top and bottom, corners and center map")
    func wideInSquare() {
        let view = CGSize(width: 400, height: 400)
        let content = CGSize(width: 1920, height: 1080)
        let rect = MeshLetterbox.contentRect(viewSize: view, contentSize: content)
        // scale = 400/1920 → content 400×225, centered vertically.
        #expect(abs(rect.minX - 0) < 0.001)
        #expect(abs(rect.minY - 87.5) < 0.001)
        #expect(abs(rect.width - 400) < 0.001)
        #expect(abs(rect.height - 225) < 0.001)

        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 200, y: 200),
                                                 viewSize: view, contentSize: content),
                   0.5, 0.5)
        // Just inside the content's top-left corner → (0, 0):
        // the top edge is the rect's maxY in AppKit space.
        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 0.1, y: 312.4),
                                                 viewSize: view, contentSize: content),
                   0.0, 0.0)
        // Just inside the bottom-right corner → (1, 1).
        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 399.9, y: 87.6),
                                                 viewSize: view, contentSize: content),
                   1.0, 1.0)
        // Bars are dropped, not clamped.
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 200, y: 390),
                                              viewSize: view, contentSize: content) == nil)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 200, y: 10),
                                              viewSize: view, contentSize: content) == nil)
    }

    @Test("Tall content in a wide view: bars left and right are dropped")
    func tallInWide() {
        let view = CGSize(width: 800, height: 300)
        let content = CGSize(width: 1080, height: 1920)
        let rect = MeshLetterbox.contentRect(viewSize: view, contentSize: content)
        // scale = 300/1920 → content 168.75×300, centered horizontally.
        #expect(abs(rect.minX - 315.625) < 0.001)
        #expect(abs(rect.width - 168.75) < 0.001)
        #expect(abs(rect.height - 300) < 0.001)
        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 400, y: 150),
                                                 viewSize: view, contentSize: content),
                   0.5, 0.5)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 100, y: 150),
                                              viewSize: view, contentSize: content) == nil)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 700, y: 150),
                                              viewSize: view, contentSize: content) == nil)
    }

    @Test("Exact aspect match fills the view with no bars")
    func exactFit() {
        let view = CGSize(width: 640, height: 360)
        let content = CGSize(width: 1920, height: 1080)
        let rect = MeshLetterbox.contentRect(viewSize: view, contentSize: content)
        #expect(rect == CGRect(x: 0, y: 0, width: 640, height: 360))
        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 0.1, y: 359.9),
                                                 viewSize: view, contentSize: content),
                   0.0, 0.0)
        expectNear(MeshLetterbox.normalizedPoint(CGPoint(x: 639.9, y: 0.1),
                                                 viewSize: view, contentSize: content),
                   1.0, 1.0)
    }

    @Test("Degenerate sizes map nothing")
    func degenerate() {
        let view = CGSize(width: 400, height: 400)
        #expect(MeshLetterbox.contentRect(viewSize: view, contentSize: .zero) == .zero)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 10, y: 10),
                                              viewSize: view, contentSize: .zero) == nil)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: 10, y: 10),
                                              viewSize: .zero,
                                              contentSize: CGSize(width: 100, height: 100)) == nil)
        #expect(MeshLetterbox.normalizedPoint(CGPoint(x: .nan, y: 10),
                                              viewSize: view,
                                              contentSize: CGSize(width: 100, height: 100)) == nil)
    }

    @Test("Capture stream size: capped at 1920×1080, aspect kept, dimensions even")
    func streamSize() {
        var size = RealScreenCapture.streamSize(width: 1920, height: 1080)
        #expect(size.width == 1920 && size.height == 1080)
        size = RealScreenCapture.streamSize(width: 3840, height: 2160)
        #expect(size.width == 1920 && size.height == 1080)
        size = RealScreenCapture.streamSize(width: 2560, height: 1440)
        #expect(size.width == 1920 && size.height == 1080)
        size = RealScreenCapture.streamSize(width: 1280, height: 720)
        #expect(size.width == 1280 && size.height == 720)
        // Ultrawide: width-limited, height follows the aspect.
        size = RealScreenCapture.streamSize(width: 3440, height: 1440)
        #expect(size.width == 1920 && size.height == 802)
        // Odd dimensions are forced even (the encoder's rule).
        size = RealScreenCapture.streamSize(width: 1365, height: 767)
        #expect(size.width == 1364 && size.height == 766)
        size = RealScreenCapture.streamSize(width: 0, height: 0)
        #expect(size.width == 2 && size.height == 2)
    }

    @Test("NSEvent modifier flags map onto the codec's modifier bits")
    func modifierMapping() {
        #expect(meshInputModifiers(from: []) == [])
        #expect(meshInputModifiers(from: [.shift, .command]) == [.shift, .command])
        #expect(meshInputModifiers(from: [.control, .option, .capsLock])
                == [.control, .option, .capsLock])
        // Function / numeric-pad flags are not modifier state.
        #expect(meshInputModifiers(from: [.function, .numericPad]) == [])
    }
}
