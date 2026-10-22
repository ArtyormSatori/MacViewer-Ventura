import Foundation
import SwiftUI

/// The logic behind the personal-server frame in Settings →
/// Self-hosted (redesign spec §3.4): the ONLY place in the app where
/// a server address can be configured. Kept separate from the view
/// so the test-before-you-save rule is unit-testable: a failed (or
/// stale) connection test saves nothing, ever.
@MainActor
final class MeshServerSettingsModel: ObservableObject {
    enum Selection: Equatable {
        case `default`
        case custom
    }

    enum TestState: Equatable {
        /// The draft address cannot even be normalized.
        case invalidAddress
        case finished(MeshConnectionTestOutcome)
    }

    /// Which server the user is aiming at. Intent only — nothing is
    /// stored until Save (custom) or Use default server is pressed.
    @Published var selection: Selection
    /// The custom address draft. Editing it after a successful test
    /// invalidates that test: what gets saved is always exactly what
    /// was proven reachable.
    @Published var customAddress: String {
        didSet {
            if let testedURL, MeshDefaults.normalizeServerAddress(customAddress) != testedURL {
                testState = nil
            }
        }
    }
    /// Optional invite for the custom server. Not persisted as a
    /// standing value: on save it becomes the one-shot pending
    /// invite the next registration consumes (MeshDefaults).
    @Published var inviteCode: String = ""
    @Published private(set) var testState: TestState?
    @Published private(set) var isTesting = false
    @Published private(set) var note: String?
    /// The configuration actually in effect, refreshed on save/reset.
    @Published private(set) var current: MeshServerConfiguration

    private var testedURL: URL?
    private let defaults: UserDefaults
    private let tester: any MeshServerConnectionTesting

    init(defaults: UserDefaults = .standard,
         tester: any MeshServerConnectionTesting = MeshHealthConnectionTester()) {
        self.defaults = defaults
        self.tester = tester
        let configuration = MeshDefaults.configuration(in: defaults)
        self.current = configuration
        switch configuration {
        case .default:
            self.selection = .default
            self.customAddress = ""
        case .custom(let url):
            self.selection = .custom
            self.customAddress = url.absoluteString
        }
    }

    /// True only when the current draft is byte-for-byte the address
    /// a successful test just proved reachable.
    var canSave: Bool {
        guard selection == .custom,
              case .finished(.reachable) = testState,
              let testedURL else { return false }
        return MeshDefaults.normalizeServerAddress(customAddress) == testedURL
    }

    /// Plain-text rendering of the last test: what was actually
    /// proven, or the precise failure — nothing more.
    var testMessage: String? {
        switch testState {
        case nil: return nil
        case .invalidAddress:
            return L("That address is not usable. Enter a host, a host:port, or a full URL.")
        case .finished(.reachable(let milliseconds)):
            return LF("Server reachable · %d ms", milliseconds)
        case .finished(.unreachable):
            return L("Could not reach a server at this address. Check the address and that the server is running.")
        case .finished(.inviteRequired):
            return L("This server requires an invite code to register a new device.")
        }
    }

    /// Probes the draft address. The result is reported, never saved.
    func testConnection() async {
        guard !isTesting else { return }
        note = nil
        guard let url = MeshDefaults.normalizeServerAddress(customAddress) else {
            testedURL = nil
            testState = .invalidAddress
            return
        }
        isTesting = true
        defer { isTesting = false }
        let outcome = await tester.testConnection(to: url)
        // The user may have edited the draft while the probe was in
        // flight; a result for an address no longer in the field is
        // discarded rather than shown (Save is guarded by `canSave`
        // either way, but the message must never describe a test the
        // user is no longer looking at).
        guard MeshDefaults.normalizeServerAddress(customAddress) == url else {
            testedURL = nil
            testState = nil
            return
        }
        testedURL = url
        testState = .finished(outcome)
    }

    /// Applies the tested custom server. Applies from the next
    /// Mode 2 connection (the session model's server-change path
    /// re-registers); it never rewrites a server mid-flight beyond
    /// that existing path. Saves nothing when `canSave` is false.
    func saveAndSwitch() {
        guard canSave, let url = testedURL else { return }
        MeshDefaults.setCustomServer(url, in: defaults)
        let invite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !invite.isEmpty {
            defaults.set(invite, forKey: MeshDefaults.pendingInviteKey)
        }
        current = .custom(url)
        note = L("Saved. This server will be used from the next Mode 2 connection.")
    }

    /// Resets to the built-in default server. Pairings are stored
    /// per server and are kept on both sides of the switch.
    func useDefaultServer() {
        MeshDefaults.useDefaultServer(in: defaults)
        selection = .default
        current = .default
        note = L("The default server is in use.")
    }
}

/// The personal-server frame itself (spec §3.4): since Part 2 it
/// is the Server group of the Settings sidebar's Self-hosted pane.
/// Button audit (§1.8): the mode picker's "Default server" choice
/// IS the reset — choosing it while a custom server is in effect
/// applies `useDefaultServer()` — so the frame carries no second,
/// duplicate "Use default server" button.
struct MeshServerSettingsSection: View {
    @StateObject private var frame = MeshServerSettingsModel()

    var body: some View {
        Section("Server") {
            LabeledContent("Server in use") {
                Text(currentText).foregroundStyle(.secondary)
            }
            Text("The server only introduces devices to each other. Your screen and input stay end-to-end encrypted between the two devices, so the server never sees a session. Pairings belong to the server in use, so switching servers means pairing again on the new server — pairings on the old server are kept.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Server", selection: $frame.selection) {
                Text("Default server").tag(MeshServerSettingsModel.Selection.default)
                Text("Custom server").tag(MeshServerSettingsModel.Selection.custom)
            }
            .onChange(of: frame.selection) { newSelection in
                // The choice applies the reset itself (§1.8: an
                // action that exists as a mode choice is never
                // repeated as a separate button). Choosing Custom
                // only reveals the draft fields; it saves nothing.
                if newSelection == .default, frame.current.isCustom {
                    frame.useDefaultServer()
                }
            }
            if frame.selection == .custom {
                TextField("Server address", text: $frame.customAddress,
                          prompt: Text("mesh.example.com:8734"))
                    .textFieldStyle(.roundedBorder)
                TextField("Invite code", text: $frame.inviteCode,
                          prompt: Text("Optional"))
                    .textFieldStyle(.roundedBorder)
                Text("Only needed when your server requires one for a first registration.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Test connection") { Task { await frame.testConnection() } }
                        .disabled(frame.isTesting
                                  || frame.customAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    if frame.isTesting {
                        ProgressView().controlSize(.small)
                        Text("Testing connection…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = frame.testMessage {
                    Text(message).font(.caption)
                        .foregroundStyle(isTestSuccess ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Save and switch to this server") { frame.saveAndSwitch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!frame.canSave)
                Text("Save is enabled after a successful connection test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Switching servers changes which pairings you see. Pairings on the other server are kept and come back when you switch back.")
                .font(.caption).foregroundStyle(.secondary)
            if let note = frame.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text("Changes apply the next time Mode 2 connects.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Create your own server") {
            Text("1. Get the server program: the mesh-server package that ships with the project (see SELF_HOSTING.md).")
                .font(.caption).foregroundStyle(.secondary)
            Text("2. Run it on a machine that stays on — a home computer, a NAS, or a small VPS — and note its address and an invite code.")
                .font(.caption).foregroundStyle(.secondary)
            Text("3. Come back here, enter the address and invite code above, then press Test connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var currentText: String {
        switch frame.current {
        case .default:
            return L("Default server") + " · " + (MeshDefaults.serverURL.host ?? "")
        case .custom(let url):
            return L("Custom server") + " · " + (url.host ?? url.absoluteString)
        }
    }

    private var isTestSuccess: Bool {
        if case .finished(.reachable) = frame.testState { return true }
        return false
    }
}
