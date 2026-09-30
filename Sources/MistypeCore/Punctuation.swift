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
    /// Every CJK literal this IME can insert (single commit unit "——"): the
    /// key table's outputs plus every symbol-menu choice. All are non-ASCII,
    /// so none can collide with a physical key label in `Composition.rawKeys`.
    public static let literals: Set<String> = Set([
        "，", "。", "？", "！", "：", "「", "」", "『", "』",
        "、", "·", "；", "——",
        "＠", "＃", "＄", "％", "︿", "＆", "＊", "（", "）", "＋", "｛", "｝", "～",
    ] + groups.flatMap { $0 })

    /// Symbol menu: after a mark is typed, the candidate list offers its
    /// group. Open and close marks are separate groups so a swap never turns
    /// an opening mark into a closing one. One group per literal (first hit
    /// wins); the typed mark is listed first, the rest in group order.
    public static let groups: [[String]] = [
        ["，", "、", "；", "：", "︐", "︑"],
        ["。", "．", "…", "⋯", "‧"],
        ["？", "⁇", "⁈", "﹖"],
        ["！", "‼", "⁉", "﹗"],
        ["「", "『", "“", "‘", "《", "〈", "﹁", "﹃"],
        ["」", "』", "”", "’", "》", "〉", "﹂", "﹄"],
        ["（", "【", "〔", "［", "｛", "〖", "〘"],
        ["）", "】", "〕", "］", "｝", "〗", "〙"],
        ["——", "─", "—", "～", "〜", "＿"],
        ["·", "‧", "•", "・", "∙"],
        ["＠", "©", "®", "™"],
        ["＃", "♯", "№", "♭", "♮"],
        ["＄", "￥", "￡", "€", "¢", "¥"],
        ["％", "‰", "‱"],
        ["︿", "＾", "∧", "↑", "→", "←", "↓"],
        ["＆", "§", "¶"],
        ["＊", "※", "★", "☆", "✱"],
        ["＋", "±", "×", "÷", "－", "＝", "≠", "≈"],
    ]

    /// Menu choices for a just-typed literal: itself first, then its group.
    /// Empty when the mark has no alternatives.
    public static func choices(for literal: String) -> [String] {
        guard let group = groups.first(where: { $0.contains(literal) }) else { return [] }
        return [literal] + group.filter { $0 != literal }
    }

    /// `'` and Shift+`'` pair themselves within the composition: 「 opens, and
    /// stays 」 while a 「 is unclosed (Shift: 『 』). Nested marks stay
    /// reachable directly via `[` / `]` and through the symbol menu. Only the
    /// composition is inspected — a 「 already committed to the app is not.
    public static func smartQuote(label: String, shift: Bool, ctrl: Bool, in keys: [String]) -> String? {
        guard label == "'", !ctrl else { return nil }
        let (open, close) = shift ? ("『", "』") : ("「", "」")
        var depth = 0
        for key in keys {
            if key == open { depth += 1 } else if key == close { depth = max(0, depth - 1) }
        }
        return depth > 0 ? close : open
    }
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
