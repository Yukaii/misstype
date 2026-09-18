import Foundation

/// Jev gateway policy (M4 follow-up): explicit opt-in remote assistance.
/// Offline is the baseline and the default: `enabled == false` means the
/// native adapter never attempts a gateway call and decode stays
/// byte-identical to the offline path. Even when enabled, an empty key
/// means "stay offline" — the gate, not the caller, enforces this.
///
/// - enabled: master switch (default false, UserDefaults-backed in the IME).
/// - allowRichContext: when false, the state sent on an explicit run carries
///   only the minimal decision inputs (raw keys, readings, candidate texts
///   with offline rank/score). When true, it may additionally carry the
///   richer alignment/diff/contract metadata the prompt-sweep harness found
///   useful as an explicit user signal (never a silent upgrade).
/// - apiKey: gateway key from Preferences (or env fallback at call sites);
///   presence is logged, value never is.
/// - model: gateway model id (default typesafe-ai/jev).
public struct JevConfig: Equatable, Sendable {
    public var enabled: Bool
    public var allowRichContext: Bool
    public var apiKey: String
    public var model: String

    public static let defaultModel = "typesafe-ai/jev"

    public init(enabled: Bool = false,
                allowRichContext: Bool = false,
                apiKey: String = "",
                model: String = defaultModel) {
        self.enabled = enabled
        self.allowRichContext = allowRichContext
        self.apiKey = apiKey
        self.model = model
    }

    /// Key presence only — never log the value.
    public var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Single gate the adapter checks: explicit enable AND a key present.
    /// Everything else (revision, deadline, battery verdict) is checked by
    /// the caller; this stays a pure policy predicate for testability.
    public var canAttempt: Bool {
        enabled && hasKey
    }

    /// Preferences key wins; empty falls back to the process environment so
    /// CLI runs (`AI_GATEWAY_API_KEY=... MistypeIME --decode ...`) work
    /// without persisting a secret in defaults.
    public static func resolveApiKey(preferencesKey: String,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if !preferencesKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferencesKey
        }
        return environment["AI_GATEWAY_API_KEY"] ?? ""
    }
}

/// Decision state serialized for an explicit Jev run. Mirrors the Python
/// harness (`tools/lm_choose.build_jev_state`) shape so experiments and any
/// future native caller share one contract:
///
/// - minimal (allowRichContext == false): raw keys, syllable evidence,
///   candidate texts with offline provenance (rank/score/repairs), optional
///   explicit user context + matching local preferences.
/// - rich: additionally per-candidate phonetic alignment, diff vs
///   candidate 1, and the decoder contract.
///
/// No network happens here — this is pure data shaping behind the gate.
public enum JevState {
    public struct Evidence: Equatable, Sendable {
        public var base: String
        public var tone: String?
        public init(base: String, tone: String?) {
            self.base = base
            self.tone = tone
        }
    }

    public static func build(rawKeys: String,
                             evidence: [Evidence],
                             candidates: [(text: String, score: Double, repairs: Int, unresolved: Int)],
                             userContext: String = "",
                             userPreferences: [[String: String]] = [],
                             richContext: Bool = false) -> [String: Any] {
        var rows: [[String: Any]] = []
        let baseline = candidates.first?.text ?? ""
        for (index, candidate) in candidates.enumerated() {
            var row: [String: Any] = [
                "index": index + 1,
                "text": candidate.text,
                "rank": index + 1,
                "score": candidate.score,
                "repairs": candidate.repairs,
                "unresolved": candidate.unresolved,
            ]
            if richContext {
                row["phonetic_alignment"] = alignment(text: candidate.text, evidence: evidence)
                row["diff_from_candidate_1"] = diff(text: candidate.text, baseline: baseline)
            }
            rows.append(row)
        }
        var state: [String: Any] = [
            "phonetic_input": [
                "raw_keys": rawKeys,
                "syllables": evidence.map { ["base": $0.base, "tone": $0.tone as Any] },
            ],
            "candidates": rows,
            "user_context": userContext.isEmpty ? NSNull() : userContext,
            "user_preferences": userPreferences,
        ]
        if richContext {
            state["decoder_contract"] = [
                "input_mode": "bopomofo_zhuyin",
                "stage": "completed_delayed_phrase",
                "tone_policy": "explicit tones are evidence; absent tones remain uncertain",
                "selection_goal": "recover user intent, not generic text frequency",
                "candidate_rank_is_offline_provenance": true,
            ]
        }
        return state
    }

    private static func alignment(text: String, evidence: [Evidence]) -> [String: Any] {
        let chars = Array(text)
        let matched = 0
        var cells: [[String: Any]] = []
        for (index, item) in evidence.enumerated() {
            let char: String? = index < chars.count ? String(chars[index]) : nil
            // Native core has no char→base table; report the structural
            // shape (length/position) and leave base matching to a caller
            // with lexicon access. Rich flag gates verbosity, not verdicts.
            cells.append([
                "position": index + 1,
                "char": char as Any,
                "input_base": item.base,
                "input_tone": item.tone as Any,
            ])
        }
        return [
            "length_match": chars.count == evidence.count,
            "matched_bases": matched,
            "syllable_count": evidence.count,
            "characters": cells,
        ]
    }

    private static func diff(text: String, baseline: String) -> [[String: Any]] {
        let left = Array(baseline), right = Array(text)
        var out: [[String: Any]] = []
        for index in 0..<max(left.count, right.count) {
            let l: String? = index < left.count ? String(left[index]) : nil
            let r: String? = index < right.count ? String(right[index]) : nil
            if l != r {
                out.append(["position": index + 1, "offline": l as Any, "candidate": r as Any])
            }
        }
        return out
    }
}
