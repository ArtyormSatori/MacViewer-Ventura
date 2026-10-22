import Foundation

/// The main window's sidebar destinations (redesign spec §1.1,
/// decision D1 — replaces the 5.0 segmented control and its §9.1).
/// Mode remains a property of a CONNECTION, never of the window:
/// the sidebar is a set of destinations, and each destination's
/// data stays in its own store (§1.1, principle N2).
enum MainSection: String, CaseIterable, Identifiable {
    /// Mode 1 viewer side: the connect card and Mode 1's recents.
    case control
    /// Mode 2 home: This device, Connect, Requests, Paired.
    case selfHosted
    /// The host surface of BOTH modes (§2.3).
    case allowConnections
    /// The shared address library (§2.5, decision D5).
    case devicesHistory

    static let defaultsKey = "MacViewer.mainSection"
    var id: Self { self }

    /// Sidebar groups, in display order (§1.1 wireframe).
    enum Group: CaseIterable {
        case connect
        case thisMac

        var titleKey: String {
            switch self {
            case .connect: return "Connect"
            case .thisMac: return "This Mac"
            }
        }
    }

    var group: Group {
        switch self {
        case .control, .selfHosted: return .connect
        case .allowConnections, .devicesHistory: return .thisMac
        }
    }

    /// Localization key of the row's title.
    var titleKey: String {
        switch self {
        case .control: return "Control"
        case .selfHosted: return "Self-hosted"
        case .allowConnections: return "Allow connections"
        case .devicesHistory: return "Devices & History"
        }
    }

    /// SF Symbol for the row (spec §1.7 mapping).
    var symbol: String {
        switch self {
        case .control: return "desktopcomputer"
        case .selfHosted: return "network"
        case .allowConnections: return "person.wave.2"
        case .devicesHistory: return "list.bullet.rectangle"
        }
    }

    /// The short subtitle naming the owning mode, so nobody
    /// mistakes which mode a destination belongs to (§1.1). Only
    /// the two mode-owned destinations carry one; the two shared
    /// destinations sit under the "This Mac" group header instead.
    var subtitleKey: String? {
        switch self {
        case .control: return "UltraViewer"
        case .selfHosted: return "Your mesh"
        case .allowConnections, .devicesHistory: return nil
        }
    }

    /// The section to show at launch: the remembered section wins;
    /// before this key existed, the 5.0 mode memory (`AppMode`)
    /// maps onto its destination (UltraViewer → Control,
    /// Self-hosted → Self-hosted). Anything unrecognized falls
    /// back to Control, the Mode 1 home every user knows.
    static func restored(in defaults: UserDefaults = .standard) -> MainSection {
        if let raw = defaults.string(forKey: defaultsKey),
           let section = MainSection(rawValue: raw) {
            return section
        }
        if let legacy = defaults.string(forKey: AppMode.defaultsKey) {
            switch AppMode(rawValue: legacy) {
            case .selfHosted: return .selfHosted
            case .ultraViewer, nil: return .control
            }
        }
        return .control
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Main window geometry (spec §1.2 and decision D3). The collapse
/// threshold sits below the window's minimum width on purpose:
/// the sidebar's icon-only form is what the layout takes if the
/// minimum ever drops, and the rule is unit-tested at its
/// boundary either way.
enum MainWindowLayout {
    static let defaultWidth: CGFloat = 1100
    static let defaultHeight: CGFloat = 740
    static let minWidth: CGFloat = 940
    static let minHeight: CGFloat = 620
    /// Sidebar width in its full (labelled) form.
    static let sidebarFullWidth: CGFloat = 220
    /// Sidebar width in its icon-only form.
    static let sidebarIconOnlyWidth: CGFloat = 52
    /// Below this window width the sidebar collapses to icons.
    static let collapseThreshold: CGFloat = 900
    /// Content column: the spec's single standardized measure.
    static let contentMaxWidth: CGFloat = 880
    static let contentHorizontalPadding: CGFloat = 24
    static let contentVerticalPadding: CGFloat = 20
    /// Padding inside a card.
    static let cardPadding: CGFloat = 16

    enum SidebarStyle: Equatable {
        case full
        case iconOnly
    }

    static func sidebarStyle(windowWidth: CGFloat) -> SidebarStyle {
        windowWidth >= collapseThreshold ? .full : .iconOnly
    }

    static func sidebarWidth(windowWidth: CGFloat) -> CGFloat {
        switch sidebarStyle(windowWidth: windowWidth) {
        case .full: return sidebarFullWidth
        case .iconOnly: return sidebarIconOnlyWidth
        }
    }
}

/// What the server status pill shows (spec §3.2): a text key and
/// the dot's color token. The text is resolved through the app's
/// localization at render time; the mapping itself is pure and
/// unit-tested for every state the session model can produce.
struct ServerPillPresentation: Equatable {
    enum Token: Equatable {
        case online
        case limited
        case idle
    }

    var textKey: String
    var token: Token
    var showsSpinner: Bool
}

enum ServerPill {
    /// Maps the observed server state to the pill. Only states the
    /// app actually observed appear here (Part 1's rule): a failed
    /// health probe of the built-in default, a registration refusal
    /// naming the invite requirement, a failed registration against
    /// a custom server, the model's offline phase. The invite and
    /// unreachable states outrank the offline phase because they
    /// are the more specific observation; the offline phase alone
    /// (no server observation yet) reads simply "Offline".
    static func presentation(isCustom: Bool,
                             availability: MeshServerAvailability,
                             phase: MeshSessionModel.Phase) -> ServerPillPresentation {
        switch availability {
        case .checking:
            return ServerPillPresentation(textKey: "Connecting to server…",
                                          token: .idle, showsSpinner: true)
        case .online:
            return ServerPillPresentation(textKey: isCustom ? "Custom server · Online"
                                                            : "Default server · Online",
                                          token: .online, showsSpinner: false)
        case .defaultNotAvailable where !isCustom:
            return ServerPillPresentation(textKey: "Default server · Not available yet",
                                          token: .idle, showsSpinner: false)
        case .inviteRequired:
            return ServerPillPresentation(textKey: "Invite required to register",
                                          token: .limited, showsSpinner: false)
        case .unreachable:
            return ServerPillPresentation(textKey: "Cannot reach the server",
                                          token: .limited, showsSpinner: false)
        case .unknown, .defaultNotAvailable:
            break
        }
        if case .offline = phase {
            return ServerPillPresentation(textKey: "Offline",
                                          token: .idle, showsSpinner: false)
        }
        return ServerPillPresentation(textKey: isCustom ? "Custom server" : "Default server",
                                      token: .idle, showsSpinner: false)
    }
}

/// The Devices & History library's two groups (spec §2.5, D5):
/// always these two, always in this order, each fed by its own
/// mode's store. Merging them into one list is exactly what this
/// model makes impossible — there is no combined collection.
enum DeviceLibraryGroup: CaseIterable, Identifiable {
    case meshPaired
    case ultraViewerRecent

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .meshPaired: return "Paired devices — Self-hosted"
        case .ultraViewerRecent: return "Recent Windows computers — UltraViewer"
        }
    }
}

/// The library's content, as two separate stores side by side.
/// `MeshItem` comes from the mesh pairing store, `RecentItem`
/// from Mode 1's recents store; the struct never mixes them.
struct LibraryGroups<MeshItem, RecentItem> {
    var meshDevices: [MeshItem]
    var recentPartners: [RecentItem]

    /// Groups in display order (§2.5: mesh group first).
    var orderedGroups: [DeviceLibraryGroup] { DeviceLibraryGroup.allCases }

    func count(for group: DeviceLibraryGroup) -> Int {
        switch group {
        case .meshPaired: return meshDevices.count
        case .ultraViewerRecent: return recentPartners.count
        }
    }
}

/// The Settings window's sidebar sections: the existing Form's
/// sections, regrouped only where the redesign names it (Language
/// and Appearance together form General). Every control keeps its
/// binding and behavior; only the container changes.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case selfHosted
    case unattendedAccess
    case keyboard
    case clipboard
    case remoteScreen
    case history
    case about

    static let defaultsKey = "MacViewer.settingsSection"
    var id: Self { self }

    var titleKey: String {
        switch self {
        case .general: return "General"
        case .selfHosted: return "Self-hosted"
        case .unattendedAccess: return "Unattended access"
        case .keyboard: return "Keyboard"
        case .clipboard: return "Clipboard"
        case .remoteScreen: return "Remote screen"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .selfHosted: return "server.rack"
        case .unattendedAccess: return "lock.shield"
        case .keyboard: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .remoteScreen: return "display"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    static func restored(in defaults: UserDefaults = .standard) -> SettingsSection {
        guard let raw = defaults.string(forKey: defaultsKey),
              let section = SettingsSection(rawValue: raw) else { return .general }
        return section
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
