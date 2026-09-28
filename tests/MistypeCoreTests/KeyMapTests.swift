import XCTest
@testable import MistypeCore

/// Key map parity tests: MacKeyCode, EvdevKeyCode, and USLayout must agree on
/// the same physical key labels and special key mappings.
final class KeyMapTests: XCTestCase {

    func testEvdevAndMacLabelsMatch() {
        let evdevLabels = Set(EvdevKeyCode.labels.values)
        let macLabels = Set(MacKeyCode.labels.values)
        XCTAssertEqual(evdevLabels, macLabels, "Evdev and Mac key labels must be identical (47 labels)")
        XCTAssertEqual(evdevLabels.count, 47)
    }

    func testEvdevKeyMappings() {
        // Letter keys
        XCTAssertEqual(EvdevKeyCode.key(31), .character("s"))   // KEY_S
        XCTAssertEqual(EvdevKeyCode.key(4), .character("3"))    // KEY_3
        // Special keys
        XCTAssertEqual(EvdevKeyCode.key(57), .space)            // KEY_SPACE
        XCTAssertEqual(EvdevKeyCode.key(96), .enter)            // KEY_KPENTER
        XCTAssertEqual(EvdevKeyCode.key(42), .shift(.left))     // KEY_LEFTSHIFT
        XCTAssertEqual(EvdevKeyCode.key(54), .shift(.right))    // KEY_RIGHTSHIFT
        XCTAssertEqual(EvdevKeyCode.key(29), .modifier)         // KEY_LEFTCTRL
        XCTAssertEqual(EvdevKeyCode.key(102), .other)           // KEY_HOME
    }

    func testUSLayoutMappings() {
        // Uppercase letters → shifted
        XCTAssertEqual(USLayout.key(forCharacter: "A"), USLayout.KeyMapping(key: .character("a"), shifted: true))
        XCTAssertEqual(USLayout.key(forCharacter: "Z"), USLayout.KeyMapping(key: .character("z"), shifted: true))
        // Shifted symbols
        XCTAssertEqual(USLayout.key(forCharacter: "!"), USLayout.KeyMapping(key: .character("1"), shifted: true))
        XCTAssertEqual(USLayout.key(forCharacter: "~"), USLayout.KeyMapping(key: .character("`"), shifted: true))
        // Unshifted symbols
        XCTAssertEqual(USLayout.key(forCharacter: ";"), USLayout.KeyMapping(key: .character(";"), shifted: false))
        // Space
        XCTAssertEqual(USLayout.key(forCharacter: " "), USLayout.KeyMapping(key: .space, shifted: false))
        // Non-ASCII → nil
        XCTAssertNil(USLayout.key(forCharacter: "中"))
    }

    func testUSLayoutCoversAllLabels() {
        // Every label from MacKeyCode (which equals EvdevKeyCode) must be
        // mappable via USLayout for its unshifted character.
        for label in MacKeyCode.labels.values {
            let ch = Character(label)
            let result = USLayout.key(forCharacter: ch)
            XCTAssertNotNil(result, "Label '\(label)' must be mappable via USLayout")
            XCTAssertEqual(result?.key, .character(label), "Label '\(label)' must map to .character(\"\(label)\")")
            XCTAssertEqual(result?.shifted, false, "Unshifted label '\(label)' must have shifted == false")
        }
        // Also check tone keys and space which aren't in labels dict
        XCTAssertEqual(USLayout.key(forCharacter: " "), USLayout.KeyMapping(key: .space, shifted: false))
        // Tone keys (digits 3,4,6,7) are already in labels
    }

    func testZhuyinAndToneLabelsPresentInEvdev() {
        // Every Zhuyin symbol key and tone key (minus space) must be present in EvdevKeyCode.labels
        let evdevLabelSet = Set(EvdevKeyCode.labels.values)
        for key in ZhuyinKeyboard.symbols.keys {
            XCTAssertTrue(evdevLabelSet.contains(key), "Zhuyin symbol key '\(key)' missing from EvdevKeyCode.labels")
        }
        for key in ZhuyinKeyboard.tones.keys where key != " " {
            XCTAssertTrue(evdevLabelSet.contains(key), "Tone key '\(key)' missing from EvdevKeyCode.labels")
        }
    }
}