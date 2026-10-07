import XCTest
@testable import MisstypeCore

/// Repair strength (issue #21), seeded slip sweep on the REAL lexicon.
/// Measurement, not a gate: skipped unless MISSTYPE_REPAIR_SWEEP is set.
///
///   python3 script/prepare_lexicon.py   # once (.cache/, never committed)
///   MISSTYPE_REPAIR_SWEEP=1 swift test --filter RepairStrengthSweepTests
///   (optional: MISSTYPE_REPAIR_SEEDS=10)
///
/// Hypothesis: one generic repair cost cannot serve both a precise typist
/// and a sloppy one. Shifting every generic repair tier by an offset trades
/// clean-input accuracy (exact keys mis-"repaired") against slip recovery,
/// so a cheaper offset wins at high slip rates and a dearer one at ~0.
/// Falsified if the standard offset (0) is best or tied at every slip rate.
/// Result (2026-10-06): the offset alone moves top-1 by ~2 pp either way;
/// opening the gate on valid readings (inside words) is the lever (toned
/// p=10%: 37.3% → 42.5%). Offset -1 adds ~2 pp but changes 8 of 1000
/// exactly typed frequent chars (屋→一), so strong keeps 0. See
/// `RepairStrength`.
/// Slot-order repair (2026-10-07, tools/baseline libchewing comparison):
/// toned standard 63.1/37.3/24.8% → 65.6/42.5/29.6% at p=5/10/15%,
/// toneless and clean rows unchanged.
/// Synthetic typist: the cursor_replay sentences, toned and toneless; each
/// symbol key slips with probability p into one of neighbor substitution,
/// transposition with the next key of its syllable, a dropped key, or a
/// phonetic confusion. Score: sentence top-1.
final class RepairStrengthSweepTests: XCTestCase {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let toneKeys: [Character: String] = ["ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"]
    /// (offset, repairValidReadings) arms: standard, light, strong (0, true),
    /// and the rejected (-1, true).
    private static let arms: [(offset: Double, ungated: Bool)] =
        [(0, false), (2, false), (0, true), (-1, true)]
    private static let slipRates = [0.0, 0.02, 0.05, 0.10, 0.15]

    private func realDecoder() throws -> LexiconDecoder {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
    }

    /// Most frequent text per reading with `syllables` syllables, best first.
    private func words(syllables: ClosedRange<Int>, limit: Int) throws -> [(text: String, readings: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try String(contentsOf: root.appendingPathComponent(".cache/mcbopomofo/lexicon.tsv"), encoding: .utf8)
        var best: [String: (String, Double)] = [:]
        for line in lexicon.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let score = Double(fields[2]) else { continue }
            let reading = String(fields[0])
            let count = reading.split(separator: "-").count
            guard syllables.contains(count), fields[1].count == count else { continue }
            if let seen = best[reading], seen.1 >= score { continue }
            best[reading] = (String(fields[1]), score)
        }
        return best.sorted { $0.value.1 == $1.value.1 ? $0.key < $1.key : $0.value.1 > $1.value.1 }
            .prefix(limit).map { (text: $0.value.0, readings: $0.key.replacingOccurrences(of: "-", with: " ")) }
    }

    /// Per-syllable symbol keys plus the tone key (" " for first tone).
    private func syllables(_ readings: String) -> [(keys: [String], tone: String)] {
        var reverse: [String: String] = [:]
        for (key, symbol) in ZhuyinKeyboard.symbols { reverse[symbol] = key }
        return readings.split(separator: " ").map { syllable in
            var keys: [String] = [], tone = " "
            for char in syllable {
                if let key = Self.toneKeys[char] { tone = key } else { keys.append(reverse[String(char)]!) }
            }
            return (keys, tone)
        }
    }

    private func typed(_ syllables: [(keys: [String], tone: String)], toned: Bool, slip p: Double,
                       rng: inout SplitMix64) -> [String] {
        var out: [String] = []
        for syllable in syllables {
            var keys = syllable.keys
            var index = 0
            while index < keys.count {
                guard p > 0, Double.random(in: 0..<1, using: &rng) < p else { index += 1; continue }
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    if let near = ZhuyinKeyboard.neighbors(of: keys[index]).randomElement(using: &rng) {
                        keys[index] = near
                    }
                case 1 where index + 1 < keys.count:
                    keys.swapAt(index, index + 1)
                    index += 1
                case 2 where keys.count > 1:
                    keys.remove(at: index)
                    continue
                default:
                    if let other = ZhuyinKeyboard.phoneticConfusions[keys[index]]?.randomElement(using: &rng) {
                        keys[index] = other
                    }
                }
                index += 1
            }
            out += keys
            if toned { out.append(syllable.tone) }
        }
        return out
    }

    private func top(_ decoder: LexiconDecoder, _ keys: [String]) -> String? {
        var composition = Composition()
        for key in keys { composition.append(key) }
        return decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending,
                                      fuzzy: true).first?.text
    }

    func testSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISSTYPE_REPAIR_SWEEP"] == nil, "measurement; set MISSTYPE_REPAIR_SWEEP=1")
        let decoder = try realDecoder()
        let seeds = environment["MISSTYPE_REPAIR_SEEDS"].flatMap(Int.init) ?? 6
        let probes = ChannelSweepTests.sentences.map { (text: $0.text, syllables: syllables($0.readings)) }
        var out = "\nrepair strength sweep: \(probes.count) sentences, \(seeds) seeds per slip rate, sentence top-1\n"
        for toned in [true, false] {
            out += (toned ? "toned" : "toneless") + "\narm        |"
            for p in Self.slipRates { out += String(format: " p=%2.0f%% ", p * 100) }
            out += "| ms/decode\n"
            for arm in Self.arms {
                decoder.repairCostOffset = arm.offset
                decoder.repairValidReadings = arm.ungated
                out += String(format: "%+5.1f ", arm.offset) + (arm.ungated ? "all  |" : "gate |")
                let started = Date()
                var decodes = 0
                for p in Self.slipRates {
                    var hits = 0, total = 0
                    for (number, probe) in probes.enumerated() {
                        for seed in 0..<(p == 0 ? 1 : seeds) {
                            var rng = SplitMix64(state: UInt64(seed) &* 104_729 &+ UInt64(number) &* 31 &+ UInt64(p * 1000))
                            let keys = typed(probe.syllables, toned: toned, slip: p, rng: &rng)
                            hits += top(decoder, keys) == probe.text ? 1 : 0
                            total += 1
                        }
                    }
                    decodes += total
                    out += String(format: "  %5.1f%%", Double(hits) * 100 / Double(total))
                }
                out += String(format: " | %6.1f\n", Date().timeIntervalSince(started) * 1000 / Double(decodes))
            }
        }
        // Clean input: frequent chars and words typed exactly (the 好喔→好一
        // class). Only probes standard decodes right count; reports how many
        // each arm keeps.
        let limit = environment["MISSTYPE_REPAIR_WORDS"].flatMap(Int.init) ?? 1000
        for (name, range) in [("chars", 1...1), ("words", 2...4)] {
            let probes = try words(syllables: range, limit: limit)
            for toned in [true, false] {
                decoder.repairCostOffset = 0
                decoder.repairValidReadings = false
                var rng = SplitMix64(state: 0)
                let baseline = probes.filter { top(decoder, typed(syllables($0.readings), toned: toned, slip: 0, rng: &rng)) == $0.text }
                out += "\nclean \(name) \(toned ? "toned" : "toneless"): \(baseline.count) of \(probes.count) right at standard\n"
                for arm in Self.arms {
                    decoder.repairCostOffset = arm.offset
                    decoder.repairValidReadings = arm.ungated
                    let lost = baseline.compactMap { probe -> String? in
                        let got = top(decoder, typed(syllables(probe.readings), toned: toned, slip: 0, rng: &rng))
                        return got == probe.text ? nil : "\(probe.text)→\(got ?? "-")"
                    }
                    out += String(format: "%+5.1f ", arm.offset) + (arm.ungated ? "all  " : "gate ")
                        + "lost \(lost.count)  " + lost.prefix(8).joined(separator: " ") + "\n"
                }
            }
        }
        decoder.repairCostOffset = 0
        decoder.repairValidReadings = false
        print(out)
    }

    /// Exact phrases users reported flipping, at every level.
    func testSpotChecks() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MISSTYPE_REPAIR_SWEEP"] == nil,
                      "measurement; set MISSTYPE_REPAIR_SWEEP=1")
        let decoder = try realDecoder()
        let spots = [("好喔", "ㄏㄠˇ ㄛ"), ("好喔", "ㄏㄠˇ ㄛ˙")]
        var out = "\nspot checks\n"
        for (text, readings) in spots {
            for toned in [true, false] {
                var rng = SplitMix64(state: 0)
                let keys = typed(syllables(readings), toned: toned, slip: 0, rng: &rng)
                out += "\(readings) \(toned ? "toned" : "toneless"):"
                for level in RepairStrength.allCases where level != .off {
                    decoder.repairCostOffset = level.costOffset
                    decoder.repairValidReadings = level.repairsValidReadings
                    out += " \(level)=\(top(decoder, keys) ?? "-")"
                }
                decoder.repairCostOffset = 0
                decoder.repairValidReadings = false
                out += " (want \(text))\n"
            }
        }
        print(out)
    }
}
