import Foundation

/// Builds the shipping decoder from a resource directory, identically on
/// every platform (macOS: the app bundle's Resources; Linux: e.g.
/// /usr/share/mistype). Adapters only say where the files live.
///
/// - lexicon.tsv (required): `script/prepare_lexicon.py` output.
/// - local_phrases.tsv (optional): curated high-frequency words missing
///   upstream. Same shape, concatenated — one parse path, first-class
///   entries. Missing file means empty.
/// - toneless.tsv (optional; `prepare_lexicon.py --word-frequency`):
///   toneless single-char order. Missing file = no override.
public enum LexiconLoader {
    /// 0.5 per word: measured on held-out Common Voice zh-TW (+18/-3 of
    /// 800) and the synthetic battery (+1/-2); larger values fix more but
    /// break faster (1.5: +33/-15). MISTYPE_WORD_PENALTY overrides (dev).
    public static let defaultWordPenalty = 0.5

    /// Nil when lexicon.tsv is missing: callers must refuse to start rather
    /// than run a fixture decoder.
    public static func load(resourceDirectory: URL,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            log: (String) -> Void = { _ in }) -> LexiconDecoder? {
        // Experiment hook (dev only): MISTYPE_LEXICON=<tsv> replaces the
        // bundled lexicon and supplement (different score scale).
        if let path = environment["MISTYPE_LEXICON"],
           let data = try? String(contentsOfFile: path, encoding: .utf8) {
            log("Mistype: lexicon override \(path)")
            let toneless = environment["MISTYPE_TONELESS"]
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            return configure(LexiconDecoder(tsv: data, toneless: toneless), environment: environment, log: log)
        }
        func resource(_ name: String) -> String? {
            try? String(contentsOf: resourceDirectory.appendingPathComponent(name), encoding: .utf8)
        }
        guard let data = resource("lexicon.tsv") else { return nil }
        let supplement = resource("local_phrases.tsv") ?? ""
        let toneless = resource("toneless.tsv") ?? ""
        return configure(LexiconDecoder(tsv: data + "\n" + supplement, toneless: toneless),
                         environment: environment, log: log)
    }

    private static func configure(_ decoder: LexiconDecoder, environment: [String: String],
                                  log: (String) -> Void) -> LexiconDecoder {
        decoder.wordPenalty = environment["MISTYPE_WORD_PENALTY"].flatMap(Double.init) ?? defaultWordPenalty
        // Experiment hook (dev only, local file, never user input):
        // MISTYPE_BIGRAM=<ChiaKey bigrams.tsv> [MISTYPE_BIGRAM_WEIGHT=w].
        if let path = environment["MISTYPE_BIGRAM"],
           let tsv = try? String(contentsOfFile: path, encoding: .utf8) {
            let weight = environment["MISTYPE_BIGRAM_WEIGHT"].flatMap(Double.init) ?? 1.0
            decoder.contextBigrams = ContextBigrams(tsv: tsv, weight: weight)
            log("Mistype: bigram overlay \(path) rows=\(decoder.contextBigrams!.count) weight=\(weight)")
        }
        return decoder
    }
}
