import Foundation

public struct SentenceCandidate: Equatable {
    public let text: String
    public let score: Double
    public let repairs: Int
    public let unresolved: Int
}

public final class LexiconDecoder {
    private final class Node {
        var children: [String: Node] = [:]
        var entries: [(text: String, score: Double)] = []
    }
    private let root = Node()
    private var readings: Set<String> = []
    private var toneless: [String: Set<String>] = [:]
    public private(set) var entryCount = 0

    public init(tsv: String) {
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let score = Double(fields[2]), score.isFinite else { continue }
            let parts = fields[0].split(separator: "-").map(String.init)
            guard !parts.isEmpty && parts.count <= 8 else { continue }
            var node = root
            for reading in parts {
                readings.insert(reading)
                toneless[Self.withoutTone(reading), default: []].insert(reading)
                if node.children[reading] == nil { node.children[reading] = Node() }
                node = node.children[reading]!
            }
            node.entries.append((String(fields[1]), score))
            node.entries.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            node.entries = Array(node.entries.prefix(3))
            entryCount += 1
        }
    }

    private static func withoutTone(_ text: String) -> String {
        String(text.filter { !"ˊˇˋ˙".contains($0) })
    }

    private func alternatives(_ syllable: Syllable, fuzzy: Bool) -> [(String, Double, Int)] {
        let reading = syllable.reading
        if readings.contains(reading), syllable.tone != nil { return [(reading, 0, 0)] }
        if syllable.tone == nil, let variants = toneless[Self.withoutTone(reading)] {
            return variants.sorted().map { ($0, 0.5, 0) }
        }
        guard fuzzy else { return [] }
        var candidates: Set<String> = []
        for index in syllable.keys.indices {
            for replacement in ZhuyinKeyboard.neighbors(of: syllable.keys[index]) {
                var keys = syllable.keys
                keys[index] = replacement
                let candidate = Syllable(keys: keys, tone: syllable.tone).reading
                if syllable.tone != nil && readings.contains(candidate) { candidates.insert(candidate) }
                if syllable.tone == nil { candidates.formUnion(toneless[candidate] ?? []) }
            }
        }
        return candidates.sorted().prefix(12).map { ($0, 5, 1) }
    }

    public func decode(_ syllables: [Syllable], fuzzy: Bool = true) -> [SentenceCandidate] {
        guard !syllables.isEmpty else { return [] }
        let options = syllables.map { alternatives($0, fuzzy: fuzzy) }
        var paths = Array(repeating: [SentenceCandidate](), count: syllables.count + 1)
        paths[0] = [SentenceCandidate(text: "", score: 0, repairs: 0, unresolved: 0)]
        func add(_ candidate: SentenceCandidate, at index: Int) {
            if let same = paths[index].firstIndex(where: { $0.text == candidate.text }) {
                if paths[index][same].score >= candidate.score { return }
                paths[index].remove(at: same)
            }
            paths[index].append(candidate)
            paths[index].sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            paths[index] = Array(paths[index].prefix(5))
        }
        for start in syllables.indices {
            guard !paths[start].isEmpty else { continue }
            let prefixes = paths[start]
            for prefix in prefixes {
                add(SentenceCandidate(text: prefix.text + syllables[start].reading,
                    score: prefix.score - 100, repairs: prefix.repairs,
                    unresolved: prefix.unresolved + 1), at: start + 1)
            }
            var states: [(Node, Double, Int)] = [(root, 0, 0)]
            for end in start..<min(syllables.count, start + 8) {
                var next: [(Node, Double, Int)] = []
                for (node, penalty, repairs) in states {
                    for (reading, cost, correction) in options[end] {
                        guard let child = node.children[reading] else { continue }
                        next.append((child, penalty + cost, repairs + correction))
                        for entry in child.entries {
                            for prefix in prefixes {
                                add(SentenceCandidate(text: prefix.text + entry.text,
                                    score: prefix.score + entry.score - penalty - cost,
                                    repairs: prefix.repairs + repairs + correction,
                                    unresolved: prefix.unresolved), at: end + 1)
                            }
                        }
                    }
                }
                states = next.enumerated().sorted {
                    $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1
                }.prefix(32).map(\.element)
                if states.isEmpty { break }
            }
        }
        return paths[syllables.count]
    }
}
