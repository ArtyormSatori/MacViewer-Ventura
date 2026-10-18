import Foundation
import Testing
@testable import MacViewer

struct KeyboardInputModeTests {
    @Test("VNI passthrough never attaches a character, not even for digits or Delete")
    func vniSendsPureKeys() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true, mode: .vniPassthrough)
        // Letter A: keycode mode would carry 0x61; VNI must carry 0.
        #expect(encoder.encode(.key(keyCode: 0x00, characters: "a", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0, 0, 0])
        ])
        // Digit 1 carries the tone in VNI, so it must reach the remote IME raw.
        #expect(encoder.encode(.key(keyCode: 0x12, characters: "1", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x31, 0x02, 0, 0, 0, 0])
        ])
        // Delete: keycode mode attaches character 8; VNI must not, so the
        // remote IME can treat it as its own editing key.
        #expect(encoder.encode(.key(keyCode: 0x33, characters: "\u{7f}", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 8, 14, 0, 0, 0, 0])
        ])
    }

    @Test("Unicode text mode sends single-unit composed characters")
    func unicodeSendsComposedCharacters() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true, mode: .unicodeText)
        // á (U+00E1) typed on the A key.
        #expect(encoder.encode(.key(keyCode: 0x00, characters: "á", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0xe1, 0x00, 0])
        ])
        // ế (U+1EBF) typed on the E key.
        #expect(encoder.encode(.key(keyCode: 0x0e, characters: "ế", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x45, 0x12, 0, 0xbf, 0x1e, 0])
        ])
    }

    @Test("Unicode text mode falls back to the physical key for multi-unit or shortcut input")
    func unicodeFallbacks() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true, mode: .unicodeText)
        // Combining sequence e + U+0301 is two UTF-16 units: cannot be sent.
        #expect(encoder.encode(.key(keyCode: 0x0e, characters: "e\u{301}", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x45, 0x12, 0, 0, 0, 0])
        ])
        // An emoji is a surrogate pair: also two units.
        #expect(encoder.encode(.key(keyCode: 0x0e, characters: "😀", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x45, 0x12, 0, 0, 0, 0])
        ])
        // With Control held, á must go down the physical shortcut path: the
        // encoder first synthesizes the Control key itself (its standard
        // modifier reconciliation, in every mode), then the A key with NO
        // composed character attached.
        let shortcut = encoder.encode(.key(keyCode: 0x00, characters: "á", pressed: true, modifiers: [.control]))
        #expect(shortcut.count == 2)
        #expect(shortcut.last == Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0, 0, 0]))
        #expect(shortcut.allSatisfy { $0[8] == 0 && $0[9] == 0 })
    }

    @Test("Keyboard mode default and stored key stay stable")
    func modeDefaults() {
        #expect(KeyboardInputMode(rawValue: "vniPassthrough") == .vniPassthrough)
        #expect(KeyboardInputMode(rawValue: "nonsense") == nil)
        #expect(KeyboardInputMode.defaultsKey == "MacViewer.keyboardMode")
        #expect(KeyboardInputMode.keycode.rawValue == "keycode")
    }
}
