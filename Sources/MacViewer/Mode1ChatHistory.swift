import Foundation

/// Stable identity of a Mode 1 (UltraViewer) chat partner: the
/// partner's UltraViewer ID plus its display name when the
/// session reported one (Phase 3, Mode-1 chat seam). The shared
/// floating chat window keys Mode 1 conversations by this value,
/// so a partner's history persists across sessions — unlike the
/// per-session `SessionToolsModel`, which clears its transcript
/// on every activation by design.
struct UltraViewerChatPartner: Hashable, Sendable {
    /// The partner's UltraViewer ID, normalized the way
    /// `ConnectionModel` normalizes dialed IDs (whitespace and
    /// dashes removed), so every surface keys the same partner
    /// identically however the ID was written.
    let id: String
    var name: String?

    init(id: String, name: String? = nil) {
        self.id = id.filter { !$0.isWhitespace && $0 != "-" }
        self.name = name
    }

    /// The conversation's stable identity line: the ID grouped in
    /// threes, the same presentation as the partner card.
    var displaySubtitle: String { Self.grouped(id) }

    /// Namespaces this partner inside the shared chat directory.
    /// Mode 1 history files are `chat-uv-<id>.json` while Mode 2
    /// files are `chat-<meshID>.json`, so a partner whose
    /// UltraViewer ID is numerically equal to a Mesh ID can never
    /// collide with that peer's history.
    var storageKey: String { "uv-\(id)" }

    static func grouped(_ id: String) -> String {
        guard !id.isEmpty else { return id }
        return stride(from: 0, to: id.count, by: 3).map { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            let end = id.index(start, offsetBy: min(3, id.count - offset))
            return String(id[start..<end])
        }.joined(separator: " ")
    }
}

/// Per-partner Mode 1 chat history on disk: one JSON file per
/// partner inside the same Application Support chat directory
/// Mode 2 uses, namespaced by `UltraViewerChatPartner.storageKey`.
///
/// The policies deliberately match `MeshChatHistoryStore` (the
/// two stores are parallel implementations of one contract, kept
/// separate because their key types differ): a missing,
/// truncated, or otherwise corrupt file loads as an *empty*
/// history and the next save overwrites it cleanly (writes are
/// atomic); disk growth is capped per conversation; a message
/// persisted mid-send (`.sending`) loads as `.failed`, the
/// factual end state.
struct UltraViewerChatHistoryStore: Sendable {
    /// Bounds disk growth per conversation; older messages beyond
    /// the cap are dropped on save.
    static let maxMessagesPerPartner = 500

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(for partner: UltraViewerChatPartner) -> URL {
        directory.appendingPathComponent("chat-\(partner.storageKey).json")
    }

    /// The stored conversation with `partner`, oldest first.
    func load(partner: UltraViewerChatPartner) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL(for: partner)),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return [] }
        return decoded.map { message in
            var message = message
            if message.delivery == .sending { message.delivery = .failed }
            return message
        }
    }

    /// Replaces the stored conversation with `partner`.
    /// Best-effort: a failed write loses this update, never the
    /// process.
    func save(partner: UltraViewerChatPartner, messages: [ChatMessage]) {
        let trimmed = Array(messages.suffix(Self.maxMessagesPerPartner))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: partner), options: [.atomic])
    }
}
