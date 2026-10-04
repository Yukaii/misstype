import XCTest
@testable import MistypeCore

final class TouchTests: XCTestCase {
    private var decoder: LexiconDecoder {
        LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄗㄠˇ-ㄕㄤˋ-ㄏㄠˇ\t早上好\t-3
        """)
    }

    /// (surface, x, y, key) rows of a Python-recorded fixture.
    private func fixtureTaps(_ name: String) throws
        -> [(surface: TouchSurface, x: Double, y: Double, key: String)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let payload = try XCTUnwrap(row["payload"] as? [String: Any])
            return (TouchSurface(rawValue: row["surface"] as! String)!,
                    (payload["x"] as! NSNumber).doubleValue, (payload["y"] as! NSNumber).doubleValue,
                    payload["key"] as! String)
        }
    }

    func testLayoutCoversEveryZhuyinAndToneKeyOnce() {
        let all = Set(TouchLayout.left.keys).union(TouchLayout.right.keys)
        XCTAssertEqual(all.count, TouchLayout.left.count + TouchLayout.right.count)
        XCTAssertEqual(all, Set(ZhuyinKeyboard.symbols.keys).union(["3", "4", "6", "7"]))
    }

    func testMapperPicksTheKeysRecordedInPythonFixtures() throws {
        for name in ["touch-ni-hao", "touch-zao-shang-hao"] {
            for tap in try fixtureTaps(name) {
                let hypothesis = try XCTUnwrap(TouchMapper.hypothesis(surface: tap.surface, x: tap.x, y: tap.y))
                XCTAssertEqual(hypothesis.key, tap.key, name)
            }
        }
    }

    /// Golden values computed by `mistype.touch.nearest_key(...).spatial`
    /// (fixtures predate the neighbors payload, so they cannot carry them).
    func testNeighborRankingAndWeightsMatchPython() throws {
        let golden: [(TouchSurface, Double, Double, [(String, Double)])] = [
            (.left, 0.7, 0.58, [("x", 0.94), ("c", 0.865), ("5", 0.745), ("g", 0.723413666281), ("v", 0.698130823038)]),
            (.right, 0.31, 0.52, [("k", 0.966458980338), ("o", 0.713425402382), (",", 0.579732228216), ("i", 0.519765682193), ("l", 0.492432270529)]),
            (.left, 0.5, 0.8, [("s", 1.0), ("z", 0.7), ("5", 0.690767078079), ("t", 0.676890111572), ("x", 0.596391278588)]),
            (.right, 0.8, 0.3, [("j", 0.85), ("u", 0.840547812809), ("h", 0.825071443155), ("y", 0.816901665764), ("m", 0.690767078079)]),
        ]
        for (surface, x, y, expected) in golden {
            let ranked = try XCTUnwrap(TouchMapper.hypothesis(surface: surface, x: x, y: y)).ranked
            XCTAssertEqual(ranked.map(\.key), expected.map(\.0))
            for (mine, theirs) in zip(ranked, expected) {
                XCTAssertEqual(mine.weight, theirs.1, accuracy: 1e-9)
            }
        }
    }

    func testOutOfSurfacePointIsRejected() {
        XCTAssertNil(TouchMapper.hypothesis(surface: .left, x: 1.1, y: 0.5))
        XCTAssertNil(TouchMapper.hypothesis(surface: .right, x: 0.5, y: -0.01))
    }

    func testReplayOfRecordedTouchTracesDecodes() throws {
        for (name, expected) in [("touch-ni-hao", "你好"), ("touch-zao-shang-hao", "早上好")] {
            let taps = try fixtureTaps(name).map {
                try XCTUnwrap(TouchMapper.hypothesis(surface: $0.surface, x: $0.x, y: $0.y))
            }
            XCTAssertEqual(decoder.decodeTouch(taps).first?.text, expected, name)
            XCTAssertEqual(decoder.decodeTouchBeam(taps).first?.text, expected, name)
            XCTAssertEqual(decoder.decodeTouchBeam(taps).first?.spatialCost, 0, name)
        }
    }

    func testSpatialNeighborsRescueAMissWithoutKeyboardRepair() throws {
        // ㄏ (c) tapped low: x is nearer, so the nearest-key reading is ㄌㄠˇ.
        let keys = ["s", "u", "3", "c", "l", "3"]
        var taps: [TouchHypothesis] = []
        for key in keys {
            let p = try XCTUnwrap(TouchLayout.position(of: key))
            let y = key == "c" ? p.y + 0.09 : p.y
            taps.append(try XCTUnwrap(TouchMapper.hypothesis(surface: p.surface, x: p.x, y: y)))
        }
        XCTAssertEqual(taps[3].key, "x")
        for (name, decode) in [("beam", { (spatial: Bool) in self.decoder.decodeTouchBeam(taps, spatial: spatial, fuzzy: false) }),
                               ("lattice", { (spatial: Bool) in self.decoder.decodeTouch(taps, spatial: spatial, fuzzy: false) })] {
            XCTAssertNotEqual(decode(false).first?.text, "你好", name)
            XCTAssertEqual(decode(true).first?.text, "你好", name)
        }
        let beam = decoder.decodeTouchBeam(taps, spatial: true, fuzzy: false)
        XCTAssertGreaterThan(try XCTUnwrap(beam.first).spatialCost, 0)
        XCTAssertEqual(beam.first?.keys, keys)
    }

    func testToneTapsStayExact() throws {
        // A tap nearer the 3 key than anything else never becomes a Zhuyin key.
        let tap = try XCTUnwrap(TouchMapper.hypothesis(surface: .left, x: 0.70, y: 0.16))
        XCTAssertEqual(tap.key, "3")
        let candidates = decoder.decodeTouch([tap])
        XCTAssertTrue(candidates.allSatisfy { $0.keys == ["3"] })
        XCTAssertTrue(decoder.decodeTouchBeam([tap]).allSatisfy { $0.keys == ["3"] })
    }
}
