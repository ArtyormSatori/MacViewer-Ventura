import Foundation
import Testing
@testable import UltraViewerProtocol

// Tests for the 4.0.2 lag / dead-input fixes (LAG_AUDIT FX-2, FX-4,
// FX-6). The session consults these value types at exactly the points
// the scenarios describe; the types are tested directly here in the
// same style as SessionResilienceTests, because the suite has no
// fake-relay harness that could drive a whole session.

private let window: UInt64 = 35_000_000_000
private let t0: UInt64 = 1_000_000_000_000
private func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }

// MARK: - FramePacingGate (FX-2: ACK pacing)

@Test func pacingGateWithholdsAcknowledgementAboveTheBound() {
    var gate = FramePacingGate(bound: 2)
    #expect(!gate.shouldWithholdAcknowledgement)
    gate.noteFrameDecoded()
    gate.noteFrameDecoded()
    #expect(gate.inFlight == 2)
    #expect(!gate.shouldWithholdAcknowledgement)
    // The third decoded-but-unpresented frame trips the gate: the
    // session withholds its ACK until presentation catches up.
    gate.noteFrameDecoded()
    #expect(gate.shouldWithholdAcknowledgement)
    gate.noteFrameConsumed()
    #expect(!gate.shouldWithholdAcknowledgement)
    // Consumption is floored at zero: stray signals cannot drive the
    // count negative and unthrottle production.
    gate.noteFrameConsumed()
    gate.noteFrameConsumed()
    gate.noteFrameConsumed()
    #expect(gate.inFlight == 0)
    gate.noteFrameDecoded()
    gate.reset()
    #expect(gate.inFlight == 0)
    #expect(!gate.shouldWithholdAcknowledgement)
}

/// Soak, in deterministic unit form: a producer emitting frames at
/// full rate against a consumer four times slower, with the same
/// serial decode → emit → wait-for-capacity shape as the session's
/// frame handler and the adapter's latest-wins hand-off (one awaiting
/// frame, one pending slot, replacements dropped without a consumption
/// signal). The audit's discriminating quantities: the decoded-but-
/// unpresented count must stay bounded at the pacing bound + 1 (the
/// frame that trips the gate), and the frame the consumer finally
/// presents must be the newest one produced, not a stale one.
@Test func pacingSoakKeepsDecodedButUnpresentedBounded() {
    var gate = FramePacingGate(bound: 2)
    var awaiting: Int?
    var pending: Int?
    var presented: [Int] = []
    var coalesced = 0
    var maxInFlight = 0
    let total = 600
    var nextFrame = 1
    var step = 0
    while nextFrame <= total || awaiting != nil {
        if nextFrame <= total, !gate.shouldWithholdAcknowledgement {
            let frame = nextFrame
            nextFrame += 1
            gate.noteFrameDecoded()
            maxInFlight = max(maxInFlight, gate.inFlight)
            if awaiting == nil { awaiting = frame }
            else if pending == nil { pending = frame }
            else { pending = frame; coalesced += 1 }
        }
        step += 1
        if step % 4 == 0, let frame = awaiting {
            presented.append(frame)
            gate.noteFrameConsumed()
            awaiting = pending
            pending = nil
        }
        if step >= 1_000_000 {
            Issue.record("Soak simulation did not converge")
            break
        }
    }
    // Production was throttled at the source: never more than the
    // bound plus the tripping frame in flight, however long the blast.
    #expect(maxInFlight <= 3)
    // Frames really were shed under the rate mismatch…
    #expect(coalesced > 0)
    // …every produced frame is accounted for exactly once…
    #expect(presented.count + coalesced == total)
    // …presentation order is monotone, and the last frame presented
    // is the newest frame produced — staleness stays bounded instead
    // of growing with the session.
    #expect(presented == presented.sorted())
    #expect(presented.last == total)
}

// MARK: - SessionRefreshBudget (FX-6: per-episode refresh budget)

@Test func refreshBudgetIsPerEpisodeAndRestoredByReinitialisation() {
    var budget = SessionRefreshBudget()
    // One episode: two tolerated decode-error refreshes…
    #expect(budget.consume() == true)
    #expect(budget.consume() == true)
    // …and the third failure in the same episode is fatal.
    #expect(budget.consume() == false)
    // A successful re-initialisation (command 0 → .active, where the
    // session calls reset()) starts a new episode with a full budget:
    // after 2 refreshes + successful re-init, a further tolerated
    // decode error refreshes instead of finishing the session. Under
    // the pre-fix lifetime counter this consume() returned false.
    budget.reset()
    #expect(budget.used == 0)
    #expect(budget.consume() == true)
    #expect(budget.consume() == true)
    #expect(budget.consume() == false)
}

// MARK: - PeerForwardPathHealth (FX-4: forward-path gate)

@Test func forwardPathGateTripsWhenPongsFlowButPeerRepliesStop() {
    var health = PeerForwardPathHealth()
    // The path demonstrably worked: the host answered a ping.
    health.notePeerPingReply(at: t0)
    // Pings keep going out; no reply ever comes back…
    health.notePeerPingSent(at: t0 + seconds(10))
    health.notePeerPingSent(at: t0 + seconds(20))
    health.notePeerPingSent(at: t0 + seconds(30))
    // …while relay pongs keep arriving on the same connection.
    health.noteRelayPong(at: t0 + seconds(20))
    health.noteRelayPong(at: t0 + seconds(30))
    health.noteRelayPong(at: t0 + seconds(40))
    // Inside the window since the first unanswered ping: no verdict.
    #expect(!health.isForwardPathDead(at: t0 + seconds(10) + window - 1, window: window))
    // A full window of unanswered pings with pongs still fresh: the
    // forward hop is dead even though the connection looks alive.
    #expect(health.isForwardPathDead(at: t0 + seconds(10) + window + 1, window: window))
}

@Test func forwardPathGateStaysQuietWhilePeerRepliesAreFresh() {
    var health = PeerForwardPathHealth()
    health.notePeerPingReply(at: t0)
    // Every ping is answered a couple of seconds later; pongs flow.
    for offset in stride(from: UInt64(10), through: 120, by: 10) {
        health.notePeerPingSent(at: t0 + seconds(offset))
        health.notePeerPingReply(at: t0 + seconds(offset + 2))
        health.noteRelayPong(at: t0 + seconds(offset + 5))
    }
    #expect(!health.isForwardPathDead(at: t0 + seconds(125), window: window))
    #expect(health.lastPeerPingReplyUptimeNanoseconds == t0 + seconds(122))
}

@Test func forwardPathGateStaysOutWhenPongsAlsoStop() {
    var health = PeerForwardPathHealth()
    health.notePeerPingReply(at: t0)
    health.noteRelayPong(at: t0)
    health.notePeerPingSent(at: t0 + seconds(10))
    // Both signals silent for a full window: that is total inbound
    // silence, which the existing reply watchdog owns — the forward-
    // path gate must not double-trigger on it.
    #expect(!health.isForwardPathDead(at: t0 + seconds(10) + window + 1, window: window))
}

@Test func forwardPathGateIgnoresAPathThatNeverAnswered() {
    var health = PeerForwardPathHealth()
    // Pongs flow and pings go out, but no "20" reply has EVER arrived:
    // indistinguishable from a host that does not answer pings at all,
    // so the gate never judges it (the session worked for years
    // without gating this case).
    for offset in stride(from: UInt64(10), through: 120, by: 10) {
        health.notePeerPingSent(at: t0 + seconds(offset))
        health.noteRelayPong(at: t0 + seconds(offset + 5))
    }
    #expect(!health.isForwardPathDead(at: t0 + seconds(130), window: window))
    #expect(health.lastPeerPingReplyUptimeNanoseconds == nil)
}
