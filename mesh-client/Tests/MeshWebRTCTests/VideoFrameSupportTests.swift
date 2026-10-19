import XCTest
import MeshClient
import MeshWebRTC

/// Tests for the pure video-plane helpers (`MeshVideoGeometry`,
/// `SyntheticFramePalette`, and the outbound-codec stats
/// selection). These run on every platform, including Linux —
/// they pin the math the macOS video path and its end-to-end
/// tests are built on, so a wrong constant fails here first,
/// not in a CI-only media test.
final class VideoFrameSupportTests: XCTestCase {

    // MARK: - Geometry

    func testBGRAGeometry() {
        XCTAssertEqual(MeshVideoGeometry.bgraRowBytes(width: 320), 1280)
        XCTAssertEqual(MeshVideoGeometry.bgraRowBytes(width: 1), 4)
        XCTAssertEqual(MeshVideoGeometry.bgraFrameBytes(width: 320, height: 180), 230_400)
        XCTAssertEqual(MeshVideoGeometry.bgraFrameBytes(width: 1920, height: 1080), 8_294_400)
    }

    func testNV12Geometry() {
        // Even height: luma + exactly half again.
        XCTAssertEqual(MeshVideoGeometry.nv12FrameBytes(width: 320, height: 180), 86_400)
        XCTAssertEqual(MeshVideoGeometry.nv12FrameBytes(width: 2, height: 2), 6)
        // Odd height: the chroma plane rounds up a row.
        XCTAssertEqual(MeshVideoGeometry.nv12FrameBytes(width: 320, height: 181), 87_040)
    }

    // MARK: - Timestamps

    func testNanosecondConversion() {
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 0, timescale: 600), 0)
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 600, timescale: 600), 1_000_000_000)
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 300, timescale: 600), 500_000_000)
        // 1001/600 s — the remainder term must stay exact.
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 1001, timescale: 600), 1_668_333_333)
        // One hour at a 1 MHz timescale: no overflow, exact.
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 3_600_000_000, timescale: 1_000_000),
                       3_600_000_000_000)
        // Degenerate inputs clamp to zero, never trap.
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: -42, timescale: 600), 0)
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 42, timescale: 0), 0)
        XCTAssertEqual(MeshVideoGeometry.nanoseconds(value: 42, timescale: -600), 0)
    }

    // MARK: - Palette

    func testPaletteLumasAreMaximallySeparated() {
        let lumas = SyntheticFramePalette.colors.map(\.luma)
        XCTAssertEqual(lumas, [0, 29, 76, 105, 149, 178, 225, 255])
        // The invariant the classifier's ±12 tolerance rests
        // on: every neighbouring pair is at least 29 apart.
        for (a, b) in zip(lumas, lumas.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 29)
        }
    }

    func testPaletteIndexingWraps() {
        let colors = SyntheticFramePalette.colors
        XCTAssertEqual(SyntheticFramePalette.color(forFrameIndex: 0), colors[0])
        XCTAssertEqual(SyntheticFramePalette.color(forFrameIndex: 7), colors[7])
        XCTAssertEqual(SyntheticFramePalette.color(forFrameIndex: 8), colors[0])
        XCTAssertEqual(SyntheticFramePalette.color(forFrameIndex: 11), colors[3])
        XCTAssertEqual(SyntheticFramePalette.color(forFrameIndex: -1), colors[7])
    }

    func testPaletteClassification() {
        // Every slot classifies back to itself, exactly and
        // with lossy-codec-sized perturbations.
        for (slot, color) in SyntheticFramePalette.colors.enumerated() {
            XCTAssertEqual(SyntheticFramePalette.classify(luma: color.luma), slot)
            XCTAssertEqual(SyntheticFramePalette.classify(luma: color.luma + 10), slot)
            XCTAssertEqual(SyntheticFramePalette.classify(luma: color.luma - 10), slot)
        }
        // Between slots (blue 29 / red 76): outside tolerance
        // of both — reported unclassifiable, never guessed.
        XCTAssertNil(SyntheticFramePalette.classify(luma: 45))
        XCTAssertNil(SyntheticFramePalette.classify(luma: -20))
        // A custom tolerance is honoured.
        XCTAssertNil(SyntheticFramePalette.classify(luma: 40, tolerance: 5))
        XCTAssertEqual(SyntheticFramePalette.classify(luma: 40, tolerance: 12), 1)
    }

    // MARK: - Outbound codec selection

    private func entry(_ id: String, _ type: String,
                       _ values: [String: JSONValue]) -> MeshStatsEntry {
        MeshStatsEntry(id: id, type: type, values: values)
    }

    func testOutboundVideoCodecResolvesThroughCodecID() {
        let stats = [
            entry("C1", "codec", ["mimeType": .string("video/H264")]),
            entry("O1", "outbound-rtp", ["kind": .string("video"),
                                          "codecId": .string("C1")]),
        ]
        XCTAssertEqual(MeshStatsSelection.outboundVideoCodecMimeType(in: stats),
                       "video/H264")
    }

    func testOutboundVideoCodecIgnoresAudioAndDanglingReferences() {
        // An audio stream's codec does not count as video.
        let audioOnly = [
            entry("C2", "codec", ["mimeType": .string("audio/opus")]),
            entry("O2", "outbound-rtp", ["kind": .string("audio"),
                                          "codecId": .string("C2")]),
        ]
        XCTAssertNil(MeshStatsSelection.outboundVideoCodecMimeType(in: audioOnly))

        // A codecId pointing at a missing codec entry resolves
        // to nil, not a guess.
        let dangling = [
            entry("O3", "outbound-rtp", ["kind": .string("video"),
                                          "codecId": .string("missing")]),
        ]
        XCTAssertNil(MeshStatsSelection.outboundVideoCodecMimeType(in: dangling))

        // No outbound stream yet: nil.
        XCTAssertNil(MeshStatsSelection.outboundVideoCodecMimeType(in: []))
    }

    func testOutboundVideoCodecAcceptsLegacyMediaTypeKey() {
        let stats = [
            entry("C4", "codec", ["mimeType": .string("video/VP8")]),
            entry("O4", "outbound-rtp", ["mediaType": .string("video"),
                                          "codecId": .string("C4")]),
        ]
        XCTAssertEqual(MeshStatsSelection.outboundVideoCodecMimeType(in: stats),
                       "video/VP8")
    }
}
