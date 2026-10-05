import XCTest
@testable import MisstypeCore

/// Replayable key traces through the platform-neutral session: the same
/// rules every adapter (IMK today, fcitx5/IBus later) inherits.
final class InputSessionTests: XCTestCase {
    private final class Host: InputSessionHost {
        var contextRequests = 0
        func surroundingContext() -> ClientContext {
            contextRequests += 1
            return ClientContext()
        }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    private var settings = SessionSettings()
    private var host = Host()

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

    private func key(_ key: KeyEvent.Key, _ modifiers: KeyEvent.Modifiers = [], text: String? = nil) -> KeyEvent {
        KeyEvent(key, modifiers: modifiers, text: text)
    }

    /// Plain typing on the physical keys: letters, digits, punctuation, space.
    @discardableResult
    private func type(_ keys: String, into session: InputSession) -> [KeyResult] {
        keys.map { char in
            let label = String(char)
            return session.handle(label == " " ? key(.space, text: " ") : key(.character(label), text: label))
        }
    }

    func testTypingConvertsLiveAndReturnCommitsThePreview() {
        let session = makeSession()
        XCTAssertTrue(type("su3cl3", into: session).allSatisfy { $0.consumed && $0.commit == nil })
        XCTAssertEqual(session.view.preedit, "你好")
        XCTAssertEqual(session.view.caret, 2)
        XCTAssertEqual(session.rawPhonetic, "ㄋㄧˇㄏㄠˇ")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult(consumed: true, commit: "你好"))
        XCTAssertEqual(session.view, SessionView.empty.with(selectionKeys: session.view.selectionKeys))
    }

    func testEmptyCompositionPassesKeysThrough() {
        let session = makeSession()
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult(consumed: false))
        XCTAssertEqual(session.handle(key(.backspace, text: "\u{7f}")), KeyResult(consumed: false))
        XCTAssertEqual(session.handle(key(.left, text: "\u{F702}")), KeyResult(consumed: false))
        // Space is inserted by the IME itself (never a tone without keys).
        XCTAssertEqual(session.handle(key(.space, text: " ")), KeyResult(consumed: true, commit: " "))
    }

    func testBackspaceEditsWithoutCommitting() {
        let session = makeSession()
        type("su3cl3", into: session)
        XCTAssertEqual(session.handle(key(.backspace, text: "\u{7f}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你")
        type("cl", into: session)
        XCTAssertEqual(session.handle(key(.backspace, [.command], text: "\u{7f}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "")
        XCTAssertEqual(session.rawPhonetic, "")
    }

    func testTabSelectsAndSelectionKeysPickThenLearn() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertFalse(session.view.keysActive)
        XCTAssertEqual(session.handle(key(.tab, text: "\t")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.selected, 1)
        XCTAssertTrue(session.view.keysActive)
        // Home-row "d" is slot 2 in selection mode (it types ㄎ elsewhere).
        XCTAssertEqual(session.handle(key(.character("d"), text: "d")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "尼")
        XCTAssertFalse(session.view.keysActive)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "尼")
        XCTAssertEqual(session.engine.userLexicon.count, 1)
    }

    func testPanelStaysClosedUntilSelectionWhenAutoShowIsOff() {
        settings.autoShowCandidates = false
        let session = makeSession()
        type("su3", into: session)
        XCTAssertFalse(session.view.showsCandidates)
        XCTAssertEqual(session.handle(key(.tab, text: "\t")), KeyResult(consumed: true))
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertTrue(session.view.keysActive)
        // Esc leaves selection and the panel closes again.
        session.handle(key(.escape, text: "\u{1b}"))
        XCTAssertFalse(session.view.showsCandidates)
    }

    func testArrowsAndSymbolMenuOpenThePanelWhenAutoShowIsOff() {
        settings.autoShowCandidates = false
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.down, text: "\u{F701}")), KeyResult(consumed: true))
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertEqual(session.view.selected, 1)
        session.handle(key(.escape, text: "\u{1b}"))
        XCTAssertEqual(session.handle(key(.up, text: "\u{F700}")), KeyResult(consumed: true))
        XCTAssertTrue(session.view.showsCandidates)
        session.handle(key(.escape, text: "\u{1b}"))
        session.handle(key(.escape, text: "\u{1b}"))
        type("su3", into: session)
        session.handle(key(.character(","), [.shift], text: "<"))
        XCTAssertFalse(session.view.showsCandidates)
        session.handle(key(.tab, text: "\t"))
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertTrue(session.view.keysActive)
    }

    func testArrowsStillOpenListAfterSpaceThenBackspace() {
        let session = makeSession()
        type("su3", into: session)
        let before = session.view.candidates
        session.handle(key(.space, text: " "))
        session.handle(key(.backspace, text: "\u{7f}"))
        XCTAssertEqual(session.view.candidates, before)
        XCTAssertEqual(session.handle(key(.down, text: "\u{F701}")), KeyResult(consumed: true))
        XCTAssertTrue(session.view.keysActive)
    }

    func testReturnConfirmsSelectionBeforeCommittingWhenEnabled() {
        settings.returnConfirmsSelection = true
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.tab, text: "\t"))
        XCTAssertEqual(session.view.preedit, "妳")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult(consumed: true))
        XCTAssertFalse(session.view.keysActive)
        XCTAssertEqual(session.view.preedit, "妳")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "妳")
        // Without a selection Return still commits at once (fresh session:
        // the pick above was learned).
        let plain = makeSession()
        type("su3", into: plain)
        XCTAssertEqual(plain.handle(key(.enter, text: "\r")).commit, "你")
        // Symbol menu: Return accepts the stepped mark, the next one commits.
        let menu = makeSession()
        type("su3", into: menu)
        menu.handle(key(.character(","), [.shift], text: "<"))
        menu.handle(key(.tab, text: "\t"))
        XCTAssertEqual(menu.handle(key(.enter, text: "\r")), KeyResult(consumed: true))
        XCTAssertEqual(menu.handle(key(.enter, text: "\r")).commit, "你、")
    }

    func testReturnCommitsAtOnceWhenConfirmIsOff() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.tab, text: "\t"))
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "妳")
    }

    func testSelectionKeyPicksFromSecondPageInASentence() {
        // Homophones past the decoder's per-node cap (page 2 of the picker)
        // must still win once picked; they used to be pinned but unreachable.
        var rows = ""
        for (i, c) in "你妳尼泥擬逆匿膩溺暱".enumerated() { rows += "ㄋㄧˇ\t\(c)\t-\(5 + i)\n" }
        rows += "ㄏㄠˇ\t好\t-5\n"
        let engine = InputEngine(decoder: LexiconDecoder(tsv: rows), settings: { [unowned self] in self.settings })
        let session = InputSession(engine: engine)
        session.host = host
        type("su3cl3", into: session)
        _ = session.handle(key(.left)); _ = session.handle(key(.left))
        for _ in 0..<8 { _ = session.handle(key(.down)) }
        XCTAssertEqual(session.view.selected, 8)
        XCTAssertEqual(session.handle(key(.character("a"), text: "a")).consumed, true)
        XCTAssertEqual(session.view.preedit, "溺好")
    }

    /// 10 homophones of ㄋㄧˇ: two pages (8 + 2) in the focused list.
    private func homophoneSession() -> InputSession {
        var rows = ""
        for (i, c) in "你妳尼泥擬逆匿膩溺暱".enumerated() { rows += "ㄋㄧˇ\t\(c)\t-\(5 + i)\n" }
        let engine = InputEngine(decoder: LexiconDecoder(tsv: rows), settings: { [unowned self] in self.settings })
        let session = InputSession(engine: engine)
        session.host = host
        type("su3", into: session)
        return session
    }

    func testPageKeysFlipPagesKeepingTheRow() {
        let session = homophoneSession()
        XCTAssertEqual(session.handle(key(.pageDown)), KeyResult(consumed: true))
        XCTAssertEqual(session.view.selected, 8)
        XCTAssertTrue(session.view.keysActive)
        _ = session.handle(key(.pageDown)) // wraps to page 1, row 0
        XCTAssertEqual(session.view.selected, 0)
        XCTAssertEqual(session.view.candidates.count, 11) // 10 homophones + the raw fallback
        for _ in 0..<5 { _ = session.handle(key(.down)) } // row 5
        _ = session.handle(key(.pageDown)) // page 2 has 3 rows: clamp to last
        XCTAssertEqual(session.view.selected, 10)
        _ = session.handle(key(.pageUp))
        XCTAssertEqual(session.view.selected, 2)
    }

    func testMinusEqualsPageOnlyInSelectionMode() {
        let session = homophoneSession()
        // Not selecting: `-` is ㄦ and types.
        _ = session.handle(key(.character("-"), text: "-"))
        XCTAssertFalse(session.view.keysActive)
        XCTAssertTrue(session.view.preedit.hasSuffix("ㄦ"))
        _ = session.handle(key(.backspace))
        _ = session.handle(key(.down))
        _ = session.handle(key(.character("="), text: "="))
        XCTAssertEqual(session.view.selected, 9)
        _ = session.handle(key(.character("-"), text: "-"))
        XCTAssertEqual(session.view.selected, 1)
    }

    func testPageSizeSetsRowsSelectionKeysAndPaging() {
        settings.pageSize = 5
        let session = homophoneSession()
        _ = session.handle(key(.down)) // row 1
        XCTAssertEqual(session.view.pageSize, 5)
        XCTAssertEqual(session.view.selectionKeys, ["a", "s", "d", "f", "g"])
        _ = session.handle(key(.pageDown))
        XCTAssertEqual(session.view.selected, 6)
        // Selection keys address the visible page of 5: `d` is row 3 → 7.
        _ = session.handle(key(.character("d"), text: "d"))
        XCTAssertEqual(session.view.selected, 7)
        XCTAssertFalse(session.view.keysActive)
        XCTAssertEqual(session.view.preedit, session.view.candidates[7])
        // Out-of-range sizes clamp.
        settings.pageSize = 99
        XCTAssertEqual(settings.pageSize, SelectionKeys.pageSizes.upperBound)
    }

    func testPageKeysPreferenceRebindsPaging() {
        settings.pageKeys = .commaPeriod
        let session = homophoneSession()
        _ = session.handle(key(.down))
        _ = session.handle(key(.character("."), text: "."))
        XCTAssertEqual(session.view.selected, 9)
        _ = session.handle(key(.character(","), text: ","))
        XCTAssertEqual(session.view.selected, 1)
        // `-` no longer pages: it leaves selection and types ㄦ.
        _ = session.handle(key(.character("-"), text: "-"))
        XCTAssertFalse(session.view.keysActive)
        XCTAssertTrue(session.view.preedit.hasSuffix("ㄦ"))
    }

    func testSelectionKeyWinsOverPageKey() {
        settings.candidateKeys = "asdfghj-"
        let session = homophoneSession()
        _ = session.handle(key(.down))
        _ = session.handle(key(.character("-"), text: "-")) // slot 7, not previous page
        XCTAssertEqual(session.view.selected, 7)
        XCTAssertFalse(session.view.keysActive)
    }

    func testPageKeyBeepsWhenOnePage() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.pageDown)), KeyResult(consumed: true, beep: true))
        XCTAssertEqual(session.handle(key(.pageDown)).commit, nil)
    }

    func testPageKeyPassesThroughWithoutComposition() {
        let session = makeSession()
        XCTAssertEqual(session.handle(key(.pageDown)), KeyResult(consumed: false))
    }

    func testEscapeLeavesSelectionFirstThenClears() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.down, text: "\u{F701}"))
        XCTAssertEqual(session.view.preedit, "妳")
        XCTAssertEqual(session.handle(key(.escape, text: "\u{1b}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "妳")
        XCTAssertFalse(session.view.keysActive)
        XCTAssertEqual(session.handle(key(.escape, text: "\u{1b}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "")
    }

    func testPunctuationAndShiftLatinStayInsideTheComposition() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.character(","), [.shift], text: "<")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你，")
        XCTAssertEqual(session.handle(key(.character("a"), [.shift], text: "A")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你，A")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "你，A")
    }

    func testBacktickLatinRun() {
        let session = makeSession()
        type("su3`hi", into: session)
        XCTAssertEqual(session.view.preedit, "你hi")
        // Letters and digits stay latin (a tone key is just a digit here;
        // the run used to end on it, which turned "mp3" into Zhuyin). The
        // closing backtick returns to Zhuyin.
        XCTAssertEqual(session.handle(key(.character("3"), text: "3")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你hi3")
        type("`cl3", into: session)
        XCTAssertEqual(session.view.preedit, "你hi3好")
    }

    func testPeriodsInsideLatinRunStayLiteral() {
        let session = makeSession()
        // `.` is ㄡ in Zhuyin but plain text inside a latin run ("..." used to
        // become 歐歐歐).
        type("su3`hi...", into: session)
        XCTAssertEqual(session.view.preedit, "你hi...")
    }

    func testBackspaceInsideLatinRunKeepsTheRun() {
        let session = makeSession()
        type("su3`hx", into: session)
        XCTAssertEqual(session.handle(key(.backspace, text: "\u{7f}")), KeyResult(consumed: true))
        type("i", into: session)
        XCTAssertEqual(session.view.preedit, "你hi")
        // Deleting the whole word keeps the run open for retyping.
        session.handle(key(.backspace, text: "\u{7f}"))
        session.handle(key(.backspace, text: "\u{7f}"))
        type("yo", into: session)
        XCTAssertEqual(session.view.preedit, "你yo")
        // Ended by punctuation, then edited back into the word: the run resumes.
        session.handle(key(.character(","), [.shift], text: "<"))
        XCTAssertEqual(session.view.preedit, "你yo，")
        session.handle(key(.backspace, text: "\u{7f}"))
        type("u", into: session)
        XCTAssertEqual(session.view.preedit, "你you")
    }

    func testBackspaceAfterFusedTonelessRunDeletesOneSyllable() {
        let session = makeSession()
        // Toneless continuous typing, then one first-tone Space: the raw keys
        // are a single fused body (ㄋㄧㄏㄠ + Space) but the user typed two
        // syllables, so one Backspace must not drop both.
        type("sucl ", into: session)
        XCTAssertEqual(session.view.preedit, "你好")
        session.handle(key(.backspace, text: "\u{7f}"))
        XCTAssertEqual(session.rawPhonetic, "ㄋㄧ")
    }

    func testLongCompositionCommitsSettledHeadInChunks() {
        settings.autoCommitSyllables = 6
        let session = makeSession()
        var committed = ""
        var chunks = 0
        for _ in 0..<20 {
            for result in type("su3", into: session) {
                XCTAssertTrue(result.consumed)
                if let text = result.commit { committed += text; chunks += 1 }
            }
            // The composition stays bounded and keeps its look-ahead tail.
            XCTAssertLessThanOrEqual(session.rawPhonetic.count, 6 * 3)
        }
        XCTAssertGreaterThan(chunks, 1, "one chunk per overflow, not one big commit")
        XCTAssertFalse(committed.isEmpty)
        XCTAssertGreaterThanOrEqual(session.view.preedit.count, 3)
        // Chunks plus the final Return reproduce everything that was typed.
        let rest = session.handle(key(.enter, text: "\r")).commit ?? ""
        XCTAssertEqual(committed + rest, String(repeating: "你", count: 20))
    }

    func testAutoCommitOffKeepsEverythingInTheComposition() {
        settings.autoCommitSyllables = 0
        let session = makeSession()
        for _ in 0..<10 {
            XCTAssertTrue(type("su3", into: session).allSatisfy { $0.commit == nil })
        }
        XCTAssertEqual(session.view.preedit, String(repeating: "你", count: 10))
    }

    func testSmartQuotesOpenThenCloseAndNestWithShift() {
        let session = makeSession()
        session.handle(key(.character("'"), text: "'"))
        type("su3cl3", into: session)
        XCTAssertEqual(session.view.preedit, "「你好")
        session.handle(key(.character("'"), text: "'"))
        XCTAssertEqual(session.view.preedit, "「你好」")
        // Balanced again, so the next one opens; Shift pairs 『』 on its own.
        session.handle(key(.character("'"), [.shift], text: "\""))
        session.handle(key(.character("'"), [.shift], text: "\""))
        XCTAssertEqual(session.view.preedit, "「你好」『』")
        // The direct bracket keys keep working.
        session.handle(key(.character("["), text: "["))
        XCTAssertEqual(session.view.preedit, "「你好」『』『")
    }

    func testSymbolMenuStepsPicksAndAcceptsOnAnyOtherKey() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.character(","), [.shift], text: "<"))
        XCTAssertEqual(session.view.preedit, "你，")
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertEqual(Array(session.view.candidates.prefix(3)), ["，", "、", "；"])
        XCTAssertFalse(session.view.keysActive)
        // Letters are still Zhuyin until stepping starts.
        // Tab swaps the mark live and arms the selection keys.
        session.handle(key(.tab, text: "\t"))
        XCTAssertEqual(session.view.preedit, "你、")
        XCTAssertTrue(session.view.keysActive)
        // Selection key `d` = slot 2 on the page: 「；」.
        XCTAssertEqual(session.handle(key(.character("d"), text: "d")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你；")
        XCTAssertFalse(session.view.showsCandidates)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "你；")
    }

    func testSymbolMenuAnyOtherKeyAcceptsEscKeepsAndClickPicks() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.character("."), [.shift], text: ">"))
        XCTAssertEqual(session.view.preedit, "你。")
        // Typing on accepts the mark and composes normally.
        type("cl3", into: session)
        XCTAssertEqual(session.view.preedit, "你。好")
        XCTAssertFalse(session.view.candidates.contains("．"))
        // Esc closes the menu but keeps the composition; a second one clears.
        session.handle(key(.character("1"), [.shift], text: "!"))
        XCTAssertTrue(session.view.candidates.contains("‼"))
        XCTAssertEqual(session.handle(key(.escape, text: "\u{1b}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你。好！")
        XCTAssertFalse(session.view.candidates.contains("‼"))
        // Panel click picks a row.
        session.handle(key(.character("/"), [.shift], text: "?"))
        session.pick(at: 1)
        XCTAssertEqual(session.view.preedit, "你。好！⁇")
        XCTAssertFalse(session.view.showsCandidates)
    }

    func testSyllableCursorFocusesAWord() {
        let session = makeSession()
        type("su3cl3", into: session)
        XCTAssertEqual(session.handle(key(.right, text: "\u{F703}")), KeyResult(consumed: true, beep: true))
        XCTAssertEqual(session.handle(key(.left, text: "\u{F702}")), KeyResult(consumed: true))
        XCTAssertTrue(session.view.keysActive)
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertEqual(session.view.candidates.first, "你好")
        XCTAssertEqual(session.view.caret, 1)
        XCTAssertEqual(session.handle(key(.right, text: "\u{F703}")), KeyResult(consumed: true))
        XCTAssertEqual(session.view.caret, 2)
    }

    func testCursorBeforeTheCaretListsWordsEndingThere() {
        settings.cursorCandidates = .endingAt
        let session = makeSession()
        type("su3cl3", into: session)
        // First Left: caret stays after 好, the words ending there are listed.
        _ = session.handle(key(.left, text: "\u{F702}"))
        XCTAssertEqual(session.view.candidates, ["你好", "好"])
        XCTAssertEqual(session.view.selected, 0)
        XCTAssertEqual(session.view.caret, 2)
        // Second Left: words ending after 你; 你好 does not, so 你 is highlighted.
        _ = session.handle(key(.left, text: "\u{F702}"))
        XCTAssertEqual(session.view.candidates, ["你", "妳", "尼", "泥"])
        XCTAssertEqual(session.view.caret, 1)
        _ = session.handle(key(.character("d"), text: "d")) // row 3: 尼
        XCTAssertEqual(session.view.preedit, "尼好")
    }

    func testCursorAfterTheCaretListsWordsStartingThere() {
        settings.cursorCandidates = .beginningAt
        let session = makeSession()
        type("su3cl3", into: session)
        _ = session.handle(key(.left, text: "\u{F702}"))
        XCTAssertEqual(session.view.candidates, ["好"])
        XCTAssertEqual(session.view.caret, 1)
        _ = session.handle(key(.left, text: "\u{F702}"))
        XCTAssertEqual(session.view.candidates.first, "你好")
        XCTAssertFalse(session.view.candidates.contains("好"))
        XCTAssertEqual(session.view.caret, 0)
    }

    func testChordsAndCapsLockCommitThenPassThrough() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.character("c"), [.command], text: "c")),
                       KeyResult(consumed: false, commit: "你"))
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.character("a"), [.capsLock], text: "A")),
                       KeyResult(consumed: false, commit: "你"))
        // A bare modifier press is swallowed and leaves the composition alone.
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.modifier, [.control])), KeyResult(consumed: true))
        XCTAssertEqual(session.view.preedit, "你")
    }

    func testShiftSpaceTogglesEnglishCommittingFirst() {
        let session = makeSession()
        type("su3", into: session)
        XCTAssertEqual(session.handle(key(.space, [.shift], text: " ")),
                       KeyResult(consumed: true, commit: "你", modeChanged: true))
        XCTAssertTrue(session.engine.english)
        XCTAssertEqual(session.handle(key(.character("s"), text: "s")), KeyResult(consumed: false))
        session.handle(key(.space, [.shift], text: " "))
        XCTAssertFalse(session.engine.english)
    }

    func testLoneShiftTapTogglesUnlessDisabled() {
        let session = makeSession()
        let press = KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 100)
        let release = KeyEvent(.shift(.left), phase: .release, modifiers: [], timestamp: 100.1)
        XCTAssertEqual(session.handle(press), KeyResult(consumed: true))
        XCTAssertEqual(session.handle(release), KeyResult(consumed: true, modeChanged: true))
        XCTAssertTrue(session.engine.english)
        // Shift+letter in between is a capital, not a tap.
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 101))
        session.handle(KeyEvent(.character("a"), modifiers: [.shift], text: "A", timestamp: 101.05))
        XCTAssertFalse(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 101.1)).modeChanged)
        settings.shiftToggle = false
        session.handle(KeyEvent(.shift(.right), phase: .press, modifiers: [.shift], timestamp: 102))
        XCTAssertFalse(session.handle(KeyEvent(.shift(.right), phase: .release, timestamp: 102.1)).modeChanged)
    }

    func testShiftToggleSideLimitsWhichShiftTaps() {
        settings.shiftToggleSide = .right
        let session = makeSession()
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 100))
        XCTAssertFalse(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 100.1)).modeChanged)
        XCTAssertFalse(session.engine.english)
        session.handle(KeyEvent(.shift(.right), phase: .press, modifiers: [.shift], timestamp: 101))
        XCTAssertTrue(session.handle(KeyEvent(.shift(.right), phase: .release, timestamp: 101.1)).modeChanged)
        XCTAssertTrue(session.engine.english)
    }

    func testShiftSpaceToggleCanBeTurnedOff() {
        settings.shiftSpaceToggle = false
        let session = makeSession()
        type("su3", into: session)
        let result = session.handle(key(.space, [.shift], text: " "))
        XCTAssertFalse(result.modeChanged)
        XCTAssertNil(result.commit)
        XCTAssertFalse(session.engine.english)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "你")
    }

    func testLoneShiftTapMidCompositionOpensLatinRunWithoutCommitting() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 100))
        // No commit, no global mode flip.
        XCTAssertEqual(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 100.1)),
                       KeyResult(consumed: true, latinToggled: true))
        XCTAssertTrue(session.latinActive)
        XCTAssertFalse(session.engine.english)
        type("hi", into: session)
        XCTAssertEqual(session.view.preedit, "你hi")
        // A second tap closes the run: letters are Zhuyin again.
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 101))
        XCTAssertTrue(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 101.1)).latinToggled)
        XCTAssertFalse(session.latinActive)
        type("cl3", into: session)
        XCTAssertEqual(session.view.preedit, "你hi好")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "你hi好")
        // With nothing composed the tap still flips 中/英.
        session.handle(KeyEvent(.shift(.left), phase: .press, modifiers: [.shift], timestamp: 102))
        XCTAssertTrue(session.handle(KeyEvent(.shift(.left), phase: .release, timestamp: 102.1)).modeChanged)
    }

    func testPanelPickAndHostCommit() {
        let session = makeSession()
        type("su3", into: session)
        session.pick(at: 3)
        XCTAssertEqual(session.view.preedit, "泥")
        XCTAssertEqual(session.commit(), "泥")
        XCTAssertNil(session.commit())
    }

    func testOfflineTypingNeverAsksTheHostForSurroundingText() {
        let session = makeSession()
        type("su3cl3a87", into: session)
        session.handle(key(.enter, text: "\r"))
        XCTAssertEqual(host.contextRequests, 0)
        // Enabled without a key is still offline (JevConfig.canAttempt).
        settings.jev = JevConfig(enabled: true)
        type("su3", into: session)
        XCTAssertEqual(host.contextRequests, 0)
    }
}

private extension SessionView {
    func with(selectionKeys: [String]) -> SessionView {
        var copy = self
        copy.selectionKeys = selectionKeys
        return copy
    }
}
