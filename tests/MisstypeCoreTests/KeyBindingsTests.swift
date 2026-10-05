import XCTest
@testable import MisstypeCore

/// User key bindings: text form, and the rewrite into each action's
/// canonical key before the session sees the event.
final class KeyBindingsTests: XCTestCase {
    private var settings = SessionSettings()

    private func makeSession() -> InputSession {
        let decoder = LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄋㄧˇ\t妳\t-6
        ㄋㄧˇ\t尼\t-7
        ㄋㄧˇ\t泥\t-8
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        """)
        let engine = InputEngine(decoder: decoder, settings: { [unowned self] in self.settings })
        return InputSession(engine: engine)
    }

    private func type(_ keys: String, into session: InputSession) {
        for char in keys { _ = session.handle(KeyEvent(.character(String(char)), text: String(char))) }
    }

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

    func testBoundChordActsLikeTheCanonicalKey() {
        settings.keyBindings = KeyBindings(overrides: [.nextCandidate: [KeyChord(.down), KeyChord("ctrl+n")!]])
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(KeyEvent(.character("n"), modifiers: [.control], text: "\u{0e}")),
                       KeyResult(consumed: true))
        XCTAssertEqual(session.view.selected, 1)
        XCTAssertTrue(session.view.keysActive)
    }

    func testUnboundChordCommitsAndPassesLikeAnyChord() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(KeyEvent(.character("n"), modifiers: [.control], text: "\u{0e}")),
                       KeyResult(consumed: false, commit: "你"))
    }

    func testRemovedDefaultGoesToTheApplication() {
        settings.keyBindings = KeyBindings(overrides: [.nextPage: [KeyChord(.pageDown)]])
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(KeyEvent(.tab, text: "\t")), KeyResult(consumed: false, commit: "你"))
    }

    func testExplicitBindingWinsOverAnotherActionsDefault() {
        // Tab now walks the syllable cursor back instead of stepping the list.
        settings.keyBindings = KeyBindings(overrides: [.cursorBack: [KeyChord(.left), KeyChord(.tab)]])
        XCTAssertTrue(settings.keyBindings.conflicts.contains(KeyChord(.tab)))
        let session = makeSession()
        type("su3cl3", into: session)
        XCTAssertEqual(session.handle(KeyEvent(.tab, text: "\t")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.candidates.first, "你好")
        XCTAssertEqual(session.view.caret, 1)
    }

    func testDefaultsHaveNoConflicts() {
        XCTAssertTrue(KeyBindings().conflicts.isEmpty)
        XCTAssertEqual(KeyBindings().resolve(KeyEvent(.pageDown)), .unchanged)
        XCTAssertEqual(KeyBindings().resolve(KeyEvent(.tab, text: "\t")), .rewritten(KeyEvent(.pageDown)))
    }
}
