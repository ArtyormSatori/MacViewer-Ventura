import AppKit
import Combine
import Foundation

struct SessionChatMessage: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let text: String
    let isOutgoing: Bool
}

/// The outcome of one message-level chat send (see
/// `SessionToolsModel.sendChatMessage(_:)`). The UltraViewer
/// protocol has no acknowledgement and no read receipt, so the
/// strongest claim a completed send supports is that the text was
/// handed to the session's socket path — never that the partner
/// saw it. The shared chat window maps `.handedToSocket` to its
/// "Sent" caption on exactly that basis.
enum ChatSendOutcome: Equatable, Sendable {
    /// Refused locally: whitespace-only or over the
    /// 16,384-character cap. The transport was never touched.
    case refused
    /// The send closure completed without throwing: the text was
    /// handed to the session's socket path.
    case handedToSocket
    /// The send closure threw, or the session ended before the
    /// send could run (or while it was in flight).
    case failed
}

/// Per-session text tools. Clipboard polling starts only after an explicit
/// toggle and successful protocol setup; existing clipboard contents are not
/// sent when sharing is enabled. Nothing is persisted to disk.
@MainActor
final class SessionToolsModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [SessionChatMessage] = []
    @Published private(set) var isActive = false
    @Published private(set) var isSending = false
    @Published private(set) var peerIsTyping = false
    @Published private(set) var clipboardEnabled = false
    @Published private(set) var isUpdatingClipboard = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var clipboardStatus = "Clipboard sharing is off."

    typealias SendText = @MainActor (String) async throws -> Void
    typealias SetSharing = @MainActor (Bool) async throws -> Void
    typealias SendTyping = @MainActor (Bool) async throws -> Void

    /// Mirrors for the shared floating chat window (Phase 3,
    /// Mode-1 seam). Set by `UltraViewerChatCenter` while a
    /// session is bound to a persistent conversation; nil in the
    /// legacy-only flow, and behavior is identical while unset.
    /// `onChatMessageReceived` fires for every accepted inbound
    /// message; `onDraftMessageSent` fires after a `sendDraft()`
    /// send completes (the draft path appends only on success, so
    /// this reports a completed send, never an attempt).
    var onChatMessageReceived: (@MainActor (String) -> Void)?
    var onDraftMessageSent: (@MainActor (String) -> Void)?

    private var sendChat: SendText?
    private var sendClipboard: SendText?
    private var setSharing: SetSharing?
    private var sendTyping: SendTyping?
    private var typingTask: Task<Void, Never>?
    private var peerTypingTask: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private var generation = UUID()
    private var clipboardGeneration = UUID()
    private var chatTask: Task<Void, Never>?
    private var chatSendQueue: [ChatSendJob] = []
    private var inFlightChatSend: ChatSendJob?
    private var chatSendWorker: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var clipboardSetup: Task<Void, Never>?
    private var clipboardChange = 0
    private var latestClipboardText: String?

    /// Like UltraViewer on Windows, clipboard sharing starts with each session
    /// unless turned off in Settings.
    static let shareClipboardKey = "MacViewer.shareClipboard"
    private let defaults: UserDefaults

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        defaults.register(defaults: [Self.shareClipboardKey: true])
    }

    func activate(sendChat: @escaping SendText, sendClipboard: @escaping SendText,
                  setSharing: @escaping SetSharing, sendTyping: SendTyping? = nil) {
        deactivate()
        self.sendChat = sendChat; self.sendClipboard = sendClipboard; self.setSharing = setSharing
        self.sendTyping = sendTyping
        messages = []; draft = ""; errorMessage = nil; isActive = true
        if defaults.bool(forKey: Self.shareClipboardKey) { setClipboardEnabled(true) }
    }

    func deactivate() {
        generation = UUID(); clipboardGeneration = UUID()
        chatTask?.cancel(); chatTask = nil
        // Settle every message-level send: nothing queued or in
        // flight may outlive the session, and no caller may be
        // left awaiting an outcome that can no longer arrive. The
        // send worker is deliberately not cancelled: it observes
        // the drained queue, settles its current job as a no-op
        // (settling is idempotent), and exits on its own, so a
        // send enqueued by a following activate() is never left
        // without a worker.
        inFlightChatSend?.settle(.failed); inFlightChatSend = nil
        for job in chatSendQueue { job.settle(.failed) }
        chatSendQueue.removeAll()
        onChatMessageReceived = nil
        onDraftMessageSent = nil
        typingTask?.cancel(); typingTask = nil
        peerTypingTask?.cancel(); peerTypingTask = nil; peerIsTyping = false
        clipboardTask?.cancel(); clipboardTask = nil
        clipboardSetup?.cancel(); clipboardSetup = nil
        sendChat = nil; sendClipboard = nil; setSharing = nil
        sendTyping = nil
        isActive = false; isSending = false; clipboardEnabled = false; isUpdatingClipboard = false
        latestClipboardText = nil
        clipboardStatus = "Clipboard sharing is off."
    }

    func sendDraft() {
        guard isActive, !isSending, let sendChat,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        guard text.utf16.count <= 16_384 else { errorMessage = "Keep chat messages under 16,384 characters."; return }
        let token = generation
        isSending = true; errorMessage = nil
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sendChat(text)
                guard generation == token, isActive else { return }
                append(text, outgoing: true)
                onDraftMessageSent?(text)
                if draft == text { draft = "" }
            } catch {
                guard generation == token, isActive, !Task.isCancelled else { return }
                errorMessage = "The chat message could not be sent."
            }
            if generation == token { isSending = false }
        }
    }

    /// Message-level chat send for the shared chat window: sends
    /// `text` and reports the outcome for exactly this message,
    /// without reading or modifying `draft` and without appending
    /// to the legacy transcript (the caller's conversation model
    /// keeps its own record). Sends serialize through a FIFO
    /// queue: a call made while another send is in flight waits
    /// its turn instead of being refused — the draft path's
    /// single-flight gate is a UI convenience, not a transport
    /// limit, and the session underneath serializes its own
    /// sends. Whitespace-only and over-cap text is refused
    /// locally and never reaches the transport.
    func sendChatMessage(_ text: String) async -> ChatSendOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 16_384 else { return .refused }
        guard isActive, sendChat != nil else { return .failed }
        let token = generation
        return await withCheckedContinuation { continuation in
            chatSendQueue.append(ChatSendJob(text: text, token: token,
                                             continuation: continuation))
            startChatSendWorkerIfNeeded()
        }
    }

    private func startChatSendWorkerIfNeeded() {
        guard chatSendWorker == nil else { return }
        chatSendWorker = Task { [weak self] in
            // One strong unwrap for the worker's whole life:
            // per-iteration `while let self` unwrapping left
            // later statements seeing the optional self again
            // (Swift 6 rejects the implicit access). deactivate()
            // settles queued jobs as failed, so a held-alive
            // worker still drains promptly at session end.
            guard let self else { return }
            while !chatSendQueue.isEmpty {
                let job = chatSendQueue.removeFirst()
                inFlightChatSend = job
                guard job.token == generation, isActive, let sendChat else {
                    job.settle(.failed)
                    if inFlightChatSend === job { inFlightChatSend = nil }
                    continue
                }
                do {
                    try await sendChat(job.text)
                    // A send that completes after the session
                    // turned over did not deliver in this session
                    // (same rule as the draft path's append).
                    job.settle(job.token == generation && isActive
                               ? .handedToSocket : .failed)
                } catch {
                    job.settle(.failed)
                }
                if inFlightChatSend === job { inFlightChatSend = nil }
            }
            chatSendWorker = nil
        }
    }

    func receiveChat(_ text: String) {
        guard isActive, text.utf16.count <= 16_384 else { return }
        receiveTyping(false)
        append(text, outgoing: false)
        onChatMessageReceived?(text)
    }

    func receiveTyping(_ typing: Bool) {
        guard isActive else { return }
        peerTypingTask?.cancel(); peerIsTyping = typing
        guard typing else { return }
        let token = generation
        peerTypingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, generation == token else { return }
            peerIsTyping = false
        }
    }

    func draftChanged() {
        guard isActive, let sendTyping else { return }
        typingTask?.cancel()
        let token = generation, typing = !draft.isEmpty
        typingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, generation == token, isActive else { return }
                try await sendTyping(typing)
                if typing {
                    try await Task.sleep(for: .seconds(2))
                    guard generation == token, isActive else { return }
                    try await sendTyping(false)
                }
            } catch {}
        }
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard isActive, let setSharing else { return }
        let token = generation, revision = UUID()
        clipboardGeneration = revision
        clipboardSetup?.cancel(); clipboardTask?.cancel(); clipboardTask = nil
        clipboardEnabled = false; latestClipboardText = nil; isUpdatingClipboard = true
        clipboardStatus = enabled ? "Enabling clipboard sharing…" : "Clipboard sharing is off."
        clipboardSetup = Task { [weak self] in
            guard let self else { return }
            do {
                try await setSharing(enabled)
                guard generation == token, clipboardGeneration == revision, isActive, !Task.isCancelled else { return }
                clipboardEnabled = enabled; isUpdatingClipboard = false
                if enabled {
                    clipboardChange = pasteboard.changeCount
                    clipboardStatus = "Newly copied text is shared in both directions."
                    beginClipboardPolling(token: token, revision: revision)
                }
            } catch {
                guard generation == token, clipboardGeneration == revision, isActive, !Task.isCancelled else { return }
                isUpdatingClipboard = false; clipboardEnabled = false
                clipboardStatus = "Clipboard sharing is off."
                errorMessage = "Clipboard sharing could not be enabled."
            }
        }
    }

    func receiveClipboard(_ text: String) {
        guard isActive, clipboardEnabled, text.utf16.count <= 524_288 else { return }
        latestClipboardText = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        clipboardChange = pasteboard.changeCount
    }

    private func beginClipboardPolling(token: UUID, revision: UUID) {
        clipboardTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, generation == token, clipboardGeneration == revision,
                      isActive, clipboardEnabled else { return }
                await pollClipboardOnce()
            }
        }
    }

    func pollClipboardOnce() async {
        guard isActive, clipboardEnabled, let sendClipboard else { return }
        let token = generation, revision = clipboardGeneration
        let change = pasteboard.changeCount
        guard change != clipboardChange else { return }
        clipboardChange = change
        guard let text = pasteboard.string(forType: .string), text != latestClipboardText else { return }
        guard text.utf16.count <= 524_288 else {
            errorMessage = "Clipboard text exceeds the 1 MB sharing limit."; return
        }
        latestClipboardText = text
        do { try await sendClipboard(text) }
        catch {
            guard generation == token, clipboardGeneration == revision, !Task.isCancelled else { return }
            errorMessage = "Clipboard text could not be sent."
        }
    }

    /// One queued message-level send. A reference type so the
    /// send worker and `deactivate()` can race to settle it
    /// exactly once (every access is on the main actor).
    private final class ChatSendJob {
        let text: String
        let token: UUID
        let continuation: CheckedContinuation<ChatSendOutcome, Never>
        private(set) var settled = false

        init(text: String, token: UUID,
             continuation: CheckedContinuation<ChatSendOutcome, Never>) {
            self.text = text
            self.token = token
            self.continuation = continuation
        }

        func settle(_ outcome: ChatSendOutcome) {
            guard !settled else { return }
            settled = true
            continuation.resume(returning: outcome)
        }
    }

    private func append(_ text: String, outgoing: Bool) {
        messages.append(SessionChatMessage(text: text, isOutgoing: outgoing))
        // Bound both transcript item count and text storage.
        while messages.count > 200 || messages.reduce(0, { $0 + $1.text.utf8.count }) > 1_048_576 {
            messages.removeFirst()
        }
    }
}
