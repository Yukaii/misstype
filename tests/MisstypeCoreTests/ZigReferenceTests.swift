import Dispatch
import XCTest
@testable import MisstypeCore

/// Reference output for the Zig port (docs/zig-port.md): decodes
/// core-zig/bench/inputs.tsv with the shipping lexicon and prints the top
/// candidates to the file MISSTYPE_ZIG_REF names, in misstype-bench's
/// format, then a `swift:` latency line. Measurement, not a gate: skipped
/// unless MISSTYPE_ZIG_REF is set.
///
///   python3 script/prepare_lexicon.py   # once (.cache/, never committed)
///   core-zig/bench/compare.sh           # runs this and diffs against Zig
final class ZigReferenceTests: XCTestCase {
    func testPrintReference() throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["MISSTYPE_ZIG_REF"] else { throw XCTSkip("set MISSTYPE_ZIG_REF=<output file>") }
        let repeats = env["MISSTYPE_ZIG_REPEATS"].flatMap(Int.init) ?? 20
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zig-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let decoder = try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1e6

        let inputs = try String(contentsOf: root.appendingPathComponent("core-zig/bench/inputs.tsv"), encoding: .utf8)
        var means: [Double] = []
        var lines: [String] = []
        for line in inputs.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let syllables = fields[2].split(separator: " ").map { word -> Syllable in
                let keys = word.map(String.init)
                guard let last = keys.last, "3467_".contains(last) else { return Syllable(keys: keys, tone: nil) }
                return Syllable(keys: Array(keys.dropLast()), tone: ZhuyinKeyboard.tones[last == "_" ? " " : last])
            }
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<repeats { _ = decoder.decode(syllables, fuzzy: false) }
            means.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(repeats) / 1000)
            for (rank, candidate) in decoder.decode(syllables, fuzzy: false).enumerated() {
                let bits = String(candidate.score.bitPattern, radix: 16)
                let alignment = candidate.alignment.map {
                    "\($0.syllables.lowerBound)-\($0.syllables.upperBound):\($0.chars.lowerBound)-\($0.chars.upperBound)"
                }.joined(separator: ",")
                lines.append([fields[0], fields[1], "\(rank)", candidate.text,
                       String(repeating: "0", count: 16 - bits.count) + bits,
                       "\(candidate.repairs)", "\(candidate.unresolved)", alignment].joined(separator: "\t"))
            }
        }
        means.sort()
        let n = means.count
        lines.append(String(format: "swift: entries=%d load=%.1fms inputs=%d repeats=%d decode mean=%.1fus p50=%.1fus p95=%.1fus max=%.1fus",
                     decoder.entryCount, loadMs, n, repeats, means.reduce(0, +) / Double(n),
                     means[n / 2], means[min(n - 1, n * 95 / 100)], means[n - 1]))
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

