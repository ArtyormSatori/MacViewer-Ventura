#if os(macOS)
import XCTest
import MeshClient
import MeshWebRTC

/// End-to-end tests for the part-3a input plane: scripted
/// `MeshInputEvent`s cross a REAL `MeshPeerSession` control
/// channel (viewer session → host session, negotiated over
/// `SignalingEnvelope` JSON only, the part-1 harness pattern)
/// and are decoded on the host side with the same codec.
///
/// These tests can only RUN on macOS (the WebRTC binary
/// target has no Linux slice), i.e. in CI. The codec,
/// coalescer and planner halves are covered on every platform
/// by InputCodecTests / InputCoalescerTests /
/// InputPlannerTests.
///
/// What this proves: the exact event sequence a viewer sends
/// is the exact sequence the host decodes — no event lost,
/// reordered, or mangled by the JSON wire form or the data
/// channel. (What the host then does with the events is the
/// planner's contract, proven separately; CGEvent posting
/// itself needs a live desktop + Accessibility and is a
/// field proof, by design.)
final class MeshInputChannelTests: XCTestCase {

    private let aID = MeshID(unchecked: "111111111")
    private let bID = MeshID(unchecked: "222222222")

    private final class SessionSlot: @unchecked Sendable {
        var session: MeshPeerSession?
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func with<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private struct Pair {
        let a: MeshPeerSession
        let b: MeshPeerSession
        /// Events decoded on the host (B) side, in arrival order.
        let bEvents: Locked<[MeshInputEvent]>
        /// Payloads that failed to decode on the host side.
        let bUndecodable: Locked<Int>
        let tasks: [Task<Void, Never>]
    }

    private func makePair() -> Pair {
        let hop = DispatchQueue(label: "mesh.inputchannel.testbus",
                                attributes: .concurrent)
        func deliver(_ envelope: SignalingEnvelope, to slot: SessionSlot) {
            guard let json = try? envelope.encodedJSON() else { return }
            hop.async {
                guard let decoded = try? SignalingEnvelope.decodeJSON(json),
                      let from = decoded.from, let kind = decoded.kind,
                      let data = decoded.data,
                      let session = slot.session
                else { return }
                session.handleSignal(SignalEnvelope(from: from, kind: kind, data: data))
            }
        }
        let slotA = SessionSlot()
        let slotB = SessionSlot()
        let a = MeshPeerSession(localID: aID, remoteID: bID, role: .initiator) { envelope in
            deliver(envelope, to: slotB)
        }
        let b = MeshPeerSession(localID: bID, remoteID: aID, role: .responder) { envelope in
            deliver(envelope, to: slotA)
        }
        slotA.session = a
        slotB.session = b

        let bEvents = Locked<[MeshInputEvent]>([])
        let bUndecodable = Locked(0)
        let taskB = Task {
            for await message in b.controlMessages {
                if let event = MeshInputEvent(data: message) {
                    bEvents.with { $0.append(event) }
                } else {
                    bUndecodable.with { $0 += 1 }
                }
            }
        }
        return Pair(a: a, b: b, bEvents: bEvents,
                    bUndecodable: bUndecodable, tasks: [taskB])
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 15,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    private func connect(_ pair: Pair) async throws {
        try await pair.a.start()
        await waitUntil("A connected") { pair.a.state == .connected }
        await waitUntil("B connected") { pair.b.state == .connected }
    }

    // MARK: - Without coalescing: the sequence is exact

    func testInputSequenceArrivesExactWithoutCoalescing() async throws {
        let pair = makePair()
        defer {
            pair.a.close()
            pair.b.close()
            pair.tasks.forEach { $0.cancel() }
        }
        try await connect(pair)

        // Coalescing DISABLED: every event is encoded and sent
        // directly, so the host must receive this exact list —
        // the deterministic baseline for the wire + channel.
        let script: [MeshInputEvent] = [
            .pointerMove(x: 0.10, y: 0.10),
            .pointerButton(button: .left, down: true, x: 0.10, y: 0.10),
            .pointerButton(button: .left, down: false, x: 0.10, y: 0.10),
            .wheel(deltaX: 0, deltaY: -2),
            .key(code: 56, down: true, flags: [.shift]),
            .key(code: 0, down: true, flags: [.shift]),
            .key(code: 0, down: false, flags: [.shift]),
            .key(code: 56, down: false, flags: []),
            .modifiers([.command]),
            .textInput("tiếng Việt ✓"),
            .releaseAll,
        ]
        for event in script {
            pair.a.sendControl(try event.encodedData())
        }

        await waitUntil("host received the whole script") {
            pair.bEvents.with { $0.count } >= script.count
        }
        XCTAssertEqual(pair.bUndecodable.with { $0 }, 0)
        XCTAssertEqual(pair.bEvents.with { $0 }, script)
    }

    // MARK: - With coalescing: the documented reduction

    func testInputSequenceWithCoalescingReducesMoves() async throws {
        let pair = makePair()
        defer {
            pair.a.close()
            pair.b.close()
            pair.tasks.forEach { $0.cancel() }
        }
        try await connect(pair)

        var coalescer = InputEventCoalescer()
        var wire: [MeshInputEvent] = []
        var uncoalescedCount = 0
        func emit(_ event: MeshInputEvent) {
            uncoalescedCount += 1
            wire += coalescer.enqueue(event)
        }
        // A 10-move burst into a click: only the last move of
        // the burst may travel, ahead of the click.
        for i in 1...10 { emit(.pointerMove(x: Double(i) / 20, y: 0.5)) }
        emit(.pointerButton(button: .left, down: true, x: 0.5, y: 0.5))
        emit(.pointerButton(button: .left, down: false, x: 0.5, y: 0.5))
        // A 5-move burst into a keystroke.
        for i in 1...5 { emit(.pointerMove(x: 0.6, y: Double(i) / 20)) }
        emit(.key(code: 36, down: true, flags: nil))
        emit(.key(code: 36, down: false, flags: nil))
        // A trailing move, released by the explicit flush.
        emit(.pointerMove(x: 0.9, y: 0.9))
        wire += coalescer.flush()

        let expected: [MeshInputEvent] = [
            .pointerMove(x: 0.5, y: 0.5),
            .pointerButton(button: .left, down: true, x: 0.5, y: 0.5),
            .pointerButton(button: .left, down: false, x: 0.5, y: 0.5),
            .pointerMove(x: 0.6, y: 0.25),
            .key(code: 36, down: true, flags: nil),
            .key(code: 36, down: false, flags: nil),
            .pointerMove(x: 0.9, y: 0.9),
        ]
        XCTAssertEqual(wire, expected, "sender-side reduction differs from the contract")
        XCTAssertLessThan(wire.count, uncoalescedCount)

        for event in wire {
            pair.a.sendControl(try event.encodedData())
        }
        await waitUntil("host received the reduced stream") {
            pair.bEvents.with { $0.count } >= expected.count
        }
        XCTAssertEqual(pair.bUndecodable.with { $0 }, 0)
        XCTAssertEqual(pair.bEvents.with { $0 }, expected)
    }
}
#endif
