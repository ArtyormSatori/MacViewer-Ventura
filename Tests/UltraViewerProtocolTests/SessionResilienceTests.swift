import Foundation
@preconcurrency import Network
import Testing
@testable import UltraViewerProtocol

// MARK: - RelayLegLiveness (watchdog + per-leg counters)

@Test func legLivenessRequiresThreeConsecutiveSendFailures() {
    var leg = RelayLegLiveness()
    #expect(leg.noteSendFailed() == false)
    #expect(leg.noteSendFailed() == false)
    #expect(leg.noteSendFailed() == true)
    #expect(leg.consecutiveSendFailures == 3)
    leg.noteSendSucceeded()
    #expect(leg.consecutiveSendFailures == 0)
    #expect(leg.noteSendFailed() == false)
}

@Test func legLivenessCountersDoNotLeakBetweenLegs() {
    var peer = RelayLegLiveness()
    var command = RelayLegLiveness()
    _ = peer.noteSendFailed()
    _ = peer.noteSendFailed()
    command.noteSendSucceeded()
    // The healthy command leg's success must not reset the dying peer leg,
    // and the peer leg's failures must not taint the command leg — the
    // pre-4.1 shared counter allowed exactly that.
    #expect(peer.consecutiveSendFailures == 2)
    #expect(command.consecutiveSendFailures == 0)
    #expect(peer.noteSendFailed() == true)
    #expect(command.noteSendFailed() == false)
}

@Test func legLivenessStalenessHonoursTheWindow() {
    var leg = RelayLegLiveness()
    let window: UInt64 = 35_000_000_000
    // A leg with no traffic yet is never stale.
    #expect(leg.isStale(at: 10_000_000_000_000, window: window) == false)
    leg.noteInbound(at: 1_000_000_000)
    #expect(leg.isStale(at: 1_000_000_000 + window, window: window) == false)
    #expect(leg.isStale(at: 1_000_000_000 + window + 1, window: window) == true)
    // Fresh inbound traffic revives the leg.
    leg.noteInbound(at: 2_000_000_000_000)
    #expect(leg.isStale(at: 2_000_000_000_000 + 1, window: window) == false)
}

// MARK: - SessionReconnectPolicy

@Test func reconnectPolicyBackoffSchedule() {
    let policy = SessionReconnectPolicy()
    #expect(policy.delay(beforeAttempt: 1) == nil)
    #expect(policy.delay(beforeAttempt: 2) == .seconds(2))
    #expect(policy.delay(beforeAttempt: 3) == .seconds(5))
    #expect(policy.delay(beforeAttempt: 4) == .seconds(10))
    #expect(policy.delay(beforeAttempt: 5) == .seconds(20))
    #expect(policy.delay(beforeAttempt: 6) == .seconds(30))
    #expect(policy.delay(beforeAttempt: 7) == nil)
}

@Test func reconnectPolicyStopsAtAttemptCapAndWindow() {
    let policy = SessionReconnectPolicy()
    #expect(policy.shouldContinue(afterAttempt: 1, elapsed: .seconds(1)))
    #expect(policy.shouldContinue(afterAttempt: 5, elapsed: .seconds(119)))
    #expect(!policy.shouldContinue(afterAttempt: 6, elapsed: .seconds(1)))
    #expect(!policy.shouldContinue(afterAttempt: 1, elapsed: .seconds(120)))
}

@Test func reconnectEligibilityMatrix() {
    typealias Failure = UltraViewerRelaySession.Failure
    // A session that never got accepted never reconnects.
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.timedOut, hostEndedSession: false, wasAccepted: false))
    // Network-class deaths of an established session reconnect.
    #expect(SessionReconnectPolicy.isEligibleForReconnect(
        Failure.timedOut, hostEndedSession: false, wasAccepted: true))
    #expect(SessionReconnectPolicy.isEligibleForReconnect(
        Failure.notConnected, hostEndedSession: false, wasAccepted: true))
    #expect(SessionReconnectPolicy.isEligibleForReconnect(
        Failure.closed, hostEndedSession: false, wasAccepted: true))
    struct TransportBoom: Swift.Error {}
    #expect(SessionReconnectPolicy.isEligibleForReconnect(
        TransportBoom(), hostEndedSession: false, wasAccepted: true))
    // The host ended the session on purpose: terminal, not a network death.
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.closed, hostEndedSession: true, wasAccepted: true))
    // Terminal auth/lookup outcomes never reconnect.
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.wrongPassword, hostEndedSession: false, wasAccepted: true))
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.partnerBlocked, hostEndedSession: false, wasAccepted: true))
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.lookupRejected(code: 5), hostEndedSession: false, wasAccepted: true))
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        Failure.invalidPartner, hostEndedSession: false, wasAccepted: true))
    #expect(!SessionReconnectPolicy.isEligibleForReconnect(
        CancellationError(), hostEndedSession: false, wasAccepted: true))
}

// MARK: - ScreenDecodeTolerance

@Test func screenDecodeToleranceIsBoundedAndResetBySuccess() {
    var tolerance = ScreenDecodeTolerance()
    #expect(tolerance.noteFailure() == false)
    #expect(tolerance.noteFailure() == false)
    // The third consecutive bad frame exhausts the budget and goes fatal.
    #expect(tolerance.noteFailure() == true)

    var recovered = ScreenDecodeTolerance()
    _ = recovered.noteFailure()
    _ = recovered.noteFailure()
    recovered.noteSuccess()
    #expect(recovered.consecutiveFailures == 0)
    // Isolated failures spread over a healthy session never accumulate.
    #expect(recovered.noteFailure() == false)
    #expect(recovered.noteFailure() == false)
    recovered.noteSuccess()
    #expect(recovered.noteFailure() == false)
}

// MARK: - SessionSendRace (heartbeat send timeout)

@Test(.timeLimit(.minutes(1))) func sendRaceCompletesAFastSend() async throws {
    try await SessionSendRace.run(timeout: .seconds(5)) {}
}

@Test(.timeLimit(.minutes(1))) func sendRacePropagatesTheSendError() async {
    struct SendBoom: Swift.Error {}
    await #expect(throws: SendBoom.self) {
        try await SessionSendRace.run(timeout: .seconds(5)) { throw SendBoom() }
    }
}

@Test(.timeLimit(.minutes(1))) func sendRaceBoundsAHungSend() async {
    let started = DispatchTime.now().uptimeNanoseconds
    await #expect(throws: SessionSendTimeout.self) {
        try await SessionSendRace.run(timeout: .milliseconds(150)) {
            // A send parked on a half-open connection: without the race
            // this await would freeze the heartbeat loop indefinitely.
            try await Task.sleep(for: .seconds(60))
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    #expect(elapsed < 10_000_000_000)
}

// MARK: - FramedTCPTransport frame delivery policy

/// Minimal loopback listener that blasts a fixed number of framed
/// payloads as one write, then finishes after a delay so the client's
/// receive loop has fully processed (and, under load, shed) the blast.
private final class BlastServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "MacViewer.tests.blast")
    private var clients: [NWConnection] = []

    init(frameCount: Int) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { client.cancel(); return }
            queue.async { self.clients.append(client) }
            client.start(queue: queue)
            var blast = Data()
            for index in 0..<frameCount {
                blast.append(try! LengthPrefixedFrame.encode(Data("frame-\(index)".utf8)))
            }
            client.send(content: blast, completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 1.5) {
                    client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
                }
            })
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            clients.forEach { $0.cancel() }
            clients.removeAll()
            listener.cancel()
        }
    }
}

@Test(.timeLimit(.minutes(1))) func dropPolicyTransportShedsFramesInsteadOfDying() async throws {
    let frameCount = 200
    let server = try BlastServer(frameCount: frameCount)
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport(frameDeliveryPolicy: .dropOnConsumerTooSlow)
    let stream = try await transport.open(host: "127.0.0.1", port: port)
    // Deliberately do not consume yet: the receive loop fills the 64-frame
    // buffer and must shed the overflow (counted), never throw.
    try await Task.sleep(for: .milliseconds(900))
    var received = 0
    for try await _ in stream { received += 1 }
    #expect(received >= 64)
    #expect(received < frameCount)
    let dropped = await transport.droppedFrames
    #expect(dropped > 0)
    #expect(received + dropped == frameCount)
}

@Test(.timeLimit(.minutes(1))) func strictPolicyTransportStillDiesOnConsumerLag() async throws {
    let server = try BlastServer(frameCount: 200)
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport()
    let stream = try await transport.open(host: "127.0.0.1", port: port)
    try await Task.sleep(for: .milliseconds(900))
    do {
        for try await _ in stream {}
        Issue.record("Lagging consumer did not fail under the strict policy")
    } catch {
        #expect(error as? FramedTCPTransport.Error == .consumerTooSlow)
    }
}
