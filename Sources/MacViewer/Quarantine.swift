import Darwin
import Foundation

/// Gatekeeper assesses apps that carry the `com.apple.quarantine` extended
/// attribute. A copy this app staged itself — from a checksum-verified
/// download — must not inherit that marker, or every self-update would end
/// at the "unidentified developer" prompt.
enum Quarantine {
    static let attributeName = "com.apple.quarantine"

    static func isPresent(at url: URL) -> Bool {
        getxattr(url.path, attributeName, nil, 0, 0, 0) >= 0
    }

    /// Removes the attribute from `root` and everything inside it. Items
    /// without the attribute are ignored; the walk covers files and folders.
    static func strip(from root: URL) {
        var targets = [root]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { targets.append(url) }
        }
        for url in targets { _ = removexattr(url.path, attributeName, 0) }
    }
}
