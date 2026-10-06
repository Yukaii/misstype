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
/// opening the gate on valid readings is the lever (toned p=10%: 37.3% →
/// 44.2% at offset -1), see `RepairStrength`.
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
    /// (offset, repairValidReadings) arms: standard, light, gated offset
    /// only, then the gate opened. Strong is (-1, true).
    private static let arms: [(offset: Double, ungated: Bool)] =
        [(0, false), (2, false), (-1.5, false), (0, true), (1, true), (2, true), (-1, true)]
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
        decoder.repairCostOffset = 0
        decoder.repairValidReadings = false
        print(out)
    }
}
