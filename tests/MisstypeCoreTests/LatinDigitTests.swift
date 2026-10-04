import XCTest
@testable import MisstypeCore

/// Digits inside a latin run (backtick or mid-composition Shift tap) are text.
final class LatinDigitTests: XCTestCase {
    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }
    private var host = Host()
    private func make() -> InputSession {
        let engine = InputEngine(decoder: LexiconDecoder(tsv: "ㄋㄧˇ\t你\t-5\nㄏㄠˇ\t好\t-5\nㄋㄧˇ-ㄏㄠˇ\t你好\t-3\n"),
                                 settings: { SessionSettings() })
        let session = InputSession(engine: engine)
        session.host = host
        return session
    }
    @discardableResult
    private func type(_ keys: String, _ session: InputSession) -> [KeyResult] {
        keys.map { session.handle(KeyEvent(.character(String($0)), text: String($0))) }
    }

    func testDigitsStayInTheLatinRun() {
        let session = make()
        type("`abc123", session)
        XCTAssertEqual(session.view.preedit, "abc123")
        XCTAssertEqual(session.rawPhonetic, "abc123")
        XCTAssertEqual(session.handle(KeyEvent(.enter, text: "\r")).commit, "abc123")
    }

    func testChineseResumesAfterTheClosingBacktick() {
        let session = make()
        type("`mp3`su3cl3", session)
        XCTAssertEqual(session.view.preedit, "mp3你好")
    }

    func testDigitsOutsideALatinRunAreStillZhuyin() {
        let session = make()
        type("su3cl3", session)
        XCTAssertEqual(session.view.preedit, "你好")
        // A digit right after Chinese keys is a tone/Zhuyin key, not text.
        XCTAssertEqual(session.rawPhonetic, "ㄋㄧˇㄏㄠˇ")
    }

    func testBackspaceKeepsTheRunAndDigitsErase() {
        let session = make()
        type("`ab12", session)
        session.handle(KeyEvent(.backspace, text: "\u{7f}"))
        XCTAssertEqual(session.view.preedit, "ab1")
        type("2", session)
        XCTAssertEqual(session.view.preedit, "ab12")
    }

    func testGlobalEnglishModePassesDigitsThrough() {
        let session = make()
        session.engine.english = true
        for digit in "1234567890" {
            XCTAssertFalse(session.handle(KeyEvent(.character(String(digit)), text: String(digit))).consumed)
        }
    }

    /// The reported case: English started with a lone Shift tap mid-composition.
    func testDigitsAfterAShiftTapLatinRunAreDigits() {
        let session = make()
        type("su3", session)
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 100))
        XCTAssertTrue(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 100.1)).latinToggled)
        type("abc123", session)
        XCTAssertEqual(session.view.preedit, "你abc123")
        // A second tap closes the run; Zhuyin resumes.
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 101))
        XCTAssertTrue(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 101.1)).latinToggled)
        type("cl3", session)
        XCTAssertEqual(session.view.preedit, "你abc123好")
    }
}
