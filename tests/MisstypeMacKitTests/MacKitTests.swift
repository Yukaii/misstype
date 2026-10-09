import XCTest
@testable import MisstypeMacKit

/// The UI-side types the macOS IME keeps in Swift. Editing behavior lives in
/// the Zig core and is tested there (core-zig/src/tests).
final class MacKitTests: XCTestCase {
    // MARK: Key bindings (port of KeyBindingsTests; resolve lives in Zig)

    func testChordTextRoundTripsAndRejectsKeysThatType() {
        XCTAssertEqual(KeyChord("ctrl+shift+J")?.description, "ctrl+shift+j")
        XCTAssertEqual(KeyChord("cmd+comma"), KeyChord(.character(","), .command))
        XCTAssertEqual(KeyChord(.character(","), .control).description, "ctrl+comma")
        XCTAssertEqual(KeyChord("shift+space"), KeyChord(.space, .shift))
        XCTAssertEqual(KeyChord("pagedown"), KeyChord(.pageDown))
        // Printable keys need Control/Option/Command; editing keys never bind.
        XCTAssertNil(KeyChord("j"))
        XCTAssertNil(KeyChord("shift+j"))
        XCTAssertNil(KeyChord("ctrl+backspace"))
        XCTAssertNil(KeyChord("hyper+j"))
        XCTAssertNil(KeyChord("ctrl+"))
    }

    func testParseSerializeKeepsOverridesAndUnboundActions() {
        let bindings = KeyBindings.parse("""
        # comment
        nextCandidate = down, ctrl+n
        latinRun =
        bogus = ctrl+x
        cancel = j, ctrl+g
        """)
        XCTAssertEqual(bindings.chords(for: .nextCandidate), [KeyChord(.down), KeyChord(.character("n"), .control)])
        XCTAssertEqual(bindings.chords(for: .latinRun), [])
        XCTAssertEqual(bindings.chords(for: .cancel), [KeyChord(.character("g"), .control)])
        XCTAssertEqual(bindings.chords(for: .commit), [KeyChord(.enter)])
        XCTAssertEqual(KeyBindings.parse(bindings.serialized), bindings)
    }

    func testConflictsListChordsBoundToMoreThanOneAction() {
        let bindings = KeyBindings(overrides: [.cursorBack: [KeyChord(.left), KeyChord(.tab)]])
        XCTAssertTrue(bindings.conflicts.contains(KeyChord(.tab)))
        XCTAssertTrue(KeyBindings().conflicts.isEmpty)
    }

    // MARK: Selection keys and settings (port of CoreTests.testSelectionKeys)

    func testSelectionKeys() {
        XCTAssertEqual(SelectionKeys.labels(keys: "asdfghjkl;"), ["a", "s", "d", "f", "g", "h", "j", "k"])
        XCTAssertEqual(SelectionKeys.sanitize("ASdd f!"), "asdf")
        XCTAssertEqual(SelectionKeys.sanitize("   "), "asdfghjk")
        XCTAssertEqual(SelectionKeys.sanitize("12345678"), "12345678")
        XCTAssertEqual(SelectionKeys.sanitize("1234567890", pageSize: 10), "1234567890")
        XCTAssertEqual(SelectionKeys.sanitize("aab"), "ab")
    }

    func testPageSizeClamps() {
        var settings = SessionSettings()
        settings.pageSize = 99
        XCTAssertEqual(settings.pageSize, SelectionKeys.pageSizes.upperBound)
        settings.pageSize = 1
        XCTAssertEqual(settings.pageSize, SelectionKeys.pageSizes.lowerBound)
        XCTAssertEqual(RepairStrength.strong.level, 3)
        XCTAssertEqual(CursorCandidates.endingAt.level, 1)
        XCTAssertFalse(SessionSettings(repairStrength: .off).fuzzyRepair)
    }

    // MARK: Candidate rows and the trace caret (port of CoreTests)

    func testCandidateDisplayShowsWhereRowsDiffer() {
        let rows = ["但中間有些字都會立即找到配對", "但中間有些字都會立即找到配隊", "但中間有些字都會立即找到佩對"]
        XCTAssertEqual(CandidateDisplay.windows(rows), ["…找到配對", "…找到配隊", "…找到佩對"])
        // A difference in the middle keeps context on both sides.
        XCTAssertEqual(CandidateDisplay.windows(["測試一下會不會大對", "測試以下會不會大對"]),
                       ["測試一下會…", "測試以下會…"])
        // Word lists (cursor mode) share nothing: shown whole.
        XCTAssertEqual(CandidateDisplay.windows(["打對", "大", "打"]), ["打對", "大", "打"])
        // A single long row keeps its tail, as before.
        XCTAssertEqual(CandidateDisplay.windows([String(repeating: "字", count: 20)], maxChars: 5), ["…字字字字字"])
        XCTAssertEqual(CandidateDisplay.windows([]), [])
        // A window wider than a row keeps the end nearest the cursor.
        XCTAssertEqual(CandidateDisplay.windows(["學系的狀況是怎麼樣字典", "學習的狀況是怎麼樣自點"], maxChars: 6),
                       ["…是怎麼樣字典", "…是怎麼樣自點"])
    }

    func testPreeditWithCursorMarksPosition() {
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 0), "|你好嗎")
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 1), "你|好嗎")
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 3), "你好嗎|")
        // Out-of-range clamps instead of trapping.
        XCTAssertEqual(preeditWithCursor("你好", caretUTF16: 99), "你好|")
        XCTAssertEqual(preeditWithCursor("你好", caretUTF16: -2), "|你好")
        XCTAssertEqual(preeditWithCursor("", caretUTF16: 0), "|")
    }
}
