import Foundation
import MeshClient

/// Mode 2 session negotiation (Phase 3, chunk 2): the state machine
/// that turns a paired device into a *negotiated* session over the
/// signaling channel, with host-side consent (UI spec §5.4 / §9
/// item 4).
///
/// "Active" in this chunk means the two sides have agreed on a
/// session and its capabilities. No media exists yet — the WebRTC
/// media path is milestone M1; the session window states the
/// negotiated state factually until then.
///
/// One negotiation at a time. Every exit from a pending or active
/// phase lands in `.ended(reason)`; `dismissEnded()` (or starting a
/// new request) returns to `.idle`.
@MainActor
final class MeshSessionController: ObservableObject {
    enum Role: Equatable {
        case viewer
        case host
    }

    enum EndReason: Equatable {
        /// The host declined the request (or the user declined here).
        case rejected
        /// The other device is already in a session.
        case busy
        /// No answer within the consent timeout, on either side.
        case timeout
        /// The requester cancelled before an answer.
        case cancelled
        /// A live session was ended by the other side.
        case endedByPeer
        /// A live session was ended here.
        case endedLocally
        /// The server refused delivery (peer offline / not paired).
        case peerUnreachable
    }

    enum Phase: Equatable {
        case idle
        case outgoingPending(sessionID: String, peer: MeshID, peerName: String?,
                             capabilities: Set<MeshSessionCapability>)
        case incomingPending(sessionID: String, peer: MeshID, peerName: String?,
                             capabilities: Set<MeshSessionCapability>)
        case active(sessionID: String, peer: MeshID, peerName: String?,
                    role: Role, capabilities: Set<MeshSessionCapability>, startedAt: Date)
        case ended(reason: EndReason)
    }

    /// How long a request waits for the other side's answer before
    /// it is treated as rejected (spec consent timeout).
    static let defaultTimeout: TimeInterval = 60

    @Published private(set) var phase: Phase = .idle
    /// Factual, user-facing status for the last transition (already
    /// localized). Views render it as-is.
    @Published private(set) var statusMessage: String?

    /// True when a new outgoing request may be started.
    var canStartSession: Bool {
        switch phase {
        case .idle, .ended: return true
        default: return false
        }
    }

    private let signaling: any MeshSignalingAPI
    private let isPaired: @MainActor (MeshID) -> Bool
    private let localName: @MainActor () -> String
    private let timeout: TimeInterval

    private var pumpTask: Task<Void, Never>?
    private var errorPumpTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(signaling: any MeshSignalingAPI,
         isPaired: @escaping @MainActor (MeshID) -> Bool,
         localName: @escaping @MainActor () -> String,
         timeout: TimeInterval = MeshSessionController.defaultTimeout) {
        self.signaling = signaling
        self.isPaired = isPaired
        self.localName = localName
        self.timeout = timeout
    }

    deinit {
        pumpTask?.cancel()
        errorPumpTask?.cancel()
        timeoutTask?.cancel()
    }

    // MARK: Lifecycle

    /// Begins consuming the signaling streams. Idempotent.
    func start() {
        guard pumpTask == nil else { return }
        let signals = signaling.signals
        pumpTask = Task { [weak self] in
            for await envelope in signals {
                guard let self else { return }
                self.handle(envelope)
            }
        }
        let errors = signaling.serverErrors
        errorPumpTask = Task { [weak self] in
            for await error in errors {
                guard let self else { return }
                self.handleServerError(error)
            }
        }
    }

    /// Stops listening and abandons any negotiation in flight. Used
    /// when the signaling connection itself is torn down.
    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        errorPumpTask?.cancel()
        errorPumpTask = nil
        cancelTimeout()
        phase = .idle
        statusMessage = nil
    }

    // MARK: Viewer actions

    /// The paired-row "Connect" action (§9 item 7): asks the peer
    /// for a session with the given capabilities and waits for the
    /// host's consent answer.
    func requestSession(to peer: MeshID, peerName: String?,
                        capabilities: Set<MeshSessionCapability> = [.view, .control]) {
        switch phase {
        case .idle, .ended: break
        default: return
        }
        guard signaling.isConnected else {
            statusMessage = L("Not connected to the mesh server. Reopen Self-hosted to reconnect.")
            return
        }
        let sessionID = UUID().uuidString
        phase = .outgoingPending(sessionID: sessionID, peer: peer, peerName: peerName,
                                  capabilities: capabilities)
        statusMessage = nil
        armTimeout()
        let message = MeshSessionMessage(kind: .request, sessionID: sessionID,
                                         fromName: localName(), capabilities: capabilities)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await signaling.sendSignal(to: peer, kind: MeshSessionMessage.transportKind,
                                               data: message.signalingData)
            } catch {
                if case .outgoingPending(let current, _, _, _) = phase, current == sessionID {
                    finish(.peerUnreachable,
                           message: LF("Could not reach %@.", peerName ?? peer.formatted))
                }
            }
        }
    }

    /// Cancels an unanswered outgoing request; the host's consent
    /// prompt is withdrawn by the session-end that follows.
    func cancelOutgoing() {
        guard case let .outgoingPending(sessionID, peer, _, _) = phase else { return }
        send(.init(kind: .end, sessionID: sessionID, reason: .cancelled), to: peer)
        finish(.cancelled, message: L("You cancelled the request."))
    }

    // MARK: Host actions

    /// Consent granted (consent window's Approve): the session
    /// becomes active on both sides with the granted capabilities.
    func approveIncoming() {
        guard case let .incomingPending(sessionID, peer, peerName, capabilities) = phase else { return }
        send(.init(kind: .accept, sessionID: sessionID, capabilities: capabilities), to: peer)
        phase = .active(sessionID: sessionID, peer: peer, peerName: peerName,
                        role: .host, capabilities: capabilities, startedAt: Date())
        cancelTimeout()
        statusMessage = LF("%@ is connected to this device.", peerName ?? peer.formatted)
    }

    /// Consent denied (consent window's Reject, or the window is
    /// closed unanswered): the requester is told immediately.
    func rejectIncoming() {
        guard case let .incomingPending(sessionID, peer, peerName, _) = phase else { return }
        send(.init(kind: .reject, sessionID: sessionID, reason: .rejected), to: peer)
        finish(.rejected, message: LF("You rejected the request from %@.", peerName ?? peer.formatted))
    }

    // MARK: Shared actions

    /// Ends a live session from either side.
    func endSession() {
        guard case let .active(sessionID, peer, _, _, _, _) = phase else { return }
        send(.init(kind: .end, sessionID: sessionID, reason: .ended), to: peer)
        finish(.endedLocally, message: L("You ended the session."))
    }

    /// Acknowledges a terminal state; the machine returns to idle.
    func dismissEnded() {
        guard case .ended = phase else { return }
        phase = .idle
    }

    // MARK: Inbound messages

    private func handle(_ envelope: SignalEnvelope) {
        guard let message = MeshSessionMessage(data: envelope.data) else {
            return // Media signaling (M1) or unrelated traffic.
        }
        let from = envelope.from
        switch message.kind {
        case .request: handleRequest(message, from: from)
        case .accept: handleAccept(message, from: from)
        case .reject: handleReject(message, from: from)
        case .end: handleEnd(message, from: from)
        }
    }

    private func handleRequest(_ message: MeshSessionMessage, from peer: MeshID) {
        // Sessions exist only between paired devices (the server
        // also enforces the grant; this is the app-side check).
        guard isPaired(peer) else { return }
        switch phase {
        case .idle, .ended:
            phase = .incomingPending(sessionID: message.sessionID, peer: peer,
                                     peerName: message.fromName,
                                     capabilities: message.capabilities)
            statusMessage = nil
            armTimeout()
        default:
            // One negotiation at a time: refuse honestly instead of
            // leaving the requester to time out.
            send(.init(kind: .reject, sessionID: message.sessionID, reason: .busy), to: peer)
        }
    }

    private func handleAccept(_ message: MeshSessionMessage, from peer: MeshID) {
        guard case let .outgoingPending(sessionID, pendingPeer, peerName, requested) = phase,
              sessionID == message.sessionID, pendingPeer == peer else { return }
        let granted = message.capabilities.isEmpty ? requested : message.capabilities
        phase = .active(sessionID: sessionID, peer: peer, peerName: peerName,
                        role: .viewer, capabilities: granted, startedAt: Date())
        cancelTimeout()
        statusMessage = nil
    }

    private func handleReject(_ message: MeshSessionMessage, from peer: MeshID) {
        guard case let .outgoingPending(sessionID, pendingPeer, peerName, _) = phase,
              sessionID == message.sessionID, pendingPeer == peer else { return }
        if message.reason == .busy {
            finish(.busy, message: LF("%@ is busy with another session.", peerName ?? peer.formatted))
        } else {
            finish(.rejected, message: LF("%@ rejected the request.", peerName ?? peer.formatted))
        }
    }

    private func handleEnd(_ message: MeshSessionMessage, from peer: MeshID) {
        switch phase {
        case let .outgoingPending(sessionID, pendingPeer, peerName, _):
            guard sessionID == message.sessionID, pendingPeer == peer else { return }
            switch message.reason {
            case .timeout:
                finish(.timeout, message: L("The request timed out."))
            case .cancelled:
                finish(.cancelled, message: L("The request was cancelled."))
            default:
                finish(.endedByPeer, message: LF("%@ ended the session.", peerName ?? peer.formatted))
            }
        case let .incomingPending(sessionID, pendingPeer, peerName, _):
            guard sessionID == message.sessionID, pendingPeer == peer else { return }
            // The requester withdrew (cancel or its own timeout):
            // the consent prompt goes away, no session ever existed.
            cancelTimeout()
            phase = .idle
            statusMessage = message.reason == .timeout
                ? LF("The request from %@ timed out.", peerName ?? peer.formatted)
                : LF("The request from %@ was cancelled.", peerName ?? peer.formatted)
        case let .active(sessionID, activePeer, peerName, _, _, _):
            guard sessionID == message.sessionID, activePeer == peer else { return }
            finish(.endedByPeer, message: LF("%@ ended the session.", peerName ?? peer.formatted))
        default:
            return
        }
    }

    private func handleServerError(_ error: MeshError) {
        // This chunk's only sends are session messages, so a server
        // refusal while a request is unanswered means the request
        // could not be delivered (peer offline or grant missing).
        guard case let .outgoingPending(_, peer, peerName, _) = phase else { return }
        finish(.peerUnreachable,
               message: LF("Could not reach %@.", peerName ?? peer.formatted))
    }

    // MARK: Timeout

    /// Arms the consent timeout for the pending phase just entered.
    private func armTimeout() {
        cancelTimeout()
        let sessionID: String
        switch phase {
        case .outgoingPending(let id, _, _, _), .incomingPending(let id, _, _, _):
            sessionID = id
        default:
            return
        }
        let delay = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.expire(sessionID: sessionID)
        }
    }

    private func expire(sessionID: String) {
        switch phase {
        case let .outgoingPending(current, peer, _, _):
            guard current == sessionID else { return }
            // Tell the host to drop its consent prompt as well.
            send(.init(kind: .end, sessionID: sessionID, reason: .timeout), to: peer)
            finish(.timeout, message: L("The request timed out."))
        case let .incomingPending(current, peer, _, _):
            guard current == sessionID else { return }
            // Unanswered consent counts as a rejection (spec §5.4):
            // the requester is told, the prompt goes away.
            send(.init(kind: .end, sessionID: sessionID, reason: .timeout), to: peer)
            finish(.timeout, message: L("The request timed out."))
        default:
            return
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: Helpers

    private func finish(_ reason: EndReason, message: String) {
        cancelTimeout()
        phase = .ended(reason: reason)
        statusMessage = message
    }

    /// Fire-and-forget send for answers and endings: the state
    /// transition has already been decided locally, and a transport
    /// failure leaves the peer to its own timeout.
    private func send(_ message: MeshSessionMessage, to peer: MeshID) {
        let signaling = signaling
        Task {
            try? await signaling.sendSignal(to: peer, kind: MeshSessionMessage.transportKind,
                                            data: message.signalingData)
        }
    }
}
