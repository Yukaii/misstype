import Foundation
import XCTest
@testable import MisstypeCore

/// Offline, synthetic full-candidate/touch/Unicode oracle for the Zig port.
final class ZigParityTests: XCTestCase {
    struct Probe: Decodable {
        struct Tap: Decodable { let surface: TouchSurface; let x: Double; let y: Double }
        let id: String; let mode: String
        var keys: String?; var text: String?; var fuzzy: Bool?; var tone: Bool?
        var strength: Int?; var spatial: Bool?; var algorithm: String?; var taps: [Tap]?
    }
    func testReference() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["MISSTYPE_PARITY_CASES"], let output = env["MISSTYPE_PARITY_OUTPUT"] else {
            throw XCTSkip("set MISSTYPE_PARITY_CASES and MISSTYPE_PARITY_OUTPUT")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent(".cache/mcbopomofo/lexicon.tsv"), encoding: .utf8)
        let local = try String(contentsOf: root.appendingPathComponent("Resources/local_phrases.tsv"), encoding: .utf8)
        let toneless = try String(contentsOf: root.appendingPathComponent(".cache/mcbopomofo/toneless.tsv"), encoding: .utf8)
        let decoder = LexiconDecoder(tsv: main + "\n" + local, toneless: toneless)
        decoder.wordPenalty = 0.5
        var lines: [String] = []
        func bits(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }
        func candidate(_ id: String, _ rank: Int, _ c: SentenceCandidate, _ spatial: Double = 0, _ keys: [String] = []) {
            let alignment = c.alignment.map { "\($0.syllables.lowerBound)-\($0.syllables.upperBound):\($0.chars.lowerBound)-\($0.chars.upperBound)" }.joined(separator: ",")
            let syllables = c.syllables.map { "\($0.keys.joined()):\($0.tone.flatMap { tone in ZhuyinKeyboard.tones.first { $0.value == tone }?.key } ?? "~")" }.joined(separator: ",")
            let runs = c.runs.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
            lines.append(["C",id,String(rank),c.text,bits(c.score),String(c.repairs),String(c.unresolved),alignment,syllables,runs,bits(spatial),keys.joined()].joined(separator: "\t"))
        }
        var totals = ["keys": 0.0, "touch": 0.0]
        var counts = ["keys": 0, "touch": 0]
        for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            let p = try JSONDecoder().decode(Probe.self, from: Data(line.utf8))
            let started = Date()
            func recordTime() {
                totals[p.mode]! += Date().timeIntervalSince(started)
                counts[p.mode]! += 1
            }
            switch p.mode {
            case "keys":
                decoder.repairCostOffset = p.strength == 1 ? 1.5 : p.strength == 3 ? -1.5 : 0
                decoder.repairValidReadings = p.strength == 3
                var composition = Composition()
                for key in p.keys ?? "" { composition.append(String(key)) }
                let result = decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending, fuzzy: p.fuzzy ?? true, toneTolerance: p.tone ?? true)
                recordTime()
                for (rank,c) in result.enumerated() { candidate(p.id,rank,c) }
            case "touch":
                decoder.repairCostOffset = 0; decoder.repairValidReadings = false
                let taps = try (p.taps ?? []).map { try XCTUnwrap(TouchMapper.hypothesis(surface: $0.surface, x: $0.x, y: $0.y)) }
                for (index,tap) in taps.enumerated() {
                    lines.append(["H",p.id,String(index),tap.ranked.map { "\($0.key):\(bits($0.distance)):\(bits($0.weight))" }.joined(separator: ",")].joined(separator: "\t"))
                }
                let result = p.algorithm == "beam"
                    ? decoder.decodeTouchBeam(taps, spatial: p.spatial ?? true, fuzzy: p.fuzzy ?? true, toneTolerance: p.tone ?? true)
                    : decoder.decodeTouch(taps, spatial: p.spatial ?? true, fuzzy: p.fuzzy ?? true, toneTolerance: p.tone ?? true)
                recordTime()
                for (rank,c) in result.enumerated() { candidate(p.id,rank,c.sentence,c.spatialCost,c.keys) }
            case "unicode":
                let text = p.text ?? ""
                lines.append(["U",p.id,String(text.count),String(text.utf16.count),text.map { String(String($0).utf8.count) }.joined(separator: ",")].joined(separator: "\t"))
            case "dictionary":
                let text = p.text ?? ""
                let reading = Array(repeating: "ㄋㄧˇ", count: text.count).joined(separator: "-")
                lines.append(["D",p.id,UserDictionary.validate(reading: reading,text: text) == nil ? "1" : "0"].joined(separator: "\t"))
            default: XCTFail("bad probe mode")
            }
        }
        for mode in ["keys", "touch"] {
            FileHandle.standardError.write(Data("parity: \(mode) n=\(counts[mode]!) mean_us=\(Int(totals[mode]! * 1_000_000 / Double(counts[mode]!)))\n".utf8))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
