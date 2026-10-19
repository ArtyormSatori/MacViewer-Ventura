import Foundation
import Testing

/// Mechanical checks for the integrated S3 app icon (5.0, UI spec
/// §9 item 6). The icon ships prebuilt: `scripts/AppIcon.appiconset`
/// is the canonical PNG set and `scripts/MacViewer.icns` is the
/// artifact `scripts/package_app.sh` installs as
/// `Contents/Resources/MacViewer.icns`. These tests read the repo
/// tree (the same `#filePath` pattern as the G722 fixture tests),
/// so they run wherever the package is checked out, and they pin
/// the two artifacts together so one cannot drift from the other.
struct AppIconTests {

    // MARK: - Locations

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MacViewerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    private var iconset: URL {
        packageRoot.appendingPathComponent("scripts/AppIcon.appiconset")
    }

    private var icnsFile: URL {
        packageRoot.appendingPathComponent("scripts/MacViewer.icns")
    }

    // MARK: - Contents.json

    private struct Catalog: Decodable {
        struct Image: Decodable {
            let filename: String
            let idiom: String
            let scale: String
            let size: String
        }
        let images: [Image]
    }

    private func catalog() throws -> Catalog {
        let data = try Data(contentsOf: iconset.appendingPathComponent("Contents.json"))
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    @Test("Contents.json declares exactly the ten mac icon sizes")
    func catalogDeclaresTheTenMacSizes() throws {
        let catalog = try catalog()
        #expect(catalog.images.count == 10)
        var seen: Set<String> = []
        for image in catalog.images {
            #expect(image.idiom == "mac")
            let points = try #require(Int(image.size.split(separator: "x").first ?? ""))
            #expect(image.size == "\(points)x\(points)")
            #expect(image.scale == "1x" || image.scale == "2x")
            let suffix = image.scale == "2x" ? "@2x" : ""
            #expect(image.filename == "icon_\(points)x\(points)\(suffix).png",
                    "Unexpected filename for \(image.size)@\(image.scale): \(image.filename)")
            #expect(seen.insert("\(points)@\(image.scale)").inserted,
                    "Duplicate declaration: \(image.size)@\(image.scale)")
        }
        #expect(seen == ["16@1x", "16@2x", "32@1x", "32@2x", "128@1x", "128@2x",
                         "256@1x", "256@2x", "512@1x", "512@2x"])
    }

    @Test("Every declared icon file exists and its pixels match the declaration")
    func declaredFilesExistWithMatchingPixels() throws {
        for image in try catalog().images {
            let url = iconset.appendingPathComponent(image.filename)
            let data = try Data(contentsOf: url)
            let dimensions = try #require(pngDimensions(data),
                                          "Not a PNG: \(image.filename)")
            let points = try #require(Int(image.size.split(separator: "x").first ?? ""))
            let scale = image.scale == "2x" ? 2 : 1
            #expect(dimensions.width == points * scale,
                    "\(image.filename): width \(dimensions.width) != \(points * scale)")
            #expect(dimensions.height == points * scale,
                    "\(image.filename): height \(dimensions.height) != \(points * scale)")
        }
    }

    // MARK: - MacViewer.icns

    /// One parsed icns entry: the four-character type plus its payload.
    private struct IcnsEntry {
        let type: String
        let payload: Data
    }

    private func icnsEntries() throws -> [IcnsEntry] {
        let data = try Data(contentsOf: icnsFile)
        let bytes = [UInt8](data)
        #expect(bytes.count >= 8)
        #expect(String(bytes: bytes[0..<4], encoding: .ascii) == "icns")
        #expect(bigEndian32(bytes, at: 4) == bytes.count,
                "icns header length must equal the file size")
        var entries: [IcnsEntry] = []
        var offset = 8
        while offset < bytes.count {
            let type = try #require(String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii))
            let length = bigEndian32(bytes, at: offset + 4)
            #expect(length >= 8 && offset + length <= bytes.count,
                    "Malformed icns entry \(type) at \(offset)")
            entries.append(IcnsEntry(type: type,
                                     payload: Data(bytes[(offset + 8)..<(offset + length)])))
            offset += length
        }
        #expect(offset == bytes.count, "icns entries must end exactly at EOF")
        return entries
    }

    /// Canonical pixel size for each icns entry type used by this icon.
    private static let icnsPixelSizes: [(type: String, pixels: Int, iconsetFile: String)] = [
        ("icp4", 16, "icon_16x16.png"),
        ("icp5", 32, "icon_16x16@2x.png"),
        ("icp6", 64, "icon_32x32@2x.png"),
        ("ic07", 128, "icon_128x128.png"),
        ("ic08", 256, "icon_128x128@2x.png"),
        ("ic09", 512, "icon_256x256@2x.png"),
        ("ic10", 1024, "icon_512x512@2x.png"),
    ]

    @Test("MacViewer.icns parses and contains the seven expected PNG entries")
    func icnsParsesWithExpectedEntries() throws {
        let entries = try icnsEntries()
        #expect(entries.map(\.type) == Self.icnsPixelSizes.map(\.type))
        for (entry, expected) in zip(entries, Self.icnsPixelSizes) {
            let dimensions = try #require(pngDimensions(entry.payload),
                                          "icns entry \(entry.type) is not a PNG")
            #expect(dimensions.width == expected.pixels,
                    "icns \(entry.type): width \(dimensions.width) != \(expected.pixels)")
            #expect(dimensions.height == expected.pixels,
                    "icns \(entry.type): height \(dimensions.height) != \(expected.pixels)")
        }
    }

    @Test("Every icns payload is byte-identical to its iconset PNG")
    func icnsPayloadsEqualIconsetPNGs() throws {
        let entries = try icnsEntries()
        #expect(entries.count == Self.icnsPixelSizes.count)
        for (entry, expected) in zip(entries, Self.icnsPixelSizes) {
            let fileData = try Data(contentsOf: iconset.appendingPathComponent(expected.iconsetFile))
            #expect(entry.payload == fileData,
                    "icns \(entry.type) payload differs from \(expected.iconsetFile)")
        }
    }

    // MARK: - Packaging path

    @Test("The packaging script installs the vendored icon as the bundle icon")
    func packagingInstallsTheVendoredIcon() throws {
        #expect(FileManager.default.fileExists(atPath: icnsFile.path),
                "scripts/MacViewer.icns (the packaging input) is missing")
        let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/package_app.sh"),
                                encoding: .utf8)
        // The script copies the vendored file to the bundle destination
        // that CFBundleIconFile names and that MacPermissionsSetup
        // loads at runtime.
        #expect(script.contains("scripts/MacViewer.icns"))
        #expect(script.contains("Contents/Resources/MacViewer.icns"))
        #expect(script.contains("<key>CFBundleIconFile</key><string>MacViewer.icns</string>"))
        // The pre-S3 procedural generator is retired, not bypassed.
        #expect(!script.contains("make_app_icon"))
        #expect(!FileManager.default.fileExists(
            atPath: packageRoot.appendingPathComponent("scripts/make_app_icon.swift").path))
    }

    // MARK: - Byte helpers

    private func bigEndian32(_ bytes: [UInt8], at offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    /// Width/height from a PNG's IHDR chunk; nil if the data is not a PNG.
    private func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 24,
              Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR"
        else { return nil }
        return (bigEndian32(bytes, at: 16), bigEndian32(bytes, at: 20))
    }
}
