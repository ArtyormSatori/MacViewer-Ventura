import Foundation
import ServiceManagement

/// Start-at-login for the main app bundle (macOS 13+ `SMAppService`).
/// Registration can fail for builds that are not in /Applications; callers
/// surface that error instead of pretending the setting worked.
enum MacLoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try await SMAppService.mainApp.unregister()
        }
    }
}
