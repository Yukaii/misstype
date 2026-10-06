import XCTest
@testable import MisstypeCore

final class RepairStrengthTests: XCTestCase {
    // g = ㄕ, p = ㄣ, / = ㄥ, s = ㄋ, u = ㄧ; Space = first tone.
    private func top(_ decoder: LexiconDecoder, _ keys: String) -> SentenceCandidate? {
        var composition = Composition()
        for key in keys { _ = key == " " ? composition.appendSpace() : composition.append(String(key)) }
        return decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending).first
    }

    func testOffsetDecidesWhenARepairBeatsExactInput() {
        // Exact 升 (-9) against 深 via the generic ㄥ→ㄣ confusion (-4.5 - 5).
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-4.5\nㄕㄥ\t升\t-9\n")
        for level in RepairStrength.allCases where level != .off {
            decoder.repairCostOffset = level.costOffset
            decoder.repairValidReadings = level.repairsValidReadings
            XCTAssertEqual(top(decoder, "g/ ")?.text, "升", "\(level)")
        }
        decoder.repairCostOffset = -1
        let cheaper = top(decoder, "g/ ")
        XCTAssertEqual(cheaper?.text, "深")
        XCTAssertEqual(cheaper?.repairs, 1)
    }

    func testLightKeepsExactInputThatStandardRepairs() {
        // Exact 升 (-9) against 深 (-3.5) via ㄥ→ㄣ: -8.5 standard, -10.5 light.
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-3.5\nㄕㄥ\t升\t-9\n")
        XCTAssertEqual(top(decoder, "g/ ")?.text, "深")
        decoder.repairCostOffset = RepairStrength.light.costOffset
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
    }

    func testLightStillRescuesInputWithNoReading() {
        // Bare ㄋˇ is no reading at all; inserting ㄧ is the only way to 你.
        let decoder = LexiconDecoder(tsv: "ㄋㄧˇ\t你\t-5\n")
        decoder.repairCostOffset = RepairStrength.light.costOffset
        XCTAssertEqual(top(decoder, "s3")?.text, "你")
    }

    func testStrongUndoesASlipOntoAnotherRealSyllableInsideAWord() throws {
        // ㄕㄥ is a real reading, so a neighbor-key repair of it is gated off
        // unless the level repairs valid readings too; then it may complete
        // the word 好對 (c = ㄏ, l = ㄠ).
        let neighbor = try XCTUnwrap(ZhuyinKeyboard.neighbors(of: "g").first)
        let symbol = try XCTUnwrap(ZhuyinKeyboard.symbols[neighbor])
        let decoder = LexiconDecoder(tsv: "ㄏㄠˇ\t好\t-6\nㄕㄥ\t升\t-12\n\(symbol)ㄥ\t對\t-12\nㄏㄠˇ-\(symbol)ㄥ\t好對\t-5\n")
        XCTAssertEqual(top(decoder, "cl3g/ ")?.text, "好升")
        decoder.repairValidReadings = true
        let strong = top(decoder, "cl3g/ ")
        XCTAssertEqual(strong?.text, "好對")
        XCTAssertEqual(strong?.repairs, 1)
    }

    func testStrongNeverTurnsARealSingleSyllableIntoAMoreCommonNeighbor() {
        // 好喔 (i = ㄛ) must not become 好一 (u = ㄧ, a neighbor key): a
        // single character has only frequency to argue for a repair.
        let decoder = LexiconDecoder(tsv: "ㄏㄠˇ\t好\t-6\nㄛ\t喔\t-11\nㄧ\t一\t-2\n")
        decoder.repairValidReadings = RepairStrength.strong.repairsValidReadings
        XCTAssertEqual(top(decoder, "cl3i")?.text, "好喔")
        XCTAssertEqual(top(decoder, "i ")?.text, "喔")
        let picker = decoder.segmentOptions([Syllable(keys: ["i"], tone: "")], span: 0..<1).map(\.text)
        XCTAssertFalse(picker.contains("一"))
    }

    func testLearnedPairIgnoresTheOffset() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        decoder.repairCostOffset = RepairStrength.light.costOffset
        XCTAssertEqual(top(decoder, "g/ ")?.text, "深")
    }

    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    func testSessionAppliesTheLevelPerKeystroke() throws {
        let neighbor = try XCTUnwrap(ZhuyinKeyboard.neighbors(of: "g").first)
        let symbol = try XCTUnwrap(ZhuyinKeyboard.symbols[neighbor])
        let decoder = LexiconDecoder(tsv: "ㄏㄠˇ\t好\t-6\nㄕㄥ\t升\t-12\n\(symbol)ㄥ\t對\t-12\nㄏㄠˇ-\(symbol)ㄥ\t好對\t-5\nㄋㄧˇ\t你\t-5\n")
        var settings = SessionSettings()
        let engine = InputEngine(decoder: decoder, settings: { settings })
        let session = InputSession(engine: engine)
        let host = Host()
        session.host = host
        func type(_ keys: String) -> String? {
            for char in keys {
                let label = String(char)
                _ = session.handle(label == " " ? KeyEvent(.space, text: " ") : KeyEvent(.character(label), text: label))
            }
            return session.handle(KeyEvent(.enter, text: "\r")).commit
        }
        XCTAssertEqual(type("cl3g/ "), "好升")
        settings.repairStrength = .strong
        XCTAssertEqual(type("cl3g/ "), "好對")
        settings.repairStrength = .off
        XCTAssertFalse(settings.fuzzyRepair)
        XCTAssertNotEqual(type("s3"), "你")
        settings.repairStrength = .light
        XCTAssertEqual(type("s3"), "你")
    }
}
