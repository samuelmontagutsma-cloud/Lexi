import Foundation
import SQLite3

/// Language codes used by the bundled lexicon.
enum Lang: String, Codable, CaseIterable, Identifiable, Sendable {
    case en, es, zh
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return String(localized: "English")
        case .es: return String(localized: "Spanish")
        case .zh: return String(localized: "Chinese")
        }
    }
    var flag: String {
        switch self { case .en: return "🇺🇸"; case .es: return "🇪🇸"; case .zh: return "🇨🇳" }
    }
}

struct LexWord: Hashable, Sendable {
    let id: Int64
    let key: String
    let lang: Lang
    let lemma: String
    let pos: String?
    let rank: Int
    let level: Int
    let ipa: String?
    let pinyin: String?
    let traditional: String?
}

struct LexSense: Hashable, Sendable {
    let pos: String?
    let defLang: Lang
    let definition: String?
    let example: String?
    let exampleTranslation: String?
    let exampleTranslationLang: Lang?
    let exampleSource: String?
    let definitionMT: Bool
    let exampleTranslationMT: Bool
}

struct LexCredit: Hashable, Sendable { let name, license, url: String }

/// Read-only access to the bundled `lexi.sqlite` (built by tools/build_db.py).
final class Lexicon: @unchecked Sendable {
    static let shared = Lexicon()

    private var db: OpaquePointer?
    private let lock = NSLock()
    let isAvailable: Bool

    /// Database location: own bundle, or the containing app's bundle when running in the widget.
    static var databaseURL: URL? {
        if let url = Bundle.main.url(forResource: "lexi", withExtension: "sqlite") { return url }
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if let app = Bundle(url: appURL), let url = app.url(forResource: "lexi", withExtension: "sqlite") { return url }
        return nil
    }

    init(url: URL? = Lexicon.databaseURL) {
        guard let url else { isAvailable = false; return }
        // immutable=1: no locking or journal reads; the file never changes at run time.
        let uri = "file:\(url.path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        isAvailable = sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK
    }

    deinit { sqlite3_close(db) }

    // MARK: low-level

    private enum Bind { case int(Int64), text(String), null }

    private func query<T>(_ sql: String, _ args: [Bind] = [], row: (OpaquePointer) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static let wordCols = "w.id, w.word_key, w.lang, w.lemma, w.pos, w.freq_rank, w.level, w.ipa, w.pinyin, w.traditional"

    private static func word(_ s: OpaquePointer) -> LexWord {
        LexWord(id: sqlite3_column_int64(s, 0), key: text(s, 1) ?? "", lang: Lang(rawValue: text(s, 2) ?? "en") ?? .en,
                lemma: text(s, 3) ?? "", pos: text(s, 4), rank: Int(sqlite3_column_int64(s, 5)),
                level: Int(sqlite3_column_int64(s, 6)), ipa: text(s, 7), pinyin: text(s, 8), traditional: text(s, 9))
    }

    // MARK: words

    func word(key: String) -> LexWord? {
        query("SELECT \(Self.wordCols) FROM word w WHERE w.word_key = ?", [.text(key)], row: Self.word).first
    }

    func words(keys: [String]) -> [String: LexWord] {
        var out: [String: LexWord] = [:]
        for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for w in query("SELECT \(Self.wordCols) FROM word w WHERE w.word_key IN (\(marks))",
                           chunk.map { .text($0) }, row: Self.word) {
                out[w.key] = w
            }
        }
        return out
    }

    /// Next unseen words for a deck: lowest frequency rank at or above `minLevel`, optionally in categories.
    /// `isExcluded` filters words already in the deck or marked "already know".
    func newWords(lang: Lang, minLevel: Int, categories: [String], limit: Int,
                  isExcluded: (String) -> Bool) -> [LexWord] {
        var out: [LexWord] = []
        var offset: Int64 = 0
        let page: Int64 = 200
        let catFilter: String
        var baseArgs: [Bind] = [.text(lang.rawValue), .int(Int64(minLevel))]
        if categories.isEmpty {
            catFilter = ""
        } else {
            catFilter = " AND w.id IN (SELECT wc.word_id FROM word_category wc JOIN category c ON c.id = wc.category_id WHERE c.key IN (\(categories.map { _ in "?" }.joined(separator: ","))))"
            baseArgs += categories.map { .text($0) }
        }
        while out.count < limit {
            let rows = query("SELECT \(Self.wordCols) FROM word w WHERE w.lang = ? AND w.level >= ?\(catFilter) ORDER BY w.freq_rank LIMIT ? OFFSET ?",
                             baseArgs + [.int(page), .int(offset)], row: Self.word)
            if rows.isEmpty { break }
            for w in rows where !isExcluded(w.key) {
                out.append(w)
                if out.count == limit { break }
            }
            offset += page
        }
        return out
    }

    /// Random words of a language near a level, for game distractors.
    func randomWords(lang: Lang, near level: Int, count: Int, excluding: Set<String>) -> [LexWord] {
        let rows = query("SELECT \(Self.wordCols) FROM word w WHERE w.lang = ? AND w.level BETWEEN ? AND ? ORDER BY random() LIMIT ?",
                         [.text(lang.rawValue), .int(Int64(max(1, level - 1))), .int(Int64(level + 1)), .int(Int64(count + excluding.count + 4))],
                         row: Self.word)
        return Array(rows.filter { !excluding.contains($0.key) }.prefix(count))
    }

    func search(_ text: String, langs: [Lang] = Lang.allCases, limit: Int = 60) -> [LexWord] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let marks = langs.map { _ in "?" }.joined(separator: ",")
        // exact lemma first, then prefix, then substring; frequency order inside each group
        return query("""
            SELECT \(Self.wordCols) FROM word w JOIN word_search s ON s.word_id = w.id
            WHERE w.lang IN (\(marks)) AND s.text LIKE ?
            ORDER BY (lower(w.lemma) = ?) DESC, (lower(w.lemma) LIKE ?) DESC, w.freq_rank LIMIT ?
            """, langs.map { .text($0.rawValue) } + [.text("%\(q)%"), .text(q), .text("\(q)%"), .int(Int64(limit))],
                     row: Self.word)
    }

    // MARK: details

    func senses(wordID: Int64) -> [LexSense] {
        query("SELECT pos, def_lang, definition, example, example_translation, example_translation_lang, example_source, definition_mt, example_translation_mt FROM sense WHERE word_id = ? ORDER BY sense_order",
              [.int(wordID)]) { s in
            LexSense(pos: Self.text(s, 0), defLang: Lang(rawValue: Self.text(s, 1) ?? "en") ?? .en,
                     definition: Self.text(s, 2), example: Self.text(s, 3), exampleTranslation: Self.text(s, 4),
                     exampleTranslationLang: Self.text(s, 5).flatMap(Lang.init(rawValue:)), exampleSource: Self.text(s, 6),
                     definitionMT: sqlite3_column_int(s, 7) != 0, exampleTranslationMT: sqlite3_column_int(s, 8) != 0)
        }
    }

    func translations(wordID: Int64, to lang: Lang) -> [String] {
        translationsWithMT(wordID: wordID, to: lang).map(\.gloss)
    }

    /// Glosses plus whether they are machine translated.
    func translationsWithMT(wordID: Int64, to lang: Lang) -> [(gloss: String, mt: Bool)] {
        query("SELECT gloss, mt FROM translation WHERE word_id = ? AND target_lang = ? ORDER BY gloss_order",
              [.int(wordID), .text(lang.rawValue)]) { (Self.text($0, 0) ?? "", sqlite3_column_int($0, 1) != 0) }
    }

    /// Words with a given key prefix list, in frequency order (category/collection practice).
    func words(lang: Lang, category: String, limit: Int) -> [LexWord] {
        query("""
            SELECT \(Self.wordCols) FROM word w JOIN word_category wc ON wc.word_id = w.id
            JOIN category c ON c.id = wc.category_id WHERE w.lang = ? AND c.key = ? ORDER BY w.freq_rank LIMIT ?
            """, [.text(lang.rawValue), .text(category), .int(Int64(limit))], row: Self.word)
    }

    func categories(wordID: Int64) -> [String] {
        query("SELECT c.key FROM category c JOIN word_category wc ON wc.category_id = c.id WHERE wc.word_id = ?",
              [.int(wordID)]) { Self.text($0, 0) ?? "" }
    }

    func categoryCounts(lang: Lang) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: query("""
            SELECT c.key, COUNT(*) FROM word_category wc JOIN category c ON c.id = wc.category_id
            JOIN word w ON w.id = wc.word_id WHERE w.lang = ? GROUP BY c.key
            """, [.text(lang.rawValue)]) { (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))) })
    }

    func wordCount(lang: Lang, minLevel: Int = 1) -> Int {
        query("SELECT COUNT(*) FROM word WHERE lang = ? AND level >= ?", [.text(lang.rawValue), .int(Int64(minLevel))]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    func credits() -> [LexCredit] {
        query("SELECT name, license, url FROM credit ORDER BY id") {
            LexCredit(name: Self.text($0, 0) ?? "", license: Self.text($0, 1) ?? "", url: Self.text($0, 2) ?? "")
        }
    }

    func meta(_ key: String) -> String? {
        query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { Self.text($0, 0) }.first ?? nil
    }
}
