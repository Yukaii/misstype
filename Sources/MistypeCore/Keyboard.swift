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
    public var rawPhonetic: String { rawKeys.map { ZhuyinKeyboard.symbols[$0] ?? ZhuyinKeyboard.tones[$0] ?? $0 }.joined() }

    public var parsed: (complete: [Syllable], pending: [String]) {
        var complete: [Syllable] = [], pending: [String] = []
        for key in rawKeys {
            if let tone = ZhuyinKeyboard.tones[key] {
                if !pending.isEmpty {
                    complete.append(Syllable(keys: pending, tone: tone))
                    pending = []
                }
            } else { pending.append(key) }
        }
        return (complete, pending)
    }

    @discardableResult public mutating func append(_ key: String) -> Bool {
        guard rawKeys.count < 256,
              ZhuyinKeyboard.symbols[key] != nil || ZhuyinKeyboard.tones[key] != nil else { return false }
        if ZhuyinKeyboard.tones[key] != nil && parsed.pending.isEmpty { return false }
        rawKeys.append(key)
        return true
    }
    public mutating func backspace() { if !rawKeys.isEmpty { rawKeys.removeLast() } }
    public mutating func clear() { rawKeys.removeAll(keepingCapacity: true) }
    public func syllables(finishing: Bool) -> [Syllable] {
        let p = parsed
        return p.complete + (finishing && !p.pending.isEmpty ? [Syllable(keys: p.pending, tone: nil)] : [])
    }
    public var pendingText: String { parsed.pending.compactMap { ZhuyinKeyboard.symbols[$0] }.joined() }
}
