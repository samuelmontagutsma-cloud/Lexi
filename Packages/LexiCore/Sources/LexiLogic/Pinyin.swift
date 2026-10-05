import Foundation

/// Pinyin helpers: tone marks ↔ tone numbers, answer checking, tone variants for the tone trainer.
public enum Pinyin {
    static let toneVowels: [Character: (Character, Int)] = {
        var m: [Character: (Character, Int)] = [:]
        let table: [(Character, String)] = [("a", "āáǎà"), ("e", "ēéěè"), ("i", "īíǐì"), ("o", "ōóǒò"),
                                            ("u", "ūúǔù"), ("ü", "ǖǘǚǜ"), ("A", "ĀÁǍÀ"), ("E", "ĒÉĚÈ"),
                                            ("O", "ŌÓǑÒ"), ("U", "ŪÚǓÙ")]
        for (base, marks) in table {
            for (i, c) in marks.enumerated() { m[c] = (base, i + 1) }
        }
        return m
    }()
    static let marks: [Character: [Character]] = [
        "a": Array("āáǎà"), "e": Array("ēéěè"), "i": Array("īíǐì"), "o": Array("ōóǒò"),
        "u": Array("ūúǔù"), "ü": Array("ǖǘǚǜ"),
    ]

    public struct Syllable: Equatable, Sendable {
        public let letters: String   // lowercase, no tone, ü kept
        public let tone: Int         // 1-4, 5 = neutral
    }

    /// "qīng chu" → [qing/1, chu/5]. Non-letter tokens are dropped.
    public static func syllables(marked: String) -> [Syllable] {
        marked.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "'" || $0 == "-" }).compactMap { tok in
            var letters = ""
            var tone = 5
            for ch in tok {
                if let (base, t) = toneVowels[ch] {
                    letters.append(Character(base.lowercased()))
                    tone = t
                } else if ch.isLetter {
                    letters.append(Character(ch.lowercased()))
                }
            }
            return letters.isEmpty ? nil : Syllable(letters: letters, tone: tone)
        }
    }

    /// "qing1 chu5" or "lu:4" or "lv4" → "qīng chu", "lǜ".
    public static func marked(numbered: String) -> String {
        numbered.split(separator: " ").map { markSyllable(String($0)) }.joined(separator: " ")
    }

    static func markSyllable(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "u:", with: "ü").replacingOccurrences(of: "v", with: "ü")
        guard let last = s.last, let tone = Int(String(last)), (1...5).contains(tone) else { return s }
        s.removeLast()
        return mark(letters: s, tone: tone)
    }

    /// Places the tone mark: a or e first; "ou" → o; else the last vowel.
    public static func mark(letters s: String, tone: Int) -> String {
        guard (1...4).contains(tone) else { return s }
        let low = Array(s.lowercased())
        var idx: Int?
        if let i = low.firstIndex(of: "a") { idx = i }
        else if let i = low.firstIndex(of: "e") { idx = i }
        else if let r = String(low).range(of: "ou") { idx = String(low).distance(from: String(low).startIndex, to: r.lowerBound) }
        else { idx = low.lastIndex(where: { "aeiouü".contains($0) }) }
        guard let i = idx, let row = marks[low[i]] else { return s }
        var chars = Array(s)
        let m = row[tone - 1]
        chars[i] = chars[i].isUppercase ? Character(String(m).uppercased()) : m
        return String(chars)
    }

    public static func numbered(marked: String) -> String {
        syllables(marked: marked).map { "\($0.letters)\($0.tone)" }.joined(separator: " ")
    }

    /// Normalizes typed pinyin: lowercase, v/u: → ü, no spaces or apostrophes.
    static func normalizeTyped(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "u:", with: "ü").replacingOccurrences(of: "v", with: "ü")
            .filter { !" '’·-".contains($0) }
    }

    /// True when `typed` matches `answerMarked`.
    /// Accepts: tone marks, tone numbers (some or all), or no tones. "u" is accepted for "ü".
    public static func matches(typed: String, answerMarked: String) -> Bool {
        let answer = syllables(marked: answerMarked)
        guard !answer.isEmpty else { return false }
        let t = normalizeTyped(typed)
        // typed with tone marks: map each mark to the answer syllable that contains it
        if t.contains(where: { toneVowels[$0] != nil }) {
            var letters = ""
            var marksAt: [(index: Int, tone: Int)] = []
            for ch in t {
                if let (base, tone) = toneVowels[ch] {
                    marksAt.append((letters.count, tone))
                    letters.append(Character(base.lowercased()))
                } else if ch.isLetter {
                    letters.append(ch)
                }
            }
            let joined = answer.map(\.letters).joined()
            guard loose(letters) == loose(joined) else { return false }
            var typedTones = Array(repeating: 5, count: answer.count)
            var start = 0
            var bounds: [Range<Int>] = []
            for syl in answer { bounds.append(start..<(start + syl.letters.count)); start += syl.letters.count }
            for m in marksAt {
                guard let i = bounds.firstIndex(where: { $0.contains(m.index) }), typedTones[i] == 5 else { return false }
                typedTones[i] = m.tone
            }
            return typedTones == answer.map(\.tone)
        }
        // letters + optional digits
        var letters = ""
        var tonesAt: [(end: Int, tone: Int)] = []
        for ch in t {
            if let d = ch.wholeNumberValue {
                guard (0...5).contains(d) else { return false }
                tonesAt.append((letters.count, d == 0 ? 5 : d))
            } else if ch.isLetter {
                letters.append(ch)
            }
        }
        let joined = answer.map(\.letters).joined()
        guard loose(letters) == loose(joined) else { return false }
        // every given tone digit must sit at a syllable end and match that syllable's tone
        var ends: [Int: Int] = [:]
        var pos = 0
        for syl in answer { pos += syl.letters.count; ends[pos] = syl.tone }
        for (end, tone) in tonesAt {
            guard let want = ends[end], want == tone else { return false }
        }
        return true
    }

    /// ü typed as u is accepted.
    static func loose(_ s: String) -> String { s.replacingOccurrences(of: "ü", with: "u") }

    /// Tone patterns for the tone trainer: the correct one plus up to `count - 1` distractors.
    /// Neutral tones (5) are kept fixed: learners hear them as unstressed, not as a choice.
    public static func toneOptions(answerMarked: String, count: Int = 4,
                                   random: () -> Double = { Double.random(in: 0..<1) }) -> [String] {
        let syl = syllables(marked: answerMarked)
        guard !syl.isEmpty else { return [] }
        let correct = syl.map(\.tone)
        let variable = syl.indices.filter { syl[$0].tone != 5 }
        guard !variable.isEmpty else { return [render(syl, correct)] }
        var seen: Set<[Int]> = [correct]
        var out: [[Int]] = [correct]
        var tries = 0
        while out.count < count && tries < 200 {
            tries += 1
            var t = correct
            let changes = variable.count == 1 ? 1 : (random() < 0.6 ? 1 : 2)
            for _ in 0..<changes {
                let i = variable[Int(random() * Double(variable.count)) % variable.count]
                var nt = 1 + Int(random() * 4) % 4
                if nt == t[i] { nt = nt % 4 + 1 }
                t[i] = nt
            }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out.map { render(syl, $0) }
    }

    static func render(_ syl: [Syllable], _ tones: [Int]) -> String {
        zip(syl, tones).map { mark(letters: $0.letters, tone: $1) }.joined(separator: " ")
    }

    /// Tone numbers as a short label, e.g. "1 5".
    public static func toneDigits(marked: String) -> String {
        syllables(marked: marked).map { String($0.tone) }.joined(separator: " ")
    }
}
