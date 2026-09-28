import Foundation

/// CJK punctuation table, keyed by physical key label (pure, unit-tested).
///
/// Thesis first: keys that carry Zhuyin symbols (`,`, `.`, `/`, `;`, `-`,
/// digits) stay phonetic even with an empty composition, so syllable-initial
/// ㄝ ㄡ ㄥ ㄤ ㄦ keep working. Their Shifted variants are free — Shift
/// always commits first — so ，。？！： live there. Quotes and brackets live
/// on non-Zhuyin keys. Ctrl+; is the conflict-free home for ； (Cmd is
/// never hijacked — see call site). … stays ASCII until the Option layer
/// is designed (roadmap).
///
/// Full-width Shift layer (2026-09-27, 大千 convention): the Shift+digit
/// row plus Shift+= [ ] ` give ＠＃＄％︿＆＊（）＋｛｝～. Candidate
/// selection moved off Shift+digit into selection mode (SelectionKeys), so
/// these never collide with picking.
public enum Punctuation {
    /// Every CJK literal this IME can insert (single commit unit "——").
    public static let literals: Set<String> = [
        "，", "。", "？", "！", "：", "「", "」", "『", "』",
        "、", "·", "；", "——",
        "＠", "＃", "＄", "％", "︿", "＆", "＊", "（", "）", "＋", "｛", "｝", "～",
    ]
    public static func output(label: String, shift: Bool, ctrl: Bool = false) -> String? {
        if ctrl && !shift && label == ";" { return "；" }
        if shift {
            switch label {
            case "1": return "！"
            case "2": return "＠"
            case "3": return "＃"
            case "4": return "＄"
            case "5": return "％"
            case "6": return "︿"
            case "7": return "＆"
            case "8": return "＊"
            case "9": return "（"
            case "0": return "）"
            case "=": return "＋"
            case "[": return "｛"
            case "]": return "｝"
            case "`": return "～"
            case "-": return "——"
            case "'": return "」"
            case ";": return "："
            case "\\": return "·"
            case ",": return "，"
            case "/": return "？"
            case ".": return "。"
            default: break
            }
        }
        switch label {
        case "]": return "』"
        case "[": return "『"
        case "'": return "「"
        case "\\": return "、"
        default: return nil
        }
    }
}
