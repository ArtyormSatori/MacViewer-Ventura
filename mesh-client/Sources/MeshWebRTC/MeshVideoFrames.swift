import Foundation

/// Pure, platform-independent helpers for the MeshWebRTC video
/// plane: frame geometry math, rational-timestamp conversion,
/// and the synthetic-frame palette the end-to-end video tests
/// use to prove real media flowed (a received frame's content
/// must classify back to a palette slot a sender actually
/// painted). Nothing here touches WebRTC, CoreVideo or
/// ScreenCaptureKit, so all of it is unit-tested on every
/// platform, including Linux.
public enum MeshVideoGeometry {

    /// Bytes per row of a tightly packed 32BGRA frame.
    public static func bgraRowBytes(width: Int) -> Int {
        width * 4
    }

    /// Total bytes of a tightly packed 32BGRA frame.
    public static func bgraFrameBytes(width: Int, height: Int) -> Int {
        bgraRowBytes(width: width) * height
    }

    /// Total bytes of an NV12 (bi-planar 4:2:0) frame: the full
    /// luma plane plus a half-height interleaved chroma plane.
    /// An odd height rounds the chroma plane up, matching how
    /// CVPixelBuffer lays out 4:2:0 planes.
    public static func nv12FrameBytes(width: Int, height: Int) -> Int {
        width * height + width * ((height + 1) / 2)
    }

    /// Converts a rational timestamp (value / timescale — the
    /// shape CoreMedia's CMTime carries, and what a
    /// CMSampleBuffer presentation timestamp decomposes into) to
    /// nanoseconds, the unit `RTCVideoFrame.timeStampNs` wants.
    /// Non-positive values and timescales yield zero rather
    /// than a negative timestamp or a divide-by-zero.
    public static func nanoseconds(value: Int64, timescale: Int32) -> Int64 {
        guard timescale > 0, value > 0 else { return 0 }
        // Divide first, then scale the remainder: value * 1e9
        // overflows Int64 for long-running captures in large
        // timescales; this form loses nothing (the remainder
        // term is exact integer arithmetic).
        let scale = Int64(timescale)
        let seconds = value / scale
        let remainder = value % scale
        return seconds * 1_000_000_000 + remainder * 1_000_000_000 / scale
    }
}

/// The eight maximally separated colors the video end-to-end
/// test paints synthetic frames with, one per frame index.
///
/// After an H.264 encode/decode round trip a solid color is
/// NOT bit-exact (4:2:0 chroma subsampling, YUV conversion,
/// quantization), but the luma of a solid region survives
/// within a few counts — and the palette's BT.601 lumas
/// (0, 29, 76, 105, 149, 178, 225, 255) are all ≥ 29 apart,
/// so a received frame's center luma classifies back to the
/// slot it was sent with, with a tolerance of ±12. Honest by
/// construction: this proves real content flowed and survived
/// the codec recognizably — it does not pretend the path is
/// lossless.
public enum SyntheticFramePalette {

    public struct Color: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// BT.601 luma — the Y of the YUV the encoder produces.
        public var luma: Int {
            (299 * Int(red) + 587 * Int(green) + 114 * Int(blue)) / 1000
        }
    }

    public static let colors: [Color] = [
        Color(red: 0, green: 0, blue: 0),          // 0 black   Y=0
        Color(red: 0, green: 0, blue: 255),        // 1 blue    Y=29
        Color(red: 255, green: 0, blue: 0),        // 2 red     Y=76
        Color(red: 255, green: 0, blue: 255),      // 3 magenta Y=105
        Color(red: 0, green: 255, blue: 0),        // 4 green   Y=149
        Color(red: 0, green: 255, blue: 255),      // 5 cyan    Y=178
        Color(red: 255, green: 255, blue: 0),      // 6 yellow  Y=225
        Color(red: 255, green: 255, blue: 255),    // 7 white   Y=255
    ]

    /// The color painted for frame `index`; wraps every eight
    /// frames, and negative indices wrap from the end.
    public static func color(forFrameIndex index: Int) -> Color {
        let count = colors.count
        return colors[((index % count) + count) % count]
    }

    /// The palette slot whose luma is nearest the observed
    /// one, or nil when no slot is within `tolerance` counts —
    /// an unclassifiable frame is reported as such, never
    /// guessed into a slot.
    public static func classify(luma observed: Int, tolerance: Int = 12) -> Int? {
        var best: (slot: Int, distance: Int)?
        for (slot, color) in colors.enumerated() {
            let distance = abs(color.luma - observed)
            guard distance <= tolerance else { continue }
            if let current = best, distance >= current.distance { continue }
            best = (slot, distance)
        }
        return best?.slot
    }
}
