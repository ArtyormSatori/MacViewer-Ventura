import XCTest
import MeshWebRTC

/// Tests for `InputEventCoalescer` (pure). These pin the
/// sender-side contract: moves are held and replaced (never
/// deliver stale input), discrete events are never dropped or
/// reordered, and the flush points are exactly the documented
/// ones — a discrete enqueue, or an explicit `flush()`.
final class InputCoalescerTests: XCTestCase {

    private func move(_ x: Double) -> MeshInputEvent { .pointerMove(x: x, y: x) }
    private let click = MeshInputEvent.pointerButton(button: .left, down: true, x: 0.5, y: 0.5)
    private let keystroke = MeshInputEvent.key(code: 0, down: true, flags: nil)

    func testSingleMoveIsHeldUntilFlush() {
        var coalescer = InputEventCoalescer()
        XCTAssertEqual(coalescer.enqueue(move(0.1)), [])
        XCTAssertEqual(coalescer.pendingCount, 1)
        XCTAssertEqual(coalescer.flush(), [move(0.1)])
        XCTAssertTrue(coalescer.isEmpty)
        XCTAssertEqual(coalescer.flush(), [])
    }

    func testMoveBurstCollapsesToLatest() {
        var coalescer = InputEventCoalescer()
        for i in 1...5 {
            XCTAssertEqual(coalescer.enqueue(move(Double(i) / 10)), [])
        }
        XCTAssertEqual(coalescer.pendingCount, 1)
        XCTAssertEqual(coalescer.flush(), [move(0.5)])
    }

    func testDiscreteEventFlushesHeldMoveAheadOfItself() {
        var coalescer = InputEventCoalescer()
        coalescer.enqueue(move(0.1))
        coalescer.enqueue(move(0.2))
        // The click must land at the latest position: the held
        // move comes out first, then the click itself.
        XCTAssertEqual(coalescer.enqueue(click), [move(0.2), click])
        XCTAssertTrue(coalescer.isEmpty)
    }

    func testInterleavedStreamKeepsDiscreteOrderAndLatestMoves() {
        var coalescer = InputEventCoalescer()
        var sent: [MeshInputEvent] = []
        sent += coalescer.enqueue(move(0.1))
        sent += coalescer.enqueue(click)                        // → [move .1, click]
        sent += coalescer.enqueue(move(0.2))
        sent += coalescer.enqueue(move(0.3))                    // replaces .2
        sent += coalescer.enqueue(.wheel(deltaX: 0, deltaY: -1)) // → [move .3, wheel]
        sent += coalescer.enqueue(move(0.4))
        sent += coalescer.enqueue(keystroke)                    // → [move .4, key]
        sent += coalescer.flush()
        XCTAssertEqual(sent, [
            move(0.1), click,
            move(0.3), .wheel(deltaX: 0, deltaY: -1),
            move(0.4), keystroke,
        ])
    }

    func testDiscreteOnlyStreamPassesThroughInOrder() {
        var coalescer = InputEventCoalescer()
        let events: [MeshInputEvent] = [
            .key(code: 56, down: true, flags: [.shift]),
            .key(code: 0, down: true, flags: [.shift]),
            .key(code: 0, down: false, flags: [.shift]),
            .key(code: 56, down: false, flags: []),
            .wheel(deltaX: 0, deltaY: 2),
            .textInput("a"),
            .modifiers([]),
            .releaseAll,
        ]
        for event in events {
            XCTAssertEqual(coalescer.enqueue(event), [event])
        }
        XCTAssertTrue(coalescer.isEmpty)
    }

    func testEveryDiscreteKindIsAFlushPoint() {
        let discrete: [MeshInputEvent] = [
            click, keystroke, .wheel(deltaX: 1, deltaY: 0),
            .modifiers([.shift]), .textInput("x"), .releaseAll,
        ]
        for event in discrete {
            var coalescer = InputEventCoalescer()
            coalescer.enqueue(move(0.9))
            XCTAssertEqual(coalescer.enqueue(event), [move(0.9), event],
                           "\(event) did not flush the held move")
        }
    }

    func testCoalescerReusableAfterFlush() {
        var coalescer = InputEventCoalescer()
        coalescer.enqueue(move(0.1))
        XCTAssertEqual(coalescer.flush(), [move(0.1)])
        coalescer.enqueue(move(0.2))
        XCTAssertEqual(coalescer.enqueue(keystroke), [move(0.2), keystroke])
    }

    func testMoveAfterDiscreteIsHeldNotSent() {
        var coalescer = InputEventCoalescer()
        XCTAssertEqual(coalescer.enqueue(click), [click])
        // A move right after a discrete event must not ride
        // along with it retroactively; it is held for the next
        // flush point like any other move.
        XCTAssertEqual(coalescer.enqueue(move(0.7)), [])
        XCTAssertEqual(coalescer.flush(), [move(0.7)])
    }
}
