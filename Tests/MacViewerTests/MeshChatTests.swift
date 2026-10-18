import Foundation
import MeshClient
import Testing
@testable import MacViewer

/// Mode 2 chat (Phase 3, chunk 3): wire codec, delivery states,
/// ordering/dedupe, per-peer isolation, and history persistence.
/// Combine-bound (the model/center are ObservableObjects), so this
/// suite is CI-only; the codec and history store are additionally
/// exercised on Linux by the harness noted in PHASE3_NOTES.md.
@MainActor
struct MeshChatTests {
    private let alice = MeshID(unchecked: "111222333")
    private let bob = MeshID(unchecked: "444555666")
    private let carol = MeshID(unchecked: "777888999")

    // MARK: Helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshChatTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeCenter(signaling: FakeChatSignaling, paired: Set<MeshID>,
                            directory: URL, window: TimeInterval = 1.25,
                            localName: String = "Alice Mac") -> MeshChatCenter {
        MeshChatCenter(signaling: signaling,
                       isPaired: { paired.contains($0) },
                       localName: { localName },
                       historyDirectory: directory,
                       deliveryWindow: window)
    }

    /// Polls a condition that becomes true once an async send or a
    /// delivery settle has run (same pattern as chunk 2's tests).
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

    private func chatEnvelope(_ wire: MeshChatMessage, from peer: MeshID) -> SignalEnvelope {
        SignalEnvelope(from: peer, kind: MeshChatMessage.transportKind, data: wire.signalingData)
    }

    // MARK: Wire codec

    @Test("Chat envelope codec round-trips id, sender, text, and timestamp")
    func codecRoundTrip() {
        let wire = MeshChatMessage(id: UUID(), fromName: "Bob's Mac",
                                   text: "hello mesh",
                                   timestamp: Date(timeIntervalSince1970: 1_700_000_000.25))
        #expect(MeshChatMessage(data: wire.signalingData) == wire)
    }

    @Test("Codec rejects garbage, media payloads, and session envelopes; session codec rejects chat")
    func codecRejectsGarbage() {
        // Media-style payload: data is a bare SDP string.
        #expect(MeshChatMessage(data: .string("v=0 o=- 1 IN IP4")) == nil)
        // Object without the chat marker.
        #expect(MeshChatMessage(data: .object(["type": .string("chat")])) == nil)
        // Marker present but the payload is a session message.
        let session = MeshSessionMessage(kind: .request, sessionID: "S1", fromName: "Bob")
        #expect(MeshChatMessage(data: session.signalingData) == nil)
        // Chat marker with a wrong message type.
        #expect(MeshChatMessage(data: .object(["mvChat": .object([
            "type": .string("session-request"), "id": .string(UUID().uuidString),
            "text": .string("hi"), "ts": .number(1),
        ])])) == nil)
        // Missing text / missing timestamp / unparseable id / empty text.
        #expect(MeshChatMessage(data: .object(["mvChat": .object([
            "type": .string("chat"), "id": .string(UUID().uuidString), "ts": .number(1),
        ])])) == nil)
        #expect(MeshChatMessage(data: .object(["mvChat": .object([
            "type": .string("chat"), "id": .string(UUID().uuidString), "text": .string("hi"),
        ])])) == nil)
        #expect(MeshChatMessage(data: .object(["mvChat": .object([
            "type": .string("chat"), "id": .string("not-a-uuid"),
            "text": .string("hi"), "ts": .number(1),
        ])])) == nil)
        #expect(MeshChatMessage(data: .object(["mvChat": .object([
            "type": .string("chat"), "id": .string(UUID().uuidString),
            "text": .string(""), "ts": .number(1),
        ])])) == nil)
        // Non-object payloads.
        #expect(MeshChatMessage(data: .array([])) == nil)
        #expect(MeshChatMessage(data: .null) == nil)
        // Discrimination runs both ways: the session codec ignores chat.
        let chat = MeshChatMessage(id: UUID(), text: "hi",
                                   timestamp: Date(timeIntervalSince1970: 5))
        #expect(MeshSessionMessage(data: chat.signalingData) == nil)
    }

    @Test("Unicode text (Vietnamese diacritics, emoji, 10k chars) round-trips byte-exact")
    func unicodeFidelityRoundTrip() {
        let unit = "Xin chào! Tiếng Việt có dấu đầy đủ: ă â đ ê ô ơ ư á à ả ã ạ — emoji 🎉🚀😀🇻🇳 — "
        var text = ""
        while text.count < 10_000 { text += unit }
        #expect(text.utf8.count > 10_000)
        let wire = MeshChatMessage(id: UUID(), fromName: "Máy của Bố",
                                   text: text, timestamp: Date(timeIntervalSince1970: 42))
        let decoded = MeshChatMessage(data: wire.signalingData)
        #expect(decoded?.text == text)
        #expect(decoded.map { Array($0.text.utf8) } == Array(text.utf8))
        #expect(decoded?.fromName == "Máy của Bố")
    }

    // MARK: Sending and delivery states

    @Test("Send records the message, delivers it, and settles to sent; history persists it as sent")
    func sendDeliversAndSettlesToSent() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 0.05)
        let model = center.conversation(for: bob, name: "Bob's Mac")
        model.send(text: "hello bob")
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.delivery == .sending)
        #expect(model.messages.first?.isOutgoing == true)
        await settle("send recorded") { fake.sent.count == 1 }
        let sentWire = fake.sentChatMessages.first
        #expect(sentWire?.id == model.messages.first?.id)
        #expect(sentWire?.text == "hello bob")
        #expect(sentWire?.fromName == "Alice Mac")
        #expect(fake.sent.first?.peer == bob)
        await settle("settled to sent") { model.messages.first?.delivery == .sent }
        let stored = MeshChatHistoryStore(directory: dir).load(peer: bob)
        #expect(stored.count == 1)
        #expect(stored.first?.text == "hello bob")
        #expect(stored.first?.delivery == .sent)
    }

    @Test("A message sent without ever opening the chat window is recorded in history with its delivery state")
    func sendWithoutWindowRecorded() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 0.05)
        // No setWindowOpen call anywhere in this test.
        let model = center.conversation(for: bob, name: nil)
        model.send(text: "no window involved")
        await settle("settled") { model.messages.first?.delivery == .sent }
        let reloaded = MeshChatCenter(signaling: fake, isPaired: { _ in true },
                                      localName: { "Alice Mac" }, historyDirectory: dir)
            .conversation(for: bob, name: nil)
        #expect(reloaded.messages.count == 1)
        #expect(reloaded.messages.first?.text == "no window involved")
        #expect(reloaded.messages.first?.delivery == .sent)
    }

    @Test("A relay refusal (peer offline) fails the in-flight message, which never flips to sent")
    func refusalFailsInFlight() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        // Long delivery window: only the refusal can settle this.
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 30)
        let model = center.conversation(for: bob, name: nil)
        model.send(text: "are you there?")
        await settle("send recorded") { fake.sent.count == 1 }
        center.handleServerError(.peerOffline)
        #expect(model.messages.first?.delivery == .failed)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.messages.first?.delivery == .failed)
        #expect(MeshChatHistoryStore(directory: dir).load(peer: bob).first?.delivery == .failed)
    }

    @Test("A transport failure (not connected) fails the message immediately")
    func transportThrowFails() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        fake.setConnected(false)
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 0.05)
        let model = center.conversation(for: bob, name: nil)
        model.send(text: "cannot go out")
        await settle("failed") { model.messages.first?.delivery == .failed }
        #expect(fake.sent.isEmpty)
    }

    @Test("Whitespace-only and over-cap sends are refused without a history entry")
    func refusedSendsLeaveNoTrace() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 0.05)
        let model = center.conversation(for: bob, name: nil)
        model.send(text: "   \n\t  ")
        model.send(text: String(repeating: "a", count: MeshChatModel.maxTextLength + 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.messages.isEmpty)
        #expect(fake.sent.isEmpty)
        #expect(MeshChatHistoryStore(directory: dir).load(peer: bob).isEmpty)
    }

    @Test("Disconnecting settles every in-flight message as failed")
    func disconnectFailsInFlight() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 30)
        let model = center.conversation(for: bob, name: nil)
        model.send(text: "in flight")
        await settle("send recorded") { fake.sent.count == 1 }
        center.disconnect()
        #expect(model.messages.first?.delivery == .failed)
    }

    // MARK: Receiving

    @Test("Two models exchange a message end to end over the fake channel, byte-exact")
    func twoModelRoundTrip() async {
        let dirA = tempDir(); let dirB = tempDir()
        defer { cleanup(dirA); cleanup(dirB) }
        let fakeA = FakeChatSignaling()
        let fakeB = FakeChatSignaling()
        let aliceCenter = makeCenter(signaling: fakeA, paired: [bob], directory: dirA, window: 0.05)
        let bobCenter = MeshChatCenter(signaling: fakeB,
                                       isPaired: { $0 == self.alice },
                                       localName: { "Bob's Mac" },
                                       historyDirectory: dirB, deliveryWindow: 0.05)
        let text = "Chào Bob, đây là tin nhắn thử nghiệm 👋"
        aliceCenter.conversation(for: bob, name: "Bob's Mac").send(text: text)
        await settle("alice sent") { fakeA.sent.count == 1 }
        guard let frame = fakeA.sent.first else { return }
        bobCenter.handle(SignalEnvelope(from: alice, kind: frame.kind, data: frame.data))
        let bobModel = bobCenter.conversationIfExists(for: alice)
        #expect(bobModel?.messages.count == 1)
        #expect(bobModel?.messages.first?.text == text)
        #expect(bobModel.map { Array($0.messages[0].text.utf8) } == Array(text.utf8))
        #expect(bobModel?.messages.first?.senderName == "Alice Mac")
        #expect(bobModel?.messages.first?.delivery == .received)
        #expect(bobModel?.messages.first?.isOutgoing == false)
        #expect(bobCenter.totalUnread == 1)
    }

    @Test("Inbound messages count as unread until the conversation's window opens")
    func unreadUntilWindowOpens() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir)
        let wire = MeshChatMessage(id: UUID(), fromName: "Bob's Mac", text: "ping",
                                   timestamp: Date(timeIntervalSince1970: 100))
        center.handle(chatEnvelope(wire, from: bob))
        let model = center.conversationIfExists(for: bob)
        #expect(model?.unreadCount == 1)
        #expect(center.totalUnread == 1)
        center.setWindowOpen(peer: bob, open: true)
        #expect(model?.unreadCount == 0)
        #expect(center.totalUnread == 0)
        // While the window is open, new arrivals are read at once.
        let wire2 = MeshChatMessage(id: UUID(), fromName: "Bob's Mac", text: "pong",
                                    timestamp: Date(timeIntervalSince1970: 101))
        center.handle(chatEnvelope(wire2, from: bob))
        #expect(model?.unreadCount == 0)
        #expect(model?.messages.count == 2)
        center.setWindowOpen(peer: bob, open: false)
        let wire3 = MeshChatMessage(id: UUID(), fromName: "Bob's Mac", text: "again",
                                    timestamp: Date(timeIntervalSince1970: 102))
        center.handle(chatEnvelope(wire3, from: bob))
        #expect(model?.unreadCount == 1)
    }

    @Test("A chat message from an unpaired peer is ignored entirely")
    func unpairedPeerIgnored() {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir)
        let wire = MeshChatMessage(id: UUID(), fromName: "Carol", text: "let me in",
                                   timestamp: Date(timeIntervalSince1970: 100))
        center.handle(chatEnvelope(wire, from: carol))
        #expect(center.conversationIfExists(for: carol) == nil)
        #expect(center.totalUnread == 0)
        #expect(MeshChatHistoryStore(directory: dir).load(peer: carol).isEmpty)
    }

    @Test("Garbage inbound envelopes change nothing: no conversation, no messages, no unread")
    func garbageInboundIgnored() {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir)
        // A session envelope (not chat), an SDP string, a junk object.
        center.handle(SignalEnvelope(
            from: bob, kind: .offer,
            data: MeshSessionMessage(kind: .request, sessionID: "S1").signalingData))
        center.handle(SignalEnvelope(from: bob, kind: .offer, data: .string("v=0 o=-")))
        center.handle(SignalEnvelope(from: bob, kind: .ice,
                                     data: .object(["whatever": .number(1)])))
        #expect(center.conversationIfExists(for: bob) == nil)
        #expect(center.totalUnread == 0)
    }

    @Test("A duplicated inbound delivery is displayed and stored exactly once")
    func duplicateInboundStoredOnce() {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir)
        let wire = MeshChatMessage(id: UUID(), fromName: "Bob's Mac", text: "once only",
                                   timestamp: Date(timeIntervalSince1970: 100))
        center.handle(chatEnvelope(wire, from: bob))
        center.handle(chatEnvelope(wire, from: bob))
        let model = center.conversationIfExists(for: bob)
        #expect(model?.messages.count == 1)
        #expect(model?.unreadCount == 1)
        #expect(MeshChatHistoryStore(directory: dir).load(peer: bob).count == 1)
    }

    @Test("Out-of-order inbound arrivals sort by timestamp; equal timestamps keep arrival order")
    func outOfOrderInboundSorted() {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir)
        func wire(_ text: String, _ ts: Double) -> MeshChatMessage {
            MeshChatMessage(id: UUID(), fromName: "Bob", text: text,
                            timestamp: Date(timeIntervalSince1970: ts))
        }
        center.handle(chatEnvelope(wire("third", 300), from: bob))
        center.handle(chatEnvelope(wire("first", 100), from: bob))
        center.handle(chatEnvelope(wire("second-a", 200), from: bob))
        center.handle(chatEnvelope(wire("second-b", 200), from: bob))
        let texts = center.conversationIfExists(for: bob)?.messages.map(\.text)
        #expect(texts == ["first", "second-a", "second-b", "third"])
        let storedTexts = MeshChatHistoryStore(directory: dir).load(peer: bob).map(\.text)
        #expect(storedTexts == ["first", "second-a", "second-b", "third"])
    }

    @Test("Two peers' histories and unread state never leak into each other")
    func perPeerIsolation() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob, carol], directory: dir, window: 0.05)
        center.handle(chatEnvelope(
            MeshChatMessage(id: UUID(), fromName: "Bob", text: "for alice from bob",
                            timestamp: Date(timeIntervalSince1970: 100)), from: bob))
        center.conversation(for: carol, name: "Carol").send(text: "for carol")
        await settle("carol send settled") {
            center.conversationIfExists(for: carol)?.messages.first?.delivery == .sent
        }
        let bobModel = center.conversationIfExists(for: bob)
        let carolModel = center.conversationIfExists(for: carol)
        #expect(bobModel?.messages.map(\.text) == ["for alice from bob"])
        #expect(carolModel?.messages.map(\.text) == ["for carol"])
        #expect(bobModel?.unreadCount == 1)
        #expect(carolModel?.unreadCount == 0)
        #expect(center.totalUnread == 1)
        let store = MeshChatHistoryStore(directory: dir)
        #expect(store.load(peer: bob).map(\.text) == ["for alice from bob"])
        #expect(store.load(peer: carol).map(\.text) == ["for carol"])
        #expect(store.load(peer: alice).isEmpty)
    }

    // MARK: History persistence

    private func sample(_ text: String, outgoing: Bool,
                        delivery: ChatMessage.Delivery, sequence: Int,
                        ts: Double = 1_700_000_000) -> ChatMessage {
        ChatMessage(id: UUID(), senderName: outgoing ? "Alice Mac" : "Bob's Mac",
                    text: text, timestamp: Date(timeIntervalSince1970: ts),
                    isOutgoing: outgoing, delivery: delivery, sequence: sequence)
    }

    @Test("History store round-trips a mixed conversation exactly")
    func historyRoundTrip() {
        let dir = tempDir(); defer { cleanup(dir) }
        let store = MeshChatHistoryStore(directory: dir)
        let messages = [
            sample("one", outgoing: false, delivery: .received, sequence: 0),
            sample("two", outgoing: true, delivery: .sent, sequence: 1),
            sample("three", outgoing: true, delivery: .failed, sequence: 2),
        ]
        store.save(peer: bob, messages: messages)
        #expect(store.load(peer: bob) == messages)
        #expect(store.load(peer: carol).isEmpty)
    }

    @Test("A message persisted mid-send loads as failed, never as still sending")
    func historyLoadNormalizesSending() {
        let dir = tempDir(); defer { cleanup(dir) }
        let store = MeshChatHistoryStore(directory: dir)
        store.save(peer: bob, messages: [sample("mid-send", outgoing: true,
                                               delivery: .sending, sequence: 0)])
        #expect(store.load(peer: bob).first?.delivery == .failed)
    }

    @Test("A corrupt history file loads as empty and the next save overwrites it cleanly")
    func corruptHistoryRecovers() async {
        let dir = tempDir(); defer { cleanup(dir) }
        let store = MeshChatHistoryStore(directory: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = store.fileURL(for: bob)
        // Garbage bytes, then a truncated JSON array: both are empty.
        try! Data([0xFF, 0x00, 0x41, 0x7B]).write(to: file)
        #expect(store.load(peer: bob).isEmpty)
        try! Data("[{\"id\":".utf8).write(to: file)
        #expect(store.load(peer: bob).isEmpty)
        // A model built on the corrupt file starts empty, then saves
        // over it: the recovered history contains only the new message.
        let fake = FakeChatSignaling()
        let center = makeCenter(signaling: fake, paired: [bob], directory: dir, window: 0.05)
        let model = center.conversation(for: bob, name: nil)
        #expect(model.messages.isEmpty)
        model.send(text: "fresh start")
        await settle("settled") { model.messages.first?.delivery == .sent }
        let stored = store.load(peer: bob)
        #expect(stored.count == 1)
        #expect(stored.first?.text == "fresh start")
    }
}

/// In-memory `MeshSignalingAPI` double for chat tests: records
/// sends, lets tests inject peer signals and server errors. All
/// mutable state sits behind `withLock` (Swift 6 forbids
/// lock/unlock in async contexts).
private final class FakeChatSignaling: MeshSignalingAPI, @unchecked Sendable {
    struct Sent: Equatable {
        let peer: MeshID
        let kind: SignalKind
        let data: JSONValue
    }

    private let lock = NSLock()
    private var connected = true
    private var sentStorage: [Sent] = []

    let signals: AsyncStream<SignalEnvelope>
    let serverErrors: AsyncStream<MeshError>
    private let signalContinuation: AsyncStream<SignalEnvelope>.Continuation
    private let errorContinuation: AsyncStream<MeshError>.Continuation

    init() {
        var sc: AsyncStream<SignalEnvelope>.Continuation!
        signals = AsyncStream { sc = $0 }
        signalContinuation = sc
        var ec: AsyncStream<MeshError>.Continuation!
        serverErrors = AsyncStream { ec = $0 }
        errorContinuation = ec
    }

    var isConnected: Bool { lock.withLock { connected } }

    func setConnected(_ value: Bool) {
        lock.withLock { connected = value }
    }

    func sendSignal(to peer: MeshID, kind: SignalKind, data: JSONValue) async throws {
        guard isConnected else { throw MeshError.connectionClosed }
        lock.withLock { sentStorage.append(Sent(peer: peer, kind: kind, data: data)) }
    }

    var sent: [Sent] { lock.withLock { sentStorage } }

    var sentChatMessages: [MeshChatMessage] {
        sent.compactMap { MeshChatMessage(data: $0.data) }
    }

    func inject(_ envelope: SignalEnvelope) {
        signalContinuation.yield(envelope)
    }

    func emitError(_ error: MeshError) {
        errorContinuation.yield(error)
    }
}
