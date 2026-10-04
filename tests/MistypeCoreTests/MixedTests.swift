import XCTest
@testable import MistypeCore

final class MixedTests: XCTestCase {
    private var decoder: LexiconDecoder {
        LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄒㄧㄝˋ-ㄒㄧㄝ˙\t謝謝\t-3
        """)
    }
    private let english = EnglishLexicon(tsv: """
    python\t-12.9
    script\t-11.0
    meeting\t-9.2
    the\t-3.4
    """)

    private func keys(_ typed: String) -> [String] { typed.map(String.init) }

    func testEnglishWordTypedWithoutAToggleIsRecognized() {
        let top = decoder.decodeMixed(keys: keys("su3cl3python"), english: english).first
        XCTAssertEqual(top?.text, "你好python")
        XCTAssertEqual(top?.englishSpans, [6..<12])
        XCTAssertEqual(top?.englishWords, ["python"])
    }

    func testEnglishBetweenChineseAndAfterToneless() {
        XCTAssertEqual(decoder.decodeMixed(keys: keys("sucl3pythonvu,4vu,7"), english: english).first?.text,
                       "你好python謝謝")
    }

    func testOneLetterTypoInAnEnglishWordIsCorrected() {
        for typed in ["pyhton", "pythn", "pythoon", "pytnon"] {
            let top = decoder.decodeMixed(keys: keys("su3cl3" + typed), english: english).first
            XCTAssertEqual(top?.text, "你好python", typed)
        }
        XCTAssertNotEqual(decoder.decodeMixed(keys: keys("su3cl3pyhton"), english: english,
                                              fuzzyEnglish: false).first?.text, "你好python")
    }

    func testPureChineseIsNeverSwitched() {
        for typed in ["su3cl3", "sucl", "vu,4vu,7", "su3cl3vu,4vu,7"] {
            let top = decoder.decodeMixed(keys: keys(typed), english: english).first
            XCTAssertEqual(top?.englishSpans, [], typed)
            XCTAssertEqual(top?.sentence.text,
                           decoder.decodeSegments({ var c = Composition(); typed.forEach { c.append(String($0)) }; return c.segments }(),
                                                  pendingKeys: { var c = Composition(); typed.forEach { c.append(String($0)) }; return c.parsed.pending }()).first?.text,
                           typed)
        }
    }

    func testShortWordsNeedLengthAndAFairScore() {
        // Two-letter runs are never English; "the" (3 letters) is allowed.
        XCTAssertEqual(decoder.decodeMixed(keys: keys("th"), english: english).first?.englishSpans, [])
        XCTAssertEqual(english.matches(of: "ths", fuzzy: true).count, 0)  // below fuzzy length
    }

    func testEditDistanceOneKinds() {
        let lexicon = EnglishLexicon(tsv: "deadline\t-9\n")
        for typed in ["deadline", "deadlin", "deadlinee", "daedline", "deadlune"] {
            XCTAssertEqual(lexicon.matches(of: typed, fuzzy: true).first?.word, "deadline", typed)
        }
        XCTAssertTrue(lexicon.matches(of: "deadlnn", fuzzy: true).isEmpty)  // two edits
        XCTAssertEqual(lexicon.matches(of: "deadline", fuzzy: true).first?.edits, 0)
        XCTAssertEqual(lexicon.matches(of: "daedline", fuzzy: true).first?.edits, 1)
    }
}
