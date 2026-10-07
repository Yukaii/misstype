import Foundation

/// Where a composition's raw keys show in its preview: the bridge between
/// the syllable cursor (decoded syllables), the insertion caret (a raw key
/// index, `Composition.caret`) and the drawn caret (UTF-16 offset).
///
/// Built from the shown candidate by walking the keys the way
/// `Composition.segments` groups them. A syllable body (symbol keys up to a
/// tone) can hold several decoded syllables (toneless typing fuses them), so
/// its keys are handed out by each decoded syllable's key count; the tone
/// key closes the last one. Nil when the candidate's syllables do not
/// account for the keys exactly (English readings from the mixed pass carry
/// syllables of a rewritten composition).
public struct CompositionLayout: Equatable {
    /// UTF-16 offset in the preview before raw key `i`; the extra last entry
    /// is the end of the preview. Keys inside a syllable sit after its char.
    public let offsets: [Int]
    /// Raw keys of each decoded syllable: its symbol keys plus the tone key
    /// closing it.
    public let syllableKeys: [Range<Int>]
    /// Option+Left / Option+Right stops, ascending raw indexes: where a word
    /// starts / ends. Words are decoded words, Latin words, single
    /// punctuation marks and the raw Zhuyin tail; separator spaces are not.
    public let wordStarts: [Int]
    public let wordEnds: [Int]

    /// `caret`: the composition's mid-composition caret, a syllable
    /// boundary in its segments.
    public init?(keys: [String], caret: Int? = nil, shown top: SentenceCandidate, rawTail: Int) {
        let syllables = top.syllables
        var offsets = Array(repeating: 0, count: keys.count + 1)
        var syllableKeys: [Range<Int>] = []
        var starts: Set<Int> = [], ends: Set<Int> = []
        var pos = 0
        var body: [Int] = []

        func charEnd(_ syllable: Int) -> Int? {
            guard let word = top.alignment.first(where: { $0.syllables.contains(syllable) }) else { return nil }
            guard word.chars.count == word.syllables.count else { return word.chars.upperBound }
            return word.chars.lowerBound + (syllable - word.syllables.lowerBound) + 1
        }
        /// Hand the open body to the next decoded syllables. Keys left over
        /// are the live raw tail, legal only at the very end.
        func closeBody(tone: Int?, final: Bool) -> Bool {
            defer { body = [] }
            var used = 0
            while used < body.count, syllableKeys.count < syllables.count {
                let index = syllableKeys.count
                let count = syllables[index].keys.count
                guard count > 0, used + count <= body.count,
                      let start = top.charOffset(ofSyllable: index), let end = charEnd(index) else { return false }
                offsets[body[used]] = start
                for key in body[(used + 1)..<(used + count)] { offsets[key] = end }
                var upper = body[used + count - 1] + 1
                if used + count == body.count, let tone {
                    offsets[tone] = end
                    upper = tone + 1
                }
                syllableKeys.append(body[used]..<upper)
                pos = end
                used += count
            }
            let left = body.count - used
            guard left == 0 || (final && tone == nil && left == rawTail) else { return false }
            if left > 0 {
                starts.insert(body[used])
                ends.insert(keys.count)
            }
            for key in body[used...] {
                offsets[key] = pos
                pos += 1
            }
            return true
        }

        for (index, key) in keys.enumerated() {
            if index == caret, !body.isEmpty {
                guard closeBody(tone: nil, final: false) else { return nil }
            }
            let latin = Composition.isLatinKey(key)
            if latin || Punctuation.literals.contains(key) || (key == " " && body.isEmpty) {
                guard closeBody(tone: nil, final: false) else { return nil }
                offsets[index] = pos
                pos += (latin ? Composition.latinChar(key) : key).utf16.count
                guard key != " " else { continue }
                // A Latin word is a run of letters/digits; anything else
                // (punctuation, Latin or CJK) is a word of its own.
                let word = Composition.isLatinWordKey(key)
                if !word || index == 0 || !Composition.isLatinWordKey(keys[index - 1]) { starts.insert(index) }
                if !word || index + 1 == keys.count || !Composition.isLatinWordKey(keys[index + 1]) {
                    ends.insert(index + 1)
                }
            } else if ZhuyinKeyboard.tones[key] != nil {
                if body.isEmpty {
                    offsets[index] = pos
                } else {
                    guard closeBody(tone: index, final: false) else { return nil }
                }
            } else {
                body.append(index)
            }
        }
        guard closeBody(tone: nil, final: true), syllableKeys.count == syllables.count,
              pos == top.text.utf16.count + rawTail else { return nil }
        offsets[keys.count] = pos
        for word in top.alignment where word.syllables.upperBound <= syllableKeys.count && !word.syllables.isEmpty {
            starts.insert(syllableKeys[word.syllables.lowerBound].lowerBound)
            ends.insert(syllableKeys[word.syllables.upperBound - 1].upperBound)
        }
        self.offsets = offsets
        self.syllableKeys = syllableKeys
        wordStarts = starts.sorted()
        wordEnds = ends.sorted()
    }

    /// Raw index of syllable boundary `boundary` (0…n): the first key of
    /// that syllable, or after the last syllable's tone.
    public func keyIndex(ofBoundary boundary: Int) -> Int? {
        guard boundary >= 0, boundary <= syllableKeys.count, !syllableKeys.isEmpty else { return nil }
        return boundary < syllableKeys.count ? syllableKeys[boundary].lowerBound : syllableKeys[boundary - 1].upperBound
    }

    /// Syllable boundary at raw index `key`: the syllables wholly before it.
    public func boundary(atKey key: Int) -> Int {
        syllableKeys.filter { $0.upperBound <= key }.count
    }
}
