import Foundation
import Testing
@testable import MacViewer

@Test func updateVersionsCompareNumerically() {
    #expect(UpdateChecker.isVersion("0.3.2", newerThan: "0.3.1"))
    #expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.9"))
    #expect(UpdateChecker.isVersion("1.0", newerThan: "0.99.99"))
    #expect(UpdateChecker.isVersion("0.3.1.1", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3.1", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3", newerThan: "0.3.0"))
    #expect(!UpdateChecker.isVersion("0.3.0", newerThan: "0.3.1"))
    #expect(!UpdateChecker.isVersion("0.3.2-beta", newerThan: "0.3.2"))
}

@Test func updateReleaseParsingPicksTheDMGAndStripsTheTagPrefix() throws {
    let json = """
    {"tag_name": "v0.3.2", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.3.2",
     "draft": false, "prerelease": false,
     "assets": [
       {"name": "MacViewer-0.3.2.zip", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/MacViewer-0.3.2.zip"},
       {"name": "MacViewer-0.3.2.dmg", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/MacViewer-0.3.2.dmg"},
       {"name": "SHA256SUMS.txt", "browser_download_url": "https://github.com/DeanOpen/MacViewer/releases/download/v0.3.2/SHA256SUMS.txt"}
     ]}
    """
    let release = try UpdateChecker.parseRelease(Data(json.utf8))
    #expect(release.version == "0.3.2")
    #expect(release.dmgURL?.lastPathComponent == "MacViewer-0.3.2.dmg")
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.3.2"))
}

@Test func updateReleaseParsingRejectsPrereleasesAndForeignDownloadHosts() {
    let prerelease = """
    {"tag_name": "v0.4.0-beta", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.4.0-beta",
     "prerelease": true, "assets": []}
    """
    #expect(throws: (any Error).self) { try UpdateChecker.parseRelease(Data(prerelease.utf8)) }
    let foreign = """
    {"tag_name": "v0.3.2", "html_url": "https://github.com/DeanOpen/MacViewer/releases/tag/v0.3.2",
     "assets": [{"name": "MacViewer-0.3.2.dmg", "browser_download_url": "https://example.com/MacViewer-0.3.2.dmg"}]}
    """
    #expect(throws: (any Error).self) { try UpdateChecker.parseRelease(Data(foreign.utf8)) }
}

@MainActor
@Test func automaticUpdateChecksRespectTheSetting() throws {
    let suite = "UpdateCheckerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let checker = UpdateChecker(currentVersion: "0.3.2", defaults: defaults)
    defaults.set(false, forKey: UpdateChecker.automaticKey)
    checker.checkAutomatically()
    #expect(checker.state == .idle)
}

@Test func updateNotesDropTheInstallSection() {
    let body = """
    ## Install
    1. Download the DMG.
    2. Drag MacViewer to Applications.

    ## What's Changed
    * Close connections when quitting
    """
    #expect(UpdateChecker.releaseNotes(body) == "## What's Changed\n* Close connections when quitting")
    #expect(UpdateChecker.releaseNotes("") == "")
}

@Test func updateVersionsCompareVenturaSuffixes() {
    #expect(UpdateChecker.isVersion("0.3.4-ventura.3", newerThan: "0.3.4-ventura.2"))
    #expect(UpdateChecker.isVersion("0.3.4-ventura.2", newerThan: "0.3.4"))
    #expect(!UpdateChecker.isVersion("0.3.4-ventura.2", newerThan: "0.3.4-ventura.2"))
    #expect(!UpdateChecker.isVersion("0.3.4-ventura.1", newerThan: "0.3.4-ventura.2"))
    #expect(UpdateChecker.isVersion("0.3.5", newerThan: "0.3.4-ventura.9"))
    #expect(UpdateChecker.venturaNumber(of: "0.3.4-ventura.12") == 12)
    #expect(UpdateChecker.venturaNumber(of: "0.3.4") == 0)
    #expect(UpdateChecker.venturaNumber(of: "0.3.4-beta") == 0)
}

@Test func updateReleaseParsingPicksTheChecksumFile() throws {
    let json = """
    {"tag_name": "v0.3.4-ventura.3", "html_url": "https://github.com/ArtyormSatori/MacViewer-Ventura/releases/tag/v0.3.4-ventura.3",
     "draft": false, "prerelease": false,
     "assets": [
       {"name": "MacViewer-0.3.4-Ventura.dmg", "browser_download_url": "https://github.com/ArtyormSatori/MacViewer-Ventura/releases/download/v0.3.4-ventura.3/MacViewer-0.3.4-Ventura.dmg"},
       {"name": "SHA256SUMS-Ventura.txt", "browser_download_url": "https://github.com/ArtyormSatori/MacViewer-Ventura/releases/download/v0.3.4-ventura.3/SHA256SUMS-Ventura.txt"}
     ]}
    """
    let release = try UpdateChecker.parseRelease(Data(json.utf8))
    #expect(release.version == "0.3.4-ventura.3")
    #expect(release.sumsURL?.lastPathComponent == "SHA256SUMS-Ventura.txt")
}

@Test func updateChecksumLookupParsesSHA256SumsOutput() {
    let hashA = String(repeating: "a", count: 64)
    let hashB = String(repeating: "b", count: 64)
    let sums = "\(hashA)  MacViewer-0.3.4-Ventura.dmg\n\(hashB) *MacViewer-0.3.4-Ventura.zip\n"
    #expect(UpdateChecker.expectedHash(in: sums, forFile: "MacViewer-0.3.4-Ventura.dmg") == hashA)
    #expect(UpdateChecker.expectedHash(in: sums, forFile: "MacViewer-0.3.4-Ventura.zip") == hashB)
    #expect(UpdateChecker.expectedHash(in: sums, forFile: "MacViewer-0.3.4-Ventura.pkg") == nil)
    #expect(UpdateChecker.expectedHash(in: "not-a-hash  file.dmg", forFile: "file.dmg") == nil)
}

@Test func updateSHA256OfFileMatchesTheKnownVector() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha256-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try UpdateChecker.sha256Hex(ofFile: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
