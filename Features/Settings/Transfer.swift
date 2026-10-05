import Foundation
import SwiftData
import LexiLogic

/// CSV word lists and full JSON backup/restore.
@MainActor
enum Transfer {
    // MARK: CSV

    static let csvHeader = ["word", "definition", "example", "translation", "pos", "pronunciation"]

    /// Imports custom words into a deck. Duplicate lemmas (case-insensitive) are skipped.
    static func importCSV(result: Result<URL, Error>, deck: Deck, context: ModelContext) -> String {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            return importCSV(text: text, deck: deck, context: context)
        } catch {
            return String(localized: "Import failed: \(error.localizedDescription)")
        }
    }

    static func importCSV(text: String, deck: Deck, context: ModelContext) -> String {
        let records = CSV.records(text)
        guard !records.isEmpty else { return String(localized: "No rows found. The first row must be a header.") }
        let existing = Set(StudyService(context: context).customWords(deck: deck).map { $0.lemma.lowercased() })
        var added = 0, skipped = 0
        for r in records {
            guard let word = r["word"] ?? r["lemma"] ?? r["term"],
                  let def = r["definition"] ?? r["meaning"] ?? r["translation"] else { skipped += 1; continue }
            if existing.contains(word.lowercased()) { skipped += 1; continue }
            let w = CustomWord(deckID: deck.id, lang: deck.studyLang, lemma: word, definition: def)
            w.example = r["example"]
            w.translation = r["definition"] != nil ? r["translation"] : nil
            w.pos = r["pos"]
            if let p = r["pronunciation"] ?? r["pinyin"] ?? r["ipa"] {
                w.pronunciation = deck.studyLang == .zh && p.contains(where: \.isNumber) ? Pinyin.marked(numbered: p) : p
            }
            context.insert(w)
            added += 1
        }
        try? context.save()
        return String(localized: "Imported \(added) words. Skipped \(skipped) (duplicates or missing word/definition).")
    }

    /// Exports every word the deck has seen plus its custom words, with the deck's definitions.
    static func exportDeckCSV(deck: Deck, context: ModelContext) -> String {
        let s = StudyService(context: context)
        let keys = s.states(deck: deck).sorted { $0.introducedAt < $1.introducedAt }.map(\.wordKey)
        let custom = s.customWords(deck: deck).map(\.key).filter { !keys.contains($0) }
        var rows = [csvHeader]
        for c in s.cards(keys: keys + custom, deck: deck) {
            rows.append([c.lemma, c.definitions.first?.text ?? "", c.examples.first?.text ?? "",
                         c.translations.joined(separator: "; "), c.pos ?? "", c.pronunciation ?? ""])
        }
        return CSV.write(rows)
    }

    // MARK: JSON backup

    struct Backup: Codable {
        var format = "lexi-backup"
        var version = 1
        var createdAt = Date()
        var decks: [DeckDTO]
        var states: [StateDTO]
        var logs: [LogDTO]
        var userWords: [UserWordDTO]
        var collections: [CollectionDTO]
        var customWords: [CustomWordDTO]
        var settings: [String: String]
    }
    struct DeckDTO: Codable {
        var id: UUID, mode, study, explanation: String, minLevel: Int, categories: [String], dailyNewWords: Int
        var targetRetention: Double, showTargetDefinition, useTraditional: Bool, createdAt: Date, sortIndex: Int
    }
    struct StateDTO: Codable {
        var deckID: UUID, wordKey: String, state: Int, step: Int?, stability, difficulty: Double?
        var due: Date, lastReview: Date?, reps, lapses: Int, introducedAt: Date
    }
    struct LogDTO: Codable {
        var deckID: UUID, wordKey: String, rating: Int, reviewedAt: Date, responseMs, priorState: Int, source: String
    }
    struct UserWordDTO: Codable { var wordKey: String, favorite, alreadyKnow: Bool, collectionIDs: [UUID], updatedAt: Date }
    struct CollectionDTO: Codable { var id: UUID, name: String, createdAt: Date }
    struct CustomWordDTO: Codable {
        var id, deckID: UUID, lang, lemma: String, pos, pronunciation: String?, definition: String
        var example, translation: String?, createdAt: Date
    }

    static let settingKeys = [SettingKey.themeID, SettingKey.speechRate, SettingKey.spanishVoice, SettingKey.reminderCount,
                              SettingKey.reminderStart, SettingKey.reminderEnd, SettingKey.widgetInterval,
                              SettingKey.useTraditionalGlobal]

    static func backupJSON(context: ModelContext) throws -> String {
        func all<T: PersistentModel>(_ t: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
        var settings: [String: String] = [:]
        for k in settingKeys { if let v = AppGroup.defaults.object(forKey: k) { settings[k] = "\(v)" } }
        let b = Backup(
            decks: all(Deck.self).map { .init(id: $0.id, mode: $0.modeRaw, study: $0.studyLangRaw, explanation: $0.explanationLangRaw,
                                              minLevel: $0.minLevel, categories: $0.categories, dailyNewWords: $0.dailyNewWords,
                                              targetRetention: $0.targetRetention, showTargetDefinition: $0.showTargetDefinition,
                                              useTraditional: $0.useTraditional, createdAt: $0.createdAt, sortIndex: $0.sortIndex) },
            states: all(ReviewState.self).map { .init(deckID: $0.deckID, wordKey: $0.wordKey, state: $0.stateRaw, step: $0.step,
                                                      stability: $0.stability, difficulty: $0.difficulty, due: $0.due,
                                                      lastReview: $0.lastReview, reps: $0.reps, lapses: $0.lapses,
                                                      introducedAt: $0.introducedAt) },
            logs: all(ReviewLog.self).map { .init(deckID: $0.deckID, wordKey: $0.wordKey, rating: $0.rating, reviewedAt: $0.reviewedAt,
                                                  responseMs: $0.responseMs, priorState: $0.priorStateRaw, source: $0.source) },
            userWords: all(UserWord.self).map { .init(wordKey: $0.wordKey, favorite: $0.favorite, alreadyKnow: $0.alreadyKnow,
                                                      collectionIDs: $0.collectionIDs, updatedAt: $0.updatedAt) },
            collections: all(WordCollection.self).map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt) },
            customWords: all(CustomWord.self).map { .init(id: $0.id, deckID: $0.deckID, lang: $0.langRaw, lemma: $0.lemma, pos: $0.pos,
                                                          pronunciation: $0.pronunciation, definition: $0.definition,
                                                          example: $0.example, translation: $0.translation, createdAt: $0.createdAt) },
            settings: settings)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(b), as: UTF8.self)
    }

    /// Replaces all learning data with the backup. Returns a summary.
    static func restore(json: Data, context: ModelContext) throws -> String {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let b = try dec.decode(Backup.self, from: json)
        guard b.format == "lexi-backup" else { throw CocoaError(.fileReadCorruptFile) }
        try context.delete(model: ReviewLog.self)
        try context.delete(model: ReviewState.self)
        try context.delete(model: UserWord.self)
        try context.delete(model: WordCollection.self)
        try context.delete(model: CustomWord.self)
        try context.delete(model: Deck.self)
        for d in b.decks {
            let m = Deck(mode: StudyMode(rawValue: d.mode) ?? .dictionary, study: Lang(rawValue: d.study) ?? .en,
                         explanation: Lang(rawValue: d.explanation) ?? .en, minLevel: d.minLevel, categories: d.categories,
                         dailyNewWords: d.dailyNewWords, targetRetention: d.targetRetention, sortIndex: d.sortIndex)
            m.id = d.id; m.createdAt = d.createdAt
            m.showTargetDefinition = d.showTargetDefinition; m.useTraditional = d.useTraditional
            context.insert(m)
        }
        for s in b.states {
            let m = ReviewState(deckID: s.deckID, wordKey: s.wordKey, now: s.introducedAt)
            m.stateRaw = s.state; m.step = s.step; m.stability = s.stability; m.difficulty = s.difficulty
            m.due = s.due; m.lastReview = s.lastReview; m.reps = s.reps; m.lapses = s.lapses
            context.insert(m)
        }
        for l in b.logs {
            let m = ReviewLog(deckID: l.deckID, wordKey: l.wordKey, rating: .init(rawValue: l.rating) ?? .good,
                              reviewedAt: l.reviewedAt, responseMs: l.responseMs, priorState: nil, source: l.source)
            m.priorStateRaw = l.priorState
            context.insert(m)
        }
        for u in b.userWords {
            let m = UserWord(wordKey: u.wordKey)
            m.favorite = u.favorite; m.alreadyKnow = u.alreadyKnow; m.collectionIDs = u.collectionIDs; m.updatedAt = u.updatedAt
            context.insert(m)
        }
        for c in b.collections {
            let m = WordCollection(name: c.name)
            m.id = c.id; m.createdAt = c.createdAt
            context.insert(m)
        }
        for c in b.customWords {
            let m = CustomWord(deckID: c.deckID, lang: Lang(rawValue: c.lang) ?? .en, lemma: c.lemma, definition: c.definition)
            m.id = c.id; m.pos = c.pos; m.pronunciation = c.pronunciation; m.example = c.example
            m.translation = c.translation; m.createdAt = c.createdAt
            context.insert(m)
        }
        for (k, v) in b.settings where settingKeys.contains(k) {
            if let i = Int(v) { AppGroup.defaults.set(i, forKey: k) }
            else if let d = Double(v) { AppGroup.defaults.set(d, forKey: k) }
            else { AppGroup.defaults.set(v, forKey: k) }
        }
        try context.save()
        return String(localized: "Restored \(b.decks.count) decks, \(b.states.count) words and \(b.logs.count) reviews.")
    }
}
