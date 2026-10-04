import XCTest
@testable import MistypeCore

/// Mixed Chinese/English typing without a mode switch, on the REAL lexicons.
/// Measurement: skipped unless MISTYPE_MIXED_SWEEP is set.
///
///   python3 script/prepare_lexicon.py
///   MISTYPE_MIXED_SWEEP=1 swift test -c release -Xswiftc -enable-testing --filter MixedSweepTests
///
/// Positives: Chinese piece + English word + Chinese piece, typed as bare
/// keys (toned and toneless). Negatives: pure Chinese sentences sampled from
/// the lexicon; any English span in the top result is a false switch. The
/// switch penalty is the knob that trades one against the other.
final class MixedSweepTests: XCTestCase {
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

    private static let pieces: [(text: String, keys: String)] = [
        ("你好", "su3cl3"), ("早上好", "yl3g;4cl3"), ("學生", "vm,6g/"),
        ("我是", "ji3g4"), ("謝謝", "vu,4vu,7"),
    ]
    private static let words = ["python", "script", "email", "meeting", "deadline", "project",
                                "server", "update", "hello", "world", "house", "phone",
                                "app", "the", "you", "for", "and", "not"]
    private static let penalties = [0.0, 2, 4, 6, 8]
    private static let toneKeys = Set("3467")

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func realDecoder() throws -> LexiconDecoder {
        let root = root()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
    }

    /// Reading like ㄋㄧˇ-ㄏㄠˇ -> physical keys (first tone has no key).
    private func keys(forReading reading: String) -> String {
        var symbolToKey: [Character: String] = [:]
        for (key, symbol) in ZhuyinKeyboard.symbols { symbolToKey[Character(symbol)] = key }
        let toneToKey: [Character: String] = ["ˇ": "3", "ˋ": "4", "ˊ": "6", "˙": "7"]
        return reading.compactMap { char -> String? in
            symbolToKey[char] ?? toneToKey[char]
        }.joined()
    }

    func testSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISTYPE_MIXED_SWEEP"] == nil, "measurement; set MISTYPE_MIXED_SWEEP=1")
        let decoder = try realDecoder()
        let tsv = try String(contentsOf: root().appendingPathComponent(".cache/frequencywords/english.tsv"),
                             encoding: .utf8)
        let buildStarted = Date()
        let english = EnglishLexicon(tsv: tsv)
        let buildMillis = Date().timeIntervalSince(buildStarted) * 1000
        XCTAssertFalse(english.isEmpty)
        let sampleCount = environment["MISTYPE_MIXED_SAMPLES"].flatMap(Int.init) ?? 150

        // Positives.
        var positives: [(keys: [String], expected: String, toneless: Bool)] = []
        var rng = SplitMix64(state: 17)
        for _ in 0..<sampleCount {
            let pre = Self.pieces.randomElement(using: &rng)!
            let post = Self.pieces.randomElement(using: &rng)!
            let word = Self.words.randomElement(using: &rng)!
            for toneless in [false, true] {
                let strip: (String) -> String = { toneless ? String($0.filter { !Self.toneKeys.contains($0) }) : $0 }
                let typed = strip(pre.keys) + word + strip(post.keys)
                positives.append((typed.map(String.init), pre.text + word + post.text, toneless))
            }
        }
        // Negatives: 3-6 frequent lexicon words, no English anywhere.
        let rows = try String(contentsOf: root().appendingPathComponent(".cache/mcbopomofo/lexicon.tsv"), encoding: .utf8)
            .split(separator: "\n").compactMap { line -> (String, Double)? in
                let f = line.split(separator: "\t")
                guard f.count == 3, let score = Double(f[2]), score > -9 else { return nil }
                return (String(f[0]), score)
            }
        var negatives: [(keys: [String], toneless: Bool)] = []
        for _ in 0..<(sampleCount * 3) {
            let readings = (0..<Int.random(in: 3...6, using: &rng)).map { _ in rows.randomElement(using: &rng)!.0 }
            for toneless in [false, true] {
                var typed = readings.map { keys(forReading: $0) }.joined()
                if toneless { typed = String(typed.filter { !Self.toneKeys.contains($0) }) }
                negatives.append((typed.map(String.init), toneless))
            }
        }

        // Typo'd English: one slip (neighbor key, swap, drop, double) in words of 6+ letters.
        let typoWords = ["python", "script", "meeting", "deadline", "project", "server", "update"]
        var typos: [(keys: [String], expected: String, toneless: Bool)] = []
        for _ in 0..<sampleCount {
            let pre = Self.pieces.randomElement(using: &rng)!
            let post = Self.pieces.randomElement(using: &rng)!
            let word = typoWords.randomElement(using: &rng)!
            var letters = Array(word).map(String.init)
            let at = Int.random(in: 1..<(letters.count - 1), using: &rng)
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                let near = ZhuyinKeyboard.neighbors(of: letters[at]).filter { $0.first!.isLetter }
                if let pick = near.randomElement(using: &rng) { letters[at] = pick }
            case 1: letters.swapAt(at, at + 1)
            case 2: letters.remove(at: at)
            default: letters.insert(letters[at], at: at)
            }
            for toneless in [false, true] {
                let strip: (String) -> String = { toneless ? String($0.filter { !Self.toneKeys.contains($0) }) : $0 }
                typos.append(((strip(pre.keys) + letters.joined() + strip(post.keys)).map(String.init),
                              pre.text + word + post.text, toneless))
            }
        }

        var out = "\nmixed typing sweep: real lexicons, \(positives.count) mixed / \(negatives.count) pure-Chinese inputs\n"
        out += "penalty |  mixed top-1 (toned / toneless) | English found | false switch (toned / toneless) | typo'd English top-1 (fuzzy on: toned / toneless; off: toned / toneless)\n"
        for penalty in Self.penalties {
            var hit = [0, 0], found = [0, 0], total = [0, 0]
            for item in positives {
                let i = item.toneless ? 1 : 0
                let top = decoder.decodeMixed(keys: item.keys, english: english, switchPenalty: penalty).first
                total[i] += 1
                hit[i] += top?.text == item.expected ? 1 : 0
                found[i] += top?.englishSpans.isEmpty == false ? 1 : 0
            }
            var wrong = [0, 0], negTotal = [0, 0]
            for item in negatives {
                let i = item.toneless ? 1 : 0
                let top = decoder.decodeMixed(keys: item.keys, english: english, switchPenalty: penalty).first
                negTotal[i] += 1
                wrong[i] += top?.englishSpans.isEmpty == false ? 1 : 0
            }
            var typoHit = [0, 0, 0, 0], typoTotal = [0, 0]
            for item in typos {
                let i = item.toneless ? 1 : 0
                typoTotal[i] += 1
                for (slot, fuzzyEnglish) in [(0, true), (2, false)] {
                    let top = decoder.decodeMixed(keys: item.keys, english: english, switchPenalty: penalty,
                                                  fuzzyEnglish: fuzzyEnglish).first
                    typoHit[slot + i] += top?.text == item.expected ? 1 : 0
                }
            }
            func pct(_ n: Int, _ d: Int) -> String { String(format: "%3.0f%%", Double(n) * 100 / Double(max(d, 1))) }
            out += String(format: "%6.0f  |  ", penalty)
                + "\(pct(hit[0], total[0])) / \(pct(hit[1], total[1]))"
                + "                  |  \(pct(found[0], total[0])) / \(pct(found[1], total[1]))"
                + "  |  \(pct(wrong[0], negTotal[0])) / \(pct(wrong[1], negTotal[1]))"
                + "  |  \(pct(typoHit[0], typoTotal[0])) / \(pct(typoHit[1], typoTotal[1])); \(pct(typoHit[2], typoTotal[0])) / \(pct(typoHit[3], typoTotal[1]))\n"
        }
        var millis = 0.0, plain = 0.0
        for item in positives {
            var started = Date()
            _ = decoder.decodeMixed(keys: item.keys, english: english)
            millis += Date().timeIntervalSince(started) * 1000
            started = Date()
            var composition = Composition()
            for key in item.keys { composition.append(key) }
            _ = decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending)
            plain += Date().timeIntervalSince(started) * 1000
        }
        out += String(format: "English index build %.0f ms (%d words); decodeMixed %.1f ms vs plain decode %.1f ms per mixed input\n",
                      buildMillis, english.scores.count, millis / Double(positives.count), plain / Double(positives.count))
        print(out)
    }
}
