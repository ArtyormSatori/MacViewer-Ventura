import Combine
import Foundation

/// The seam between the shared floating chat window (Phase 3,
/// chunk 3) and a mode's chat backend. One instance per
/// conversation. The window renders any conformer; Mode 2 conforms
/// with `MeshChatModel`. Mode 1's `SessionToolsModel` does not
/// conform yet — the precise seam it still needs is recorded in
/// PHASE3_NOTES.md (chunk 3), and its existing chat surface is
/// untouched until then.
@MainActor
protocol ChatTransport: ObservableObject {
    /// Who the conversation is with (peer display name, falling
    /// back to its ID).
    var conversationTitle: String { get }
    /// The conversation's stable identity line: a formatted Mesh
    /// ID in Mode 2, the partner ID in Mode 1.
    var conversationSubtitle: String { get }
    /// The transcript, in display order: (timestamp, sequence).
    var messages: [ChatMessage] { get }
    /// Whether the peer can currently be reached for chat.
    var peerIsOnline: Bool { get }
    /// A factual note for the empty state (e.g. the peer is
    /// offline), or nil for the plain "no messages yet" state.
    var emptyStateNote: String? { get }
    /// The longest message the transport accepts, in UTF-16 code
    /// units (both modes enforce the same 16,384 cap).
    var maxTextLength: Int { get }
    /// Sends a message. Implementations refuse empty /
    /// whitespace-only / over-cap text without recording it.
    func send(text: String)
    /// Clears the conversation's unread count (window opened).
    func markAllRead()
}

extension ChatTransport {
    var maxTextLength: Int { 16_384 }
}
