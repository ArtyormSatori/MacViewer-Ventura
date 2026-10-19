import AppKit
import SwiftUI

/// Owns the Mode 1 chat windows: one floating window per
/// UltraViewer partner, rendering the shared
/// `ChatConversationView` — the same window Mode 2 uses (Phase 3,
/// Mode-1 chat seam). This owner is deliberately parallel to
/// `MeshChatWindows` (same chrome, same open-marks-read /
/// close-re-arms-unread contract) rather than a modification of
/// it: the two centers key their conversations differently
/// (namespaced UltraViewer IDs vs Mesh IDs), and Mode 2's owner
/// stays untouched. Window identity is the partner's storage
/// key: showing a partner whose window already exists focuses
/// that window, never a second one.
@MainActor
final class UltraViewerChatWindows: NSObject, NSWindowDelegate {
    /// Keyed by `UltraViewerChatPartner.storageKey`. Readable for
    /// tests; mutated only through `show` / `windowWillClose` /
    /// `bind`.
    private(set) var windows: [String: NSWindow] = [:]
    private var partners: [String: UltraViewerChatPartner] = [:]
    private weak var center: UltraViewerChatCenter?

    func bind(to center: UltraViewerChatCenter) {
        guard self.center !== center else { return }
        for window in windows.values { window.close() }
        windows.removeAll()
        partners.removeAll()
        self.center = center
    }

    func show(partner: UltraViewerChatPartner) {
        guard let center else { return }
        let transport = center.conversation(for: partner)
        center.setWindowOpen(partner: partner, open: true)
        let key = partner.storageKey
        partners[key] = partner
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(
            rootView: ChatConversationView(transport: transport).appLanguage())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = LF("Chat with %@", transport.conversationTitle)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 300, height: 360)
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key,
              let partner = partners[key] else { return }
        windows[key] = nil
        center?.setWindowOpen(partner: partner, open: false)
    }
}

/// The session surfaces' shared-chat button for a Mode 1
/// conversation: opens (or focuses) the floating conversation
/// window for the current partner and badges its unread count,
/// the same presentation the Mode 2 paired list uses. The legacy
/// tools button beside it keeps opening the chat + clipboard
/// panel; this button is chat only.
@MainActor
struct UltraViewerChatButton: View {
    @ObservedObject var model: UltraViewerChatModel
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                if model.unreadCount > 0 {
                    Text(model.unreadCount > 99 ? "99+" : String(model.unreadCount))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
            }
        }
        .help(LF("Chat with %@", model.conversationTitle))
    }
}
