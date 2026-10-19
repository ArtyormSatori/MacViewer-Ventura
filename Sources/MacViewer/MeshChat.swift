import Combine
import Foundation
import MeshClient

/// One Mode 2 chat conversation with a paired peer (Phase 3,
/// chunk 3). Messages ride the signaling channel as `mvChat`
/// envelopes; history persists per peer via `MeshChatHistoryStore`.
///
/// Delivery model (factual, protocol-honest): the mesh server
/// gives no positive acknowledgement. An outgoing message is
/// `.sending` when recorded; if `sendSignal` throws it is
/// `.failed` at once; if the relay refuses delivery, the refusal
/// arrives asynchronously on the signaling client's refusal
/// stream and the center attributes it — exactly, when the
/// server echoed the message's ID as the refusal's `ref`
/// (`failInFlight(id:)`); by the oldest in-flight send when the
/// refusal carries no correlation (older server). If no refusal
/// arrives within `deliveryWindow`, the message settles to
/// `.sent` — "accepted by the relay", never "read by the peer".
@MainActor
final class MeshChatModel: ChatTransport {
    /// Same cap Mode 1 enforces on its chat (16,384 characters).
    static let maxTextLength = 16_384

    let peer: MeshID
    @Published var peerName: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var unreadCount = 0
    @Published var peerIsOnline = false

    private let signaling: any MeshSignalingAPI
    private let localName: @MainActor () -> String
    private let history: MeshChatHistoryStore
    private let deliveryWindow: TimeInterval

    private var seenIDs: Set<UUID> = []
    private var nextSequence = 0
    private var settleTasks: [UUID: Task<Void, Never>] = [:]
    private var windowOpen = false

    init(peer: MeshID, peerName: String?,
         signaling: any MeshSignalingAPI,
         localName: @escaping @MainActor () -> String,
         history: MeshChatHistoryStore,
         deliveryWindow: TimeInterval = 1.25) {
        self.peer = peer
        self.peerName = peerName
        self.signaling = signaling
        self.localName = localName
        self.history = history
        self.deliveryWindow = deliveryWindow
        let loaded = history.load(peer: peer)
        messages = loaded
        seenIDs = Set(loaded.map(\.id))
        nextSequence = (loaded.map(\.sequence).max() ?? -1) + 1
    }

    deinit {
        for task in settleTasks.values { task.cancel() }
    }

    // MARK: ChatTransport

    var conversationTitle: String { peerName ?? peer.formatted }
    var conversationSubtitle: String { peer.formatted }

    var emptyStateNote: String? {
        guard !peerIsOnline else { return nil }
        return LF("%@ is offline. Chat works while both devices are connected to the mesh server.",
                  conversationTitle)
    }

    func send(text: String) {
        // Whitespace-only and over-cap text is refused without a
        // history entry, exactly as Mode 1 refuses it.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= Self.maxTextLength else { return }
        let message = ChatMessage(id: UUID(), senderName: localName(), text: text,
                                  timestamp: Date(), isOutgoing: true,
                                  delivery: .sending, sequence: nextSequence)
        nextSequence += 1
        seenIDs.insert(message.id)
        insertInDisplayOrder(message)
        persist()
        let wire = MeshChatMessage(id: message.id, fromName: localName(),
                                   text: text, timestamp: message.timestamp)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await signaling.sendSignal(to: peer, kind: MeshChatMessage.transportKind,
                                               data: wire.signalingData)
                armSettle(for: message.id)
            } catch {
                setDelivery(.failed, for: message.id)
            }
        }
    }

    func markAllRead() {
        unreadCount = 0
    }

    // MARK: Inbound (called by MeshChatCenter only)

    /// Records a message from the peer. Duplicates (same message
    /// ID) are stored and displayed exactly once; an out-of-order
    /// arrival takes its (timestamp, sequence) place in the order.
    func receive(_ wire: MeshChatMessage) {
        guard !seenIDs.contains(wire.id) else { return }
        guard wire.text.utf16.count <= Self.maxTextLength else { return }
        seenIDs.insert(wire.id)
        let message = ChatMessage(id: wire.id,
                                  senderName: wire.fromName ?? conversationTitle,
                                  text: wire.text, timestamp: wire.timestamp,
                                  isOutgoing: false, delivery: .received,
                                  sequence: nextSequence)
        nextSequence += 1
        insertInDisplayOrder(message)
        if !windowOpen { unreadCount += 1 }
        persist()
    }

    // MARK: Delivery failures (called by MeshChatCenter only)

    /// The oldest outgoing message still awaiting its delivery
    /// outcome, if any.
    var oldestInFlight: ChatMessage? {
        messages.first { $0.isOutgoing && $0.delivery == .sending }
    }

    /// Attributes a relay refusal to the oldest in-flight send.
    /// Returns whether a message consumed the refusal.
    @discardableResult
    func failOldestInFlight() -> Bool {
        guard let inFlight = oldestInFlight else { return false }
        setDelivery(.failed, for: inFlight.id)
        return true
    }

    /// Fails exactly the in-flight message with this ID — the
    /// correlated path, when the server echoed the message's own
    /// ID as the refusal's `ref`. Returns whether that message
    /// consumed the refusal (false when it is unknown here or
    /// already settled, e.g. its delivery window expired first).
    @discardableResult
    func failInFlight(id: UUID) -> Bool {
        guard let message = messages.first(where: {
            $0.id == id && $0.isOutgoing && $0.delivery == .sending
        }) else { return false }
        setDelivery(.failed, for: message.id)
        return true
    }

    /// The signaling connection went away: nothing still in flight
    /// can complete, so it settles as failed.
    func disconnect() {
        for task in settleTasks.values { task.cancel() }
        settleTasks.removeAll()
        var changed = false
        for index in messages.indices where messages[index].delivery == .sending {
            messages[index].delivery = .failed
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Window presence (called by MeshChatCenter only)

    func windowOpened() {
        windowOpen = true
        markAllRead()
    }

    func windowClosed() {
        windowOpen = false
    }

    // MARK: Internals

    /// Display order is (timestamp, sequence): timestamps order the
    /// conversation across both writers, and the local sequence
    /// keeps ties and late arrivals deterministic.
    private func insertInDisplayOrder(_ message: ChatMessage) {
        messages.append(message)
        messages.sort {
            ($0.timestamp, $0.sequence) < ($1.timestamp, $1.sequence)
        }
    }

    private func armSettle(for id: UUID) {
        let window = deliveryWindow
        settleTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard let self, !Task.isCancelled else { return }
            settleTasks[id] = nil
            // A refusal may have landed first; only a message still
            // in flight settles to sent.
            if let index = messages.firstIndex(where: { $0.id == id }),
               messages[index].delivery == .sending {
                setDelivery(.sent, for: id)
            }
        }
    }

    private func setDelivery(_ delivery: ChatMessage.Delivery, for id: UUID) {
        settleTasks[id]?.cancel()
        settleTasks[id] = nil
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].delivery != delivery else { return }
        messages[index].delivery = delivery
        persist()
    }

    private func persist() {
        history.save(peer: peer, messages: messages)
    }
}

/// Owns every Mode 2 conversation for one signaling connection and
/// routes what arrives on it (Phase 3, chunk 3). The session
/// controller is the signaling stream's only subscriber; it hands
/// non-session envelopes to this center through its fan-out hook
/// (`MeshSessionController.onUnhandledSignal`), wired by
/// `MeshSessionModel`. Server refusals reach this center through
/// the model's own pump over the signaling client's
/// `serverRefusals` stream, so they arrive with their correlation
/// echo intact (core-fixes part).
///
/// REFUSAL ATTRIBUTION (core-fixes part): the server echoes the
/// refused envelope's app-plane marker as `ref` on its error
/// frames, and the model feeds this center the signaling client's
/// `serverRefusals` stream. A refusal with a chat message's ID as
/// its ref fails exactly that message; a refusal whose ref names
/// something else (a session negotiation's sessionID) is not the
/// chat plane's and fails nothing here. Only a refusal with NO
/// ref — a server that predates the field — falls back to the
/// original chunk-3 rule: attributed to the globally oldest
/// in-flight chat send. The session controller still interprets
/// refusals for its own pending requests independently (chunk 2
/// semantics); correlation keeps the two planes from consuming
/// each other's addressed refusals, but an uncorrelated refusal
/// can still be read by both, exactly as before.
@MainActor
final class MeshChatCenter: ObservableObject {
    /// Total unread across all conversations, computed live from
    /// the per-conversation models. The inbound path is fully
    /// synchronous (handle → receive → increment), so this total
    /// must be too: a stored cache refreshed from the models'
    /// `objectWillChange` cannot be — that publisher fires
    /// *before* the mutation, so a cache can only be refreshed
    /// from a deferred task, and every reader in the same turn
    /// (a view, a test, any synchronous consumer) sees a stale
    /// zero. A computed total has no maintenance path and cannot
    /// lag. (CI run 5 caught exactly that staleness: the model
    /// counted 1 while this total still read 0.)
    var totalUnread: Int {
        models.values.reduce(0) { $0 + $1.unreadCount }
    }

    private var models: [MeshID: MeshChatModel] = [:]
    private var modelSinks: [MeshID: AnyCancellable] = [:]

    private let signaling: any MeshSignalingAPI
    private let isPaired: @MainActor (MeshID) -> Bool
    private let localName: @MainActor () -> String
    private let historyDirectory: URL
    private let deliveryWindow: TimeInterval

    init(signaling: any MeshSignalingAPI,
         isPaired: @escaping @MainActor (MeshID) -> Bool,
         localName: @escaping @MainActor () -> String,
         historyDirectory: URL,
         deliveryWindow: TimeInterval = 1.25) {
        self.signaling = signaling
        self.isPaired = isPaired
        self.localName = localName
        self.historyDirectory = historyDirectory
        self.deliveryWindow = deliveryWindow
    }

    // MARK: Conversations

    /// The conversation with `peer`, created (and its history
    /// loaded) on first use. Conversations exist whether or not a
    /// chat window was ever opened: sends and incoming messages are
    /// recorded regardless.
    func conversation(for peer: MeshID, name: String?) -> MeshChatModel {
        if let existing = models[peer] {
            if let name { existing.peerName = name }
            return existing
        }
        let model = MeshChatModel(
            peer: peer, peerName: name, signaling: signaling, localName: localName,
            history: MeshChatHistoryStore(directory: historyDirectory),
            deliveryWindow: deliveryWindow)
        models[peer] = model
        // The model's `objectWillChange` fires before its
        // mutation; forward this center's own change notification
        // after the model has changed, so observers re-read
        // derived state (`totalUnread` is computed live and needs
        // no refresh — this hop exists only for view updates).
        modelSinks[peer] = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        return model
    }

    func conversationIfExists(for peer: MeshID) -> MeshChatModel? {
        models[peer]
    }

    func unreadCount(for peer: MeshID) -> Int {
        models[peer]?.unreadCount ?? 0
    }

    // MARK: Fan-out entry points (signals via the session controller,
    // refusals via the model's refusal pump)

    /// A signaling envelope that is not a session message. Chat
    /// messages from paired peers are routed to their conversation;
    /// anything else (garbage, media, unpaired senders) is ignored.
    func handle(_ envelope: SignalEnvelope) {
        guard let wire = MeshChatMessage(data: envelope.data) else { return }
        guard isPaired(envelope.from) else { return }
        conversation(for: envelope.from, name: nil).receive(wire)
    }

    /// A server refusal of one of our sends, without correlation
    /// (the shape a server that predates `ref` produces). Attributed
    /// to the globally oldest in-flight chat send (see the type
    /// comment).
    func handleServerError(_ error: MeshError) {
        handleServerError(error, ref: nil)
    }

    /// A server refusal with its correlation echo. A non-nil `ref`
    /// attributes the refusal exactly: the message whose ID it
    /// carries fails, and no other — including when the ref names
    /// a session negotiation or an unknown/settled message, in
    /// which case the chat plane does nothing with it. A nil `ref`
    /// keeps the uncorrelated global-oldest rule.
    func handleServerError(_ error: MeshError, ref: String?) {
        if let ref {
            guard let id = UUID(uuidString: ref) else { return }
            for model in models.values where model.failInFlight(id: id) {
                return
            }
            return
        }
        var victim: MeshChatModel?
        var oldest = Date.distantFuture
        for model in models.values {
            if let inFlight = model.oldestInFlight, inFlight.timestamp < oldest {
                oldest = inFlight.timestamp
                victim = model
            }
        }
        victim?.failOldestInFlight()
    }

    // MARK: Presence and window state (driven by the app)

    /// Keeps existing conversations' reachability in step with the
    /// paired list. Never creates a conversation.
    func updatePresence(peer: MeshID, online: Bool, name: String?) {
        guard let model = models[peer] else { return }
        model.peerIsOnline = online
        if let name { model.peerName = name }
    }

    func setWindowOpen(peer: MeshID, open: Bool) {
        guard let model = models[peer] else { return }
        if open { model.windowOpened() } else { model.windowClosed() }
    }

    /// The signaling connection is gone: every in-flight send
    /// settles as failed.
    func disconnect() {
        for model in models.values { model.disconnect() }
    }
}
