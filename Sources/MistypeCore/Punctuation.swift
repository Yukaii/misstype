import Foundation

/// CJK punctuation table for the macOS adapter (pure, unit-tested).
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
    public static func output(keyCode: Int, shift: Bool, ctrl: Bool = false) -> String? {
        if ctrl && !shift && keyCode == 41 { return "；" }
        if shift {
            switch keyCode {
            case 18: return "！"
            case 19: return "＠"
            case 20: return "＃"
            case 21: return "＄"
            case 23: return "％"
            case 22: return "︿"
            case 26: return "＆"
            case 28: return "＊"
            case 25: return "（"
            case 29: return "）"
            case 24: return "＋"
            case 33: return "｛"
            case 30: return "｝"
            case 50: return "～"
            case 27: return "——"
            case 39: return "」"
            case 41: return "："
            case 42: return "·"
            case 43: return "，"
            case 44: return "？"
            case 47: return "。"
            default: break
            }
        }
        switch keyCode {
        case 30: return "』"
        case 33: return "『"
        case 39: return "「"
        case 42: return "、"
        default: return nil
        }
    }
}
