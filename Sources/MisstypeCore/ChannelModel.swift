import Foundation

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
