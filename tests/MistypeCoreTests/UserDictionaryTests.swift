import XCTest
@testable import MistypeCore

/// The user dictionary: file format, decoder overlay (new paths, exclusions,
/// exact restore), and the Shift+arrow marking gesture that fills it.
final class UserDictionaryTests: XCTestCase {
    private static let lexicon = """
    ㄋㄧˇ\t你\t-5
    ㄋㄧˇ\t妳\t-6
    ㄏㄠˇ\t好\t-5
    ㄇㄚ˙\t嗎\t-4
    ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
    ㄉㄚˇ\t打\t-6
    ㄉㄨㄟˋ\t對\t-6
    ㄉㄚˋ\t大\t-5
    ㄉㄚˇ-ㄉㄨㄟˋ\t打對\t-7
    """

    fileprivate final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }
    private let host = Host()
    private var tempURL: URL!

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mistype-\(UUID().uuidString)/user_dictionary.tsv")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    private func makeSession(url: URL? = nil) -> InputSession {
        let engine = InputEngine(decoder: LexiconDecoder(tsv: Self.lexicon), userDictionaryURL: url ?? tempURL,
                                 settings: { SessionSettings() })
        let session = InputSession(engine: engine)
        session.host = host
        return session
    }

    private func key(_ key: KeyEvent.Key, _ modifiers: KeyEvent.Modifiers = [], text: String? = nil) -> KeyEvent {
        KeyEvent(key, modifiers: modifiers, text: text)
    }

    @discardableResult
    private func type(_ keys: String, into session: InputSession) -> [KeyResult] {
        keys.map { char in
            let label = String(char)
            return session.handle(label == " " ? key(.space, text: " ") : key(.character(label), text: label))
        }
    }

    private func shift(_ arrow: KeyEvent.Key, _ session: InputSession, times: Int = 1) {
        for _ in 0..<times { XCTAssertTrue(session.handle(key(arrow, .shift)).consumed) }
    }

    // MARK: File format

    func testParseSerializeRoundTripKeepsAdditionsWeightsAndExclusions() {
        let source = """
        # comment
        ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\t黃昱愷
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-1.5

        !ㄉㄚˇ-ㄉㄨㄟˋ\t打對
        """
        let (dictionary, problems) = UserDictionary.parse(source)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(dictionary.added.map(\.text), ["黃昱愷", "你好"])
        XCTAssertEqual(dictionary.added[1].weight, -1.5)
        XCTAssertTrue(dictionary.isExcluded(reading: "ㄉㄚˇ-ㄉㄨㄟˋ", text: "打對"))
        XCTAssertEqual(UserDictionary.parse(dictionary.serialized()).dictionary, dictionary)
    }

    func testBadLinesAreReportedAndSkippedNeverFatal() {
        let (dictionary, problems) = UserDictionary.parse("""
        ㄋㄧˇ-ㄏㄠˇ\t你好
        ㄋㄧˇ-ㄏㄠˇ\t你
        hello\tworld
        ㄋㄧˇ\t你\t3
        no tab here
        ㄇㄚ˙\t嗎
        """)
        XCTAssertEqual(dictionary.added.map(\.text), ["你好", "嗎"])
        XCTAssertEqual(problems.map(\.line), [2, 3, 4, 5])
    }

    func testAddingLiftsAnExclusionAndExcludingDropsTheAddition() {
        var dictionary = UserDictionary()
        dictionary.exclude(reading: "ㄋㄧˇ-ㄏㄠˇ", text: "你好")
        dictionary.add(reading: "ㄋㄧˇ-ㄏㄠˇ", text: "你好")
        XCTAssertTrue(dictionary.excluded.isEmpty)
        dictionary.exclude(reading: "ㄋㄧˇ-ㄏㄠˇ", text: "你好")
        XCTAssertTrue(dictionary.added.isEmpty)
        XCTAssertFalse(dictionary.add(reading: "ㄋㄧˇ", text: "你好"), "rejects a length mismatch")
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(UserDictionary.load(from: tempURL).isEmpty)
    }

    // MARK: Decoder overlay

    func testAddedWordCreatesAPathTheLexiconNeverHad() {
        let decoder = LexiconDecoder(tsv: Self.lexicon)
        let syllables = [Syllable(keys: ["s", "u"], tone: "ˇ"), Syllable(keys: ["c", "l"], tone: "ˇ"),
                         Syllable(keys: ["a", "8"], tone: "˙")]
        XCTAssertEqual(decoder.decode(syllables).first?.alignment.count, 2, "你好 + 嗎")
        var dictionary = UserDictionary()
        dictionary.add(reading: "ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙", text: "你好嗎")
        decoder.applyUserDictionary(dictionary)
        let top = decoder.decode(syllables).first
        XCTAssertEqual(top?.text, "你好嗎")
        XCTAssertEqual(top?.alignment.map(\.syllables), [0..<3], "one word, not three chars")
    }

    func testExclusionHidesABuiltInWordAndClearingRestoresItExactly() {
        let decoder = LexiconDecoder(tsv: Self.lexicon)
        let syllables = [Syllable(keys: ["2", "8"], tone: "ˇ"), Syllable(keys: ["2", "j", "o"], tone: "ˋ")]
        let before = decoder.decode(syllables)
        XCTAssertEqual(before.first?.text, "打對")
        var dictionary = UserDictionary()
        dictionary.exclude(reading: "ㄉㄚˇ-ㄉㄨㄟˋ", text: "打對")
        decoder.applyUserDictionary(dictionary)
        XCTAssertEqual(decoder.decode(syllables).first?.alignment.count, 2, "打 + 對, no longer the word")
        decoder.applyUserDictionary(nil)
        XCTAssertEqual(decoder.decode(syllables), before)
    }

    func testReadingsLookupFollowsTheTypedTones() {
        let decoder = LexiconDecoder(tsv: Self.lexicon)
        let toneless = [Syllable(keys: ["s", "u"], tone: nil), Syllable(keys: ["c", "l"], tone: nil)]
        XCTAssertEqual(decoder.readings(of: "你好", syllables: toneless, span: 0..<2), "ㄋㄧˇ-ㄏㄠˇ")
        XCTAssertNil(decoder.readings(of: "您好", syllables: toneless, span: 0..<2))
    }

    // MARK: Marking

    func testShiftArrowsMarkTheTrailingSyllablesAndReportTheAction() {
        let session = makeSession()
        type("su3cl3a87", into: session) // 你好嗎
        XCTAssertNil(session.view.mark)
        shift(.left, session, times: 2)
        var mark = try! XCTUnwrap(session.view.mark)
        XCTAssertEqual(mark.range, 1..<3)
        XCTAssertEqual(mark.text, "好嗎")
        XCTAssertEqual(mark.reading, "ㄏㄠˇ-ㄇㄚ˙")
        XCTAssertEqual(mark.action, .add)
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertTrue(session.view.candidates.isEmpty)
        shift(.left, session)
        mark = try! XCTUnwrap(session.view.mark)
        XCTAssertEqual(mark.range, 0..<3)
        shift(.right, session, times: 2)
        XCTAssertEqual(session.view.mark?.range, 2..<3)
        XCTAssertEqual(session.view.mark?.action, .tooShort)
        shift(.right, session)
        XCTAssertNil(session.view.mark, "collapsed back onto the anchor")
    }

    func testReturnFilesThePhraseWithoutCommittingAndTheDecodeUsesIt() throws {
        let session = makeSession()
        type("su3cl3a87", into: session)
        shift(.left, session, times: 3)
        XCTAssertEqual(session.view.mark?.text, "你好嗎")
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult(consumed: true))
        XCTAssertNil(session.view.mark)
        XCTAssertEqual(session.view.preedit, "你好嗎", "still composing, nothing committed")
        XCTAssertTrue(session.engine.userDictionary.contains(reading: "ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙", text: "你好嗎"))
        let saved = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙\t你好嗎"))
        // Marking the same span again offers removal, and Return undoes it.
        shift(.left, session, times: 3)
        XCTAssertEqual(session.view.mark?.action, .remove)
        session.handle(key(.enter, text: "\r"))
        XCTAssertTrue(session.engine.userDictionary.isEmpty)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")).commit, "你好嗎")
    }

    func testMarkStartsAtTheCursorAndExtendsBothWays() {
        let session = makeSession()
        type("su3cl3a87", into: session)
        XCTAssertTrue(session.handle(key(.left)).consumed) // cursor on 嗎
        XCTAssertTrue(session.handle(key(.left)).consumed) // cursor on 好
        shift(.right, session) // 好 → mark 好嗎 starting at the cursor
        XCTAssertEqual(session.view.mark?.range, 1..<2)
        shift(.right, session)
        XCTAssertEqual(session.view.mark?.text, "好嗎")
        shift(.left, session, times: 3)
        XCTAssertEqual(session.view.mark?.text, "你")
        XCTAssertEqual(session.view.mark?.action, .tooShort)
    }

    func testEscapeDropsTheMarkKeepsTheCompositionAndOtherKeysAbandonIt() {
        let session = makeSession()
        type("su3cl3", into: session)
        shift(.left, session, times: 2)
        XCTAssertEqual(session.handle(key(.escape)), KeyResult(consumed: true))
        XCTAssertNil(session.view.mark)
        XCTAssertEqual(session.view.preedit, "你好")
        shift(.left, session, times: 2)
        type("a87", into: session)
        XCTAssertNil(session.view.mark)
        XCTAssertEqual(session.view.preedit, "你好嗎")
        XCTAssertTrue(session.engine.userDictionary.isEmpty)
    }

    func testReturnOnAnUnusableMarkBeepsAndLeavesTheDictionaryAlone() {
        let session = makeSession()
        type("su3cl3", into: session)
        shift(.left, session)
        XCTAssertEqual(session.view.mark?.action, .tooShort)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult.beeped)
        XCTAssertTrue(session.engine.userDictionary.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testMarkCannotSpanPunctuation() {
        let session = makeSession()
        type("su3", into: session)
        session.handle(key(.character(","), .shift, text: "，"))
        type("cl3", into: session)
        shift(.left, session, times: 2)
        XCTAssertEqual(session.view.mark?.action, .unavailable)
        XCTAssertEqual(session.handle(key(.enter, text: "\r")), KeyResult.beeped)
        XCTAssertTrue(session.engine.userDictionary.isEmpty)
    }

    func testEditsMadeOutsideTheProcessLoadWhenTheNextCompositionStarts() throws {
        let session = makeSession()
        type("su3cl3a87", into: session)
        XCTAssertEqual(session.view.preedit, "你好嗎")
        session.handle(key(.escape)); session.handle(key(.escape))
        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙\t你好嗎\t0\n".write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: tempURL.path)
        type("su3cl3a87", into: session)
        XCTAssertEqual(session.engine.userDictionary.added.map(\.text), ["你好嗎"])
        XCTAssertEqual(session.view.preedit, "你好嗎")
    }
}

extension UserDictionaryTests {
    /// docs/cross-platform.md C13, on the shared conformance lexicon.
    func testConformanceC13MarkAndFileAPhrase() {
        let session = makeConformanceSession()
        for label in ["s", "u", "3", "c", "l", "3"] { session.handle(KeyEvent(.character(label), text: label)) }
        for _ in 0..<2 { XCTAssertTrue(session.handle(KeyEvent(.left, modifiers: .shift)).consumed) }
        let mark = session.view.mark
        XCTAssertEqual(mark, SessionView.Mark(range: 0..<2, text: "你好", reading: "ㄋㄧˇ-ㄏㄠˇ", action: .add))
        XCTAssertTrue(session.view.candidates.isEmpty)
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertEqual(session.handle(KeyEvent(.enter, text: "\r")), KeyResult(consumed: true))
        XCTAssertNil(session.view.mark)
        XCTAssertEqual(session.view.preedit, "你好")
        XCTAssertTrue(session.engine.userDictionary.contains(reading: "ㄋㄧˇ-ㄏㄠˇ", text: "你好"))
    }

    private func makeConformanceSession() -> InputSession {
        let decoder = LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄋㄧˇ\t妳\t-6
        ㄋㄧˇ\t尼\t-7
        ㄋㄧˇ\t泥\t-8
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄇㄚ˙\t嗎\t-4
        """)
        let engine = InputEngine(decoder: decoder, settings: { SessionSettings() })
        let session = InputSession(engine: engine)
        session.host = Host()
        return session
    }
}

/// Inline candidate list (no window): what a host appends after the preedit.
final class InlineListTests: XCTestCase {
    private func view(_ candidates: [String], selected: Int = 0, keysActive: Bool = true,
                      listOpen: Bool = true) -> SessionView {
        SessionView(preedit: candidates[selected], caret: 0, candidates: candidates, selected: selected,
                    selectionKeys: ["a", "s", "d", "f", "g", "h", "j", "k"], keysActive: keysActive,
                    showsCandidates: true, listOpen: listOpen)
    }

    func testListsRowsWithKeysAndReportsTheHighlightRange() throws {
        let list = try XCTUnwrap(view(["你好嗎", "妳好嗎", "尼好嗎"], selected: 1).inlineList())
        XCTAssertEqual(list.text, "  ‹a 你好…  s 妳好…  d 尼好…›")
        let units = Array(list.text.utf16)
        XCTAssertEqual(String(decoding: units[list.selected], as: UTF16.self), "s 妳好…")
    }

    func testNoKeyLabelsUntilTheyPickAndNothingUntilTheListIsOpen() throws {
        XCTAssertEqual(try XCTUnwrap(view(["你", "妳"], keysActive: false).inlineList()).text, "  ‹你  妳›")
        XCTAssertNil(view(["你", "妳"], listOpen: false).inlineList())
    }

    func testLaterPagesShowTheirPageAndHighlightWithinIt() throws {
        let rows = (0..<12).map { "字\($0)" }
        let list = try XCTUnwrap(view(rows, selected: 9).inlineList())
        XCTAssertTrue(list.text.hasSuffix("› 2/2"), list.text)
        let units = Array(list.text.utf16)
        XCTAssertEqual(String(decoding: units[list.selected], as: UTF16.self), "s 字9")
    }

    func testSessionOpensTheListOnTabOnly() {
        let engine = InputEngine(decoder: LexiconDecoder(tsv: "ㄋㄧˇ\t你\t-5\nㄋㄧˇ\t妳\t-6"),
                                 settings: { SessionSettings() })
        let session = InputSession(engine: engine)
        for key in ["s", "u", "3"] { session.handle(KeyEvent(.character(key), text: key)) }
        XCTAssertTrue(session.view.showsCandidates)
        XCTAssertNil(session.view.inlineList(), "typing alone does not open the list")
        session.handle(KeyEvent(.tab, text: "\t"))
        XCTAssertEqual(session.view.inlineList()?.text, "  ‹a 你  s 妳  d ㄋㄧˇ›")
    }
}
