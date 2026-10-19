import XCTest
import MeshClient
import MeshWebRTC

/// Tests for the `MeshInputEvent` control-channel codec
/// (pure). These run on every platform, including this Linux
/// box — they pin the version-1 wire forms and the strict
/// decode contract: anything malformed is nil, never a crash.
final class InputCodecTests: XCTestCase {

    private func roundTrip(_ event: MeshInputEvent) throws {
        let data = try event.encodedData()
        XCTAssertEqual(MeshInputEvent(data: data), event,
                       "data round trip changed \(event)")
        XCTAssertEqual(MeshInputEvent(jsonValue: event.jsonValue), event,
                       "JSONValue round trip changed \(event)")
    }

    // MARK: - Round trips, every kind

    func testPointerMoveRoundTrips() throws {
        try roundTrip(.pointerMove(x: 0, y: 0))
        try roundTrip(.pointerMove(x: 1, y: 1))
        try roundTrip(.pointerMove(x: 0.5, y: 0.25))
        try roundTrip(.pointerMove(x: 0.123456789, y: 0.987654321))
        // Out-of-range coordinates still decode — clamping is
        // the host geometry's job, not the codec's.
        try roundTrip(.pointerMove(x: -0.25, y: 1.4))
    }

    func testPointerButtonRoundTrips() throws {
        for button in MeshPointerButton.allCases {
            try roundTrip(.pointerButton(button: button, down: true, x: 0, y: 1))
            try roundTrip(.pointerButton(button: button, down: false, x: 1, y: 0))
        }
    }

    func testWheelRoundTrips() throws {
        try roundTrip(.wheel(deltaX: 0, deltaY: 0))
        try roundTrip(.wheel(deltaX: -2.5, deltaY: -120.75))
        try roundTrip(.wheel(deltaX: 3.125, deltaY: 1))
    }

    func testKeyRoundTrips() throws {
        try roundTrip(.key(code: 0, down: true, flags: nil))
        try roundTrip(.key(code: 0xFFFF, down: false, flags: nil))
        try roundTrip(.key(code: 36, down: true, flags: []))
        try roundTrip(.key(code: 56, down: true, flags: [.shift, .command]))
        try roundTrip(.key(code: 57, down: false,
                           flags: [.shift, .control, .option, .command, .capsLock]))
    }

    func testModifiersRoundTrips() throws {
        try roundTrip(.modifiers([]))
        try roundTrip(.modifiers([.shift, .control, .option, .command, .capsLock]))
    }

    func testTextRoundTrips() throws {
        try roundTrip(.textInput(""))
        try roundTrip(.textInput("plain ascii"))
        try roundTrip(.textInput("tiếng Việt ✓"))
        try roundTrip(.textInput("emoji 🎉 and CJK 日本語"))
    }

    func testReleaseAllRoundTrips() throws {
        try roundTrip(.releaseAll)
    }

    // MARK: - Wire forms are pinned

    func testWireForms() {
        XCTAssertEqual(MeshInputEvent.pointerMove(x: 0.5, y: 0.25).jsonValue,
                       .object(["v": .number(1), "t": .string("move"),
                                "x": .number(0.5), "y": .number(0.25)]))
        XCTAssertEqual(
            MeshInputEvent.pointerButton(button: .right, down: false, x: 1, y: 0).jsonValue,
            .object(["v": .number(1), "t": .string("button"), "b": .string("right"),
                     "down": .bool(false), "x": .number(1), "y": .number(0)]))
        XCTAssertEqual(
            MeshInputEvent.key(code: 36, down: true, flags: [.shift]).jsonValue,
            .object(["v": .number(1), "t": .string("key"), "c": .number(36),
                     "down": .bool(true), "f": .number(1)]))
        // Undeclared modifiers: the f field is absent entirely,
        // not zero — the two mean different things.
        XCTAssertEqual(
            MeshInputEvent.key(code: 36, down: true, flags: nil).jsonValue,
            .object(["v": .number(1), "t": .string("key"), "c": .number(36),
                     "down": .bool(true)]))
        XCTAssertEqual(MeshInputEvent.releaseAll.jsonValue,
                       .object(["v": .number(1), "t": .string("releaseAll")]))
    }

    func testEventShapeHelpers() {
        XCTAssertTrue(MeshInputEvent.pointerMove(x: 0, y: 0).isPositional)
        XCTAssertTrue(MeshInputEvent.pointerButton(button: .left, down: true, x: 0, y: 0).isPositional)
        XCTAssertTrue(MeshInputEvent.wheel(deltaX: 0, deltaY: 1).isPositional)
        XCTAssertFalse(MeshInputEvent.key(code: 0, down: true, flags: nil).isPositional)
        XCTAssertFalse(MeshInputEvent.pointerMove(x: 0, y: 0).isDiscrete)
        XCTAssertTrue(MeshInputEvent.releaseAll.isDiscrete)
        XCTAssertTrue(MeshInputEvent.modifiers([]).isDiscrete)
    }

    // MARK: - Malformed payloads decode to nil

    func testMalformedDataDecodesToNil() {
        XCTAssertNil(MeshInputEvent(data: Data()))
        XCTAssertNil(MeshInputEvent(data: Data("not json".utf8)))
        XCTAssertNil(MeshInputEvent(data: Data("[1,2,3]".utf8)))
        XCTAssertNil(MeshInputEvent(data: Data("\"move\"".utf8)))
        // Truncated mid-object.
        XCTAssertNil(MeshInputEvent(data: Data("{\"v\":1,\"t\":\"move\",\"x\":0.5".utf8)))
    }

    func testMalformedValuesDecodeToNil() {
        let malformed: [JSONValue] = [
            .string("move"),
            .array([]),
            .object([:]),  // missing everything
            // Version problems.
            .object(["t": .string("move"), "x": .number(0), "y": .number(0)]),
            .object(["v": .number(2), "t": .string("move"),
                     "x": .number(0), "y": .number(0)]),
            .object(["v": .string("1"), "t": .string("move"),
                     "x": .number(0), "y": .number(0)]),
            // Unknown kind.
            .object(["v": .number(1), "t": .string("teleport"),
                     "x": .number(0), "y": .number(0)]),
            // Move: missing / mistyped coordinates.
            .object(["v": .number(1), "t": .string("move"), "x": .number(0.5)]),
            .object(["v": .number(1), "t": .string("move"),
                     "x": .string("0.5"), "y": .number(0)]),
            .object(["v": .number(1), "t": .string("move"),
                     "x": .number(.nan), "y": .number(0)]),
            // Button: unknown button name, mistyped down.
            .object(["v": .number(1), "t": .string("button"), "b": .string("side"),
                     "down": .bool(true), "x": .number(0), "y": .number(0)]),
            .object(["v": .number(1), "t": .string("button"), "b": .string("left"),
                     "down": .number(1), "x": .number(0), "y": .number(0)]),
            // Key: code out of range / fractional, flags out of range.
            .object(["v": .number(1), "t": .string("key"),
                     "c": .number(65536), "down": .bool(true)]),
            .object(["v": .number(1), "t": .string("key"),
                     "c": .number(-1), "down": .bool(true)]),
            .object(["v": .number(1), "t": .string("key"),
                     "c": .number(36.5), "down": .bool(true)]),
            .object(["v": .number(1), "t": .string("key"), "c": .number(36),
                     "down": .bool(true), "f": .number(256)]),
            .object(["v": .number(1), "t": .string("key"), "c": .number(36),
                     "down": .bool(true), "f": .number(-1)]),
            // Modifiers: missing bits.
            .object(["v": .number(1), "t": .string("modifiers")]),
            // Text: missing string.
            .object(["v": .number(1), "t": .string("text")]),
            .object(["v": .number(1), "t": .string("text"), "s": .number(3)]),
        ]
        for value in malformed {
            XCTAssertNil(MeshInputEvent(jsonValue: value), "accepted \(value)")
        }
    }

    func testUnknownExtraFieldsAreIgnored() {
        // Same-version forward compatibility: annotations from
        // a newer sender must not break this receiver.
        let value: JSONValue = .object([
            "v": .number(1), "t": .string("move"),
            "x": .number(0.25), "y": .number(0.75),
            "futureField": .string("annotation"),
        ])
        XCTAssertEqual(MeshInputEvent(jsonValue: value),
                       .pointerMove(x: 0.25, y: 0.75))
    }

    func testNonFiniteValuesCannotEncode() {
        XCTAssertThrowsError(try MeshInputEvent.pointerMove(x: .nan, y: 0).encodedData())
        XCTAssertThrowsError(try MeshInputEvent.wheel(deltaX: 0, deltaY: .infinity).encodedData())
    }

    // MARK: - Modifier vocabulary

    func testModifierBitLayoutMatchesMode1() {
        // RemoteModifiers (Mode 1): shift 1, control 2, option
        // 4, command 8, capsLock 16 — pinned so the modes can
        // never drift apart silently.
        XCTAssertEqual(MeshInputModifiers.shift.rawValue, 1)
        XCTAssertEqual(MeshInputModifiers.control.rawValue, 2)
        XCTAssertEqual(MeshInputModifiers.option.rawValue, 4)
        XCTAssertEqual(MeshInputModifiers.command.rawValue, 8)
        XCTAssertEqual(MeshInputModifiers.capsLock.rawValue, 16)
    }

    func testModifierForKeyCode() {
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x37), .command)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x36), .command)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x38), .shift)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x3C), .shift)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x3A), .option)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x3D), .option)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x3B), .control)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x3E), .control)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x39), .capsLock)
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x00), [])
        XCTAssertEqual(MeshInputModifiers.modifier(forKeyCode: 0x24), [])
        XCTAssertTrue(MeshInputModifiers.isModifierKey(0x37))
        XCTAssertFalse(MeshInputModifiers.isModifierKey(0x00))
    }
}
