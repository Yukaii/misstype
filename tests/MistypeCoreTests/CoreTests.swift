import XCTest
@testable import MistypeCore

final class CoreTests: XCTestCase {
    private func composition(_ keys: String) -> Composition {
        var result = Composition()
        for key in keys { _ = result.append(String(key)) }
        return result
    }
    private var decoder: LexiconDecoder {
        LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄋㄧˇ\t妳\t-6
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄇㄚ˙\t嗎\t-4
        ㄒㄧㄝˋ-ㄒㄧㄝ˙\t謝謝\t-3
        ㄒㄩㄝˊ-ㄕㄥ\t學生\t-3
        """)
    }
    func testHardwareMapCoversEverySymbolOnce() {
        let mapped = ZhuyinKeyboard.labels.values.filter { ZhuyinKeyboard.symbols[$0] != nil }
        XCTAssertEqual(mapped.count, 37)
        XCTAssertEqual(Set(mapped), Set(ZhuyinKeyboard.symbols.keys))
        XCTAssertEqual(ZhuyinKeyboard.labels[45], "n")
        XCTAssertEqual(ZhuyinKeyboard.labels[28], "8")
        XCTAssertEqual(ZhuyinKeyboard.labels[27], "-")
    }
    func testToneKeysAndSpaceEndSyllables() {
        let input = composition("su3cl3a87")
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧˇ", "ㄏㄠˇ", "ㄇㄚ˙"])
        XCTAssertEqual(composition("vm,6g/ ").parsed.complete.map(\.reading), ["ㄒㄩㄝˊ", "ㄕㄥ"])
    }
    func testBackspaceRestoresPendingPhoneticEvidence() {
        var input = composition("su3")
        input.backspace()
        XCTAssertEqual(input.rawKeys, ["s", "u"])
        XCTAssertEqual(input.pendingText, "ㄋㄧ")
        XCTAssertTrue(input.parsed.complete.isEmpty)
    }
    func testPendingSyllableWaitsForToneOrCommit() {
        let input = composition("su3cl")
        XCTAssertEqual(input.syllables(finishing: false).count, 1)
        XCTAssertEqual(input.syllables(finishing: true).count, 2)
        XCTAssertEqual(decoder.decode(input.syllables(finishing: true)).first?.text, "你好")
    }
    func testComposesAnUnlistedSentenceFromMultipleWords() {
        let input = composition("su3cl3a87vu,4vu,7")
        let result = decoder.decode(input.syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你好嗎謝謝")
        XCTAssertEqual(result.first?.unresolved, 0)
        XCTAssertLessThanOrEqual(result.count, 5)
    }
    func testFuzzyRescuesInvalidSyllableWithoutTone() {
        let input = composition("du") // ㄎㄧ has adjacent ㄋㄧ as a hypothesis
        let result = decoder.decode(input.syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
        XCTAssertEqual(decoder.decode(input.syllables(finishing: true), fuzzy: false).first?.text, "ㄎㄧ")
    }
    func testValidSyllablesRemainExact() {
        let result = decoder.decode(composition("su3").syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 0)
    }
    func testUnknownInputIsPreserved() {
        let result = decoder.decode(composition("zzzz3").syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "ㄈㄈㄈㄈˇ")
        XCTAssertEqual(result.first?.unresolved, 1)
    }
    func testCaptureIsBoundedAndClearRemovesActiveInput() {
        var input = composition(String(repeating: "a", count: 300))
        XCTAssertEqual(input.rawKeys.count, 256)
        input.clear()
        XCTAssertTrue(input.isEmpty)
        XCTAssertFalse(input.append("3"))
    }
}
