import Foundation

/// Liveness bookkeeping for one relay leg (peer/data leg, command leg).
///
/// A leg can die *silently* — NAT mapping reaped, relay restart, Wi-Fi roam —
/// while local sends keep "succeeding" into the void for minutes, because an
/// NWConnection send completion only proves the local stack accepted the
/// bytes. Counting send failures alone therefore cannot detect the classic
/// idle disconnect. This tracker pairs per-leg send-failure counting with an
/// inbound-silence watchdog: the session feeds every received frame into
/// `noteInbound`, and the heartbeat asks `isStale` whether replies (pong,
/// the peer's "20" answer, or any other traffic) have stopped for a full
/// bounded window even though pings are being sent every 10 seconds.
public struct RelayLegLiveness: Equatable, Sendable {
    /// Uptime nanoseconds of the most recent inbound frame on this leg.
    /// `nil` until the first frame arrives; a leg with no traffic yet is
    /// never considered stale.
    public private(set) var lastInboundUptimeNanoseconds: UInt64?
    public private(set) var consecutiveSendFailures = 0

    public init() {}

    public mutating func noteInbound(at uptimeNanoseconds: UInt64) {
        lastInboundUptimeNanoseconds = uptimeNanoseconds
    }

    public mutating func noteSendSucceeded() {
        consecutiveSendFailures = 0
    }

    /// Records one failed (or timed-out) send on this leg only. Returns
    /// `true` once the leg has failed `limit` times in a row and must be
    /// declared dead. Counters are strictly per leg: a healthy leg can no
    /// longer reset a dying leg's count the way the pre-4.1 shared
    /// heartbeat counter allowed.
    @discardableResult
    public mutating func noteSendFailed(limit: Int = 3) -> Bool {
        consecutiveSendFailures += 1
        return consecutiveSendFailures >= limit
    }

    /// `true` when no inbound frame has arrived for longer than `window`
    /// nanoseconds. A leg that has never carried traffic is not stale.
    public func isStale(at uptimeNanoseconds: UInt64, window: UInt64) -> Bool {
        guard let lastInboundUptimeNanoseconds else { return false }
        return uptimeNanoseconds &- lastInboundUptimeNanoseconds > window
    }
}

/// Bounded auto-reconnect schedule for a mid-session network death.
///
/// The native protocol already carries an `isReconnect` flag in the partner
/// lookup; 4.0 never used it and every fatal error ended the session. The
/// policy keeps retries bounded on two axes — a maximum number of attempts
/// and a total wall-clock window on the order of two minutes — with
/// increasing backoff so a dead host or a dead network cannot spin a
/// reconnect loop forever.
public struct SessionReconnectPolicy: Equatable, Sendable {
    /// Backoff slept *before* attempts 2, 3, 4 … (attempt 1 runs at once).
    public var delays: [Duration]
    public var maximumAttempts: Int
    public var totalWindow: Duration

    public init(delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(30)],
                maximumAttempts: Int = 6, totalWindow: Duration = .seconds(120)) {
        self.delays = delays
        self.maximumAttempts = maximumAttempts
        self.totalWindow = totalWindow
    }

    /// The backoff to sleep before retry number `attempt` (1-based; the
    /// first retry after the initial failure is attempt 2). `nil` when the
    /// schedule has no entry that far.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 2, attempt - 2 < delays.count else { return nil }
        return delays[attempt - 2]
    }

    /// Whether another attempt may start after `attempt` completed
    /// attempts, given the time already spent inside the episode.
    public func shouldContinue(afterAttempt attempt: Int, elapsed: Duration) -> Bool {
        attempt < maximumAttempts && elapsed < totalWindow
    }

    public var totalWindowUptimeNanoseconds: UInt64 {
        let parts = totalWindow.components
        let seconds = UInt64(max(0, parts.seconds))
        let attoseconds = UInt64(max(0, parts.attoseconds))
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    /// Whether a session that died with `error` may be reconnected.
    ///
    /// Only network-class deaths of an *established* session qualify.
    /// Terminal outcomes — user close (the session never reaches this
    /// check), wrong password, partner-blocked, a rejected or unroutable
    /// lookup, an unsupported or malformed host, and a host that ended
    /// the session itself (commands 27/41/54, reported via
    /// `hostEndedSession`) — must surface to the user exactly as before.
    public static func isEligibleForReconnect(_ error: any Swift.Error,
                                              hostEndedSession: Bool,
                                              wasAccepted: Bool) -> Bool {
        guard wasAccepted else { return false }
        if error is CancellationError { return false }
        if let failure = error as? UltraViewerRelaySession.Failure {
            switch failure {
            case .wrongPassword, .partnerBlocked, .lookupRejected, .invalidLookupRoute,
                 .invalidPartner, .unsupportedVersion, .malformedInitialization,
                 .alreadyOpen, .viewOnly:
                return false
            case .closed:
                return !hostEndedSession
            case .notConnected, .timedOut, .consumerTooSlow:
                return true
            }
        }
        return true
    }
}

/// Bounded tolerance for screen-frame decode failures.
///
/// ModernScreenMessageError already had a refresh-and-continue path, but a
/// zstd failure escaped that typed catch and killed the session on its
/// first occurrence. This counter gives zstd failures the same shape of
/// tolerance — ask for a fresh initialization, tolerate a small number in
/// a row, then fail — while a successfully decoded frame resets the
/// budget, so a long healthy session is never worn down by ancient,
/// unrelated single failures.
public struct ScreenDecodeTolerance: Equatable, Sendable {
    /// Consecutive failures tolerated (each followed by a refresh).
    public var limit: Int
    public private(set) var consecutiveFailures = 0

    public init(limit: Int = 2) {
        self.limit = limit
    }

    public mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    /// Records one decode failure. Returns `true` when the budget is
    /// exhausted and the failure must become fatal.
    @discardableResult
    public mutating func noteFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures > limit
    }
}

/// A heartbeat send that never completed within its bound. The heartbeat
/// counts this exactly like a thrown send error.
public struct SessionSendTimeout: Swift.Error, Equatable, LocalizedError {
    public init() {}
    public var errorDescription: String? { "A network send did not complete in time." }
}

/// Races an asynchronous send against a timeout.
///
/// NWConnection sends on a half-open connection can park indefinitely, and
/// the pre-4.1 heartbeat awaited every send inline — one hung send froze
/// the whole heartbeat loop forever: no more ticks, no failure counting, a
/// zombie session. The loser of the race is *abandoned*, not awaited: the
/// send may still complete later against a closing transport, which is
/// harmless for idempotent keepalive traffic, while the caller regains
/// control at the timeout and counts the send as failed.
public enum SessionSendRace {
    public static func run(timeout: Duration,
                           operation: @escaping @Sendable () async throws -> Void) async throws {
        let gate = RaceGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            gate.install(continuation)
            Task {
                do {
                    try await operation()
                    gate.resolve(.success(()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                gate.resolve(.failure(SessionSendTimeout()))
            }
        }
    }
}

/// Exactly-once resumption for the send race: whichever side finishes
/// first resumes the continuation; the other side's late result is dropped.
private final class RaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Swift.Error>?

    func install(_ continuation: CheckedContinuation<Void, any Swift.Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Void, any Swift.Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
