import AppKit
import MeshClient
import SwiftUI

/// The shared chat conversation view (UI spec W4, §9 item 3):
/// one floating window per conversation, rendered from any
/// `ChatTransport`. Mode 2's `MeshChatModel` conforms today; Mode 1
/// joins when its model grows the seam in PHASE3_NOTES.md.
/// Transcript style mirrors the existing Mode 1 chat window:
/// bubbles, sender name and time on incoming messages, and a small
/// delivery caption under outgoing ones.
struct ChatConversationView<Transport: ChatTransport>: View {
    @ObservedObject var transport: Transport
    @State private var draft = ""

    private var draftTooLong: Bool {
        draft.utf16.count > transport.maxTextLength
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftTooLong
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if transport.messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            Divider()
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(transport.peerIsOnline ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(transport.conversationTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(transport.conversationSubtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(transport.emptyStateNote ?? L("No messages yet."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transport.messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: transport.messages.last?.id) { _ in
                if let last = transport.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = transport.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            if !message.isOutgoing {
                Text(message.senderName)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(message.isOutgoing ? Color.accentColor : Color(nsColor: .controlColor),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
            HStack(spacing: 5) {
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                if message.isOutgoing {
                    deliveryCaption(message.delivery)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private func deliveryCaption(_ delivery: ChatMessage.Delivery) -> some View {
        switch delivery {
        case .sending: Text("Sending…")
        case .sent: Text("Sent")
        case .failed: Text("Not delivered").foregroundStyle(.red)
        case .received: EmptyView()
        }
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type a message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Command-Return)")
                    .disabled(!canSend)
            }
            if draftTooLong {
                Text("Keep chat messages under 16,384 characters.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        transport.send(text: text)
    }
}

/// Owns the Mode 2 chat windows: one floating window per
/// conversation, independent of the main window like the session
/// windows (Phase 3, chunk 3). Bound to the model's chat center
/// from ConnectionView; rebinding (server change) closes all chat
/// windows, and opening a window marks its conversation read.
@MainActor
final class MeshChatWindows: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private weak var center: MeshChatCenter?

    func bind(to center: MeshChatCenter) {
        guard self.center !== center else { return }
        for window in windows.values { window.close() }
        windows.removeAll()
        self.center = center
    }

    func show(peer: MeshID, name: String?) {
        guard let center else { return }
        let transport = center.conversation(for: peer, name: name)
        center.setWindowOpen(peer: peer, open: true)
        let key = peer.rawValue
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
              let key = windows.first(where: { $0.value === window })?.key else { return }
        windows[key] = nil
        if let peer = try? MeshID(validating: key) {
            center?.setWindowOpen(peer: peer, open: false)
        }
    }
}
