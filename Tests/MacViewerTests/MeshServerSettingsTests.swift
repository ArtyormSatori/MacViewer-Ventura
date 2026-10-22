import Foundation
import MeshClient
import Testing
@testable import MacViewer

/// The personal-server frame's rules (redesign spec §3.4): test
/// before you save, a failed test saves nothing, and per-server
/// pairings survive a switch and back.
@MainActor
struct MeshServerSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MeshServerSettingsTests-\(UUID().uuidString)")!
    }

    @Test("A successful test enables saving, and saving stores the override in both keys")
    func successfulTestThenSave() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 42))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        await frame.testConnection()
        #expect(tester.testedURLs == [URL(string: "http://vega.lan:8734")!])
        #expect(frame.testMessage?.contains("42") == true)
        #expect(frame.canSave)
        frame.saveAndSwitch()
        let expected = URL(string: "http://vega.lan:8734")!
        #expect(MeshDefaults.configuration(in: defaults) == .custom(expected))
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == expected.absoluteString)
        #expect(defaults.string(forKey: MeshDefaults.serverAddressKey) == expected.absoluteString)
        #expect(frame.current == .custom(expected))
        #expect(frame.note != nil)
    }

    @Test("A failed connection test saves nothing")
    func failedTestSavesNothing() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .unreachable)
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        await frame.testConnection()
        #expect(frame.testMessage != nil)
        #expect(!frame.canSave)
        frame.saveAndSwitch()
        #expect(MeshDefaults.configuration(in: defaults) == .default)
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == nil)
        #expect(defaults.string(forKey: MeshDefaults.serverAddressKey) == nil)
    }

    @Test("An invite-required test outcome is reported in words and still saves nothing")
    func inviteRequiredOutcome() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .inviteRequired)
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        await frame.testConnection()
        #expect(frame.testMessage != nil)
        #expect(!frame.canSave)
        frame.saveAndSwitch()
        #expect(MeshDefaults.configuration(in: defaults) == .default)
    }

    @Test("Editing the address after a successful test invalidates that test")
    func editInvalidatesTest() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 5))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        await frame.testConnection()
        #expect(frame.canSave)
        frame.customAddress = "other.lan:8734"
        #expect(frame.testState == nil)
        #expect(!frame.canSave)
        frame.saveAndSwitch()
        #expect(MeshDefaults.configuration(in: defaults) == .default)
    }

    @Test("An unusable address never reaches the tester")
    func invalidAddressSkipsProbe() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 5))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "ftp://example.com"
        await frame.testConnection()
        #expect(frame.testState == .invalidAddress)
        #expect(tester.testedURLs.isEmpty)
        #expect(!frame.canSave)
    }

    @Test("Saving stores a typed invite as the one-shot pending invite")
    func saveStoresPendingInvite() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 5))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        frame.inviteCode = "INV-9"
        await frame.testConnection()
        frame.saveAndSwitch()
        #expect(defaults.string(forKey: MeshDefaults.pendingInviteKey) == "INV-9")
    }

    @Test("A deliberate loopback entered in the frame is respected, unlike the migrated placeholder")
    func deliberateLoopbackRespected() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 1))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "127.0.0.1:18734"
        await frame.testConnection()
        frame.saveAndSwitch()
        #expect(MeshDefaults.configuration(in: defaults)
                == .custom(MeshDefaults.legacyDevelopmentServerURL))
    }

    @Test("Reset returns to the default server and clears both stored keys")
    func resetToDefault() async {
        let defaults = makeDefaults()
        MeshDefaults.setCustomServer(URL(string: "http://vega.lan:8734")!, in: defaults)
        let frame = MeshServerSettingsModel(defaults: defaults,
                                            tester: FakeConnectionTester(outcome: .unreachable))
        #expect(frame.selection == .custom)
        #expect(frame.current.isCustom)
        frame.useDefaultServer()
        #expect(frame.selection == .default)
        #expect(frame.current == .default)
        #expect(MeshDefaults.configuration(in: defaults) == .default)
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == nil)
        #expect(defaults.string(forKey: MeshDefaults.serverAddressKey) == nil)
    }

    @Test("Saving without any test writes nothing")
    func saveWithoutTestWritesNothing() {
        let defaults = makeDefaults()
        let frame = MeshServerSettingsModel(defaults: defaults,
                                            tester: FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 1)))
        frame.selection = .custom
        frame.customAddress = "vega.lan:8734"
        #expect(!frame.canSave)
        frame.saveAndSwitch()
        #expect(MeshDefaults.configuration(in: defaults) == .default)
        #expect(defaults.string(forKey: MeshDefaults.serverOverrideKey) == nil)
    }

    @Test("A whitespace-only address is invalid input and never reaches the tester")
    func whitespaceAddressIsInvalid() async {
        let defaults = makeDefaults()
        let tester = FakeConnectionTester(outcome: .reachable(latencyMilliseconds: 1))
        let frame = MeshServerSettingsModel(defaults: defaults, tester: tester)
        frame.selection = .custom
        frame.customAddress = "   \n\t "
        await frame.testConnection()
        #expect(frame.testState == .invalidAddress)
        #expect(tester.testedURLs.isEmpty)
    }

    @Test("The frame opens on the migrated state: legacy custom shown, legacy loopback shown as default")
    func frameOpensOnMigratedState() {
        let legacyCustom = makeDefaults()
        legacyCustom.set("mesh.example.com:9000", forKey: MeshDefaults.serverAddressKey)
        let frameA = MeshServerSettingsModel(defaults: legacyCustom,
                                             tester: FakeConnectionTester(outcome: .unreachable))
        #expect(frameA.selection == .custom)
        #expect(frameA.customAddress == "http://mesh.example.com:9000")
        #expect(frameA.current == .custom(URL(string: "http://mesh.example.com:9000")!))

        let legacyLoopback = makeDefaults()
        legacyLoopback.set("127.0.0.1:18734", forKey: MeshDefaults.serverAddressKey)
        let frameB = MeshServerSettingsModel(defaults: legacyLoopback,
                                             tester: FakeConnectionTester(outcome: .unreachable))
        #expect(frameB.selection == .default)
        #expect(frameB.current == .default)
    }

    @Test("Pairing records survive a server switch and back (stored per server)")
    func pairingRecordsSurviveSwitch() {
        let defaults = makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshServerSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = MeshID(unchecked: "111222333")
        // Pair while the default server is in effect.
        FilePairingRecord(directory: directory,
                          server: MeshDefaults.configuration(in: defaults).url).notePaired(peer)
        // Switch to a custom server: its list is separate and empty.
        MeshDefaults.setCustomServer(URL(string: "http://vega.lan:8734")!, in: defaults)
        #expect(FilePairingRecord(directory: directory,
                                  server: MeshDefaults.configuration(in: defaults).url)
            .pairedDevices().isEmpty)
        // Switch back: the default server's pairings are intact.
        MeshDefaults.useDefaultServer(in: defaults)
        #expect(FilePairingRecord(directory: directory,
                                  server: MeshDefaults.configuration(in: defaults).url)
            .pairedDevices() == [peer])
    }
}

/// Production-tester behavior with the network replaced by a stub:
/// it may only ever claim reachable (with a measured latency) or
/// unreachable — never an invite or policy claim.
struct MeshHealthConnectionTesterTests {
    @Test("A passing health probe reports reachable with a measured latency")
    func reachable() async {
        let tester = MeshHealthConnectionTester(healthCheck: { _ in true })
        let outcome = await tester.testConnection(to: URL(string: "http://vega.lan:8734")!)
        guard case .reachable(let milliseconds) = outcome else {
            Issue.record("expected reachable, got \(outcome)")
            return
        }
        #expect(milliseconds >= 0)
    }

    @Test("A failing health probe reports unreachable, nothing more specific")
    func unreachable() async {
        let tester = MeshHealthConnectionTester(healthCheck: { _ in false })
        let outcome = await tester.testConnection(to: URL(string: "http://vega.lan:8734")!)
        #expect(outcome == .unreachable)
    }
}

private final class FakeConnectionTester: MeshServerConnectionTesting, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: MeshConnectionTestOutcome
    private(set) var testedURLs: [URL] = []

    init(outcome: MeshConnectionTestOutcome) { self.outcome = outcome }

    func testConnection(to url: URL) async -> MeshConnectionTestOutcome {
        lock.withLock { testedURLs.append(url) }
        return outcome
    }
}
