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
        decoder.repairCostOffset = RepairStrength.standard.costOffset
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.repairCostOffset = RepairStrength.light.costOffset
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.repairCostOffset = RepairStrength.strong.costOffset
        decoder.repairValidReadings = RepairStrength.strong.repairsValidReadings
        let strong = top(decoder, "g/ ")
        XCTAssertEqual(strong?.text, "深")
        XCTAssertEqual(strong?.repairs, 1)
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

    func testStrongUndoesASlipOntoAnotherRealSyllable() throws {
        // ㄕㄥ is a real reading, so a neighbor-key repair of it is gated off
        // unless the level repairs valid readings too.
        let neighbor = try XCTUnwrap(ZhuyinKeyboard.neighbors(of: "g").first)
        let symbol = try XCTUnwrap(ZhuyinKeyboard.symbols[neighbor])
        let decoder = LexiconDecoder(tsv: "\(symbol)ㄥ\t對\t-5\nㄕㄥ\t升\t-12\n")
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.repairCostOffset = RepairStrength.strong.costOffset
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.repairValidReadings = true
        let strong = top(decoder, "g/ ")
        XCTAssertEqual(strong?.text, "對")
        XCTAssertEqual(strong?.repairs, 1)
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

    func testSessionAppliesTheLevelPerKeystroke() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-4.5\nㄕㄥ\t升\t-9\nㄋㄧˇ\t你\t-5\n")
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
        XCTAssertEqual(type("g/ "), "升")
        settings.repairStrength = .strong
        XCTAssertEqual(type("g/ "), "深")
        settings.repairStrength = .off
        XCTAssertFalse(settings.fuzzyRepair)
        XCTAssertNotEqual(type("s3"), "你")
        settings.repairStrength = .light
        XCTAssertEqual(type("s3"), "你")
    }
}
