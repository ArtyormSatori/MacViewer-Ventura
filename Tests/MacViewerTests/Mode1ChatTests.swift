import AppKit
import Foundation
import MeshClient
import Testing
@testable import MacViewer

/// Mode 1 chat in the shared floating window (Phase 3, Mode-1
/// chat seam): the message-level send API on `SessionToolsModel`,
/// the per-partner conversation model/center, honest delivery
/// mapping, namespaced history, and unread bookkeeping.
/// Combine/AppKit-bound, so this suite is CI-only; the
/// Foundation-only layer (partner identity + history store) is
/// additionally exercised on Linux by the harness noted in
/// PHASE3_NOTES.md.
@MainActor
struct Mode1ChatTests {
    private let partner = UltraViewerChatPartner(id: "123456789", name: "Partner PC")
    private let otherPartner = UltraViewerChatPartner(id: "987654321", name: "Other PC")

    // MARK: Helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Mode1ChatTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Polls a condition that becomes true once an async send or
    /// a delivery settle has run (same pattern as the mesh chat
    /// tests).
    private func settle(_ description: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting: \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A tools model with clipboard sharing off (chat tests must
    /// not start the clipboard machinery) on a private pasteboard
    /// and defaults suite.
    private func makeTools() -> SessionToolsModel {
        let board = NSPasteboard.withUniqueName()
        let defaults = UserDefaults(suiteName: "Mode1ChatTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SessionToolsModel.shareClipboardKey)
        return SessionToolsModel(pasteboard: board, defaults: defaults)
    }

    private func activate(_ tools: SessionToolsModel, sender: GatedChatSender) {
        tools.activate(sendChat: { text in try await sender.send(text) },
                       sendClipboard: { _ in },
                       setSharing: { _ in })
    }

    private func makeCenter(directory: URL) -> UltraViewerChatCenter {
        UltraViewerChatCenter(historyDirectory: directory, localName: { "My Mac" })
    }

    // MARK: SessionToolsModel message-level send API

    @Test("sendChatMessage hands the text to the socket and leaves the draft and transcript alone")
    func sendHandsTextToSocket() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        tools.draft = "draft in progress"
        let outcome = await tools.sendChatMessage("window message")
        #expect(outcome == .handedToSocket)
        #expect(sender.completed == ["window message"])
        // The seam is a sibling of the draft path: it neither
        // reads/clears the draft nor appends to the legacy
        // transcript — the conversation model keeps the record.
        #expect(tools.draft == "draft in progress")
        #expect(tools.messages.isEmpty)
        tools.deactivate()
    }

    @Test("sendChatMessage maps a transport throw to .failed")
    func sendThrowMapsToFailed() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        sender.failure = TestSendError()
        activate(tools, sender: sender)
        let outcome = await tools.sendChatMessage("doomed")
        #expect(outcome == .failed)
        #expect(sender.completed.isEmpty)
        tools.deactivate()
    }

    @Test("sendChatMessage refuses whitespace-only and over-cap text without touching the transport")
    func sendRefusesLocally() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        #expect(await tools.sendChatMessage("   \n") == .refused)
        #expect(await tools.sendChatMessage(String(repeating: "a", count: 16_385)) == .refused)
        #expect(sender.started.isEmpty)
        // Exactly at the cap is accepted.
        let atCap = String(repeating: "a", count: 16_384)
        #expect(await tools.sendChatMessage(atCap) == .handedToSocket)
        #expect(sender.completed == [atCap])
        tools.deactivate()
    }

    @Test("sendChatMessage while no session is active fails without a transport call")
    func sendWhileInactiveFails() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        #expect(await tools.sendChatMessage("too early") == .failed)
        activate(tools, sender: sender)
        tools.deactivate()
        #expect(await tools.sendChatMessage("too late") == .failed)
        #expect(sender.started.isEmpty)
    }

    @Test("Concurrent sendChatMessage calls serialize FIFO, one in flight, order preserved")
    func sendsSerializeFIFO() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        sender.blocked = true
        activate(tools, sender: sender)
        let first = Task { await tools.sendChatMessage("one") }
        await settle("first send in flight") { sender.started == ["one"] }
        let second = Task { await tools.sendChatMessage("two") }
        let third = Task { await tools.sendChatMessage("three") }
        // Give the queued sends their turns to enqueue; the gate
        // guarantees neither can start while the first is held.
        for _ in 0..<20 { await Task.yield() }
        #expect(sender.started == ["one"])
        sender.release()
        #expect(await first.value == .handedToSocket)
        #expect(await second.value == .handedToSocket)
        #expect(await third.value == .handedToSocket)
        #expect(sender.completed == ["one", "two", "three"])
        #expect(sender.maxInFlight == 1)
        tools.deactivate()
    }

    @Test("deactivate() settles queued and in-flight sends as failed, and the queue works after reactivation")
    func deactivateSettlesSends() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        sender.blocked = true
        activate(tools, sender: sender)
        let first = Task { await tools.sendChatMessage("held") }
        await settle("first send in flight") { sender.started == ["held"] }
        let second = Task { await tools.sendChatMessage("queued one") }
        let third = Task { await tools.sendChatMessage("queued two") }
        for _ in 0..<20 { await Task.yield() }
        tools.deactivate()
        // Deactivation settles every outstanding send itself —
        // including the one still blocked inside the transport.
        #expect(await first.value == .failed)
        #expect(await second.value == .failed)
        #expect(await third.value == .failed)
        sender.release()
        // A later session on the same model sends normally: the
        // queue is drained, not wedged.
        let sender2 = GatedChatSender()
        activate(tools, sender: sender2)
        #expect(await tools.sendChatMessage("new session") == .handedToSocket)
        #expect(sender2.completed == ["new session"])
        tools.deactivate()
    }

    @Test("Legacy mirrors fire for inbound receives and successful draft sends only")
    func legacyHooksMirror() async {
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        var received: [String] = []
        var draftSent: [String] = []
        tools.onChatMessageReceived = { received.append($0) }
        tools.onDraftMessageSent = { draftSent.append($0) }
        tools.receiveChat("from partner")
        #expect(received == ["from partner"])
        tools.draft = "from the panel"
        tools.sendDraft()
        await settle("draft send mirrored") { draftSent == ["from the panel"] }
        // The legacy flow itself is intact: appended + draft cleared.
        #expect(tools.messages.map(\.text) == ["from partner", "from the panel"])
        #expect(tools.draft.isEmpty)
        // A failed draft send fires no mirror.
        sender.failure = TestSendError()
        tools.draft = "will fail"
        tools.sendDraft()
        await settle("draft failure surfaced") { tools.errorMessage != nil }
        #expect(draftSent == ["from the panel"])
        tools.deactivate()
        // Deactivation clears the mirrors.
        #expect(tools.onChatMessageReceived == nil)
        #expect(tools.onDraftMessageSent == nil)
    }

    // MARK: Conversation model + center

    @Test("A window send records .sending, settles to .sent when handed to the socket, and persists")
    func conversationSendSettlesSentAndPersists() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        let model = center.conversation(for: partner)
        #expect(model.peerIsOnline)
        model.send(text: "hello partner")
        // Recorded optimistically, still in flight in this turn.
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.delivery == .sending)
        await settle("send settled") { model.messages.first?.delivery == .sent }
        #expect(sender.completed == ["hello partner"])
        center.unbind(tools: tools)
        tools.deactivate()
        // A fresh center over the same directory reloads it.
        let reloaded = makeCenter(directory: dir).conversation(for: partner)
        #expect(reloaded.messages.map(\.text) == ["hello partner"])
        #expect(reloaded.messages.first?.delivery == .sent)
        #expect(reloaded.messages.first?.isOutgoing == true)
    }

    @Test("A window send whose transport throws settles to .failed and persists as failed")
    func conversationSendFailureSettlesFailed() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let tools = makeTools()
        let sender = GatedChatSender()
        sender.failure = TestSendError()
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        let model = center.conversation(for: partner)
        model.send(text: "doomed")
        await settle("send failed") { model.messages.first?.delivery == .failed }
        center.unbind(tools: tools)
        tools.deactivate()
        let reloaded = makeCenter(directory: dir).conversation(for: partner)
        #expect(reloaded.messages.map(\.text) == ["doomed"])
        #expect(reloaded.messages.first?.delivery == .failed)
    }

    @Test("Sending with no session bound records the message and fails it at once")
    func conversationSendWhileUnbound() {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let model = center.conversation(for: partner)
        #expect(!model.peerIsOnline)
        #expect(model.emptyStateNote != nil)
        model.send(text: "nobody home")
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.delivery == .failed)
        // Refused text leaves no record, as in the legacy chat.
        model.send(text: "   ")
        model.send(text: String(repeating: "a", count: 16_385))
        #expect(model.messages.count == 1)
    }

    @Test("Inbound messages record as received and drive the unread lifecycle")
    func inboundRecordsAndUnreadLifecycle() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        let model = center.conversation(for: partner)
        // The mirror fires synchronously out of the session's
        // existing receive path.
        tools.receiveChat("first")
        #expect(model.messages.map(\.text) == ["first"])
        #expect(model.messages.first?.delivery == .received)
        #expect(model.messages.first?.isOutgoing == false)
        #expect(model.unreadCount == 1)
        #expect(center.totalUnread == 1)
        // Opening the window reads the conversation.
        center.setWindowOpen(partner: partner, open: true)
        #expect(model.unreadCount == 0)
        #expect(center.totalUnread == 0)
        tools.receiveChat("while open")
        #expect(model.unreadCount == 0)
        // Closing re-arms counting.
        center.setWindowOpen(partner: partner, open: false)
        tools.receiveChat("after close")
        #expect(model.unreadCount == 1)
        #expect(model.messages.map(\.text) == ["first", "while open", "after close"])
        center.unbind(tools: tools)
        tools.deactivate()
    }

    @Test("Draft sends from the legacy panel mirror into the conversation as sent")
    func draftSendsMirrorIntoConversation() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        let model = center.conversation(for: partner)
        tools.draft = "panel hello"
        tools.sendDraft()
        await settle("draft send mirrored") { model.messages.count == 1 }
        #expect(model.messages.first?.text == "panel hello")
        #expect(model.messages.first?.isOutgoing == true)
        #expect(model.messages.first?.delivery == .sent)
        center.unbind(tools: tools)
        tools.deactivate()
    }

    @Test("Unbinding settles an in-flight window send as failed, goes offline, and clears the mirrors")
    func unbindSettlesInFlight() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        let tools = makeTools()
        let sender = GatedChatSender()
        sender.blocked = true
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        let model = center.conversation(for: partner)
        model.send(text: "stuck")
        await settle("send in flight") { sender.started == ["stuck"] }
        #expect(model.messages.first?.delivery == .sending)
        center.unbind(tools: tools)
        // The detach settles synchronously; the send's late
        // outcome must never flip the record back.
        #expect(model.messages.first?.delivery == .failed)
        #expect(!model.peerIsOnline)
        #expect(tools.onChatMessageReceived == nil)
        #expect(tools.onDraftMessageSent == nil)
        sender.release()
        tools.deactivate()
    }

    @Test("Window-open bookkeeping never creates a conversation")
    func windowBookkeepingDoesNotCreate() {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        center.setWindowOpen(partner: partner, open: true)
        #expect(center.conversationIfExists(forPartnerID: partner.id) == nil)
        #expect(center.totalUnread == 0)
    }

    @Test("Conversation identity is stable per partner and keyed by the normalized ID")
    func conversationIdentityIsStable() {
        let dir = tempDir(); defer { cleanup(dir) }
        let center = makeCenter(directory: dir)
        #expect(center.conversationIfExists(forPartnerID: partner.id) == nil)
        let first = center.conversation(for: partner)
        // The same partner written with spaces keys identically,
        // and a later name updates the conversation's title.
        let respelled = UltraViewerChatPartner(id: "123 456 789", name: "Renamed PC")
        let second = center.conversation(for: respelled)
        #expect(first === second)
        #expect(second.conversationTitle == "Renamed PC")
        #expect(center.conversationIfExists(forPartnerID: "123456789") === first)
        let other = center.conversation(for: otherPartner)
        #expect(other !== first)
        #expect(other.conversationSubtitle == "987 654 321")
    }

    // MARK: History store

    @Test("Mode 1 and Mode 2 histories in one directory never collide, even for numerically equal IDs")
    func historyIsolationBetweenModes() {
        let dir = tempDir(); defer { cleanup(dir) }
        let mode1Store = UltraViewerChatHistoryStore(directory: dir)
        let mode2Store = MeshChatHistoryStore(directory: dir)
        let meshPeer = MeshID(unchecked: "123456789")
        let mode1Message = ChatMessage(id: UUID(), senderName: "My Mac",
                                       text: "mode one text", timestamp: Date(),
                                       isOutgoing: true, delivery: .sent, sequence: 0)
        let mode2Message = ChatMessage(id: UUID(), senderName: "My Mac",
                                       text: "mode two text", timestamp: Date(),
                                       isOutgoing: true, delivery: .sent, sequence: 0)
        mode1Store.save(partner: partner, messages: [mode1Message])
        mode2Store.save(peer: meshPeer, messages: [mode2Message])
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        #expect(files == ["chat-uv-123456789.json", "chat-123456789.json"])
        #expect(mode1Store.load(partner: partner).map(\.text) == ["mode one text"])
        #expect(mode2Store.load(peer: meshPeer).map(\.text) == ["mode two text"])
        // A different partner on either side loads empty.
        #expect(mode1Store.load(partner: otherPartner).isEmpty)
    }

    @Test("A message persisted mid-send loads as failed, never as still sending")
    func persistedSendingLoadsAsFailed() {
        let dir = tempDir(); defer { cleanup(dir) }
        let store = UltraViewerChatHistoryStore(directory: dir)
        let inFlight = ChatMessage(id: UUID(), senderName: "My Mac",
                                   text: "was sending", timestamp: Date(),
                                   isOutgoing: true, delivery: .sending, sequence: 0)
        store.save(partner: partner, messages: [inFlight])
        #expect(store.load(partner: partner).first?.delivery == .failed)
        let model = makeCenter(directory: dir).conversation(for: partner)
        #expect(model.messages.first?.delivery == .failed)
    }

    @Test("Corrupt Mode 1 history loads empty and the next save overwrites it cleanly")
    func corruptHistoryRecovers() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let store = UltraViewerChatHistoryStore(directory: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("not json at all".utf8).write(to: store.fileURL(for: partner))
        let center = makeCenter(directory: dir)
        let model = center.conversation(for: partner)
        #expect(model.messages.isEmpty)
        let tools = makeTools()
        let sender = GatedChatSender()
        activate(tools, sender: sender)
        center.bind(tools: tools, partner: partner)
        model.send(text: "fresh start")
        await settle("send settled") { model.messages.first?.delivery == .sent }
        center.unbind(tools: tools)
        tools.deactivate()
        #expect(store.load(partner: partner).map(\.text) == ["fresh start"])
    }
}

/// A send transport that can block and fail on cue, so tests can
/// hold a send in flight while they poke the lifecycle around it.
/// All access is on the main actor (the tools' send closures are
/// `@MainActor`), so no locking is needed.
@MainActor
private final class GatedChatSender {
    private(set) var started: [String] = []
    private(set) var completed: [String] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    var blocked = false
    var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_ text: String) async throws {
        started.append(text)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if blocked {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight -= 1
        if let failure { throw failure }
        completed.append(text)
    }

    func release() {
        blocked = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private struct TestSendError: Error {}
