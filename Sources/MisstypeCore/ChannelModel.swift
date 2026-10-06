import Foundation

/// How readily the decoder assumes a keyboard slip (issue #21): the generic
/// half of the noisy channel, picked by the user. Two levers:
/// - `costOffset` shifts every generic edit-repair tier (transpose 4,
///   substitute/phonetic 5, insert/delete 6) in the lexicon's log units,
///   i.e. scales the assumed slip rate by e^-offset;
/// - `repairsValidReadings` also tries neighbor/transpose/delete repairs on
///   syllables that already spell a real reading, inside multi-syllable
///   words only (by default only invalid syllables are repaired, so a slip
///   onto another real syllable is never undone except by phonetic
///   confusions).
/// Measured (`RepairStrengthSweepTests`, 80 sentences, toned, top-1 at a
/// 0/5/10/15% per-key slip rate): standard 87.5/63.1/37.3/24.8, strong
/// 86.2/65.8/42.5/29.2 at 2x decode time, light 87.5/61.7/34.8/23.5. None
/// changes any of 1000 frequent chars or words typed exactly. A cheaper
/// offset is not used: at -1 phonetic confusions overrode exact single
/// chars (屋→一, 呢→了). Tone tolerance and learned `ChannelModel` pairs are
/// separate and unaffected.
public enum RepairStrength: String, CaseIterable, Codable, Sendable {
    /// No edit repair (fuzzy off): exact and toneless readings only.
    case off
    /// Assumes ~7x (e^2) fewer slips: what you type wins unless it is no
    /// reading at all or the language evidence is overwhelming.
    case light
    case standard
    /// Also undoes slips onto another real syllable inside a word.
    case strong

    /// Added to generic repair costs.
    public var costOffset: Double {
        switch self {
        case .off, .standard, .strong: return 0
        case .light: return 2
        }
    }

    public var repairsValidReadings: Bool { self == .strong }
}

/// Per-user channel model: how THIS user mistypes, as opposed to the
/// language model (what text is likely). The generic repair tiers in
/// `LexiconDecoder.alternatives` price every user alike (phonetic confusion
/// 5.0 ≈ a slip rate of e^-5 ≈ 0.7%); a user who keeps typing ㄥ for ㄣ
/// deserves a cheaper ㄥ→ㄣ repair, and only that pair.
///
/// Costs are in the lexicon's natural-log units, so a pair's cost reads as
/// -ln P(typed | intended) relative to typing it right: a 10% slip rate is
/// ~2.3, 30% ~1.2. Pairs are directional (typed → intended) and ride along
/// always, like phonetic confusions, so a learned slip that lands on another
/// valid reading is still reached. Costs never go below `floor`, so exact
/// input keeps a margin and only language-model evidence can flip it.
///
/// nil on the decoder (the default) means byte-identical decode.
public struct ChannelModel: Codable, Equatable {
    /// Typed key → intended key → repair cost.
    public var substitutions: [String: [String: Double]]

    public static let floor = 0.5

    public init(substitutions: [String: [String: Double]] = [:]) {
        self.substitutions = substitutions
    }

    /// Learned substitutes for one typed key, nil when it has none.
    func substitutes(for typed: String) -> [String: Double]? {
        substitutions[typed]?.mapValues { max(Self.floor, $0) }
    }
}

/// One commit's evidence about how the user mistypes. Keys are physical
/// Zhuyin symbol keys; a pair means "typed `typed`, meant `intended`".
public struct ChannelEvidence: Equatable {
    public typealias Pair = (typed: String, intended: String)
    /// Intended symbol keys of every committed syllable (the opportunities).
    public var intended: [String] = []
    /// Substitutions the committed text repaired. `explicit` means the user
    /// picked that text; otherwise it only went unchallenged.
    public var repaired: [Pair] = []
    public var explicit = false
    /// One-key Backspace re-types (typed X, erased it, typed Y in its place).
    public var retypes: [Pair] = []
    /// Repairs the system made that the user undid by picking the text the
    /// keys spelled exactly — the system over-corrected.
    public var reverts: [Pair] = []

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        func same(_ x: [Pair], _ y: [Pair]) -> Bool {
            x.map { $0.typed + ">" + $0.intended } == y.map { $0.typed + ">" + $0.intended }
        }
        return a.intended == b.intended && a.explicit == b.explicit && same(a.repaired, b.repaired)
            && same(a.retypes, b.retypes) && same(a.reverts, b.reverts)
    }

    public var isEmpty: Bool { intended.isEmpty && retypes.isEmpty && reverts.isEmpty }
}

/// Learns `ChannelModel` costs from use. The system follows the user, but
/// more slowly than the user changes (design: project outline, Personal
/// channel model):
/// - a pair's target cost is -ln(slip rate): slips over opportunities (how
///   often the intended key was typed at all), smoothed toward the generic
///   rate and clamped to [learnedFloor, genericCost];
/// - every count decays with a half-life in committed syllables, so a habit
///   the user dropped fades back to the generic cost;
/// - a reverted repair is the strongest signal and cancels several slips; an
///   unchallenged repair counts only weakly (it may be unnoticed);
/// - learned costs never go below `learnedFloor` (~30% slip), so exact input
///   always beats a learned habit and precise typing stays a fallback;
/// - the published cost moves at most `stepDown` per commit toward cheaper
///   and `stepUp` toward generic, and only between compositions.
/// Local data: keys and counts, never text.
public struct ChannelLearner: Codable, Equatable {
    public static let genericCost = 5.0
    public static let learnedFloor = 1.2
    public static let halfLife = 3000.0
    public static let priorOpportunities = 50.0
    public static let retypeWeight = 1.0
    public static let pickedRepairWeight = 1.0
    public static let unchallengedRepairWeight = 0.25
    public static let revertWeight = 3.0
    public static let stepDown = 0.2
    public static let stepUp = 1.0

    /// Intended key → decayed count of committed syllables containing it.
    public private(set) var opportunities: [String: Double] = [:]
    /// Typed → intended → decayed slip weight.
    public private(set) var slips: [String: [String: Double]] = [:]
    /// Typed → intended → decayed revert weight.
    public private(set) var reverts: [String: [String: Double]] = [:]
    /// Typed → intended → cost currently published to the decoder.
    public private(set) var costs: [String: [String: Double]] = [:]

    public init() {}

    /// What the decoder uses; nil until some pair is cheaper than generic.
    public var model: ChannelModel? {
        let cheaper = costs.compactMapValues { row -> [String: Double]? in
            let kept = row.filter { $0.value < Self.genericCost }
            return kept.isEmpty ? nil : kept
        }
        return cheaper.isEmpty ? nil : ChannelModel(substitutions: cheaper)
    }

    /// Target cost of one pair from the current counts.
    public func target(typed: String, intended: String) -> Double {
        let slip = max(0, (slips[typed]?[intended] ?? 0)
            - Self.revertWeight * (reverts[typed]?[intended] ?? 0))
        let prior = Self.priorOpportunities
        let rate = (slip + prior * exp(-Self.genericCost)) / ((opportunities[intended] ?? 0) + prior)
        return min(Self.genericCost, max(Self.learnedFloor, -log(rate)))
    }

    public mutating func observe(_ evidence: ChannelEvidence) {
        guard !evidence.isEmpty else { return }
        let factor = pow(0.5, Double(max(1, evidence.intended.count)) / Self.halfLife)
        func decay(_ table: inout [String: [String: Double]]) {
            table = table.mapValues { $0.mapValues { $0 * factor } }
        }
        opportunities = opportunities.mapValues { $0 * factor }
        decay(&slips)
        decay(&reverts)
        func valid(_ pair: ChannelEvidence.Pair) -> Bool {
            pair.typed != pair.intended && ZhuyinKeyboard.symbols[pair.typed] != nil
                && ZhuyinKeyboard.symbols[pair.intended] != nil
        }
        for key in evidence.intended where ZhuyinKeyboard.symbols[key] != nil {
            opportunities[key, default: 0] += 1
        }
        let repairWeight = evidence.explicit ? Self.pickedRepairWeight : Self.unchallengedRepairWeight
        for pair in evidence.repaired where valid(pair) {
            slips[pair.typed, default: [:]][pair.intended, default: 0] += repairWeight
        }
        for pair in evidence.retypes where valid(pair) {
            slips[pair.typed, default: [:]][pair.intended, default: 0] += Self.retypeWeight
        }
        for pair in evidence.reverts where valid(pair) {
            reverts[pair.typed, default: [:]][pair.intended, default: 0] += 1
        }
        // Step every known pair toward its target; drop pairs back at
        // generic with nothing left to remember.
        var pairs = Set<String>()
        for (typed, row) in slips { for intended in row.keys { pairs.insert(typed + "\t" + intended) } }
        for (typed, row) in costs { for intended in row.keys { pairs.insert(typed + "\t" + intended) } }
        for pair in pairs {
            let parts = pair.split(separator: "\t").map(String.init)
            let (typed, intended) = (parts[0], parts[1])
            let current = costs[typed]?[intended] ?? Self.genericCost
            let goal = target(typed: typed, intended: intended)
            let next = goal < current ? max(goal, current - Self.stepDown) : min(goal, current + Self.stepUp)
            costs[typed, default: [:]][intended] = next
            if next >= Self.genericCost, (slips[typed]?[intended] ?? 0) < 0.01 {
                costs[typed]?[intended] = nil
                slips[typed]?[intended] = nil
                reverts[typed]?[intended] = nil
            }
        }
        costs = costs.filter { !$0.value.isEmpty }
        slips = slips.filter { !$0.value.isEmpty }
        reverts = reverts.filter { !$0.value.isEmpty }
    }

    /// Learned pairs as (typed symbol, intended symbol, cost), cheapest
    /// first: what a settings pane lists.
    public var learnedPairs: [(typed: String, intended: String, cost: Double)] {
        var pairs: [(typed: String, intended: String, cost: Double)] = []
        for (typed, row) in model?.substitutions ?? [:] {
            for (intended, cost) in row {
                pairs.append((ZhuyinKeyboard.symbols[typed] ?? typed, ZhuyinKeyboard.symbols[intended] ?? intended, cost))
            }
        }
        return pairs.sorted { a, b in
            a.cost == b.cost ? a.typed + a.intended < b.typed + b.intended : a.cost < b.cost
        }
    }

    /// `channel_model.json` beside the learned phrases.
    public static var defaultURL: URL {
        UserLexicon.defaultURL.deletingLastPathComponent().appendingPathComponent("channel_model.json")
    }

    public static func load(from url: URL = defaultURL) -> ChannelLearner {
        guard let data = try? Data(contentsOf: url),
              let learner = try? JSONDecoder().decode(ChannelLearner.self, from: data) else { return ChannelLearner() }
        return learner
    }

    public func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension LexiconDecoder {
    /// Intended symbol keys per syllable of `candidate` (nil where the text
    /// is no dictionary word, e.g. raw Bopomofo): the readings its words
    /// were decoded from, mapped back to keys.
    func intendedKeys(of candidate: SentenceCandidate) -> [[String]?] {
        var out = [[String]?](repeating: nil, count: candidate.syllables.count)
        let units = Array(candidate.text.utf16)
        var reverse: [String: String] = [:]
        for (key, symbol) in ZhuyinKeyboard.symbols { reverse[symbol] = key }
        for span in candidate.alignment where span.chars.upperBound <= units.count
            && span.syllables.upperBound <= candidate.syllables.count {
            let word = String(decoding: units[span.chars], as: UTF16.self)
            guard let path = readings(of: word, syllables: candidate.syllables, span: span.syllables) else { continue }
            for (offset, reading) in path.split(separator: "-").enumerated() {
                out[span.syllables.lowerBound + offset] = reading.compactMap { reverse[String($0)] }
            }
        }
        return out
    }

    /// The one-key substitution turning `typed` into `intended`, if that is
    /// all that differs.
    static func substitution(typed: [String], intended: [String]) -> ChannelEvidence.Pair? {
        guard typed.count == intended.count else { return nil }
        let diffs = typed.indices.filter { typed[$0] != intended[$0] }
        guard diffs.count == 1 else { return nil }
        return (typed[diffs[0]], intended[diffs[0]])
    }

    /// Evidence from one learning-grade commit. `unpicked` is the top
    /// candidate before the user's first explicit pick, when there was one.
    func channelEvidence(committed: SentenceCandidate, unpicked: SentenceCandidate?, explicit: Bool,
                         retypes: [ChannelEvidence.Pair]) -> ChannelEvidence {
        var evidence = ChannelEvidence()
        evidence.explicit = explicit
        evidence.retypes = retypes
        let typed = committed.syllables.map(\.keys)
        let intended = intendedKeys(of: committed)
        for (index, keys) in intended.enumerated() {
            guard let keys else { continue }
            evidence.intended += keys
            if let pair = Self.substitution(typed: typed[index], intended: keys) { evidence.repaired.append(pair) }
        }
        if let unpicked, unpicked.text != committed.text, unpicked.syllables.map(\.keys) == typed {
            for (index, keys) in intendedKeys(of: unpicked).enumerated() {
                guard let keys, intended[index] == typed[index],
                      let pair = Self.substitution(typed: typed[index], intended: keys) else { continue }
                evidence.reverts.append(pair)
            }
        }
        return evidence
    }
}
