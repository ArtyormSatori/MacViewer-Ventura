import AppKit
import SwiftUI

@main
struct MacViewerApp: App {
    @StateObject private var model = ConnectionModel(adapter: NativeUltraViewerAdapter())
    @StateObject private var hosting = MacHostingModel()
    @StateObject private var capture = RemoteCaptureController()
    @StateObject private var updater = UpdateChecker()
    @NSApplicationDelegateAdaptor(MacViewerAppDelegate.self) private var applicationDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup("MacViewer") {
            ConnectionView(model: model, hosting: hosting, remoteCapture: capture, updater: updater)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear {
                    applicationDelegate.capture = capture
                    applicationDelegate.model = model
                    applicationDelegate.hosting = hosting
                    updater.startAutomaticChecks()
                    if MacHostingModel.unattendedAccessEnabled { hosting.start() }
                }
                .appLanguage()
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates…")) { updater.check(userInitiated: true) }
            }
            CommandMenu(L("Connection")) {
                Button(L("Connect")) { model.connect() }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!model.canConnect)
                Button(L("Disconnect")) { model.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.isSessionActive)
            }
        }

        Settings {
            MacViewerSettings(model: model, hosting: hosting, updater: updater).appLanguage()
        }
    }
}

struct MacViewerSettings: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    @ObservedObject var model: ConnectionModel
    @ObservedObject var hosting: MacHostingModel
    @ObservedObject var updater: UpdateChecker
    @AppStorage(MacHostingModel.unattendedAccessKey) private var unattendedAccess = false
    @AppStorage(MacHostingModel.unattendedControlKey) private var unattendedControl = true
    @AppStorage(MacHostingModel.preventSleepKey) private var preventSleep = true
    @State private var loginItemEnabled = MacLoginItem.isEnabled
    @AppStorage(KeyboardInputMode.defaultsKey) private var keyboardMode = KeyboardInputMode.keycode.rawValue
    @AppStorage(CommandKeyMapping.defaultsKey) private var commandKey = CommandKeyMapping.control.rawValue
    @State private var loginItemError: String?
    @AppStorage(ConnectionModel.rememberPartnersKey) private var rememberPartners = true
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(UpdateChecker.automaticKey) private var checkForUpdates = true
    @AppStorage(SessionToolsModel.shareClipboardKey) private var shareClipboard = true

    var body: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option.rawValue)
                    }
                }
                Text("Language changes apply immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Remember successfully connected partner IDs", isOn: $rememberPartners)
                    .onChange(of: rememberPartners) { enabled in
                        if !enabled { model.clearRecentPartners() }
                    }
                Text("Saved passwords are kept separately in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Recent Partners") { model.clearRecentPartners() }
                    .disabled(model.recentPartners.isEmpty)
                Button("Forget saved passwords", action: model.forgetSavedPasswords)
            }
            Section("Unattended access") {
                Toggle("Allow unattended access to this Mac", isOn: $unattendedAccess)
                    .onChange(of: unattendedAccess) { enabled in
                        if enabled, !hosting.isRunning { hosting.start() }
                    }
                Toggle("Allow control without approval", isOn: $unattendedControl)
                    .disabled(!unattendedAccess)
                Toggle("Open MacViewer at login", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { enabled in
                        Task {
                            do {
                                try await MacLoginItem.setEnabled(enabled)
                                loginItemError = nil
                            } catch {
                                loginItemError = error.localizedDescription
                            }
                            loginItemEnabled = MacLoginItem.isEnabled
                        }
                    }
                Toggle("Keep this Mac awake while sharing", isOn: $preventSleep)
                Text("Anyone who knows this Mac's ID and password can connect without a person approving here. This Mac still verifies the password itself before approving. Grant Screen Recording and Accessibility once so control works unattended.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginItemError {
                    Text("Start at login could not be changed: \(loginItemError)")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Keyboard") {
                Picker("Keyboard input mode", selection: $keyboardMode) {
                    ForEach(KeyboardInputMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Picker("Command (\u{2318}) key sends", selection: $commandKey) {
                    ForEach(CommandKeyMapping.allCases, id: \.rawValue) { mapping in
                        Text(mapping.title).tag(mapping.rawValue)
                    }
                }
                Text("Control makes \u{2318}C / \u{2318}V / \u{2318}X work as Ctrl+C / Ctrl+V / Ctrl+X on the Windows computer; Windows key sends \u{2318} as the Windows key instead. Applies to new sessions.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Applies to new sessions. US keycode matches the remote layout directly. VNI passthrough sends raw keys so a VNI input method on the remote computer composes the tones — keep this Mac's input source on ABC/US while using it. Unicode text sends characters already composed on this Mac, for remotes without a Vietnamese IME.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Toggle("Share clipboard with the other computer", isOn: $shareClipboard)
                Text("Text copied on either computer can be pasted on the other. Applies to new sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Remote screen") {
                Toggle("Smooth image scaling", isOn: $smoothScreen)
                Slider(value: $scrollSensitivity, in: 0.25...2, step: 0.25) {
                    Text("Scroll speed")
                }
                LabeledContent("Scroll speed", value: String(format: "%.2g×", scrollSensitivity))
            }
            Section("About") {
                LabeledContent("Application", value: "MacViewer \(Self.version)")
                Toggle("Automatically check for updates", isOn: $checkForUpdates)
                Button(L("Check for Updates…")) { updater.check(userInitiated: true) }
                    .disabled(updater.state == .checking)
                Text("An independent native Mac app for UltraViewer interoperability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 490, height: 660)
    }
}

@MainActor
final class MacViewerAppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: RemoteCaptureController?
    weak var model: ConnectionModel?
    weak var hosting: MacHostingModel?
    private var isFinishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices may retain a generic icon from the first local build.
        // Give the running application its bundled icon directly as well.
        if let url = Bundle.main.url(forResource: "MacViewer", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }

    // Closing the only window ends MacViewer, and with it every connection.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishing else { return .terminateLater }
        isFinishing = true
        Task {
            if let capture, capture.isRecording || capture.isFinishingRecording || capture.isPreparingRecording {
                await capture.stopRecording()
            }
            // Tell the other computer the session is over before the process
            // exits; otherwise it waits for a relay timeout. Never block quit
            // for long on an unresponsive network.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.closeConnections() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func closeConnections() async {
        await model?.shutdown()
        await hosting?.shutdown()
    }
}
