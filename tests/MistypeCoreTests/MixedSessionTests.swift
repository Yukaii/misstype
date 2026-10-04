import XCTest
@testable import MistypeCore

/// The English pass inside `InputSession`: no mode switch, no toggle key.
final class MixedSessionTests: XCTestCase {
    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    private var settings = SessionSettings(autoShowCandidates: true)
    private var host = Host()

    private func makeSession(english: Bool = true) -> InputSession {
        let decoder = LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄒㄧㄝˋ-ㄒㄧㄝ˙\t謝謝\t-3
        """)
        let engine = InputEngine(decoder: decoder, settings: { [unowned self] in self.settings })
        if english {
            engine.englishLexicon = EnglishLexicon(tsv: "python\t-12.9\nscript\t-11.0\nmeeting\t-9.2\nthe\t-3.4\n")
        }
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

    private func enter(_ session: InputSession) -> KeyResult {
        session.handle(KeyEvent(.enter, text: "\r"))
    }

    func testBareKeysThatSpellAnEnglishWordShowAsEnglish() {
        let session = makeSession()
        type("su3cl3python", into: session)
        XCTAssertEqual(session.view.preedit, "你好python")
        XCTAssertEqual(enter(session).commit, "你好python")
    }

    func testTypoIsRepairedInThePreview() {
        let session = makeSession()
        type("su3cl3pyhton", into: session)
        XCTAssertEqual(session.view.preedit, "你好python")
    }

    func testSpaceAfterEnglishIsALiteralSpaceAndChineseResumes() {
        let session = makeSession()
        type("su3cl3python vu,4vu,7", into: session)
        XCTAssertEqual(session.view.preedit, "你好python 謝謝")
    }

    func testPureChineseIsUntouchedAndShowsNoEnglishCandidate() {
        let session = makeSession()
        type("su3cl3", into: session)
        XCTAssertEqual(session.view.preedit, "你好")
        XCTAssertFalse(session.view.candidates.contains { $0.contains("python") })
    }

    func testSettingOffOrNoWordListChangesNothing() {
        settings.mixedEnglish = false
        let off = makeSession()
        type("su3cl3python", into: off)
        XCTAssertFalse(off.view.preedit.contains("python"))
        settings.mixedEnglish = true
        let none = makeSession(english: false)
        type("su3cl3python", into: none)
        XCTAssertFalse(none.view.preedit.contains("python"))
    }

    func testBackspaceEditsTheKeysAndTheReadingFollows() {
        let session = makeSession()
        type("su3cl3python", into: session)
        // "pytho" is one deletion from python, so it still reads as English;
        // "pyth" is two, so the reading falls back to Zhuyin.
        session.handle(KeyEvent(.backspace, text: "\u{7f}"))
        XCTAssertEqual(session.view.preedit, "你好python")
        session.handle(KeyEvent(.backspace, text: "\u{7f}"))
        XCTAssertFalse(session.view.preedit.contains("python"))
        type("on", into: session)
        XCTAssertEqual(session.view.preedit, "你好python")
    }

    func testSyllableCursorAndLearningStayOutOfEnglishReadings() {
        let session = makeSession()
        type("su3cl3python", into: session)
        // Plain Left would enter the syllable cursor; over an English reading
        // it must not (no syllable indexes of the composition's own).
        let before = session.view
        _ = session.handle(KeyEvent(.left, text: "\u{F702}"))
        XCTAssertEqual(session.view.preedit, before.preedit)
        XCTAssertEqual(enter(session).commit, "你好python")
        XCTAssertTrue(session.engine.userLexicon.entries.isEmpty)
    }

    func testEnglishCanBePickedAsASuggestionAndTheListKeepsTheChineseReading() {
        // A word whose English reading wins by less than the auto margin is
        // listed beside the Chinese reading, never forced.
        let session = makeSession()
        type("su3cl3python", into: session)
        let texts = session.view.candidates
        XCTAssertTrue(texts.contains("你好python"))
    }
}
