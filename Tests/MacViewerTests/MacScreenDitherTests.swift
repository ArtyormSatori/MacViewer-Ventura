import Foundation
import Testing
@testable import MacViewer

struct MacScreenDitherTests {
    @Test("A mid-gray gradient row dithers between the two nearest 5-bit levels")
    func gradientDithers() throws {
        // One row of RGB(128,128,128). True 5-bit value is 128*31/255 = 15.53,
        // so the Bayer pattern must alternate 15, 16, 15, 16 across x.
        var rgba = Data()
        for _ in 0..<4 { rgba.append(contentsOf: [128, 128, 128, 255]) }
        let result = try MacScreenPixels.rgb555BottomUp(rgbaTopDown: rgba, width: 4, height: 1, bytesPerRow: 16)
        let gray15: UInt16 = 15 << 10 | 15 << 5 | 15
        let gray16: UInt16 = 16 << 10 | 16 << 5 | 16
        var expected = Data()
        for word in [gray15, gray16, gray15, gray16] {
            expected.append(UInt8(truncatingIfNeeded: word))
            expected.append(UInt8(word >> 8))
        }
        #expect(result == expected)
    }

    @Test("Dithering is deterministic: the same frame converts to the same bytes")
    func deterministicOutput() throws {
        var rgba = Data()
        for y in 0..<4 {
            for x in 0..<4 {
                rgba.append(contentsOf: [UInt8(40 + x * 40), UInt8(200 - y * 40), 99, 255])
            }
        }
        let first = try MacScreenPixels.rgb555BottomUp(rgbaTopDown: rgba, width: 4, height: 4, bytesPerRow: 16)
        let second = try MacScreenPixels.rgb555BottomUp(rgbaTopDown: rgba, width: 4, height: 4, bytesPerRow: 16)
        #expect(first == second)
    }

    @Test("Flat black and white stay exact under dithering")
    func extremesAreFixedPoints() throws {
        var rgba = Data()
        for _ in 0..<4 { rgba.append(contentsOf: [0, 0, 0, 255]) }
        for _ in 0..<4 { rgba.append(contentsOf: [255, 255, 255, 255]) }
        // Height 2, bottom-up: the white row (source row 1) lands first.
        let result = try MacScreenPixels.rgb555BottomUp(rgbaTopDown: rgba, width: 4, height: 2, bytesPerRow: 16)
        var expected = Data()
        for _ in 0..<4 { expected.append(contentsOf: [0xff, 0x7f]) }
        for _ in 0..<4 { expected.append(contentsOf: [0x00, 0x00]) }
        #expect(result == expected)
    }
}
