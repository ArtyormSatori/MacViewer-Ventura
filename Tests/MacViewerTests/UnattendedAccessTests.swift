import Foundation
import Testing
@testable import MacViewer

struct UnattendedAccessTests {
    @Test("Unattended approval never happens without Screen Recording")
    func requiresViewPermission() {
        #expect(MacHostingModel.unattendedApproval(canView: false, canControl: true, controlPreference: true) == nil)
        #expect(MacHostingModel.unattendedApproval(canView: false, canControl: false, controlPreference: false) == nil)
    }

    @Test("Unattended control requires both the preference and Accessibility")
    func controlGating() {
        #expect(MacHostingModel.unattendedApproval(canView: true, canControl: true, controlPreference: true) == true)
        #expect(MacHostingModel.unattendedApproval(canView: true, canControl: false, controlPreference: true) == false)
        #expect(MacHostingModel.unattendedApproval(canView: true, canControl: true, controlPreference: false) == false)
        #expect(MacHostingModel.unattendedApproval(canView: true, canControl: false, controlPreference: false) == false)
    }

    @Test("Unattended preference keys stay stable (stored user settings depend on them)")
    func preferenceKeysAreStable() {
        #expect(MacHostingModel.unattendedAccessKey == "MacViewer.unattendedAccess")
        #expect(MacHostingModel.unattendedControlKey == "MacViewer.unattendedControl")
        #expect(MacHostingModel.preventSleepKey == "MacViewer.preventSleepWhileHosting")
    }
}
