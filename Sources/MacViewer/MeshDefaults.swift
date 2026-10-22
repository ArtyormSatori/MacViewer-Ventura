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

/// Which server Mode 2 talks to (redesign spec §3.1): the built-in
/// project default, or the user's own server. Pairing records are
/// stored per server, so switching never loses pairings — the other
/// server's list is kept and comes back on switching back.
enum MeshServerConfiguration: Equatable {
    case `default`
    case custom(URL)

    var url: URL {
        switch self {
        case .default: return MeshDefaults.serverURL
        case .custom(let url): return url
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// Mode 2 (self-hosted mesh) configuration shared by the session model
/// and Settings.
enum MeshDefaults {
    /// The project's built-in default mesh server (redesign spec
    /// §3.1). This is the single source of truth for the default: it
    /// is compiled into the app, so installs already shipped pick the
    /// server up automatically when the project deploys it at this
    /// address — no configuration and no app update needed. Until
    /// then the address does not answer, and Mode 2 must say so
    /// honestly instead of failing (spec §3.3).
    static let serverURL = URL(string: "https://tavis.loc.cc")!

    /// The loopback address the 5.0.x line shipped as its development
    /// placeholder default. It only ever reached a user's defaults as
    /// the pre-filled value of the old Settings field, so a stored
    /// address that normalizes to it is a migrated placeholder, never
    /// a deliberate choice — resolution treats it as "no override"
    /// (see `configuration(in:)`). A loopback address entered
    /// deliberately through the personal-server frame is stored under
    /// `serverOverrideKey` and IS respected.
    static let legacyDevelopmentServerURL = URL(string: "http://127.0.0.1:18734")!

    /// UserDefaults key for the custom server address set in
    /// Settings → Self-hosted (the 5.0.x storage). Still read for
    /// migration and still written by `setCustomServer` so existing
    /// observers of this key keep working. Empty means "no legacy
    /// override".
    static let serverAddressKey = "MacViewer.mesh.serverAddress"

    /// UserDefaults key for a custom server chosen through the
    /// personal-server frame (redesign spec §3.4). Its shape is what
    /// distinguishes a deliberate override from the migrated legacy
    /// placeholder: any valid value here wins, including a loopback
    /// address equal to the old development default.
    static let serverOverrideKey = "MacViewer.mesh.serverOverride"

    /// UserDefaults key for an invite code typed into the
    /// personal-server frame. Consumed (read once, then cleared) by
    /// the next registration against that custom server, so the code
    /// reaches the register call without becoming a standing field.
    static let pendingInviteKey = "MacViewer.mesh.pendingInvite"

    /// UserDefaults key for this device's mesh display name. Defaults
    /// to the system's computer name (UI spec §9 item 5).
    static let deviceNameKey = "MacViewer.mesh.deviceName"

    /// Resolves which server is in effect, in precedence order:
    /// 1. a deliberate override (`serverOverrideKey`, written by the
    ///    personal-server frame) — always respected;
    /// 2. a legacy Settings value (`serverAddressKey`) that parses to
    ///    a real address — respected, EXCEPT the old loopback
    ///    development default, which was only ever a placeholder and
    ///    means "no override";
    /// 3. the built-in default.
    static func configuration(in defaults: UserDefaults = .standard) -> MeshServerConfiguration {
        if let url = normalizeServerAddress(defaults.string(forKey: serverOverrideKey)) {
            return .custom(url)
        }
        if let url = normalizeServerAddress(defaults.string(forKey: serverAddressKey)),
           !isLegacyDevelopmentURL(url) {
            return .custom(url)
        }
        return .default
    }

    /// The server the app should talk to right now.
    static var currentServerURL: URL { configuration().url }

    /// True when a custom server address is in effect.
    static var isUsingCustomServer: Bool { configuration().isCustom }

    /// Stores a deliberate custom server choice: the override key
    /// carries it, and the legacy key is mirrored so existing
    /// observers (the main window's server-change watcher) keep
    /// firing exactly as they did for the old Settings field.
    static func setCustomServer(_ url: URL, in defaults: UserDefaults = .standard) {
        defaults.set(url.absoluteString, forKey: serverOverrideKey)
        defaults.set(url.absoluteString, forKey: serverAddressKey)
    }

    /// Clears every override and returns to the built-in default.
    /// Pairing records are per server and are not touched.
    static func useDefaultServer(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: serverOverrideKey)
        defaults.removeObject(forKey: serverAddressKey)
    }

    /// True for the 5.0.x development placeholder in any entered
    /// form (loopback host on the development port, http scheme).
    static func isLegacyDevelopmentURL(_ url: URL) -> Bool {
        url.scheme == "http"
            && (url.host == "127.0.0.1" || url.host == "localhost")
            && url.port == 18734
    }

    /// Normalizes a Settings address field value to a base URL, or
    /// returns nil when the value is empty or unusable. Accepts a
    /// full URL (`http://host:port`, `https://host`), a bare
    /// `host:port`, or a bare `host` (http is assumed for the bare
    /// forms).
    static func normalizeServerAddress(_ raw: String?) -> URL? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Normalizes a Settings address field value to a base URL.
    /// Anything unparseable falls back to the default server.
    static func resolveServerURL(_ raw: String?) -> URL {
        normalizeServerAddress(raw) ?? serverURL
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
