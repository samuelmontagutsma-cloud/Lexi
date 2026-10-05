import Foundation

/// Everything a card, game or widget shows for one word in one deck.
struct WordCard: Identifiable, Hashable, Sendable {
    struct Definition: Hashable, Sendable {
        let pos: String?
        let text: String
    }
    struct Example: Hashable, Sendable {
        let text: String
        let translation: String?
    }

    let key: String
    let lang: Lang
    let lemma: String
    let traditional: String?
    let pos: String?
    /// IPA for en/es, pinyin with tone marks for zh.
    let pronunciation: String?
    let level: Int
    let rank: Int
    /// Definitions in the deck's explanation language.
    let definitions: [Definition]
    /// Learn mode: short translations into the explanation language.
    let translations: [String]
    let examples: [Example]
    /// True when the explanation language had no data and English was shown instead.
    let usedFallback: Bool
    let isCustom: Bool
    /// The translations / definitions in the explanation language are machine translated.
    var meaningMT: Bool = false
    /// The example's translation is machine translated.
    var exampleMT: Bool = false

    var id: String { key }

    func headword(traditional useTrad: Bool) -> String {
        useTrad ? (traditional ?? lemma) : lemma
    }

    /// The text a game asks about in a deck: translation (learn) or definition (dictionary).
    var meaning: String {
        if let t = translations.first, !t.isEmpty { return translations.prefix(3).joined(separator: "; ") }
        return definitions.first?.text ?? ""
    }

    var shortMeaning: String {
        if let t = translations.first, !t.isEmpty { return t }
        let d = definitions.first?.text ?? ""
        return d.count > 80 ? String(d.prefix(77)) + "…" : d
    }

    var levelLabel: String { Levels.label(lang: lang, level: level) }
}

enum Levels {
    /// en/es: CEFR-like bands from frequency rank (1=A1 … 6=C2). zh: HSK 1–6, 7 = beyond HSK 6.
    static func label(lang: Lang, level: Int) -> String {
        switch lang {
        case .zh: return level <= 6 ? "HSK \(level)" : "HSK 6+"
        default: return ["A1", "A2", "B1", "B2", "C1", "C2"][max(0, min(5, level - 1))]
        }
    }
    static func range(for lang: Lang) -> ClosedRange<Int> { lang == .zh ? 1...7 : 1...6 }

    static func pickerLabel(lang: Lang, level: Int) -> String {
        switch lang {
        case .zh: return level <= 6 ? "HSK \(level)" : String(localized: "Beyond HSK 6")
        default:
            let names = [String(localized: "Beginner"), String(localized: "Elementary"),
                         String(localized: "Intermediate"), String(localized: "Upper intermediate"),
                         String(localized: "Advanced"), String(localized: "Proficient")]
            return "\(label(lang: lang, level: level)) · \(names[max(0, min(5, level - 1))])"
        }
    }
}

enum Categories {
    static let all = ["business", "science", "food", "travel", "emotions", "nature", "technology",
                      "art", "health", "society", "sports", "education", "home", "body", "time"]

    static func name(_ key: String) -> String {
        switch key {
        case "business": return String(localized: "Business")
        case "science": return String(localized: "Science")
        case "food": return String(localized: "Food")
        case "travel": return String(localized: "Travel")
        case "emotions": return String(localized: "Emotions")
        case "nature": return String(localized: "Nature")
        case "technology": return String(localized: "Technology")
        case "art": return String(localized: "Art")
        case "health": return String(localized: "Health")
        case "society": return String(localized: "Society")
        case "sports": return String(localized: "Sports")
        case "education": return String(localized: "Education")
        case "home": return String(localized: "Home")
        case "body": return String(localized: "Body")
        case "time": return String(localized: "Time")
        default: return key.capitalized
        }
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "business": return "briefcase"
        case "science": return "atom"
        case "food": return "fork.knife"
        case "travel": return "airplane"
        case "emotions": return "heart"
        case "nature": return "leaf"
        case "technology": return "cpu"
        case "art": return "paintpalette"
        case "health": return "cross.case"
        case "society": return "building.columns"
        case "sports": return "figure.run"
        case "education": return "graduationcap"
        case "home": return "house"
        case "body": return "figure.stand"
        case "time": return "clock"
        default: return "tag"
        }
    }
}

enum PartOfSpeech {
    static func short(_ pos: String?, in lang: Lang) -> String? {
        guard let p = pos?.lowercased(), !p.isEmpty else { return nil }
        let map: [String: String] = [
            "noun": "n.", "verb": "v.", "adj": "adj.", "adv": "adv.", "prep": "prep.", "pron": "pron.",
            "conj": "conj.", "det": "det.", "article": "art.", "intj": "interj.", "num": "num.",
            "particle": "part.", "classifier": "cl.", "idiom": "idiom", "phrase": "phr.",
        ]
        return map[p] ?? p
    }
}

/// Builds `WordCard`s for a deck from the lexicon and custom words.
struct CardFactory {
    let lexicon: Lexicon

    func card(for word: LexWord, mode: StudyMode, explanation: Lang) -> WordCard {
        let senses = lexicon.senses(wordID: word.id)
        var defs: [WordCard.Definition] = []
        var examples: [WordCard.Example] = []
        var translations: [String] = []
        var usedFallback = false
        var meaningMT = false
        var exampleMT = false

        switch mode {
        case .dictionary:
            for s in senses where s.defLang == word.lang {
                if let d = s.definition, !d.isEmpty { defs.append(.init(pos: s.pos, text: d)) }
                if let e = s.example, !e.isEmpty, examples.count < 2 { examples.append(.init(text: e, translation: nil)) }
            }
        case .learn:
            let tr = lexicon.translationsWithMT(wordID: word.id, to: explanation)
            translations = tr.map(\.gloss)
            meaningMT = tr.contains { $0.mt }
            var pick = senses.filter { $0.defLang == explanation }
            if translations.isEmpty || pick.isEmpty {
                // No data in the chosen language: show English, and say so on the card.
                if explanation != .en {
                    usedFallback = true
                    if translations.isEmpty { translations = lexicon.translations(wordID: word.id, to: .en); meaningMT = false }
                    if pick.isEmpty { pick = senses.filter { $0.defLang == .en } }
                }
            }
            for s in pick {
                if let d = s.definition, !d.isEmpty { defs.append(.init(pos: s.pos, text: d)) }
                if s.definitionMT { meaningMT = true }
            }
            // Prefer an example translated into the explanation language, then English, then untranslated.
            let ordered = senses.filter { $0.example != nil }.sorted { a, b in
                score(a, explanation) < score(b, explanation)
            }
            if let s = ordered.first, let e = s.example {
                let tr = s.exampleTranslation
                if s.exampleTranslationLang != explanation, tr != nil { usedFallback = true }
                exampleMT = s.exampleTranslationMT
                examples.append(.init(text: e, translation: tr))
            }
        }
        let pron = word.lang == .zh ? word.pinyin : word.ipa
        var card = WordCard(key: word.key, lang: word.lang, lemma: word.lemma, traditional: word.traditional,
                            pos: word.pos, pronunciation: pron, level: word.level, rank: word.rank,
                            definitions: defs, translations: translations, examples: examples,
                            usedFallback: usedFallback, isCustom: false)
        card.meaningMT = meaningMT
        card.exampleMT = exampleMT
        return card
    }

    private func score(_ s: LexSense, _ explanation: Lang) -> Int {
        if s.exampleTranslationLang == explanation { return 0 }
        if s.exampleTranslationLang == .en { return 1 }
        return 2
    }

    static func card(for w: CustomWord) -> WordCard {
        WordCard(key: w.key, lang: w.lang, lemma: w.lemma, traditional: nil, pos: w.pos,
                 pronunciation: w.pronunciation, level: 0, rank: 0,
                 definitions: [.init(pos: w.pos, text: w.definition)],
                 translations: w.translation.map { [$0] } ?? [],
                 examples: w.example.map { [.init(text: $0, translation: nil)] } ?? [],
                 usedFallback: false, isCustom: true)
    }
}
