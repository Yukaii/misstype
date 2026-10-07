import XCTest
@testable import MisstypeCore

/// Editing inside the composition: typing at the syllable cursor (issue
/// #32) and Option word editing over Latin runs and words (issue #33).
final class CaretEditingTests: XCTestCase {
    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    private var settings = SessionSettings()
    private var host = Host()

    /// The conformance fixture lexicon (`InputSessionTests`).
    private func makeSession() -> InputSession {
        let decoder = LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄋㄧˇ\t妳\t-6
        ㄋㄧˇ\t尼\t-7
        ㄋㄧˇ\t泥\t-8
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄇㄚ˙\t嗎\t-4
        """)
        let engine = InputEngine(decoder: decoder, settings: { [unowned self] in self.settings })
        let session = InputSession(engine: engine)
        session.host = host
        return session
    }

    @discardableResult
    private func type(_ keys: String, into session: InputSession) -> [KeyResult] {
        keys.map { char in
            let label = String(char)
            return session.handle(label == " " ? KeyEvent(.space, text: " ") : KeyEvent(.character(label), text: label))
        }
    }

    @discardableResult
    private func press(_ key: KeyEvent.Key, _ modifiers: KeyEvent.Modifiers = [], in session: InputSession) -> KeyResult {
        session.handle(KeyEvent(key, modifiers: modifiers))
    }

    // MARK: - #32 typing at the syllable cursor

    func testTypingAtTheCursorInsertsThere() {
        let session = makeSession()
        type("su3a87", into: session)
        XCTAssertEqual(session.view.preedit, "你嗎")
        press(.left, in: session)
        XCTAssertEqual(session.view.caret, 1)
        XCTAssertFalse(session.view.keysActive)
        XCTAssertTrue(type("cl3", into: session).allSatisfy { $0.consumed && $0.commit == nil && !$0.beep })
        XCTAssertEqual(session.view.preedit, "你好嗎")
        XCTAssertEqual(session.view.caret, 2)
        XCTAssertEqual(session.rawPhonetic, "ㄋㄧˇㄏㄠˇㄇㄚ˙")
        XCTAssertEqual(session.handle(KeyEvent(.enter, text: "\r")).commit, "你好嗎")
    }

    func testSelectionKeysTypeZhuyinAtTheCursorUntilTabArmsThem() {
        let session = makeSession()
        type("su3cl3", into: session)
        press(.left, in: session)
        type("a87", into: session) // `a` is selection slot 1 and ㄇ
        XCTAssertEqual(session.view.preedit, "你嗎好")
        // Tab arms the focused list; Esc disarms it and keeps the cursor.
        press(.left, in: session)
        press(.left, in: session)
        press(.tab, in: session)
        XCTAssertTrue(session.view.keysActive)
        XCTAssertEqual(press(.escape, in: session), KeyResult(consumed: true))
        XCTAssertFalse(session.view.keysActive)
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertEqual(session.view.caret, 0)
        type("a87", into: session)
        XCTAssertEqual(session.view.preedit, "嗎你嗎好")
    }

    func testBackspaceAndForwardDeleteAtTheCursor() {
        let session = makeSession()
        type("su3cl3a87", into: session)
        press(.left, in: session)
        press(.left, in: session) // caret before 好
        XCTAssertEqual(session.view.caret, 1)
        XCTAssertEqual(press(.backspace, in: session), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "好嗎")
        XCTAssertEqual(session.view.caret, 0)
        XCTAssertEqual(press(.forwardDelete, in: session), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "嗎")
        type("su3cl3", into: session)
        XCTAssertEqual(session.view.preedit, "你好嗎")
        XCTAssertEqual(session.view.caret, 2)
    }

    func testEscapeAndRightPastTheEndReturnTheCaretToTheEnd() {
        let session = makeSession()
        type("su3a87", into: session)
        press(.left, in: session)
        type("cl3", into: session)
        XCTAssertEqual(session.view.caret, 2)
        XCTAssertEqual(press(.right, in: session), KeyResult(consumed: true))
        XCTAssertEqual(session.view.caret, 3)
        type("su3", into: session)
        XCTAssertEqual(session.view.preedit, "你好嗎你")

        press(.left, in: session)
        XCTAssertEqual(press(.escape, in: session), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你好嗎你")
        XCTAssertEqual(session.view.caret, 4)
        XCTAssertFalse(session.view.showsCandidates && session.view.focus != nil)
        type("a87", into: session)
        XCTAssertEqual(session.view.preedit, "你好嗎你嗎")
    }

    func testNoAutoCommitWhileEditingMidComposition() {
        settings.autoCommitSyllables = 4
        let session = makeSession()
        type("su3su3", into: session)
        press(.left, in: session)
        for _ in 0..<4 {
            XCTAssertTrue(type("a87", into: session).allSatisfy { $0.commit == nil })
        }
        XCTAssertEqual(session.view.preedit, "你嗎嗎嗎嗎你")
    }

    // MARK: - #33 Option word editing

    func testOptionBackspaceDeletesALatinWord() {
        let session = makeSession()
        type("su3`hello world", into: session)
        XCTAssertEqual(session.view.preedit, "你hello world")
        press(.backspace, .option, in: session)
        XCTAssertEqual(session.view.preedit, "你hello ")
        press(.backspace, .option, in: session)
        XCTAssertEqual(session.view.preedit, "你")
        XCTAssertTrue(session.latinActive)
        type("ok", into: session)
        XCTAssertEqual(session.view.preedit, "你ok")
    }

    func testOptionArrowsJumpByWordAndTypingFollowsTheCaret() {
        let session = makeSession()
        type("su3cl3`hello world", into: session)
        XCTAssertEqual(press(.left, .option, in: session), KeyResult(consumed: true))
        XCTAssertEqual(session.view.caret, 8) // 你好hello |world
        XCTAssertTrue(session.latinActive)
        type("big ", into: session)
        XCTAssertEqual(session.view.preedit, "你好hello big world")
        XCTAssertEqual(session.view.caret, 12)
        press(.left, .option, in: session) // |big
        press(.left, .option, in: session) // |hello
        XCTAssertEqual(session.view.caret, 2)
        press(.left, .option, in: session) // |你好 (one decoded word)
        XCTAssertEqual(session.view.caret, 0)
        XCTAssertEqual(press(.left, .option, in: session), KeyResult(consumed: true, beep: true))
        XCTAssertFalse(session.latinActive)
        type("a87", into: session)
        XCTAssertEqual(session.view.preedit, "嗎你好hello big world")
        press(.right, .option, in: session) // 嗎你好| (word end)
        press(.backspace, .option, in: session) // a syllable, not the Latin word after it
        XCTAssertEqual(session.view.preedit, "嗎你hello big world")
        press(.right, .option, in: session)
        press(.right, .option, in: session)
        press(.right, .option, in: session)
        XCTAssertEqual(session.view.caret, session.view.preedit.utf16.count)
        XCTAssertEqual(press(.right, .option, in: session), KeyResult(consumed: true, beep: true))
        XCTAssertEqual(session.handle(KeyEvent(.enter, text: "\r")).commit, "嗎你hello big world")
    }

    func testCommandArrowsStillCommitAndPass() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(press(.left, .command, in: session), KeyResult(consumed: false, commit: "你"))
    }

    // MARK: - Building blocks

    func testCompositionEditsAtTheCaret() {
        var composition = Composition()
        for key in ["s", "u", "3", "a", "8", "7"] { composition.append(key) }
        composition.moveCaret(to: 3)
        XCTAssertTrue(composition.atCaret { $0.append("c") })
        composition.atCaret { _ = $0.append("l") }
        composition.atCaret { _ = $0.append("3") }
        XCTAssertEqual(composition.rawKeys, ["s", "u", "3", "c", "l", "3", "a", "8", "7"])
        XCTAssertEqual(composition.caret, 6)
        // A tone with nothing pending before the caret is refused, as at the end.
        XCTAssertFalse(composition.atCaret { $0.append("4") })
        composition.atCaret { $0.erase() }
        XCTAssertEqual(composition.rawPhonetic, "ㄋㄧˇㄇㄚ˙")
        XCTAssertEqual(composition.caret, 3)
        composition.removeKeys(3..<6)
        XCTAssertNil(composition.caret, "nothing after the caret: back at the end")
    }

    func testLayoutSplitsAFusedTonelessBodyByDecodedSyllables() {
        let decoder = LexiconDecoder(tsv: "ㄋㄧ\t你\t-5\nㄏㄠ\t好\t-5\nㄋㄧ-ㄏㄠ\t你好\t-3\n")
        var composition = Composition()
        for key in ["s", "u", "c", "l", " "] { composition.append(key) }
        let preview = decoder.livePreview(composition)
        guard let top = preview.candidates.first,
              let layout = CompositionLayout(keys: composition.rawKeys, shown: top, rawTail: preview.rawTail.count)
        else { return XCTFail("no layout") }
        XCTAssertEqual(top.text, "你好")
        XCTAssertEqual(layout.syllableKeys, [0..<2, 2..<5])
        XCTAssertEqual(layout.offsets, [0, 1, 1, 2, 2, 2])
        XCTAssertEqual(layout.keyIndex(ofBoundary: 1), 2)
        XCTAssertEqual(layout.boundary(atKey: 2), 1)
        XCTAssertEqual(layout.wordStarts, [0])
        XCTAssertEqual(layout.wordEnds, [5])
    }
}
