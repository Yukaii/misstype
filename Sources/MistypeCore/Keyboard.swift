import Foundation

public enum ZhuyinKeyboard {
    public static let symbols: [String: String] = [
        "1":"ㄅ", "q":"ㄆ", "a":"ㄇ", "z":"ㄈ", "2":"ㄉ", "w":"ㄊ", "s":"ㄋ", "x":"ㄌ",
        "e":"ㄍ", "d":"ㄎ", "c":"ㄏ", "r":"ㄐ", "f":"ㄑ", "v":"ㄒ", "5":"ㄓ", "t":"ㄔ",
        "g":"ㄕ", "b":"ㄖ", "y":"ㄗ", "h":"ㄘ", "n":"ㄙ", "u":"ㄧ", "j":"ㄨ", "m":"ㄩ",
        "8":"ㄚ", "i":"ㄛ", "k":"ㄜ", ",":"ㄝ", "9":"ㄞ", "o":"ㄟ", "l":"ㄠ", ".":"ㄡ",
        "0":"ㄢ", "p":"ㄣ", ";":"ㄤ", "/":"ㄥ", "-":"ㄦ",
    ]
    public static let tones = ["3":"ˇ", "4":"ˋ", "6":"ˊ", "7":"˙", " ":""]
    // ANSI virtual key codes, independent of the user's active Latin layout.
    public static let labels: [Int: String] = [
        0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",
        12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",
        22:"6",23:"5",25:"9",26:"7",27:"-",28:"8",29:"0",31:"o",32:"u",
        34:"i",35:"p",37:"l",38:"j",40:"k",41:";",43:",",44:"/",45:"n",46:"m",47:".",49:" ",
    ]

    /// Bopomofo symbols confused in real typing but far apart on QWERTY —
    /// neighbor substitution can never reach them. Medials (ㄧㄨㄩ taps as
    /// u/j/m), sibilant pairs (捲平舌), n/l, front/back nasals.
    public static let phoneticConfusions: [String: [String]] = {
        var groups: [[String]] = [
            ["ㄧ", "ㄨ", "ㄩ"],
            ["ㄓ", "ㄗ"], ["ㄔ", "ㄘ"], ["ㄕ", "ㄙ"],
            ["ㄋ", "ㄌ"],
            ["ㄢ", "ㄤ"], ["ㄣ", "ㄥ"],
        ]
        var reverse: [String: String] = [:]
        for (key, symbol) in symbols { reverse[symbol] = key }
        var table: [String: [String]] = [:]
        for group in groups {
            for symbol in group {
                guard let key = reverse[symbol] else { continue }
                table[key] = group.filter { $0 != symbol }.compactMap { reverse[$0] }
            }
        }
        return table
    }()
    public static func neighbors(of key: String) -> [String] {
        let rows = [Array("1234567890-"), Array("qwertyuiop"), Array("asdfghjkl;"), Array("zxcvbnm,./")]
        var positions: [String: (Double, Double)] = [:]
        for (r, row) in rows.enumerated() {
            for (c, char) in row.enumerated() {
                positions[String(char)] = (Double(c) + [0.0, 0.25, 0.5, 0.75][r], Double(r))
            }
        }
        guard let point = positions[key] else { return [] }
        return positions.compactMap { label, p -> (String, Double)? in
            let distance = hypot(point.0 - p.0, point.1 - p.1)
            return label != key && symbols[label] != nil && distance < 1.3 ? (label, distance) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
    }
}

public struct Syllable {
    public let keys: [String]
    public let tone: String? // nil = no tone evidence; "" = explicit first tone
    public var reading: String { keys.compactMap { ZhuyinKeyboard.symbols[$0] }.joined() + (tone ?? "") }
}

public struct Composition {
    public private(set) var rawKeys: [String] = []
    public init() {}
    public var isEmpty: Bool { rawKeys.isEmpty }
    public var rawPhonetic: String {
        rawKeys.map {
            if Composition.isLatinKey($0) { return Composition.latinChar($0) }
            return ZhuyinKeyboard.symbols[$0] ?? ZhuyinKeyboard.tones[$0] ?? $0
        }.joined()
    }

    public enum Segment {
        case syllable(Syllable)
        case punct(String)
        case latin(String)
    }

    /// Latin literal key marker. Letters typed in latin mode are stored as
    /// "L:x" so raw symbol keys stay unambiguously Zhuyin — the engine never
    /// has to guess which language a bare key belongs to.
    public static func isLatinKey(_ key: String) -> Bool {
        key.hasPrefix("L:")
    }
    public static func latinChar(_ key: String) -> String {
        String(key.dropFirst(2))
    }

    public var parsed: (complete: [Syllable], pending: [String]) {
        var complete: [Syllable] = [], pending: [String] = []
        for key in rawKeys {
            if Composition.isLatinKey(key) || Punctuation.literals.contains(key) {
                // Latin runs and punctuation stay inside the composition (no
                // commit): they flush pending keys as a toneless tail.
                if !pending.isEmpty {
                    complete.append(Syllable(keys: pending, tone: nil))
                    pending = []
                }
                continue
            }
            if let tone = ZhuyinKeyboard.tones[key] {
                if !pending.isEmpty {
                    complete.append(Syllable(keys: pending, tone: tone))
                    pending = []
                }
            } else { pending.append(key) }
        }
        return (complete, pending)
    }

    /// Ordered terminated runs with punctuation AND latin positions
    /// preserved (consecutive latin keys group into one .latin run).
    /// A space after pending keys is a first-tone mark; otherwise a literal
    /// separator. Trailing unfinished keys are excluded — see parsed.pending.
    public var segments: [Segment] {
        var out: [Segment] = [], pending: [String] = []
        var latin = ""
        func flushPending() {
            if !pending.isEmpty {
                out.append(.syllable(Syllable(keys: pending, tone: nil)))
                pending = []
            }
        }
        func flushLatin() {
            if !latin.isEmpty {
                out.append(.latin(latin))
                latin = ""
            }
        }
        for key in rawKeys {
            if Composition.isLatinKey(key) {
                flushPending()
                latin += Composition.latinChar(key)
                continue
            }
            if Punctuation.literals.contains(key) {
                flushPending()
                flushLatin()
                out.append(.punct(key))
                continue
            }
            if key == " " {
                if !pending.isEmpty {
                    flushLatin()
                    out.append(.syllable(Syllable(keys: pending, tone: "")))
                    pending = []
                } else {
                    flushLatin()
                    out.append(.punct(key))
                }
                continue
            }
            if let tone = ZhuyinKeyboard.tones[key] {
                if !pending.isEmpty {
                    flushLatin()
                    out.append(.syllable(Syllable(keys: pending, tone: tone)))
                    pending = []
                }
            } else {
                flushLatin()
                pending.append(key)
            }
        }
        // Trailing latin IS emitted (unlike trailing symbols): commit reads
        // segments + parsed.pending, and parsed.pending never holds latin, so
        // dropping it here would lose the run on commit. Preview avoids the
        // double count because pendingText stops at latin runs.
        flushLatin()
        return out
    }

    @discardableResult public mutating func append(_ key: String) -> Bool {
        guard rawKeys.count < 256,
              ZhuyinKeyboard.symbols[key] != nil || ZhuyinKeyboard.tones[key] != nil else { return false }
        if ZhuyinKeyboard.tones[key] != nil && parsed.pending.isEmpty { return false }
        rawKeys.append(key)
        return true
    }
    /// Append a CJK punctuation literal into the running composition
    /// (no commit — mixed spans commit once at the end).
    @discardableResult public mutating func appendLiteral(_ text: String) -> Bool {
        guard rawKeys.count < 256, Punctuation.literals.contains(text) else { return false }
        rawKeys.append(text)
        return true
    }
    /// Space inside a composition is a boundary, never a commit: after
    /// pending keys it terminates the syllable (first-tone mark), otherwise
    /// it stays a literal separator so toneless words survive with spaces.
    @discardableResult public mutating func appendSpace() -> Bool {
        guard rawKeys.count < 256 else { return false }
        rawKeys.append(" ")
        return true
    }
    public mutating func backspace() { if !rawKeys.isEmpty { rawKeys.removeLast() } }
    /// Append one Latin letter into the running composition (no commit).
    /// Stored marked so bare symbol keys stay unambiguously Zhuyin.
    @discardableResult public mutating func appendLatin(_ text: String) -> Bool {
        guard rawKeys.count < 256, text.count == 1,
              let char = text.first, char.isASCII, char.isLetter else { return false }
        rawKeys.append("L:\(char)")
        return true
    }
    /// Erase the last user-perceived unit: a whole converted syllable when
    /// nothing is pending (completed characters go one char per press),
    /// else the last raw key of the unfinished syllable. Tone fixes inside
    /// a syllable stay cheap via Option+Backspace + retype; evidence loss
    /// beyond one syllable never happens in a single press.
    public mutating func erase() {
        if parsed.pending.isEmpty { deleteLastSyllable() } else { backspace() }
    }
    /// Apply a late tone keystroke onto the last boundary: replaces a trailing
    /// tone terminator (including space) with the new tone, so a tone typed
    /// after a space — or a corrected re-hit tone — is not swallowed.
    /// Returns false when there is no boundary to attach to.
    public mutating func retoneLast(_ toneKey: String) -> Bool {
        guard ZhuyinKeyboard.tones[toneKey] != nil,
              !rawKeys.isEmpty,
              parsed.pending.isEmpty,
              ZhuyinKeyboard.tones[rawKeys.last!] != nil else { return false }
        rawKeys[rawKeys.count - 1] = toneKey
        return true
    }
    /// Unfinished tail (symbols or latin) after the last tone/punctuation
    /// mark. Powers separator settle: punctuation commits the converted
    /// head and keeps this tail typing.
    public var hasUnfinishedTail: Bool {
        for key in rawKeys.reversed() {
            if ZhuyinKeyboard.tones[key] != nil || Punctuation.literals.contains(key) {
                return false
            }
            return true
        }
        return false
    }
    /// Drop everything through the last boundary, keeping the trailing
    /// unfinished run. Reserved for partial-commit flows (commit the picked
    /// head, keep typing the tail); currently exercised by unit tests.
    public mutating func dropThroughLastBoundary() {
        var tail: [String] = []
        while let last = rawKeys.last,
              ZhuyinKeyboard.symbols[last] != nil || Composition.isLatinKey(last) {
            tail.append(rawKeys.removeLast())
        }
        rawKeys = tail.reversed()
    }
    /// Delete back to the previous syllable boundary: a trailing tone key
    /// goes first, then the syllable body up to the previous tone key or
    /// start. Powers Option+Backspace so destructive editing never commits
    /// first.
    public mutating func deleteLastSyllable() {
        guard !rawKeys.isEmpty else { return }
        // A trailing punctuation mark or latin letter deletes alone — never
        // drag the previous syllable with it.
        if Punctuation.literals.contains(rawKeys.last!) || Composition.isLatinKey(rawKeys.last!) {
            rawKeys.removeLast()
            return
        }
        if ZhuyinKeyboard.tones[rawKeys.last!] != nil { rawKeys.removeLast() }
        while let last = rawKeys.last,
              ZhuyinKeyboard.tones[last] == nil,
              !Punctuation.literals.contains(last),
              !Composition.isLatinKey(last) { rawKeys.removeLast() }
    }
    public mutating func clear() { rawKeys.removeAll(keepingCapacity: true) }
    public func syllables(finishing: Bool) -> [Syllable] {
        let p = parsed
        return p.complete + (finishing && !p.pending.isEmpty ? [Syllable(keys: p.pending, tone: nil)] : [])
    }
    /// Trailing unfinished symbols for preview. Stops at tones, punctuation
    /// AND latin runs: latin renders through segments, counting it here as
    /// well would duplicate it in the preview. (A trailing [L:, symbol]
    /// adjacency cannot occur — every latin-mode exit records a boundary.)
    public var pendingText: String {
        var out = ""
        for key in rawKeys.reversed() {
            if ZhuyinKeyboard.tones[key] != nil || Punctuation.literals.contains(key)
                || Composition.isLatinKey(key) {
                break
            }
            guard let symbol = ZhuyinKeyboard.symbols[key] else { break }
            out = symbol + out
        }
        return out
    }
}
