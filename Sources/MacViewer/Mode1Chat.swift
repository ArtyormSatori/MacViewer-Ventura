import Combine
import Foundation

/// One Mode 1 chat conversation with an UltraViewer partner
/// (Phase 3, Mode-1 chat seam): the `ChatTransport` behind the
/// shared floating chat window for UltraViewer sessions. The
/// conversation is keyed by the partner's UltraViewer ID and
/// persists across sessions via `UltraViewerChatHistoryStore`;
/// the per-session `SessionToolsModel` stays the live transport
/// while a session is bound (see `UltraViewerChatCenter`).
///
/// Delivery model (factual, protocol-honest): the UltraViewer
/// protocol has no acknowledgement and no read receipt. An
/// outgoing message is `.sending` when recorded; it settles to
/// `.sent` when the session's send closure completes — the text
/// was handed to the socket path, never "read by the partner" —
/// and to `.failed` when the send throws or the session ends
/// first. Sends made from this window go through
/// `SessionToolsModel.sendChatMessage(_:)`, which serializes
/// them FIFO and reports one outcome per message.
///
/// Inbound messages arrive through the session's existing
/// receive path: the center mirrors `tools.receiveChat` into
/// `recordIncoming`. The Mode 1 wire carries no message IDs, so
/// unlike Mode 2 there is nothing to dedupe on: every accepted
/// inbound text is recorded exactly once, mirroring what the
/// legacy transcript does with it.
@MainActor
final class UltraViewerChatModel: ChatTransport {
    /// Same cap Mode 1 has always enforced on its chat.
    static let maxTextLength = 16_384

    let partner: UltraViewerChatPartner
    @Published var partnerName: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var unreadCount = 0
    /// Whether a live session with this partner is currently
    /// bound (the window's reachability dot and empty-state note
    /// read this; Mode 1 has no presence service — a session is
    /// the only "online" there is).
    @Published private(set) var isBound = false

    private let history: UltraViewerChatHistoryStore
    private let localName: @MainActor () -> String
    private weak var tools: SessionToolsModel?
    /// Bumped on every attach and detach, so a send outcome that
    /// lands after its binding ended is never applied to the
    /// record (the detach already settled the message).
    private var bindingEpoch = 0
    private var nextSequence = 0
    private var windowOpen = false

    init(partner: UltraViewerChatPartner,
         history: UltraViewerChatHistoryStore,
         localName: @escaping @MainActor () -> String) {
        self.partner = partner
        self.partnerName = partner.name
        self.history = history
        self.localName = localName
        let loaded = history.load(partner: partner)
        messages = loaded
        nextSequence = (loaded.map(\.sequence).max() ?? -1) + 1
    }

    // MARK: ChatTransport

    var conversationTitle: String { partnerName ?? partner.displaySubtitle }
    var conversationSubtitle: String { partner.displaySubtitle }
    var peerIsOnline: Bool { isBound }

    var emptyStateNote: String? {
        guard !isBound else { return nil }
        return LF("%@ is not connected. Chat works during a session with this computer.",
                  conversationTitle)
    }

    func send(text: String) {
        // Whitespace-only and over-cap text is refused without a
        // history entry, exactly as the legacy chat refuses it.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= Self.maxTextLength else { return }
        let message = ChatMessage(id: UUID(), senderName: localName(), text: text,
                                  timestamp: Date(), isOutgoing: true,
                                  delivery: .sending, sequence: nextSequence)
        nextSequence += 1
        insertInDisplayOrder(message)
        persist()
        guard let tools else {
            setDelivery(.failed, for: message.id)
            return
        }
        let epoch = bindingEpoch
        Task { [weak self, weak tools] in
            guard let self else { return }
            guard let tools else {
                setDelivery(.failed, for: message.id)
                return
            }
            let outcome = await tools.sendChatMessage(text)
            // A binding change since the send means the detach
            // already settled this message; never flip it back.
            guard bindingEpoch == epoch else { return }
            setDelivery(outcome == .handedToSocket ? .sent : .failed, for: message.id)
        }
    }

    func markAllRead() {
        unreadCount = 0
    }

    // MARK: Binding (called by UltraViewerChatCenter only)

    /// A live session with this partner started: sends now have a
    /// transport, and the center's mirrors on the session's tools
    /// feed `recordIncoming` / `recordDraftSent`.
    func attach(tools: SessionToolsModel) {
        bindingEpoch += 1
        self.tools = tools
        isBound = true
    }

    /// The session ended: no transport remains, and everything
    /// still awaiting a send outcome settles as failed (its
    /// tools-level send was settled by `deactivate()` too).
    func detach() {
        bindingEpoch += 1
        tools = nil
        isBound = false
        var changed = false
        for index in messages.indices where messages[index].delivery == .sending {
            messages[index].delivery = .failed
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Mirrors of the legacy chat paths (center-wired)

    /// An inbound message the session accepted. Recorded once per
    /// accepted text (the wire has no IDs to dedupe on); counts as
    /// unread while the window is closed.
    func recordIncoming(_ text: String) {
        guard text.utf16.count <= Self.maxTextLength else { return }
        let message = ChatMessage(id: UUID(), senderName: conversationTitle,
                                  text: text, timestamp: Date(),
                                  isOutgoing: false, delivery: .received,
                                  sequence: nextSequence)
        nextSequence += 1
        insertInDisplayOrder(message)
        if !windowOpen { unreadCount += 1 }
        persist()
    }

    /// A message the legacy draft path sent successfully (it
    /// appends only on success, so this is a completed send:
    /// handed to the socket, `.sent` on the same basis as a
    /// window send).
    func recordDraftSent(_ text: String) {
        let message = ChatMessage(id: UUID(), senderName: localName(), text: text,
                                  timestamp: Date(), isOutgoing: true,
                                  delivery: .sent, sequence: nextSequence)
        nextSequence += 1
        insertInDisplayOrder(message)
        persist()
    }

    // MARK: Window presence (called by UltraViewerChatCenter only)

    func windowOpened() {
        windowOpen = true
        markAllRead()
    }

    func windowClosed() {
        windowOpen = false
    }

    // MARK: Internals

    /// Display order is (timestamp, sequence): timestamps order
    /// the conversation, the local sequence keeps ties
    /// deterministic.
    private func insertInDisplayOrder(_ message: ChatMessage) {
        messages.append(message)
        messages.sort {
            ($0.timestamp, $0.sequence) < ($1.timestamp, $1.sequence)
        }
    }

    private func setDelivery(_ delivery: ChatMessage.Delivery, for id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].delivery != delivery else { return }
        messages[index].delivery = delivery
        persist()
    }

    private func persist() {
        history.save(partner: partner, messages: messages)
    }
}

/// Owns every Mode 1 conversation and binds live sessions to
/// them (Phase 3, Mode-1 chat seam). One center for the whole
/// app: `ConnectionModel` creates it, `MacHostingModel` receives
/// the same instance from the composition root, so the outgoing
/// and incoming directions share one set of conversations.
///
/// Binding contract: while a session is live, its
/// `SessionToolsModel` is bound to the partner's conversation —
/// the conversation model sends through it, and its legacy-path
/// mirrors (inbound receives, draft sends) are routed into the
/// conversation. Unbinding settles the conversation's in-flight
/// sends as failed and returns it to the offline state; the
/// history stays on disk for the next session with that partner.
@MainActor
final class UltraViewerChatCenter: ObservableObject {
    /// Total unread across all conversations, computed live from
    /// the per-conversation models — the same discipline as the
    /// Mode 2 center (a stored cache refreshed from
    /// `objectWillChange` lags one turn behind the model; a
    /// computed total cannot).
    var totalUnread: Int {
        models.values.reduce(0) { $0 + $1.unreadCount }
    }

    private var models: [String: UltraViewerChatModel] = [:]
    private var modelSinks: [String: AnyCancellable] = [:]
    /// Tools instance → partner ID, for unbinding.
    private var bindings: [ObjectIdentifier: String] = [:]

    private let historyDirectory: URL
    private let localName: @MainActor () -> String

    init(historyDirectory: URL,
         localName: @escaping @MainActor () -> String = { MeshDefaults.deviceName }) {
        self.historyDirectory = historyDirectory
        self.localName = localName
    }

    // MARK: Conversations

    /// The conversation with `partner`, created (and its history
    /// loaded) on first use. Conversations exist whether or not a
    /// chat window was ever opened: bound sessions record into
    /// them regardless.
    func conversation(for partner: UltraViewerChatPartner) -> UltraViewerChatModel {
        if let existing = models[partner.id] {
            if let name = partner.name { existing.partnerName = name }
            return existing
        }
        let model = UltraViewerChatModel(
            partner: partner,
            history: UltraViewerChatHistoryStore(directory: historyDirectory),
            localName: localName)
        models[partner.id] = model
        // The model's `objectWillChange` fires before its
        // mutation; forward this center's own change notification
        // after the model has changed (same hop as the Mode 2
        // center; `totalUnread` is computed live and needs no
        // refresh — this hop exists only for view updates).
        modelSinks[partner.id] = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        return model
    }

    func conversationIfExists(forPartnerID id: String) -> UltraViewerChatModel? {
        models[UltraViewerChatPartner(id: id).id]
    }

    func unreadCount(forPartnerID id: String) -> Int {
        conversationIfExists(forPartnerID: id)?.unreadCount ?? 0
    }

    // MARK: Session binding

    /// Binds a live session's tools to the partner's
    /// conversation. A tools instance serves one session at a
    /// time; if it was somehow bound to another partner, the old
    /// binding is moved.
    func bind(tools: SessionToolsModel, partner: UltraViewerChatPartner) {
        if let previous = bindings[ObjectIdentifier(tools)], previous != partner.id {
            unbind(tools: tools)
        }
        let model = conversation(for: partner)
        bindings[ObjectIdentifier(tools)] = partner.id
        tools.onChatMessageReceived = { [weak model] text in
            model?.recordIncoming(text)
        }
        tools.onDraftMessageSent = { [weak model] text in
            model?.recordDraftSent(text)
        }
        model.attach(tools: tools)
    }

    /// Ends a binding. The conversation keeps its history and
    /// goes offline; its in-flight sends settle as failed.
    /// (Sessions also clear the mirror hooks in `deactivate()`;
    /// clearing them here too keeps unbind correct when it is
    /// called on its own.)
    func unbind(tools: SessionToolsModel) {
        guard let partnerID = bindings.removeValue(forKey: ObjectIdentifier(tools))
        else { return }
        tools.onChatMessageReceived = nil
        tools.onDraftMessageSent = nil
        models[partnerID]?.detach()
    }

    // MARK: Window state (driven by the app)

    func setWindowOpen(partner: UltraViewerChatPartner, open: Bool) {
        guard let model = models[partner.id] else { return }
        if open { model.windowOpened() } else { model.windowClosed() }
    }
}
