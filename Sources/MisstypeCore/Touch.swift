import Foundation

/// Touch/spatial fuzzy layer (M2/M3 port of `src/misstype/touch.py`).
///
/// A tap is a raw `(x, y)` on one of two surfaces. The mapper turns it into
/// distance-ranked key hypotheses; `decodeTouch` expands those into a bounded
/// set of key sequences, decodes each through the shipping decoder, and
/// charges the spatial cost of every non-nearest choice. The raw coordinates
/// stay the evidence; keys are a reconstruction.
public enum TouchSurface: String, Sendable, Codable {
    case left, right
}

/// Versioned split layout. Normalized [0, 1] per surface. Legacy compact
/// positions are preserved exactly so old traces replay (same table as
/// `touch.py`, `full-split-1`).
public enum TouchLayout {
    public static let version = "full-split-1"

    public static let left: [String: (x: Double, y: Double)] = [
        "1": (0.15, 0.20), "q": (0.30, 0.20), "a": (0.30, 0.50), "z": (0.30, 0.80),
        "2": (0.50, 0.20), "w": (0.50, 0.50), "s": (0.50, 0.80),
        "3": (0.70, 0.10), "4": (0.88, 0.10),
        "e": (0.70, 0.23), "r": (0.88, 0.23),
        "d": (0.70, 0.36), "f": (0.88, 0.36),
        "c": (0.70, 0.49), "v": (0.88, 0.49),
        "x": (0.70, 0.62), "g": (0.88, 0.62),
        "5": (0.70, 0.75), "b": (0.88, 0.75),
        "t": (0.70, 0.88),
    ]
    public static let right: [String: (x: Double, y: Double)] = [
        "8": (0.15, 0.20), "i": (0.30, 0.20), "k": (0.30, 0.50), ",": (0.30, 0.80),
        "9": (0.50, 0.20), "o": (0.50, 0.50), "l": (0.50, 0.80),
        "6": (0.70, 0.10), "7": (0.88, 0.10),
        "y": (0.70, 0.23), "u": (0.88, 0.23),
        "h": (0.70, 0.36), "j": (0.88, 0.36),
        "n": (0.70, 0.49), "m": (0.88, 0.49),
        "0": (0.70, 0.62), "/": (0.88, 0.62),
        "p": (0.70, 0.75), ".": (0.88, 0.75),
        ";": (0.70, 0.88), "-": (0.88, 0.88),
    ]

    public static func keys(on surface: TouchSurface) -> [String: (x: Double, y: Double)] {
        surface == .left ? left : right
    }

    /// Surface and centre of a physical key; nil when the key is not on the layout.
    public static func position(of key: String) -> (surface: TouchSurface, x: Double, y: Double)? {
        if let p = left[key] { return (.left, p.x, p.y) }
        if let p = right[key] { return (.right, p.x, p.y) }
        return nil
    }
}

/// One tap, mapped: key hypotheses nearest first. Includes tone keys (they
/// are exact evidence, never substituted for Zhuyin keys; see `decodeTouch`).
public struct TouchHypothesis: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let distance: Double
        /// `max(0.1, 1 - 1.5 d)`, the same weight the Python payload carries.
        public let weight: Double
    }
    public let surface: TouchSurface
    public let x: Double
    public let y: Double
    /// Nearest key first, then up to `TouchMapper.neighborCount` more.
    public let ranked: [Candidate]

    public var key: String { ranked[0].key }
    public var confidence: Double { ranked[0].weight }
}

public enum TouchMapper {
    /// Neighbors beyond the nearest key that travel with a tap.
    public static let neighborCount = 4

    public static func weight(distance: Double) -> Double {
        max(0.1, 1.0 - distance * 1.5)
    }

    /// Nil when the point is outside the normalized surface (Python raises).
    public static func hypothesis(surface: TouchSurface, x: Double, y: Double) -> TouchHypothesis? {
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        var all: [TouchHypothesis.Candidate] = []
        for (key, p) in TouchLayout.keys(on: surface) {
            let distance: Double = hypot(x - p.x, y - p.y)
            all.append(TouchHypothesis.Candidate(key: key, distance: distance,
                                                 weight: weight(distance: distance)))
        }
        all.sort { (a: TouchHypothesis.Candidate, b: TouchHypothesis.Candidate) -> Bool in
            a.distance == b.distance ? a.key < b.key : a.distance < b.distance
        }
        return TouchHypothesis(surface: surface, x: x, y: y,
                               ranked: Array(all.prefix(neighborCount + 1)))
    }
}

public struct TouchCandidate: Equatable {
    public let sentence: SentenceCandidate
    /// The key sequence this reading assumes (tones included).
    public let keys: [String]
    /// Penalty for the taps assigned to a key other than the nearest.
    public let spatialCost: Double

    public var text: String { sentence.text }
    /// Decoder score minus spatial cost; candidates rank by this.
    public var score: Double { sentence.score - spatialCost }
}

public enum TouchDecoding {
    /// Score points per unit of normalized distance beyond the nearest key.
    /// Swept 2026-10-04 on the real lexicon (r 0.08–0.12, 4 probes): 5 and 10
    /// tie, 20 is slightly worse, 40 and 80 clearly worse (ni-hao r=0.10 top-1
    /// 82% / 82% / 80% / 77% / 63%). Past the tie the decoder's own score
    /// decides, which is the point: distance only breaks near-ties.
    public static let defaultSpatialScale = 10.0
    public static let defaultBeam = 16
    public static let defaultCombosPerSlice = 24
    /// Cheapest key combinations per slice that also get keyboard edit repair
    /// (pass 2). Repair is costly on non-viable readings, so this stays small.
    public static let defaultRepairCombos = 4
}

extension LexiconDecoder {
    /// Beam version (v1, kept as the measured baseline): enumerates at most
    /// `beam` whole-phrase key sequences and decodes each. Cost grows with the
    /// beam and still misses the truth on long phrases; see `decodeTouch`.
    /// Decode a finished tap sequence. With `spatial: false` only the nearest
    /// key of each tap is used (conventional-keyboard behavior; keyboard edit
    /// repair still follows `fuzzy`). A tap whose nearest key is a tone key
    /// stays exact, and tone keys never appear as substitutes for Zhuyin
    /// taps — the Python behavior, kept for parity.
    public func decodeTouchBeam(_ taps: [TouchHypothesis], spatial: Bool = true,
                            fuzzy: Bool = true, toneTolerance: Bool = true,
                            spatialScale: Double = TouchDecoding.defaultSpatialScale,
                            beam: Int = TouchDecoding.defaultBeam,
                            userLexicon: UserLexicon? = nil) -> [TouchCandidate] {
        guard !taps.isEmpty else { return [] }
        var sequences: [(keys: [String], cost: Double)] = [([], 0)]
        for tap in taps {
            var options: [(key: String, cost: Double)] = [(tap.key, 0)]
            if spatial, ZhuyinKeyboard.symbols[tap.key] != nil {
                let nearest = tap.ranked[0].distance
                for other in tap.ranked.dropFirst() where ZhuyinKeyboard.symbols[other.key] != nil {
                    options.append((other.key, spatialScale * (other.distance - nearest)))
                }
            }
            var next: [(keys: [String], cost: Double)] = []
            for sequence in sequences {
                for option in options {
                    next.append((sequence.keys + [option.key], sequence.cost + option.cost))
                }
            }
            next.sort { $0.cost == $1.cost ? $0.keys.lexicographicallyPrecedes($1.keys) : $0.cost < $1.cost }
            sequences = Array(next.prefix(beam))
        }
        var best: [String: TouchCandidate] = [:]
        for sequence in sequences {
            var composition = Composition()
            for key in sequence.keys { composition.append(key) }
            let decoded = decodeSegments(composition.segments, pendingKeys: composition.parsed.pending,
                                         fuzzy: fuzzy, toneTolerance: toneTolerance,
                                         userLexicon: userLexicon)
            for sentence in decoded.prefix(4) {
                let candidate = TouchCandidate(sentence: sentence, keys: sequence.keys,
                                               spatialCost: sequence.cost)
                if let existing = best[sentence.text], existing.score >= candidate.score { continue }
                best[sentence.text] = candidate
            }
        }
        return best.values.sorted {
            $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score
        }.prefix(16).map { $0 }
    }
}

// MARK: - Lattice decode

extension LexiconDecoder {
    private struct TouchSlice {
        let syllable: Syllable
        let options: [ReadingOption]
    }

    /// Lattice version: spatial hypotheses are priced inside each syllable's
    /// reading options, so the decoder's own beam weighs them against the
    /// language score and no whole-phrase key sequence is ever enumerated.
    /// A syllable slice of `n` taps offers every reading reachable from the
    /// cheapest 24 key combinations (cost `spatialScale x sum(d - d_nearest)`,
    /// one correction when any tap left its nearest key). Keyboard edit repair
    /// (`fuzzy`) applies, in a second pass that runs when the first leaves
    /// unresolved text or repairs, to the `repairCombos` cheapest combinations
    /// of each slice (a tone tap that landed on a Zhuyin key needs one spatial
    /// swap AND a deletion), which keeps the cost bounded. Tone taps
    /// stay exact, as in the beam version. `TouchCandidate.spatialCost` is 0
    /// here: the cost is already inside `sentence.score`.
    public func decodeTouch(_ taps: [TouchHypothesis], spatial: Bool = true,
                            fuzzy: Bool = true, toneTolerance: Bool = true,
                            spatialScale: Double = TouchDecoding.defaultSpatialScale,
                            combosPerSlice: Int = TouchDecoding.defaultCombosPerSlice,
                            repairCombos: Int = TouchDecoding.defaultRepairCombos,
                            alwaysRepair: Bool = false,
                            userLexicon: UserLexicon? = nil) -> [TouchCandidate] {
        guard !taps.isEmpty else { return [] }
        let tapOptions: [[(key: String, cost: Double)]] = taps.map { tap in
            var options: [(key: String, cost: Double)] = [(tap.key, 0)]
            if spatial, ZhuyinKeyboard.symbols[tap.key] != nil {
                let nearest = tap.ranked[0].distance
                for other in tap.ranked.dropFirst() where ZhuyinKeyboard.symbols[other.key] != nil {
                    options.append((other.key, spatialScale * (other.distance - nearest)))
                }
            }
            return options
        }
        // Tone taps close a run of Zhuyin taps; a trailing run stays toneless.
        var runs: [(range: Range<Int>, tone: String?)] = []
        var runStart: Int?
        for (index, tap) in taps.enumerated() {
            if ZhuyinKeyboard.symbols[tap.key] != nil {
                if runStart == nil { runStart = index }
            } else if let tone = ZhuyinKeyboard.tones[tap.key], let start = runStart {
                runs.append((start..<index, tone))
                runStart = nil
            }
        }
        if let start = runStart { runs.append((start..<taps.count, nil)) }

        var cache: [String: [ReadingOption]] = [:]
        func sliceOptions(_ range: Range<Int>, tone: String?, repairNearest: Bool) -> [ReadingOption] {
            let id = "\(range.lowerBound)-\(range.upperBound)-\(repairNearest)-\(tone ?? "~")"
            if let hit = cache[id] { return hit }
            var combos: [(keys: [String], cost: Double)] = [([], 0)]
            for index in range {
                var next: [(keys: [String], cost: Double)] = []
                for combo in combos {
                    for option in tapOptions[index] { next.append((combo.keys + [option.key], combo.cost + option.cost)) }
                }
                next.sort { $0.cost == $1.cost ? $0.keys.lexicographicallyPrecedes($1.keys) : $0.cost < $1.cost }
                combos = Array(next.prefix(combosPerSlice))
            }
            let nearestKeys = range.map { taps[$0].key }
            var merged: [String: (cost: Double, correction: Int, wordOnly: Bool)] = [:]
            for (rank, combo) in combos.enumerated() {
                let isNearest = combo.keys == nearestKeys
                let syllable = Syllable(keys: combo.keys, tone: tone)
                for (reading, cost, correction, wordOnly) in alternatives(syllable, fuzzy: repairNearest && rank < repairCombos,
                                                                 toneTolerance: toneTolerance) {
                    let total = cost + combo.cost
                    if let existing = merged[reading], existing.cost <= total { continue }
                    merged[reading] = (total, correction + (isNearest ? 0 : 1), wordOnly)
                }
            }
            let result = merged.sorted { $0.value.cost == $1.value.cost ? $0.key < $1.key : $0.value.cost < $1.value.cost }
                .prefix(16).map { ($0.key, $0.value.cost, $0.value.correction, $0.value.wordOnly) }
            cache[id] = result
            return result
        }

        func segmentations(of run: (range: Range<Int>, tone: String?), repairNearest: Bool)
            -> [(slices: [TouchSlice], cost: Double)] {
            let lower = run.range.lowerBound, upper = run.range.upperBound
            var lattice = [[(slices: [TouchSlice], cost: Double)]](repeating: [], count: upper - lower + 1)
            lattice[0] = [([], 0)]
            for offset in 0..<(upper - lower) {
                lattice[offset].sort { $0.cost < $1.cost }
                lattice[offset] = Array(lattice[offset].prefix(24))
                guard !lattice[offset].isEmpty else { continue }
                for length in 1...min(4, upper - lower - offset) {
                    let range = (lower + offset)..<(lower + offset + length)
                    let tone = range.upperBound == upper ? run.tone : nil
                    let options = sliceOptions(range, tone: tone, repairNearest: repairNearest)
                    guard let cheapest = options.first?.1 else { continue }
                    let slice = TouchSlice(syllable: Syllable(keys: range.map { taps[$0].key }, tone: tone),
                                           options: options)
                    for prefix in lattice[offset].prefix(8) {
                        lattice[offset + length].append((prefix.slices + [slice], prefix.cost + cheapest))
                        if lattice[offset + length].count >= 64 { break }
                    }
                }
            }
            let done = lattice[upper - lower].sorted { $0.cost < $1.cost }
            if !done.isEmpty { return Array(done.prefix(12)) }
            // Nothing segments: keep the nearest keys raw, one slice per tap.
            let raw = run.range.map { index in
                TouchSlice(syllable: Syllable(keys: [taps[index].key],
                                              tone: index == upper - 1 ? run.tone : nil), options: [])
            }
            return [(raw, 100)]
        }

        func decodeAll(repairNearest: Bool) -> [SentenceCandidate] {
            var overall: [(slices: [TouchSlice], cost: Double)] = [([], 0)]
            for run in runs {
                let options = segmentations(of: run, repairNearest: repairNearest).prefix(6)
                var next: [(slices: [TouchSlice], cost: Double)] = []
                for prefix in overall {
                    for option in options { next.append((prefix.slices + option.slices, prefix.cost + option.cost)) }
                }
                next.sort { $0.cost < $1.cost }
                overall = Array(next.prefix(12))
            }
            var found: [SentenceCandidate] = []
            for segmentation in overall where !segmentation.slices.isEmpty {
                found += decode(segmentation.slices.map(\.syllable),
                                options: segmentation.slices.map(\.options), userLexicon: userLexicon)
            }
            return found
        }

        var sentences = decodeAll(repairNearest: false)
        func best(_ list: [SentenceCandidate]) -> SentenceCandidate? {
            list.max { $0.score == $1.score ? $0.text > $1.text : $0.score < $1.score }
        }
        if fuzzy, alwaysRepair || (best(sentences).map({ $0.unresolved > 0 || $0.repairs > 0 }) ?? true) {
            sentences += decodeAll(repairNearest: true)
        }
        var byText: [String: SentenceCandidate] = [:]
        for sentence in sentences where byText[sentence.text].map({ $0.score < sentence.score }) ?? true {
            byText[sentence.text] = sentence
        }
        let nearestKeys = taps.map(\.key)
        return byText.values.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .prefix(16).map { TouchCandidate(sentence: $0, keys: nearestKeys, spatialCost: 0) }
    }
}
