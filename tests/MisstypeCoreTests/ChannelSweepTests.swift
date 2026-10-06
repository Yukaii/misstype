import XCTest
@testable import MisstypeCore

/// Personal channel model, oracle sweep on the REAL lexicon. Measurement,
/// not a gate: skipped unless MISSTYPE_CHANNEL_SWEEP is set.
///
///   python3 script/prepare_lexicon.py   # once (.cache/, never committed)
///   MISSTYPE_CHANNEL_SWEEP=1 swift test --filter ChannelSweepTests
///   (optional: MISSTYPE_CHANNEL_WORDS=300)
///
/// Hypothesis: a user who systematically types ㄥ for ㄣ is served better by
/// a cheaper personal ㄥ→ㄣ repair than by the generic 5.0, without flipping
/// genuine ㄥ input. Synthetic user: every ㄣ is typed as ㄥ (key `/` for
/// `p`). Probes are the most frequent single chars, 2-4 syllable words and
/// the cursor_replay sentences, typed toned and toneless; only probes whose exact typing
/// already decodes top-1 count, so the arms isolate the channel.
///   recovered  slipped ㄣ probes decoded right (higher is better)
///   kept       exact ㄥ probes still decoded right (the cost of the pair)
/// Falsified if no cost recovers more than it loses for a heavy-slip user.
final class ChannelSweepTests: XCTestCase {
    /// tools/cursor_replay.py dev + holdout, readings as it derives them.
    static let sentences: [(text: String, readings: String)] = [
        ("測試一下會不會打對", "ㄘㄜˋ ㄕˋ ㄧ ㄒㄧㄚˋ ㄏㄨㄟˋ ㄅㄨˋ ㄏㄨㄟˋ ㄉㄚˇ ㄉㄨㄟˋ"),
        ("我今天要去買東西", "ㄨㄛˇ ㄐㄧㄣ ㄊㄧㄢ ㄧㄠˋ ㄑㄩˋ ㄇㄞˇ ㄉㄨㄥ ㄒㄧ"),
        ("這個問題很難回答", "ㄓㄜˋ ㄍㄜ˙ ㄨㄣˋ ㄊㄧˊ ㄏㄣˇ ㄋㄢˊ ㄏㄨㄟˊ ㄉㄚˊ"),
        ("明天下午開會", "ㄇㄧㄥˊ ㄊㄧㄢ ㄒㄧㄚˋ ㄨˇ ㄎㄞ ㄏㄨㄟˋ"),
        ("他說他不知道", "ㄊㄚ ㄕㄨㄛ ㄊㄚ ㄅㄨˋ ㄓ ㄉㄠˋ"),
        ("記得帶錢包", "ㄐㄧˋ ㄉㄜ˙ ㄉㄞˋ ㄑㄧㄢˊ ㄅㄠ"),
        ("回家要做作業", "ㄏㄨㄟˊ ㄐㄧㄚ ㄧㄠˋ ㄗㄨㄛˋ ㄗㄨㄛˋ ㄧㄝˋ"),
        ("語音辨識很準", "ㄩˇ ㄧㄣ ㄅㄧㄢˋ ㄕˋ ㄏㄣˇ ㄓㄨㄣˇ"),
        ("請幫我訂位", "ㄑㄧㄥˇ ㄅㄤ ㄨㄛˇ ㄉㄧㄥˋ ㄨㄟˋ"),
        ("你吃飯了嗎", "ㄋㄧˇ ㄔ ㄈㄢˋ ㄌㄜ˙ ㄇㄚ˙"),
        ("今天天氣不錯", "ㄐㄧㄣ ㄊㄧㄢ ㄊㄧㄢ ㄑㄧˋ ㄅㄨˋ ㄘㄨㄛˋ"),
        ("我們一起去看電影", "ㄨㄛˇ ㄇㄣ˙ ㄧ ㄑㄧˇ ㄑㄩˋ ㄎㄢˋ ㄉㄧㄢˋ ㄧㄥˇ"),
        ("這家店的東西很好吃", "ㄓㄜˋ ㄐㄧㄚ ㄉㄧㄢˋ ㄉㄜ˙ ㄉㄨㄥ ㄒㄧ ㄏㄣˇ ㄏㄠˇ ㄔ"),
        ("公司在市政府附近", "ㄍㄨㄥ ㄙ ㄗㄞˋ ㄕˋ ㄓㄥˋ ㄈㄨˇ ㄈㄨˋ ㄐㄧㄣˋ"),
        ("輸入法的選字體驗", "ㄕㄨ ㄖㄨˋ ㄈㄚˇ ㄉㄜ˙ ㄒㄩㄢˇ ㄗˋ ㄊㄧˇ ㄧㄢˋ"),
        ("全形符號", "ㄑㄩㄢˊ ㄒㄧㄥˊ ㄈㄨˊ ㄏㄠˋ"),
        ("他在公園散步", "ㄊㄚ ㄗㄞˋ ㄍㄨㄥ ㄩㄢˊ ㄙㄢˋ ㄅㄨˋ"),
        ("我想喝一杯咖啡", "ㄨㄛˇ ㄒㄧㄤˇ ㄏㄜ ㄧ ㄅㄟ ㄎㄚ ㄈㄟ"),
        ("這件事情很重要", "ㄓㄜˋ ㄐㄧㄢˋ ㄕˋ ㄑㄧㄥˊ ㄏㄣˇ ㄓㄨㄥˋ ㄧㄠˋ"),
        ("下雨天不打球", "ㄒㄧㄚˋ ㄩˇ ㄊㄧㄢ ㄅㄨˋ ㄉㄚˇ ㄑㄧㄡˊ"),
        ("會議記錄已經寄出", "ㄏㄨㄟˋ ㄧˋ ㄐㄧˋ ㄌㄨˋ ㄧˇ ㄐㄧㄥ ㄐㄧˋ ㄔㄨ"),
        ("我等一下再打給你", "ㄨㄛˇ ㄉㄥˇ ㄧ ㄒㄧㄚˋ ㄗㄞˋ ㄉㄚˇ ㄍㄟˇ ㄋㄧˇ"),
        ("這週末要不要去爬山", "ㄓㄜˋ ㄓㄡ ㄇㄛˋ ㄧㄠˋ ㄅㄨˊ ㄧㄠˋ ㄑㄩˋ ㄆㄚˊ ㄕㄢ"),
        ("晚餐想吃什麼", "ㄨㄢˇ ㄘㄢ ㄒㄧㄤˇ ㄔ ㄕㄜˊ ㄇㄛ˙"),
        ("報告明天早上交", "ㄅㄠˋ ㄍㄠˋ ㄇㄧㄥˊ ㄊㄧㄢ ㄗㄠˇ ㄕㄤˋ ㄐㄧㄠ"),
        ("電腦突然當機了", "ㄉㄧㄢˋ ㄋㄠˇ ㄊㄨˊ ㄖㄢˊ ㄉㄤˋ ㄐㄧ ㄌㄜ˙"),
        ("這個價格有點貴", "ㄓㄜˋ ㄍㄜ˙ ㄐㄧㄚˋ ㄍㄜˊ ㄧㄡˇ ㄉㄧㄢˇ ㄍㄨㄟˋ"),
        ("他剛剛下班回家", "ㄊㄚ ㄍㄤ ㄍㄤ ㄒㄧㄚˋ ㄅㄢ ㄏㄨㄟˊ ㄐㄧㄚ"),
        ("我們約在車站見面", "ㄨㄛˇ ㄇㄣˊ ㄩㄝ ㄗㄞˋ ㄔㄜ ㄓㄢˋ ㄐㄧㄢˋ ㄇㄧㄢˋ"),
        ("請把檔案寄給我", "ㄑㄧㄥˇ ㄅㄚˇ ㄉㄤˇ ㄢˋ ㄐㄧˋ ㄍㄟˇ ㄨㄛˇ"),
        ("今天的會議取消了", "ㄐㄧㄣ ㄊㄧㄢ ㄉㄜ˙ ㄏㄨㄟˋ ㄧˋ ㄑㄩˇ ㄒㄧㄠ ㄌㄜ˙"),
        ("外面正在下大雨", "ㄨㄞˋ ㄇㄧㄢˋ ㄓㄥˋ ㄗㄞˋ ㄒㄧㄚˋ ㄉㄚˋ ㄩˇ"),
        ("我覺得這樣比較好", "ㄨㄛˇ ㄐㄩㄝˊ ㄉㄜˊ ㄓㄜˋ ㄧㄤˋ ㄅㄧˇ ㄐㄧㄠˋ ㄏㄠˇ"),
        ("你有沒有看到我的手機", "ㄋㄧˇ ㄧㄡˇ ㄇㄟˊ ㄧㄡˇ ㄎㄢˋ ㄉㄠˋ ㄨㄛˇ ㄉㄜ˙ ㄕㄡˇ ㄐㄧ"),
        ("這本書非常好看", "ㄓㄜˋ ㄅㄣˇ ㄕㄨ ㄈㄟ ㄔㄤˊ ㄏㄠˇ ㄎㄢˋ"),
        ("明年打算出國旅行", "ㄇㄧㄥˊ ㄋㄧㄢˊ ㄉㄚˇ ㄙㄨㄢˋ ㄔㄨ ㄍㄨㄛˊ ㄌㄩˇ ㄒㄧㄥˊ"),
        ("記得多喝水", "ㄐㄧˋ ㄉㄜˊ ㄉㄨㄛ ㄏㄜ ㄕㄨㄟˇ"),
        ("週五晚上一起吃飯", "ㄓㄡ ㄨˇ ㄨㄢˇ ㄕㄤˋ ㄧ ㄑㄧˇ ㄔ ㄈㄢˋ"),
        ("系統更新之後變慢了", "ㄒㄧˋ ㄊㄨㄥˇ ㄍㄥˋ ㄒㄧㄣ ㄓ ㄏㄡˋ ㄅㄧㄢˋ ㄇㄢˋ ㄌㄜ˙"),
        ("我還在路上", "ㄨㄛˇ ㄏㄞˊ ㄗㄞˋ ㄌㄨˋ ㄕㄤˋ"),
        ("我先去洗澡", "ㄨㄛˇ ㄒㄧㄢ ㄑㄩˋ ㄒㄧˇ ㄗㄠˇ"),
        ("這家餐廳要排隊", "ㄓㄜˋ ㄐㄧㄚ ㄘㄢ ㄊㄧㄥ ㄧㄠˋ ㄆㄞˊ ㄉㄨㄟˋ"),
        ("你今天幾點下班", "ㄋㄧˇ ㄐㄧㄣ ㄊㄧㄢ ㄐㄧˇ ㄉㄧㄢˇ ㄒㄧㄚˋ ㄅㄢ"),
        ("老師說明天要考試", "ㄌㄠˇ ㄕ ㄕㄨㄛ ㄇㄧㄥˊ ㄊㄧㄢ ㄧㄠˋ ㄎㄠˇ ㄕˋ"),
        ("我忘記帶鑰匙", "ㄨㄛˇ ㄨㄤˋ ㄐㄧˋ ㄉㄞˋ ㄧㄠˋ ㄕˇ"),
        ("這個功能還沒上線", "ㄓㄜˋ ㄍㄜ˙ ㄍㄨㄥ ㄋㄥˊ ㄏㄞˊ ㄇㄟˊ ㄕㄤˋ ㄒㄧㄢˋ"),
        ("天氣越來越冷了", "ㄊㄧㄢ ㄑㄧˋ ㄩㄝˋ ㄌㄞˊ ㄩㄝˋ ㄌㄥˇ ㄌㄜ˙"),
        ("我們下次再聊", "ㄨㄛˇ ㄇㄣˊ ㄒㄧㄚˋ ㄘˋ ㄗㄞˋ ㄌㄧㄠˊ"),
        ("他對這件事很有興趣", "ㄊㄚ ㄉㄨㄟˋ ㄓㄜˋ ㄐㄧㄢˋ ㄕˋ ㄏㄣˇ ㄧㄡˇ ㄒㄧㄥˋ ㄑㄩˋ"),
        ("請問廁所在哪裡", "ㄑㄧㄥˇ ㄨㄣˋ ㄘㄜˋ ㄙㄨㄛˇ ㄗㄞˋ ㄋㄚˇ ㄌㄧˇ"),
        ("我想買一台新電腦", "ㄨㄛˇ ㄒㄧㄤˇ ㄇㄞˇ ㄧ ㄊㄞˊ ㄒㄧㄣ ㄉㄧㄢˋ ㄋㄠˇ"),
        ("這部電影很感人", "ㄓㄜˋ ㄅㄨˋ ㄉㄧㄢˋ ㄧㄥˇ ㄏㄣˇ ㄍㄢˇ ㄖㄣˊ"),
        ("等你到了再打電話給我", "ㄉㄥˇ ㄋㄧˇ ㄉㄠˋ ㄌㄜ˙ ㄗㄞˋ ㄉㄚˇ ㄉㄧㄢˋ ㄏㄨㄚˋ ㄍㄟˇ ㄨㄛˇ"),
        ("最近工作有點忙", "ㄗㄨㄟˋ ㄐㄧㄣˋ ㄍㄨㄥ ㄗㄨㄛˋ ㄧㄡˇ ㄉㄧㄢˇ ㄇㄤˊ"),
        ("我們需要更多時間", "ㄨㄛˇ ㄇㄣˊ ㄒㄩ ㄧㄠˋ ㄍㄥˋ ㄉㄨㄛ ㄕˊ ㄐㄧㄢ"),
        ("你要不要一起來", "ㄋㄧˇ ㄧㄠˋ ㄅㄨˊ ㄧㄠˋ ㄧ ㄑㄧˇ ㄌㄞˊ"),
        ("這個問題我也不知道", "ㄓㄜˋ ㄍㄜ˙ ㄨㄣˋ ㄊㄧˊ ㄨㄛˇ ㄧㄝˇ ㄅㄨˋ ㄓ ㄉㄠˋ"),
        ("早上起床頭很痛", "ㄗㄠˇ ㄕㄤˋ ㄑㄧˇ ㄔㄨㄤˊ ㄊㄡˊ ㄏㄣˇ ㄊㄨㄥˋ"),
        ("資料已經整理好了", "ㄗ ㄌㄧㄠˋ ㄧˇ ㄐㄧㄥ ㄓㄥˇ ㄌㄧˇ ㄏㄠˇ ㄌㄜ˙"),
        ("我明天請假", "ㄨㄛˇ ㄇㄧㄥˊ ㄊㄧㄢ ㄑㄧㄥˇ ㄐㄧㄚˋ"),
        ("這條路晚上很暗", "ㄓㄜˋ ㄊㄧㄠˊ ㄌㄨˋ ㄨㄢˇ ㄕㄤˋ ㄏㄣˇ ㄢˋ"),
        ("小心不要感冒", "ㄒㄧㄠˇ ㄒㄧㄣ ㄅㄨˊ ㄧㄠˋ ㄍㄢˇ ㄇㄠˋ"),
        ("他說的話很有道理", "ㄊㄚ ㄕㄨㄛ ㄉㄜ˙ ㄏㄨㄚˋ ㄏㄣˇ ㄧㄡˇ ㄉㄠˋ ㄌㄧˇ"),
        ("周末我想在家休息", "ㄓㄡ ㄇㄛˋ ㄨㄛˇ ㄒㄧㄤˇ ㄗㄞˋ ㄐㄧㄚ ㄒㄧㄡ ㄒㄧˊ"),
        ("請幫我確認一下時間", "ㄑㄧㄥˇ ㄅㄤ ㄨㄛˇ ㄑㄩㄝˋ ㄖㄣˋ ㄧ ㄒㄧㄚˋ ㄕˊ ㄐㄧㄢ"),
        ("這次考試考得不錯", "ㄓㄜˋ ㄘˋ ㄎㄠˇ ㄕˋ ㄎㄠˇ ㄉㄜˊ ㄅㄨˊ ㄘㄨㄛˋ"),
        ("我們公司在找工程師", "ㄨㄛˇ ㄇㄣˊ ㄍㄨㄥ ㄙ ㄗㄞˋ ㄓㄠˇ ㄍㄨㄥ ㄔㄥˊ ㄕ"),
        ("你的想法很有創意", "ㄋㄧˇ ㄉㄜ˙ ㄒㄧㄤˇ ㄈㄚˇ ㄏㄣˇ ㄧㄡˇ ㄔㄨㄤˋ ㄧˋ"),
        ("我剛才在開會", "ㄨㄛˇ ㄍㄤ ㄘㄞˊ ㄗㄞˋ ㄎㄞ ㄏㄨㄟˋ"),
        ("下個月要搬家", "ㄒㄧㄚˋ ㄍㄜ˙ ㄩㄝˋ ㄧㄠˋ ㄅㄢ ㄐㄧㄚ"),
        ("謝謝你的幫忙", "ㄒㄧㄝˋ ㄒㄧㄝˋ ㄋㄧˇ ㄉㄜ˙ ㄅㄤ ㄇㄤˊ"),
        ("這台車很省油", "ㄓㄜˋ ㄊㄞˊ ㄔㄜ ㄏㄣˇ ㄕㄥˇ ㄧㄡˊ"),
        ("我已經吃過了", "ㄨㄛˇ ㄧˇ ㄐㄧㄥ ㄔ ㄍㄨㄛˋ ㄌㄜ˙"),
        ("那間咖啡店很安靜", "ㄋㄚˋ ㄐㄧㄢ ㄎㄚ ㄈㄟ ㄉㄧㄢˋ ㄏㄣˇ ㄢ ㄐㄧㄥˋ"),
        ("他每天早上跑步", "ㄊㄚ ㄇㄟˇ ㄊㄧㄢ ㄗㄠˇ ㄕㄤˋ ㄆㄠˇ ㄅㄨˋ"),
        ("明天會不會下雨", "ㄇㄧㄥˊ ㄊㄧㄢ ㄏㄨㄟˋ ㄅㄨˊ ㄏㄨㄟˋ ㄒㄧㄚˋ ㄩˇ"),
        ("我不太喜歡吃辣", "ㄨㄛˇ ㄅㄨˊ ㄊㄞˋ ㄒㄧˇ ㄏㄨㄢ ㄔ ㄌㄚˋ"),
        ("這張照片拍得很好", "ㄓㄜˋ ㄓㄤ ㄓㄠˋ ㄆㄧㄢˋ ㄆㄞ ㄉㄜˊ ㄏㄣˇ ㄏㄠˇ"),
        ("請把門關上", "ㄑㄧㄥˇ ㄅㄚˇ ㄇㄣˊ ㄍㄨㄢ ㄕㄤˋ"),
        ("我們準備出發了", "ㄨㄛˇ ㄇㄣˊ ㄓㄨㄣˇ ㄅㄟˋ ㄔㄨ ㄈㄚ ㄌㄜ˙"),
    ]
    private static let toneKeys: [Character: String] = ["ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"]
    private static let costs: [Double?] = [nil, 3.0, 2.3, 1.6, 1.2, 0.8, 0.5]

    private func lexiconText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(".cache/mcbopomofo/lexicon.tsv"), encoding: .utf8)
    }

    private func realDecoder() throws -> LexiconDecoder {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = root.appendingPathComponent(".cache/mcbopomofo")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (from, to) in [(cache.appendingPathComponent("lexicon.tsv"), "lexicon.tsv"),
                           (cache.appendingPathComponent("toneless.tsv"), "toneless.tsv"),
                           (root.appendingPathComponent("Resources/local_phrases.tsv"), "local_phrases.tsv")] {
            try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(to))
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(LexiconLoader.load(resourceDirectory: dir, environment: [:]))
    }

    /// Most frequent text per reading with `syllables` syllables, readings
    /// containing `symbol`, best first.
    private func words(containing symbol: String, syllables: ClosedRange<Int>, limit: Int,
                       lexicon: String) -> [(text: String, readings: String)] {
        var best: [String: (String, Double)] = [:]
        for line in lexicon.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let score = Double(fields[2]) else { continue }
            let reading = String(fields[0])
            let count = reading.split(separator: "-").count
            guard syllables.contains(count), reading.contains(symbol),
                  fields[1].count == count else { continue }
            if let seen = best[reading], seen.1 >= score { continue }
            best[reading] = (String(fields[1]), score)
        }
        return best.sorted { $0.value.1 == $1.value.1 ? $0.key < $1.key : $0.value.1 > $1.value.1 }
            .prefix(limit).map { (text: $0.value.0, readings: $0.key.replacingOccurrences(of: "-", with: " ")) }
    }

    private func keys(_ readings: String, toned: Bool, slip: Bool) -> [String] {
        var reverse: [String: String] = [:]
        for (key, symbol) in ZhuyinKeyboard.symbols { reverse[symbol] = key }
        var out: [String] = []
        for syllable in readings.split(separator: " ") {
            var tone = " "
            for char in syllable {
                if let key = Self.toneKeys[char] { tone = key; continue }
                let symbol = slip && char == "ㄣ" ? "ㄥ" : String(char)
                out.append(reverse[symbol]!)
            }
            if toned { out.append(tone) }
        }
        return out
    }

    private func top(_ decoder: LexiconDecoder, _ keys: [String]) -> String? {
        var composition = Composition()
        for key in keys { composition.append(key) }
        return decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending,
                                      fuzzy: true).first?.text
    }

    func testOracleSweep() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["MISSTYPE_CHANNEL_SWEEP"] == nil, "measurement; set MISSTYPE_CHANNEL_SWEEP=1")
        let decoder = try realDecoder()
        let lexicon = try lexiconText()
        let limit = environment["MISSTYPE_CHANNEL_WORDS"].flatMap(Int.init) ?? 300
        typealias Probe = (text: String, readings: String)
        let groups: [(name: String, target: [Probe], control: [Probe])] = [
            ("chars", words(containing: "ㄣ", syllables: 1...1, limit: limit, lexicon: lexicon),
             words(containing: "ㄥ", syllables: 1...1, limit: limit, lexicon: lexicon)),
            ("words", words(containing: "ㄣ", syllables: 2...4, limit: limit, lexicon: lexicon),
             words(containing: "ㄥ", syllables: 2...4, limit: limit, lexicon: lexicon)),
            ("sentences", Self.sentences.filter { $0.readings.contains("ㄣ") },
             Self.sentences.filter { $0.readings.contains("ㄥ") }),
        ]
        var out = "\nchannel oracle sweep: typed ㄥ→intended ㄣ, real lexicon, top \(limit) readings per side\n"
        out += "group     mode     cost | recovered (slipped ㄣ) | kept (exact ㄥ) | ms/decode\n"
        func pct(_ n: Int, _ d: Int) -> String {
            String(format: "%3d/%3d %5.1f%%", n, d, d == 0 ? 0 : Double(n) * 100 / Double(d))
        }
        for group in groups {
            for toned in [true, false] {
                decoder.channel = nil
                let target = group.target.filter { top(decoder, keys($0.readings, toned: toned, slip: false)) == $0.text }
                let control = group.control.filter { top(decoder, keys($0.readings, toned: toned, slip: false)) == $0.text }
                for cost in Self.costs {
                    decoder.channel = cost.map { ChannelModel(substitutions: ["/": ["p": $0]]) }
                    let started = Date()
                    let recovered = target.filter { top(decoder, keys($0.readings, toned: toned, slip: true)) == $0.text }
                    let lost = control.compactMap { probe -> String? in
                        let got = top(decoder, keys(probe.readings, toned: toned, slip: false))
                        return got == probe.text ? nil : "\(probe.text)→\(got ?? "-")"
                    }
                    let millis = Date().timeIntervalSince(started) * 1000 / Double(max(1, target.count + control.count))
                    out += group.name.padding(toLength: 10, withPad: " ", startingAt: 0)
                        + (toned ? "toned   " : "toneless")
                        + (cost.map { String(format: " %4.1f", $0) } ?? " gen5")
                        + " | \(pct(recovered.count, target.count))       | \(pct(control.count - lost.count, control.count)) |"
                        + String(format: " %6.2f\n", millis)
                    if !lost.isEmpty { out += "    lost: " + lost.prefix(10).joined(separator: " ") + "\n" }
                }
            }
        }
        decoder.channel = nil
        print(out)
    }
}
