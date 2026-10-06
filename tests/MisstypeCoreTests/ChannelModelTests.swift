import XCTest
@testable import MisstypeCore

final class ChannelModelTests: XCTestCase {
    // g = ㄕ, p = ㄣ, / = ㄥ; Space = first tone.
    private func top(_ decoder: LexiconDecoder, _ keys: String) -> SentenceCandidate? {
        var composition = Composition()
        for key in keys { _ = key == " " ? composition.appendSpace() : composition.append(String(key)) }
        return decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending).first
    }

    func testPersonalPairCheapensOnlyThatRepair() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n")
        // Generic: 深 via ㄥ→ㄣ pays 5.0 (-10) and loses to the exact 升 (-9).
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        let personal = top(decoder, "g/ ")
        XCTAssertEqual(personal?.text, "深")
        XCTAssertEqual(personal?.repairs, 1)
        // Directional: typing ㄣ gains nothing toward ㄥ.
        let reverse = LexiconDecoder(tsv: "ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-5\n")
        reverse.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        XCTAssertEqual(top(reverse, "gp ")?.text, "深")
    }

    func testFloorKeepsExactInputAhead() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-9\n")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 0]])
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
    }

    func testEmptyChannelDecodesLikeNone() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\nㄕㄥ-ㄧㄣ\t聲音\t-6\n")
        let inputs = ["g/ ", "g/up", "gp ", "g/", "gpu/"]
        let plain = inputs.map { top(decoder, $0) }
        decoder.channel = ChannelModel()
        XCTAssertEqual(inputs.map { top(decoder, $0) }, plain)
    }
}
