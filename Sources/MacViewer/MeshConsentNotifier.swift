import Foundation
import MeshClient
import UserNotifications

/// System notifications for Mode 2 session events (UI spec §5.4 /
/// §9 item 4): an incoming session request must reach the user even
/// when the main window is not frontmost, alongside the dedicated
/// consent window. Authorization is requested lazily, the first time
/// a session controller starts listening — never at app launch.
enum MeshConsentNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postIncomingRequest(name: String, meshID: MeshID) {
        let content = UNMutableNotificationContent()
        content.title = L("Incoming session request")
        content.body = LF("%@ wants to connect to this device.", name)
        content.sound = .default
        post(content)
    }

    static func postSessionStarted(name: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Session started")
        content.body = LF("%@ is connected to this device.", name)
        content.sound = .default
        post(content)
    }

    private static func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
