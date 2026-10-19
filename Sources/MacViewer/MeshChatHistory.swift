import Foundation
import MeshClient

/// Per-peer Mode 2 chat history on disk (Phase 3, chunk 3): one
/// JSON file per peer inside an app-private directory
/// (Application Support/MacViewer/chat). Histories never mix: the
/// file name is the peer's Mesh ID and every load/save names its
/// peer explicitly.
///
/// Failure policy: a missing, truncated, or otherwise corrupt file
/// loads as an *empty* history — chat history is a convenience,
/// never a reason to crash — and the next save overwrites the bad
/// file cleanly (writes are atomic).
struct MeshChatHistoryStore: Sendable {
    /// Bounds disk growth per conversation; older messages beyond
    /// the cap are dropped on save.
    static let maxMessagesPerPeer = 500

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(for peer: MeshID) -> URL {
        directory.appendingPathComponent("chat-\(peer.rawValue).json")
    }

    /// The stored conversation with `peer`, oldest first. A message
    /// persisted mid-send (`.sending`) can never complete after the
    /// fact, so it loads as `.failed` — the factual end state.
    func load(peer: MeshID) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL(for: peer)),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return [] }
        return decoded.map { message in
            var message = message
            if message.delivery == .sending { message.delivery = .failed }
            return message
        }
    }

    /// Replaces the stored conversation with `peer`. Best-effort:
    /// a failed write loses this update, never the process.
    func save(peer: MeshID, messages: [ChatMessage]) {
        let trimmed = Array(messages.suffix(Self.maxMessagesPerPeer))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: peer), options: [.atomic])
    }
}
