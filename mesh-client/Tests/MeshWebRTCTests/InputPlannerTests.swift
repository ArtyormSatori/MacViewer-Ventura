import XCTest
import MeshWebRTC

/// Tests for `MeshInputGeometry` and `MeshInputPlanner`
/// (pure). These run on every platform, including this Linux
/// box — they are the CI-provable half of the host input
/// path: mapping math, the capability gate, held-state rules,
/// and wheel accumulation. The CGEvent executor
/// (`MeshInputApplier`) is a thin shell over these decisions.
final class InputGeometryTests: XCTestCase {

    private let hd = MeshDisplaySize(width: 1920, height: 1080)

    func testCornersAndCenter() {
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0, y: 0, in: hd) == (0, 0))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 1, y: 1, in: hd) == (1919, 1079))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0.5, y: 0.5, in: hd) == (960, 540))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0.5, y: 0.5,
                                                   in: MeshDisplaySize(width: 1366, height: 768))
                        == (683, 384))
    }

    func testNonIntegerScalingFloors() {
        // 0.333 * 1920 = 639.36 → 639; 0.999 * 1080 = 1078.92 → 1078.
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0.333, y: 0.999, in: hd) == (639, 1078))
    }

    func testOutOfRangeClampsToEdges() {
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: -0.25, y: 1.4, in: hd) == (0, 1079))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 2, y: -1,
                                                   in: MeshDisplaySize(width: 800, height: 600))
                        == (799, 0))
    }

    func testDegenerateInputs() {
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0.5, y: 0.5,
                                                   in: MeshDisplaySize(width: 0, height: 0))
                        == (0, 0))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: .nan, y: .infinity, in: hd) == (0, 0))
        XCTAssertTrue(MeshInputGeometry.pixelPoint(x: 0.9, y: 0.9,
                                                   in: MeshDisplaySize(width: 1, height: 1))
                        == (0, 0))
    }
}

final class InputPlannerTests: XCTestCase {

    private let size = MeshDisplaySize(width: 1000, height: 1000)

    private func makePlanner(allowed: Bool = true,
                             size: MeshDisplaySize? = MeshDisplaySize(width: 1000, height: 1000))
        -> MeshInputPlanner {
        MeshInputPlanner(controlAllowed: allowed, displaySize: size)
    }

    // MARK: - The gate

    func testGateDropsEveryKindAndCounts() {
        let planner = makePlanner(allowed: false)
        let events: [MeshInputEvent] = [
            .pointerMove(x: 0.5, y: 0.5),
            .pointerButton(button: .left, down: true, x: 0.5, y: 0.5),
            .wheel(deltaX: 0, deltaY: 1),
            .key(code: 0, down: true, flags: nil),
            .modifiers([.shift]),
            .textInput("x"),
            .releaseAll,
        ]
        for event in events {
            XCTAssertEqual(planner.plan(event), [], "\(event) planned while disallowed")
        }
        XCTAssertEqual(planner.droppedEventCount, events.count)
        XCTAssertEqual(planner.unmappedEventCount, 0)
        XCTAssertTrue(planner.currentlyHeldKeyCodes.isEmpty)
        XCTAssertTrue(planner.currentlyHeldButtons.isEmpty)

        planner.controlAllowed = true
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.5)),
                       [.mouseMove(x: 500, y: 500, dragButton: nil, flags: [])])
    }

    func testReleaseAllActionsBypassTheGate() {
        let planner = makePlanner()
        planner.plan(.key(code: 0, down: true, flags: nil))
        planner.plan(.pointerButton(button: .left, down: true, x: 0.5, y: 0.5))
        planner.controlAllowed = false
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.1, y: 0.1)), [])
        XCTAssertEqual(planner.droppedEventCount, 1)
        // Local teardown still releases, and is not counted
        // as a gated drop.
        XCTAssertEqual(planner.releaseAllActions(), [
            .key(code: 0, down: false, flags: [], isRepeat: false),
            .mouseButton(.left, down: false, x: 500, y: 500, flags: []),
        ])
        XCTAssertEqual(planner.droppedEventCount, 1)
        XCTAssertTrue(planner.currentlyHeldKeyCodes.isEmpty)
        XCTAssertTrue(planner.currentlyHeldButtons.isEmpty)
    }

    // MARK: - Display size requirement

    func testPositionalEventsNeedADisplaySize() {
        let planner = makePlanner(size: nil)
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.5)), [])
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: true, x: 0.5, y: 0.5)), [])
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 1)), [])
        XCTAssertEqual(planner.unmappedEventCount, 3)
        // Non-positional events plan fine without a size.
        XCTAssertEqual(planner.plan(.key(code: 36, down: true, flags: nil)),
                       [.key(code: 36, down: true, flags: [], isRepeat: false)])
        XCTAssertEqual(planner.plan(.textInput("héllo")), [.textInput("héllo")])
        // The unmapped button press did NOT latch as held.
        planner.displaySize = size
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: false, x: 0.5, y: 0.5)), [])
    }

    // MARK: - Moves

    func testMoveMappingAndDuplicateSuppression() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.25)),
                       [.mouseMove(x: 500, y: 250, dragButton: nil, flags: [])])
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.25)), [])
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.251)),
                       [.mouseMove(x: 500, y: 251, dragButton: nil, flags: [])])
    }

    func testMoveReemittedWhenOnlyFlagsChange() {
        let planner = makePlanner()
        planner.plan(.pointerMove(x: 0.5, y: 0.5))
        planner.plan(.key(code: 56, down: true, flags: nil))  // Shift
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.5)),
                       [.mouseMove(x: 500, y: 500, dragButton: nil, flags: [.shift])])
    }

    func testDragStateFollowsHeldButtons() {
        let planner = makePlanner()
        planner.plan(.pointerMove(x: 0.1, y: 0.1))
        planner.plan(.pointerButton(button: .left, down: true, x: 0.2, y: 0.2))
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.3, y: 0.3)),
                       [.mouseMove(x: 300, y: 300, dragButton: .left, flags: [])])
        // Left wins over middle while both are held.
        planner.plan(.pointerButton(button: .middle, down: true, x: 0.3, y: 0.3))
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.35, y: 0.35)),
                       [.mouseMove(x: 350, y: 350, dragButton: .left, flags: [])])
        planner.plan(.pointerButton(button: .left, down: false, x: 0.35, y: 0.35))
        planner.plan(.pointerButton(button: .middle, down: false, x: 0.35, y: 0.35))
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.4, y: 0.4)),
                       [.mouseMove(x: 400, y: 400, dragButton: nil, flags: [])])
    }

    func testDisplaySizeChangeForgetsMoveBaseline() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.5)),
                       [.mouseMove(x: 500, y: 500, dragButton: nil, flags: [])])
        planner.displaySize = MeshDisplaySize(width: 2000, height: 2000)
        XCTAssertEqual(planner.plan(.pointerMove(x: 0.5, y: 0.5)),
                       [.mouseMove(x: 1000, y: 1000, dragButton: nil, flags: [])])
    }

    // MARK: - Buttons

    func testButtonDuplicatesAndUnheldUpsAreNoops() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: true, x: 0.2, y: 0.2)),
                       [.mouseButton(.left, down: true, x: 200, y: 200, flags: [])])
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: true, x: 0.9, y: 0.9)), [])
        XCTAssertEqual(planner.currentlyHeldButtons, [.left])
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: false, x: 0.9, y: 0.9)),
                       [.mouseButton(.left, down: false, x: 900, y: 900, flags: [])])
        XCTAssertEqual(planner.plan(.pointerButton(button: .left, down: false, x: 0.9, y: 0.9)), [])
    }

    func testButtonCarriesItsOwnPointAndWheelFollowsIt() {
        let planner = makePlanner()
        planner.plan(.pointerMove(x: 0.1, y: 0.1))
        XCTAssertEqual(planner.plan(.pointerButton(button: .right, down: true, x: 0.9, y: 0.8)),
                       [.mouseButton(.right, down: true, x: 900, y: 800, flags: [])])
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 1)),
                       [.wheel(linesX: 0, linesY: 1, x: 900, y: 800, flags: [])])
    }

    // MARK: - Wheel

    func testWheelAccumulatesFractionalDeltas() {
        let planner = makePlanner()
        planner.plan(.pointerMove(x: 0.5, y: 0.5))
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 0.4)), [])
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 0.4)), [])
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 0.4)),
                       [.wheel(linesX: 0, linesY: 1, x: 500, y: 500, flags: [])])
        // Remainder ≈ 0.2; -1.7 takes it to ≈ -1.5 → one line back.
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: -1.7)),
                       [.wheel(linesX: 0, linesY: -1, x: 500, y: 500, flags: [])])
        // Horizontal accumulates independently (remainder -0.5 vertical stays).
        XCTAssertEqual(planner.plan(.wheel(deltaX: 2.5, deltaY: 0)),
                       [.wheel(linesX: 2, linesY: 0, x: 500, y: 500, flags: [])])
    }

    // MARK: - Keys and modifiers

    func testKeyFlagsLifecycle() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.key(code: 56, down: true, flags: nil)),
                       [.key(code: 56, down: true, flags: [.shift], isRepeat: false)])
        XCTAssertEqual(planner.plan(.key(code: 0, down: true, flags: nil)),
                       [.key(code: 0, down: true, flags: [.shift], isRepeat: false)])
        XCTAssertEqual(planner.plan(.key(code: 0, down: false, flags: nil)),
                       [.key(code: 0, down: false, flags: [.shift], isRepeat: false)])
        // The modifier's own release carries the post-transition state.
        XCTAssertEqual(planner.plan(.key(code: 56, down: false, flags: nil)),
                       [.key(code: 56, down: false, flags: [], isRepeat: false)])
        XCTAssertEqual(planner.plan(.key(code: 56, down: false, flags: nil)), [])
    }

    func testKeyRepeatIsMarkedNotSuppressed() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.key(code: 0, down: true, flags: nil)),
                       [.key(code: 0, down: true, flags: [], isRepeat: false)])
        XCTAssertEqual(planner.plan(.key(code: 0, down: true, flags: nil)),
                       [.key(code: 0, down: true, flags: [], isRepeat: true)])
        XCTAssertEqual(planner.currentlyHeldKeyCodes, [0])
    }

    func testDeclaredModifiersReplaceAndPersist() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.key(code: 4, down: true, flags: [.command])),
                       [.key(code: 4, down: true, flags: [.command], isRepeat: false)])
        XCTAssertEqual(planner.plan(.key(code: 4, down: false, flags: nil)),
                       [.key(code: 4, down: false, flags: [.command], isRepeat: false)])
        XCTAssertEqual(planner.plan(.modifiers([.control])), [])
        XCTAssertEqual(planner.plan(.key(code: 4, down: true, flags: nil)),
                       [.key(code: 4, down: true, flags: [.control], isRepeat: false)])
    }

    // MARK: - Release

    func testReleaseAllOrderFlagsAndCapsLockSurvival() {
        let planner = makePlanner()
        planner.plan(.wheel(deltaX: 0, deltaY: 0.5))  // remainder, must reset
        planner.plan(.modifiers([.capsLock]))
        planner.plan(.key(code: 56, down: true, flags: nil))
        planner.plan(.key(code: 0, down: true, flags: nil))
        planner.plan(.pointerButton(button: .left, down: true, x: 0.5, y: 0.5))
        XCTAssertEqual(planner.currentlyHeldKeyCodes, [56, 0])

        XCTAssertEqual(planner.plan(.releaseAll), [
            .key(code: 0, down: false, flags: [.capsLock, .shift], isRepeat: false),
            .key(code: 56, down: false, flags: [.capsLock], isRepeat: false),
            .mouseButton(.left, down: false, x: 500, y: 500, flags: [.capsLock]),
        ])
        XCTAssertTrue(planner.currentlyHeldKeyCodes.isEmpty)
        XCTAssertTrue(planner.currentlyHeldButtons.isEmpty)
        // Caps Lock survived the release; the wheel remainder did not.
        XCTAssertEqual(planner.plan(.key(code: 0, down: true, flags: nil)),
                       [.key(code: 0, down: true, flags: [.capsLock], isRepeat: false)])
        planner.plan(.key(code: 0, down: false, flags: nil))
        XCTAssertEqual(planner.plan(.wheel(deltaX: 0, deltaY: 0.6)), [])
    }

    func testReleaseAllWithNothingHeldPlansNothing() {
        let planner = makePlanner()
        XCTAssertEqual(planner.plan(.releaseAll), [])
        XCTAssertEqual(planner.releaseAllActions(), [])
    }
}
