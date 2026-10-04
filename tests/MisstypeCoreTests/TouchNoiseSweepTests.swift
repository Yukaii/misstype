import XCTest
@testable import MisstypeCore

/// Seeded jitter sweep of the touch layer on the REAL lexicon (M3).
/// Measurement, not a gate: skipped unless MISSTYPE_TOUCH_SWEEP is set.
///
///   python3 script/prepare_lexicon.py   # once (.cache/, never committed)
///   MISSTYPE_TOUCH_SWEEP=1 swift test --filter TouchNoiseSweepTests
///   (optional: MISSTYPE_TOUCH_SEEDS=50, MISSTYPE_TOUCH_SCALE=10, MISSTYPE_TOUCH_BEAM=16,
///    MISSTYPE_TOUCH_COMBOS=24, MISSTYPE_TOUCH_REPAIR_COMBOS=4,
///    MISSTYPE_TOUCH_RADII=0,0.08,0.1; add `-c release -Xswiftc -enable-testing`
///    for latency numbers that mean anything)
///
/// Each probe taps every key centre with uniform-disk jitter of radius r
/// (normalized units, clamped to the surface), then decodes five ways:
///   A       nearest key, no edit repair        (a bare touch keyboard)
///   B       nearest key + keyboard edit repair (what the IME does today)
///   Beam    16 whole-phrase key sequences + repair (v1)
///   Lat     (repairCombos 1: nearest key only)
///   Lat+R   lattice, edit repair on the cheapest `repairCombos` combos
///   Lat-nr  lattice without edit repair
/// B vs Lat is the honest question: does coordinate evidence add anything the
/// keyboard repair does not already give.
final class TouchNoiseSweepTests: XCTestCase {
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

    private static let probes: [(name: String, keys: String, expected: String)] = [
        ("ni-hao", "su3cl3", "你好"),
        ("zao-shang-hao", "yl3g;4cl3", "早上好"),
        ("wo-shi-xue-sheng", "ji3g4vm,6g/", "我是學生"),
        ("dada", "hk4g4u6vu84cjo41j6cjo42832jo4", "測試一下會不會打對"),
    ]
    private static let defaultRadii = [0.0, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]

    private func realDecoder() throws -> LexiconDecoder {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touch-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
    }

    private func taps(_ keys: String, radius: Double, seed: UInt64) throws -> [TouchHypothesis] {
        var rng = SplitMix64(state: seed)
        return try keys.map { char in
            let p = try XCTUnwrap(TouchLayout.position(of: String(char)))
            var x = p.x, y = p.y
            if radius > 0 {
                let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
                let distance = radius * Double.random(in: 0..<1, using: &rng).squareRoot()
                x = min(1, max(0, x + distance * cos(angle)))
                y = min(1, max(0, y + distance * sin(angle)))
            }
            return try XCTUnwrap(TouchMapper.hypothesis(surface: p.surface, x: x, y: y))
        }
    }

    func testSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISSTYPE_TOUCH_SWEEP"] == nil, "measurement; set MISSTYPE_TOUCH_SWEEP=1")
        let decoder = try realDecoder()
        let seeds = environment["MISSTYPE_TOUCH_SEEDS"].flatMap(Int.init) ?? 50
        let scale = environment["MISSTYPE_TOUCH_SCALE"].flatMap(Double.init) ?? TouchDecoding.defaultSpatialScale
        let beam = environment["MISSTYPE_TOUCH_BEAM"].flatMap(Int.init) ?? TouchDecoding.defaultBeam
        let combos = environment["MISSTYPE_TOUCH_COMBOS"].flatMap(Int.init) ?? TouchDecoding.defaultCombosPerSlice
        let repairCombos = environment["MISSTYPE_TOUCH_REPAIR_COMBOS"].flatMap(Int.init) ?? TouchDecoding.defaultRepairCombos
        let radii = environment["MISSTYPE_TOUCH_RADII"]
            .map { $0.split(separator: ",").compactMap { Double($0) } } ?? Self.defaultRadii
        var exactInputDiffers = 0
        var out = "\ntouch sweep: real lexicon, \(seeds) seeds/cell, spatialScale \(scale), beam \(beam)\n"
        out += "probe              radius |      A |      B |   Beam |    Lat | Lat+R | Lat-nr || B top8 | Lat top8 | Beam ms | Lat ms | Lat+R ms\n"
        typealias Arm = (name: String, run: ([TouchHypothesis]) -> [TouchCandidate])
        let arms: [Arm] = [
            ("A", { decoder.decodeTouch($0, spatial: false, fuzzy: false) }),
            ("B", { decoder.decodeTouch($0, spatial: false, fuzzy: true) }),
            ("Beam", { decoder.decodeTouchBeam($0, spatial: true, fuzzy: true, spatialScale: scale, beam: beam) }),
            ("Lat", { decoder.decodeTouch($0, spatial: true, fuzzy: true, spatialScale: scale, combosPerSlice: combos, repairCombos: 1) }),
            ("Lat+R", { decoder.decodeTouch($0, spatial: true, fuzzy: true, spatialScale: scale, combosPerSlice: combos, repairCombos: repairCombos) }),
            ("Lat-nr", { decoder.decodeTouch($0, spatial: true, fuzzy: false, spatialScale: scale) }),
        ]
        for probe in Self.probes {
            for radius in radii {
                var top1 = [Int](repeating: 0, count: arms.count), top8 = top1
                var millis = [Double](repeating: 0, count: arms.count)
                for seed in 0..<seeds {
                    let sequence = try taps(probe.keys, radius: radius,
                                            seed: UInt64(seed) &* 7919 &+ UInt64(probe.keys.count))
                    var firsts: [String?] = []
                    for (index, arm) in arms.enumerated() {
                        let started = Date()
                        let result = arm.run(sequence)
                        millis[index] += Date().timeIntervalSince(started) * 1000
                        top1[index] += result.first?.text == probe.expected ? 1 : 0
                        top8[index] += result.prefix(8).contains { $0.text == probe.expected } ? 1 : 0
                        firsts.append(result.first?.text)
                    }
                    if radius == 0, firsts[1] != firsts[3] { exactInputDiffers += 1 }
                }
                func pct(_ n: Int) -> String { String(format: "%5.0f%%", Double(n) * 100 / Double(seeds)) }
                out += probe.name.padding(toLength: 18, withPad: " ", startingAt: 0)
                    + String(format: " %5.2f |", radius)
                    + " \(pct(top1[0])) | \(pct(top1[1])) | \(pct(top1[2])) | \(pct(top1[3])) | \(pct(top1[4])) | \(pct(top1[5])) ||"
                    + " \(pct(top8[1])) |  \(pct(top8[3]))   |"
                    + String(format: " %7.1f | %6.1f | %6.1f\n", millis[2] / Double(seeds), millis[3] / Double(seeds), millis[4] / Double(seeds))
            }
        }
        out += "exact input (r=0): Lat differs from B in \(exactInputDiffers) of \(Self.probes.count * seeds) traces\n"
        print(out)
    }

    /// Break-even between a keyboard typist and a touch typist, no human data
    /// needed: for per-key slip rate p on a physical keyboard (neighbor
    /// substitution, decoded as B = what the IME does today) find the tap
    /// spread r at which touch + lattice decoding matches it. Averaged over
    /// the probes. The result is a TARGET for a real tap-spread measurement,
    /// not evidence that users reach it.
    func testBreakEven() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISSTYPE_TOUCH_SWEEP"] == nil, "measurement; set MISSTYPE_TOUCH_SWEEP=1")
        let decoder = try realDecoder()
        let seeds = environment["MISSTYPE_TOUCH_SEEDS"].flatMap(Int.init) ?? 40
        let slips = [0.01, 0.02, 0.04, 0.08]
        let radii = [0.04, 0.06, 0.08, 0.10, 0.12, 0.14]
        func keyboardRate(_ p: Double) throws -> Double {
            var hits = 0, total = 0
            for probe in Self.probes {
                for seed in 0..<seeds {
                    var rng = SplitMix64(state: UInt64(seed) &* 104_729 &+ UInt64(probe.keys.count) &+ UInt64(p * 1000))
                    var keys = Array(probe.keys).map(String.init)
                    for index in keys.indices where ZhuyinKeyboard.symbols[keys[index]] != nil
                        && Double.random(in: 0..<1, using: &rng) < p {
                        if let near = ZhuyinKeyboard.neighbors(of: keys[index]).first {
                            keys[index] = near
                        }
                    }
                    var composition = Composition()
                    for key in keys { composition.append(key) }
                    let top = decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending,
                                                     fuzzy: true).first?.text
                    hits += top == probe.expected ? 1 : 0
                    total += 1
                }
            }
            return Double(hits) / Double(total)
        }
        func touchRate(_ r: Double) throws -> Double {
            var hits = 0, total = 0
            for probe in Self.probes {
                for seed in 0..<seeds {
                    let sequence = try taps(probe.keys, radius: r, seed: UInt64(seed) &* 7919 &+ UInt64(probe.keys.count))
                    hits += decoder.decodeTouch(sequence).first?.text == probe.expected ? 1 : 0
                    total += 1
                }
            }
            return Double(hits) / Double(total)
        }
        var out = "\nbreak-even (mean sentence top-1 over \(Self.probes.count) probes, \(seeds) seeds)\n"
        out += "touch + lattice by tap spread r:  "
        let touch = try radii.map { try touchRate($0) }
        for (r, rate) in zip(radii, touch) { out += String(format: "r=%.2f %3.0f%%  ", r, rate * 100) }
        out += "\nkeyboard + repair by per-key slip p:  "
        for p in slips { out += String(format: "p=%.0f%% %3.0f%%  ", p * 100, try keyboardRate(p) * 100) }
        out += "\n"
        print(out)
    }
}
