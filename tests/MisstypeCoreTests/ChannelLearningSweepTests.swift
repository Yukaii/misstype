import XCTest
@testable import MisstypeCore

/// Channel LEARNING replayed through `InputSession` on the real lexicon.
/// Measurement, not a gate: skipped unless MISSTYPE_CHANNEL_SWEEP is set.
///
///   MISSTYPE_CHANNEL_SWEEP=1 swift test -c release -Xswiftc -enable-testing \
///     --filter ChannelLearningSweepTests   (optional: MISSTYPE_CHANNEL_EPOCHS=6)
///
/// Synthetic user: types the cursor_replay dev sentences (toned), each ㄣ
/// typed as ㄥ with probability `slip`. A slip is noticed at once with
/// probability `notice` (Backspace, retype: the re-type signal); otherwise
/// the user checks the finished preview and, when it is wrong, picks the
/// right sentence from the list if it is there (explicit pick), else
/// commits anyway. Word learning is on in both arms, so the comparison is
/// channel learning on vs off. Afterwards the HOLDOUT sentences (never
/// typed in training) are typed with the same slips and only the first-pass
/// preview is scored, with learning frozen.
/// Falsified if the learned arm does not beat generic on holdout slips, if
/// it flips exact ㄥ input, or if a never-slipping user learns any pair.
final class ChannelLearningSweepTests: XCTestCase {
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

    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    private static let toneKeys: [Character: String] = ["ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"]

    private func realDecoder() throws -> LexiconDecoder {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-learn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
    }

    /// Keystrokes for one sentence: per syllable the symbol keys (ㄣ slipped
    /// to ㄥ with probability `slip`, a noticed slip followed by Backspace
    /// and the right key), then the tone key.
    private func strokes(_ readings: String, slip: Double, notice: Double,
                         rng: inout SplitMix64) -> (keys: [String], slipped: Bool) {
        var reverse: [String: String] = [:]
        for (key, symbol) in ZhuyinKeyboard.symbols { reverse[symbol] = key }
        var out: [String] = []
        var slipped = false
        for syllable in readings.split(separator: " ") {
            var tone = " "
            for char in syllable {
                if let key = Self.toneKeys[char] { tone = key; continue }
                let right = reverse[String(char)]!
                if char == "ㄣ", Double.random(in: 0..<1, using: &rng) < slip {
                    out.append(reverse["ㄥ"]!)
                    if Double.random(in: 0..<1, using: &rng) < notice {
                        out += ["⌫", right]
                    } else {
                        slipped = true
                    }
                } else {
                    out.append(right)
                }
            }
            out.append(tone)
        }
        return (out, slipped)
    }

    private func press(_ keys: [String], _ session: InputSession) {
        for key in keys {
            switch key {
            case "⌫": _ = session.handle(KeyEvent(.backspace))
            case " ": _ = session.handle(KeyEvent(.space, text: " "))
            default: _ = session.handle(KeyEvent(.character(key), text: key))
            }
        }
    }

    private struct Run {
        var firstPassSlipped = 0, slippedTotal = 0
        var keptExact = 0, exactTotal = 0
        var cost: Double?
    }

    /// Train on `dev` for `epochs` (slip rate per phase), then score
    /// `holdout` first-pass with learning frozen.
    private func run(decoder: LexiconDecoder, learn: Bool, phases: [(slip: Double, epochs: Int)],
                     notice: Double, dev: [(text: String, readings: String)],
                     holdout: [(text: String, readings: String)], evalSlip: Double, seed: UInt64) -> Run {
        var settings = SessionSettings(channelLearning: learn)
        let engine = InputEngine(decoder: decoder, settings: { settings })
        let session = InputSession(engine: engine)
        let host = Host()
        session.host = host
        var rng = SplitMix64(state: seed)
        for phase in phases {
            for _ in 0..<phase.epochs {
                for sentence in dev.shuffled(using: &rng) {
                    let typed = strokes(sentence.readings, slip: phase.slip, notice: notice, rng: &rng)
                    press(typed.keys, session)
                    let view = session.view
                    if view.preedit != sentence.text, let index = view.candidates.firstIndex(of: sentence.text) {
                        session.pick(at: index)
                    }
                    _ = session.handle(KeyEvent(.enter, text: "\r"))
                }
            }
        }
        var result = Run()
        result.cost = engine.channelLearner.model?.substitutions["/"]?["p"]
        // Frozen evaluation: no commits, so nothing more is learned.
        for sentence in holdout {
            let typed = strokes(sentence.readings, slip: sentence.readings.contains("ㄣ") ? evalSlip : 0,
                                notice: 0, rng: &rng)
            press(typed.keys, session)
            let right = session.view.preedit == sentence.text
            _ = session.handle(KeyEvent(.escape))
            if typed.slipped {
                result.slippedTotal += 1
                result.firstPassSlipped += right ? 1 : 0
            } else if sentence.readings.contains("ㄥ") {
                result.exactTotal += 1
                result.keptExact += right ? 1 : 0
            }
        }
        settings.channelLearning = false
        return result
    }

    func testLearningSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISSTYPE_CHANNEL_SWEEP"] == nil, "measurement; set MISSTYPE_CHANNEL_SWEEP=1")
        let decoder = try realDecoder()
        let epochs = environment["MISSTYPE_CHANNEL_EPOCHS"].flatMap(Int.init) ?? 6
        let all = ChannelSweepTests.sentences
        let split = try XCTUnwrap(all.firstIndex { $0.text == "我先去洗澡" })
        let dev = Array(all[..<split]), holdout = Array(all[split...])
        // Holdout slips: every ㄣ slipped, 5 seeds, so each arm sees the same.
        let users: [(name: String, phases: [(slip: Double, epochs: Int)])] = [
            ("never slips", [(0, epochs)]),
            ("slip 10%", [(0.1, epochs)]),
            ("slip 30%", [(0.3, epochs)]),
            ("slip 60%", [(0.6, epochs)]),
            ("30% then 0%", [(0.3, epochs), (0, epochs * 4)]),
        ]
        var out = "\nchannel learning replay: \(dev.count) dev sentences x \(epochs) epochs, \(holdout.count) holdout, notice 30%\n"
        out += "user            arm      | learned ㄥ→ㄣ | holdout slipped first-pass | holdout exact ㄥ kept\n"
        for user in users {
            for learn in [false, true] {
                var total = Run()
                var costs: [String] = []
                for seed in 0..<5 as Range<UInt64> {
                    let run = run(decoder: decoder, learn: learn, phases: user.phases, notice: 0.3,
                                  dev: dev, holdout: holdout, evalSlip: 1.0, seed: seed &* 7919 &+ 17)
                    total.firstPassSlipped += run.firstPassSlipped
                    total.slippedTotal += run.slippedTotal
                    total.keptExact += run.keptExact
                    total.exactTotal += run.exactTotal
                    costs.append(run.cost.map { String(format: "%.1f", $0) } ?? "-")
                }
                func pct(_ n: Int, _ d: Int) -> String {
                    String(format: "%3d/%3d %5.1f%%", n, d, d == 0 ? 0 : Double(n) * 100 / Double(d))
                }
                out += user.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                    + (learn ? "learned " : "generic ")
                    + " | " + costs.joined(separator: ",").padding(toLength: 13, withPad: " ", startingAt: 0)
                    + " | \(pct(total.firstPassSlipped, total.slippedTotal))            | \(pct(total.keptExact, total.exactTotal))\n"
            }
        }
        decoder.channel = nil
        print(out)
    }
}
