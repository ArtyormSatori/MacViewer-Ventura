import Foundation
import SwiftUI

/// The two top-level modes of the 5.0 main window (UI spec §4). The
/// selected mode is remembered per app and restored at launch; each mode
/// owns a completely separate address book and window body.
enum AppMode: String, CaseIterable, Identifiable {
    case ultraViewer
    case selfHosted

    static let defaultsKey = "MacViewer.mode"
    var id: Self { self }

    var title: String {
        switch self {
        case .ultraViewer: return "UltraViewer"
        case .selfHosted: return "Self-hosted"
        }
    }

    var symbol: String {
        switch self {
        case .ultraViewer: return "pc"
        case .selfHosted: return "network"
        }
    }
}

/// User appearance override (UI spec §2.5 / §9 item 10): both light and
/// dark are fully supported, the system appearance is the default, and
/// the user may force either one in Settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "MacViewer.appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func current(from defaults: UserDefaults = .standard) -> AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }
}

/// Mode 2 (self-hosted mesh) configuration shared by the session model
/// and Settings.
enum MeshDefaults {
    /// Placeholder for the project's production mesh server. The real
    /// server does not exist yet; this loopback address is the local
    /// test server used throughout Mode 2 development. It will be
    /// replaced by the project server address at milestone M2.
    static let serverURL = URL(string: "http://127.0.0.1:18734")!

    /// UserDefaults key for the custom server address set in
    /// Settings → Self-hosted. Empty means "use `serverURL`".
    static let serverAddressKey = "MacViewer.mesh.serverAddress"

    /// UserDefaults key for this device's mesh display name. Defaults
    /// to the system's computer name (UI spec §9 item 5).
    static let deviceNameKey = "MacViewer.mesh.deviceName"

    /// The server the app should talk to right now: the Settings
    /// override when one is set and parseable, else the default.
    static var currentServerURL: URL {
        resolveServerURL(UserDefaults.standard.string(forKey: serverAddressKey))
    }

    /// True when a custom server address is in effect.
    static var isUsingCustomServer: Bool {
        let raw = UserDefaults.standard.string(forKey: serverAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !raw.isEmpty && resolveServerURL(raw) != serverURL
    }

    /// Normalizes a Settings address field value to a base URL.
    /// Accepts a full URL (`http://host:port`, `https://host`), a bare
    /// `host:port`, or a bare `host` (http is assumed for the bare
    /// forms). Anything unparseable falls back to the default server.
    static func resolveServerURL(_ raw: String?) -> URL {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return serverURL }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return serverURL }
        return url
    }

    /// This device's mesh display name: the stored choice, or the
    /// system's computer name on first use.
    static var deviceName: String {
        let stored = UserDefaults.standard.string(forKey: deviceNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Host.current().localizedName ?? "Mac"
    }
}
