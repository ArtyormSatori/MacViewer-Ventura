import Darwin
import Foundation
import Testing
@testable import MacViewer

@Test func quarantineStripRemovesTheAttributeRecursively() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuarantineTests-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("MacViewer")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = "0081;00000000;MacViewerTests;"
    for url in [root, file] {
        let status = value.withCString {
            setxattr(url.path, "com.apple.quarantine", UnsafeRawPointer($0), strlen($0), 0, 0)
        }
        #expect(status == 0)
    }
    #expect(Quarantine.isPresent(at: root))
    #expect(Quarantine.isPresent(at: file))
    Quarantine.strip(from: root)
    #expect(!Quarantine.isPresent(at: root))
    #expect(!Quarantine.isPresent(at: file))
}
