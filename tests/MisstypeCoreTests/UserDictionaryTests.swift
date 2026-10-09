import XCTest
@testable import MisstypeCore

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

    private var tempURL: URL!

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("misstype-\(UUID().uuidString)/user_dictionary.tsv")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    private func makeSession(url: URL? = nil) -> InputSession {
        let engine = InputEngine(decoder: LexiconDecoder(tsv: Self.lexicon), userDictionaryURL: url ?? tempURL,
                                 settings: { SessionSettings() })
        let session = InputSession(engine: engine)
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
        黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ
        你好 ㄋㄧˇ-ㄏㄠˇ -1.5

        !打對 ㄉㄚˇ-ㄉㄨㄟˋ
        """
        let (dictionary, problems) = UserDictionary.parse(source)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(dictionary.added.map(\.text), ["黃昱愷", "你好"])
        XCTAssertEqual(dictionary.added[1].weight, -1.5)
        XCTAssertTrue(dictionary.isExcluded(reading: "ㄉㄚˇ-ㄉㄨㄟˋ", text: "打對"))
        XCTAssertEqual(UserDictionary.parse(dictionary.serialized()).dictionary, dictionary)
        XCTAssertTrue(dictionary.serialized().contains("\n黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\n"), "vChewing order, space separated")
    }

    /// Output of vChewing-userdata-generator: used to be rejected line by line.
    func testReadsVChewingUserdataAsIs() {
        let (dictionary, problems) = UserDictionary.parse("""
        # 我的語彙
        免費試聽 ㄇㄧㄢˇ-ㄈㄟˋ-ㄕˋ-ㄊㄧㄥ
        談什麼原則\tㄊㄢˊ-ㄕㄜˊ-ㄇㄛ˙-ㄩㄢˊ-ㄗㄜˊ\t-3.5
        斷訊  ㄉㄨㄢˋ-ㄒㄩㄣˋ
        """)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(dictionary.added.map(\.text), ["免費試聽", "談什麼原則", "斷訊"])
        XCTAssertEqual(dictionary.added[1].weight, -3.5)
        XCTAssertTrue(dictionary.contains(reading: "ㄉㄨㄢˋ-ㄒㄩㄣˋ", text: "斷訊"))
    }

    /// First 20 lines of vChewing-userdata-generator's idiom output (MOE 成語典
    /// headwords, no personal text): a real file, not a hand-written one.
    func testReadsRealGeneratorOutputFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/vchewing-userdata-idioms.txt")
        let (dictionary, problems) = UserDictionary.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(dictionary.added.count, 20)
        XCTAssertTrue(dictionary.contains(reading: "ㄧˋ-ㄇㄠˊ-ㄅㄨˋ-ㄅㄚˊ", text: "一毛不拔"))
        XCTAssertTrue(dictionary.contains(reading: "ㄏㄨˊ-ㄌㄨㄣˊ-ㄊㄨㄣ-ㄗㄠˇ", text: "囫圇吞棗"))
    }

    func testImportAppendsOnlyNewEntriesAndKeepsExistingText() {
        let existing = "# mine\n你好 ㄋㄧˇ-ㄏㄠˇ"
        let result = UserDictionary.importing("""
        你好 ㄋㄧˇ-ㄏㄠˇ
        斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ
        壞掉
        !打對 ㄉㄚˇ-ㄉㄨㄟˋ
        """, into: existing)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.problems.map(\.line), [3])
        XCTAssertEqual(result.text, "# mine\n你好 ㄋㄧˇ-ㄏㄠˇ\n斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ\n!打對 ㄉㄚˇ-ㄉㄨㄟˋ\n")
        XCTAssertEqual(UserDictionary.importing("斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ", into: result.text).added, 0, "idempotent")
    }

    /// Files written before the format switched (reading<TAB>text) still load
    /// and come back out in the new order.
    func testLegacyReadingFirstLinesStillLoadAndRewriteInNewOrder() {
        let (dictionary, problems) = UserDictionary.parse("ㄋㄧˇ-ㄏㄠˇ\t你好\t-2\n!ㄉㄚˇ-ㄉㄨㄟˋ\t打對\n")
        XCTAssertEqual(problems, [])
        XCTAssertTrue(dictionary.contains(reading: "ㄋㄧˇ-ㄏㄠˇ", text: "你好"))
        XCTAssertTrue(dictionary.isExcluded(reading: "ㄉㄚˇ-ㄉㄨㄟˋ", text: "打對"))
        XCTAssertTrue(dictionary.serialized().contains("你好 ㄋㄧˇ-ㄏㄠˇ -2.0"))
        XCTAssertTrue(dictionary.serialized().contains("!打對 ㄉㄚˇ-ㄉㄨㄟˋ"))
    }

    func testBadLinesAreReportedAndSkippedNeverFatal() {
        let (dictionary, problems) = UserDictionary.parse("""
        ㄋㄧˇ-ㄏㄠˇ\t你好
        ㄋㄧˇ-ㄏㄠˇ\t你
        hello\tworld
        ㄋㄧˇ\t你\t3
        lonely
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
        XCTAssertTrue(saved.contains("你好嗎 ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙"))
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
        return session
    }
}
