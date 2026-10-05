import Foundation

public enum TextMatch {
    /// Case-, accent- and punctuation-insensitive comparison for typed answers (es: "esta" ≠ "está" is
    /// still accepted; accents are a spelling detail the feedback shows).
    public static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    public static func equal(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }

    /// True when the accents differ but the letters match (shown as "check the accents").
    public static func accentOnly(_ typed: String, _ answer: String) -> Bool {
        equal(typed, answer) && typed.lowercased().trimmingCharacters(in: .whitespaces) != answer.lowercased()
    }

    /// Replaces the first occurrence of `word` (or an inflected form starting with it) with a blank.
    /// Returns nil when the sentence does not contain the word.
    public static func blank(_ sentence: String, word: String, isChinese: Bool) -> String? {
        let blank = "_____"
        if isChinese {
            guard let r = sentence.range(of: word) else { return nil }
            return sentence.replacingCharacters(in: r, with: blank)
        }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var search = sentence.startIndex..<sentence.endIndex
        while let r = sentence.range(of: word, options: opts, range: search) {
            let before = r.lowerBound == sentence.startIndex ? nil : sentence[sentence.index(before: r.lowerBound)]
            if before == nil || !before!.isLetter {
                var end = r.upperBound
                while end < sentence.endIndex, sentence[end].isLetter, sentence.distance(from: r.upperBound, to: end) < 4 {
                    end = sentence.index(after: end)
                }
                if end < sentence.endIndex, sentence[end].isLetter { search = r.upperBound..<sentence.endIndex; continue }
                return sentence.replacingCharacters(in: r.lowerBound..<end, with: blank)
            }
            search = r.upperBound..<sentence.endIndex
        }
        return nil
    }
}
