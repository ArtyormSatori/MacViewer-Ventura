import Foundation
import Testing
@testable import MacViewer

/// The redesign's navigation models (spec §1.1/§1.2/§2.5/§2.6,
/// §3.2; decisions D1/D3/D4/D5/D6): sidebar sections and their
/// restore rules, the window geometry constants, the server pill
/// mapping for every state the session model can produce, and the
/// library's two-stores-never-merged guarantee.
struct NavigationModelsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "NavigationModelsTests-\(UUID().uuidString)")!
    }

    // MARK: Main sections

    @Test("Sidebar sections display in spec order, grouped Connect then This Mac")
    func sectionOrderAndGroups() {
        #expect(MainSection.allCases == [.control, .selfHosted, .allowConnections, .devicesHistory])
        #expect(MainSection.control.group == .connect)
        #expect(MainSection.selfHosted.group == .connect)
        #expect(MainSection.allowConnections.group == .thisMac)
        #expect(MainSection.devicesHistory.group == .thisMac)
        #expect(MainSection.Group.allCases == [.connect, .thisMac])
    }

    @Test("Every section has a title and an SF Symbol; only the mode-owned rows carry a subtitle")
    func sectionPresentation() {
        for section in MainSection.allCases {
            #expect(!section.titleKey.isEmpty)
            #expect(!section.symbol.isEmpty)
        }
        #expect(MainSection.control.symbol == "desktopcomputer")
        #expect(MainSection.selfHosted.symbol == "network")
        #expect(MainSection.allowConnections.symbol == "person.wave.2")
        #expect(MainSection.devicesHistory.symbol == "list.bullet.rectangle")
        #expect(MainSection.control.subtitleKey == "UltraViewer")
        #expect(MainSection.selfHosted.subtitleKey == "Your mesh")
        #expect(MainSection.allowConnections.subtitleKey == nil)
        #expect(MainSection.devicesHistory.subtitleKey == nil)
    }

    @Test("With nothing stored, the restored section is Control")
    func restoredDefaultsToControl() {
        #expect(MainSection.restored(in: makeDefaults()) == .control)
    }

    @Test("A saved section restores exactly, for every section")
    func restoredRoundTrip() {
        for section in MainSection.allCases {
            let defaults = makeDefaults()
            section.save(to: defaults)
            #expect(MainSection.restored(in: defaults) == section)
        }
    }

    @Test("The 5.0 mode memory maps onto its destination when no section was ever saved")
    func restoredFallsBackToLegacyMode() {
        let selfHosted = makeDefaults()
        selfHosted.set(AppMode.selfHosted.rawValue, forKey: AppMode.defaultsKey)
        #expect(MainSection.restored(in: selfHosted) == .selfHosted)

        let ultraViewer = makeDefaults()
        ultraViewer.set(AppMode.ultraViewer.rawValue, forKey: AppMode.defaultsKey)
        #expect(MainSection.restored(in: ultraViewer) == .control)
    }

    @Test("A saved section wins over the legacy mode memory")
    func restoredPrefersSectionOverLegacy() {
        let defaults = makeDefaults()
        defaults.set(AppMode.ultraViewer.rawValue, forKey: AppMode.defaultsKey)
        MainSection.devicesHistory.save(to: defaults)
        #expect(MainSection.restored(in: defaults) == .devicesHistory)
    }

    @Test("An unrecognized stored section falls back to the legacy mode, then to Control")
    func restoredGarbageHandling() {
        let withLegacy = makeDefaults()
        withLegacy.set("not-a-section", forKey: MainSection.defaultsKey)
        withLegacy.set(AppMode.selfHosted.rawValue, forKey: AppMode.defaultsKey)
        #expect(MainSection.restored(in: withLegacy) == .selfHosted)

        let garbageOnly = makeDefaults()
        garbageOnly.set("not-a-section", forKey: MainSection.defaultsKey)
        garbageOnly.set("not-a-mode", forKey: AppMode.defaultsKey)
        #expect(MainSection.restored(in: garbageOnly) == .control)
    }

    // MARK: Window geometry (D3)

    @Test("Window and content geometry match the settled constants")
    func layoutConstants() {
        #expect(MainWindowLayout.defaultWidth == 1100)
        #expect(MainWindowLayout.defaultHeight == 740)
        #expect(MainWindowLayout.minWidth == 940)
        #expect(MainWindowLayout.minHeight == 620)
        #expect(MainWindowLayout.sidebarFullWidth == 220)
        #expect(MainWindowLayout.sidebarIconOnlyWidth == 52)
        #expect(MainWindowLayout.contentMaxWidth == 880)
        #expect(MainWindowLayout.contentHorizontalPadding == 24)
        #expect(MainWindowLayout.contentVerticalPadding == 20)
        #expect(MainWindowLayout.cardPadding == 16)
    }

    @Test("The sidebar collapses to icon-only below 900 pt of window width, and only there")
    func sidebarCollapseBoundary() {
        #expect(MainWindowLayout.sidebarStyle(windowWidth: 1440) == .full)
        #expect(MainWindowLayout.sidebarStyle(windowWidth: 900) == .full)
        #expect(MainWindowLayout.sidebarStyle(windowWidth: 899) == .iconOnly)
        #expect(MainWindowLayout.sidebarStyle(windowWidth: 320) == .iconOnly)
        #expect(MainWindowLayout.sidebarWidth(windowWidth: 900)
                == MainWindowLayout.sidebarFullWidth)
        #expect(MainWindowLayout.sidebarWidth(windowWidth: 899)
                == MainWindowLayout.sidebarIconOnlyWidth)
    }

    // MARK: Server pill (§3.2)

    @Test("Pill: a probe in flight reads Connecting, with a spinner, for either server")
    func pillChecking() {
        for isCustom in [false, true] {
            let pill = ServerPill.presentation(isCustom: isCustom,
                                               availability: .checking, phase: .working)
            #expect(pill == ServerPillPresentation(textKey: "Connecting to server…",
                                                   token: .idle, showsSpinner: true))
        }
    }

    @Test("Pill: online names the server in use and takes the online token")
    func pillOnline() {
        #expect(ServerPill.presentation(isCustom: false, availability: .online, phase: .ready)
                == ServerPillPresentation(textKey: "Default server · Online",
                                          token: .online, showsSpinner: false))
        #expect(ServerPill.presentation(isCustom: true, availability: .online, phase: .ready)
                == ServerPillPresentation(textKey: "Custom server · Online",
                                          token: .online, showsSpinner: false))
    }

    @Test("Pill: the undeployed default server reads Not available yet, quietly")
    func pillDefaultNotAvailable() {
        #expect(ServerPill.presentation(isCustom: false,
                                        availability: .defaultNotAvailable,
                                        phase: .serverUnavailable)
                == ServerPillPresentation(textKey: "Default server · Not available yet",
                                          token: .idle, showsSpinner: false))
        // The state belongs to the default server by construction;
        // a custom configuration never borrows its wording.
        #expect(ServerPill.presentation(isCustom: true,
                                        availability: .defaultNotAvailable,
                                        phase: .ready)
                == ServerPillPresentation(textKey: "Custom server",
                                          token: .idle, showsSpinner: false))
    }

    @Test("Pill: an invite requirement and an unreachable server take the limited token")
    func pillLimitedStates() {
        for isCustom in [false, true] {
            #expect(ServerPill.presentation(isCustom: isCustom,
                                            availability: .inviteRequired,
                                            phase: .offline("refused"))
                    == ServerPillPresentation(textKey: "Invite required to register",
                                              token: .limited, showsSpinner: false))
            #expect(ServerPill.presentation(isCustom: isCustom,
                                            availability: .unreachable,
                                            phase: .offline("down"))
                    == ServerPillPresentation(textKey: "Cannot reach the server",
                                              token: .limited, showsSpinner: false))
        }
    }

    @Test("Pill: the offline phase alone reads Offline; no observation reads as the plain server kind")
    func pillIdleStates() {
        #expect(ServerPill.presentation(isCustom: false, availability: .unknown,
                                        phase: .offline("no network"))
                == ServerPillPresentation(textKey: "Offline",
                                          token: .idle, showsSpinner: false))
        #expect(ServerPill.presentation(isCustom: false, availability: .unknown, phase: .ready)
                == ServerPillPresentation(textKey: "Default server",
                                          token: .idle, showsSpinner: false))
        #expect(ServerPill.presentation(isCustom: true, availability: .unknown,
                                        phase: .serverUnavailable)
                == ServerPillPresentation(textKey: "Custom server",
                                          token: .idle, showsSpinner: false))
    }

    // MARK: Devices & History library (D5)

    @Test("Library groups are always mesh first, UltraViewer second, each with its mode title")
    func libraryGroupOrder() {
        #expect(DeviceLibraryGroup.allCases == [.meshPaired, .ultraViewerRecent])
        #expect(DeviceLibraryGroup.meshPaired.titleKey == "Paired devices — Self-hosted")
        #expect(DeviceLibraryGroup.ultraViewerRecent.titleKey
                == "Recent Windows computers — UltraViewer")
        let groups = LibraryGroups(meshDevices: [1], recentPartners: ["a"])
        #expect(groups.orderedGroups == [.meshPaired, .ultraViewerRecent])
    }

    @Test("Library counts come from two separate stores and never mix")
    func libraryStoresStaySeparate() {
        var groups = LibraryGroups(meshDevices: [10, 20, 30],
                                   recentPartners: ["111 222 333"])
        #expect(groups.count(for: .meshPaired) == 3)
        #expect(groups.count(for: .ultraViewerRecent) == 1)
        groups.recentPartners.append("444 555 666")
        #expect(groups.count(for: .meshPaired) == 3)
        #expect(groups.count(for: .ultraViewerRecent) == 2)
        groups.meshDevices.removeAll()
        #expect(groups.count(for: .meshPaired) == 0)
        #expect(groups.count(for: .ultraViewerRecent) == 2)
    }

    // MARK: Settings sections

    @Test("Settings sections display in the settled order, each with a title and a symbol")
    func settingsSectionOrderAndPresentation() {
        #expect(SettingsSection.allCases == [.general, .selfHosted, .unattendedAccess,
                                             .keyboard, .clipboard, .remoteScreen,
                                             .history, .about])
        for section in SettingsSection.allCases {
            #expect(!section.titleKey.isEmpty)
            #expect(!section.symbol.isEmpty)
        }
        #expect(SettingsSection.selfHosted.symbol == "server.rack")
    }

    @Test("Settings section restores what was saved and defaults to General")
    func settingsSectionRestore() {
        #expect(SettingsSection.restored(in: makeDefaults()) == .general)
        for section in SettingsSection.allCases {
            let defaults = makeDefaults()
            section.save(to: defaults)
            #expect(SettingsSection.restored(in: defaults) == section)
        }
        let garbage = makeDefaults()
        garbage.set("not-a-section", forKey: SettingsSection.defaultsKey)
        #expect(SettingsSection.restored(in: garbage) == .general)
    }
}
