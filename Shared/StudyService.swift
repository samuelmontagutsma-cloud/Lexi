import Foundation
import SwiftData
import FSRS
import LexiLogic

/// All reads and writes of learning state. Used by the app and the widget extension.
@MainActor
struct StudyService {
    let context: ModelContext
    var lexicon: Lexicon = .shared
    var now: () -> Date = { .now }
    var calendar: Calendar = .current

    // MARK: decks

    func decks() -> [Deck] {
        (try? context.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]))) ?? []
    }

    func deck(id: UUID?) -> Deck? {
        guard let id else { return decks().first }
        var d = FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d).first) ?? decks().first
    }

    func fsrs(for deck: Deck) -> FSRS {
        var p = FSRSParameters()
        p.desiredRetention = min(0.95, max(0.80, deck.targetRetention))
        return FSRS(parameters: p)
    }

    // MARK: review state

    func states(deck: Deck) -> [ReviewState] {
        let id = deck.id
        return (try? context.fetch(FetchDescriptor<ReviewState>(predicate: #Predicate { $0.deckID == id }))) ?? []
    }

    func state(deck: Deck, key: String) -> ReviewState? {
        let sid = "\(deck.id.uuidString)|\(key)"
        var d = FetchDescriptor<ReviewState>(predicate: #Predicate { $0.id == sid })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Due review keys (due now or earlier), most overdue first.
    func dueKeys(deck: Deck, limit: Int = 500) -> [String] {
        let id = deck.id
        let t = now()
        var d = FetchDescriptor<ReviewState>(predicate: #Predicate { $0.deckID == id && $0.due <= t },
                                             sortBy: [SortDescriptor(\.due)])
        d.fetchLimit = limit
        return ((try? context.fetch(d)) ?? []).map(\.wordKey)
    }

    func dueCount(deck: Deck) -> Int {
        let id = deck.id
        let t = now()
        return (try? context.fetchCount(FetchDescriptor<ReviewState>(predicate: #Predicate { $0.deckID == id && $0.due <= t }))) ?? 0
    }

    func introducedToday(deck: Deck) -> Int {
        let id = deck.id
        let start = calendar.startOfDay(for: now())
        return (try? context.fetchCount(FetchDescriptor<ReviewState>(
            predicate: #Predicate { $0.deckID == id && $0.introducedAt >= start }))) ?? 0
    }

    /// Extra new words the user asked for today ("learn more"), per deck.
    func extraNewToday(deck: Deck) -> Int {
        let k = extraKey(deck)
        return AppGroup.defaults.integer(forKey: k)
    }

    func addExtraNewToday(deck: Deck, _ n: Int) {
        AppGroup.defaults.set(extraNewToday(deck: deck) + n, forKey: extraKey(deck))
    }

    private func extraKey(_ deck: Deck) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        return "extraNew|\(deck.id.uuidString)|\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func newWordsLeftToday(deck: Deck) -> Int {
        max(0, deck.dailyNewWords + extraNewToday(deck: deck) - introducedToday(deck: deck))
    }

    /// Next new word keys for the deck: custom words first (the user added them on purpose), then the
    /// lowest frequency rank at or above the deck level, in the deck's categories, not "already know".
    func nextNewKeys(deck: Deck, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let seen = Set(states(deck: deck).map(\.wordKey))
        let known = alreadyKnownKeys()
        var out: [String] = customWords(deck: deck).map(\.key).filter { !seen.contains($0) }
        if out.count >= count { return Array(out.prefix(count)) }
        let words = lexicon.newWords(lang: deck.studyLang, minLevel: deck.minLevel, categories: deck.categories,
                                     limit: count - out.count) { seen.contains($0) || known.contains($0) }
        out += words.map(\.key)
        return out
    }

    /// Creates the FSRS state for a word the user sees for the first time. Idempotent.
    @discardableResult
    func introduce(deck: Deck, key: String) -> ReviewState {
        if let s = state(deck: deck, key: key) { return s }
        let s = ReviewState(deckID: deck.id, wordKey: key, now: now())
        context.insert(s)
        return s
    }

    /// Applies one graded answer: FSRS update + log. Creates the state if the word was never seen.
    @discardableResult
    func grade(deck: Deck, key: String, rating: Rating, responseMs: Int, source: GameKind) -> FSRSCard {
        let s = introduce(deck: deck, key: key)
        let prior = s.reps == 0 && s.lastReview == nil ? nil : CardState(rawValue: s.stateRaw)
        let t = now()
        let next = fsrs(for: deck).review(s.card, rating: rating, at: t)
        s.card = next
        context.insert(ReviewLog(deckID: deck.id, wordKey: key, rating: rating, reviewedAt: t,
                                 responseMs: responseMs, priorState: prior, source: source.rawValue))
        try? context.save()
        return next
    }

    // MARK: user words

    func userWord(_ key: String, create: Bool) -> UserWord? {
        var d = FetchDescriptor<UserWord>(predicate: #Predicate { $0.wordKey == key })
        d.fetchLimit = 1
        if let u = try? context.fetch(d).first { return u }
        guard create else { return nil }
        let u = UserWord(wordKey: key)
        context.insert(u)
        return u
    }

    func isFavorite(_ key: String) -> Bool { userWord(key, create: false)?.favorite ?? false }

    func toggleFavorite(_ key: String) {
        let u = userWord(key, create: true)!
        u.favorite.toggle()
        u.updatedAt = now()
        try? context.save()
    }

    /// "Already know": never offered as a new word again, and removed from every deck's schedule
    /// if it was only just introduced (no answers yet).
    func setAlreadyKnow(_ key: String, _ value: Bool) {
        let u = userWord(key, create: true)!
        u.alreadyKnow = value
        u.updatedAt = now()
        if value {
            let k = key
            let fresh = (try? context.fetch(FetchDescriptor<ReviewState>(predicate: #Predicate { $0.wordKey == k && $0.reps == 0 }))) ?? []
            fresh.forEach(context.delete)
        }
        try? context.save()
    }

    func alreadyKnownKeys() -> Set<String> {
        Set(((try? context.fetch(FetchDescriptor<UserWord>(predicate: #Predicate { $0.alreadyKnow }))) ?? []).map(\.wordKey))
    }

    func favoriteKeys() -> [String] {
        ((try? context.fetch(FetchDescriptor<UserWord>(predicate: #Predicate { $0.favorite },
                                                       sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []).map(\.wordKey)
    }

    func collections() -> [WordCollection] {
        (try? context.fetch(FetchDescriptor<WordCollection>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    func keys(in collection: WordCollection) -> [String] {
        let all = (try? context.fetch(FetchDescriptor<UserWord>())) ?? []
        return all.filter { $0.collectionIDs.contains(collection.id) }.map(\.wordKey)
    }

    func setMembership(_ key: String, collection: WordCollection, member: Bool) {
        let u = userWord(key, create: true)!
        if member, !u.collectionIDs.contains(collection.id) { u.collectionIDs.append(collection.id) }
        if !member { u.collectionIDs.removeAll { $0 == collection.id } }
        u.updatedAt = now()
        try? context.save()
    }

    /// Words answered wrong (Again) in the last `days` days, most recent first.
    func mistakeKeys(deck: Deck?, days: Int = 30) -> [String] {
        let since = calendar.date(byAdding: .day, value: -days, to: now()) ?? .distantPast
        let again = Rating.again.rawValue
        let logs = (try? context.fetch(FetchDescriptor<ReviewLog>(
            predicate: #Predicate { $0.rating == again && $0.reviewedAt >= since },
            sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]))) ?? []
        var seen = Set<String>()
        return logs.filter { deck == nil || $0.deckID == deck!.id }.map(\.wordKey).filter { seen.insert($0).inserted }
    }

    // MARK: custom words

    func customWords(deck: Deck) -> [CustomWord] {
        let id = deck.id
        return (try? context.fetch(FetchDescriptor<CustomWord>(predicate: #Predicate { $0.deckID == id },
                                                               sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func customWord(key: String) -> CustomWord? {
        guard key.hasPrefix("custom:"), let id = UUID(uuidString: String(key.dropFirst(7))) else { return nil }
        var d = FetchDescriptor<CustomWord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: cards

    func card(key: String, deck: Deck) -> WordCard? {
        if let c = customWord(key: key) { return CardFactory.card(for: c) }
        guard let w = lexicon.word(key: key) else { return nil }
        return CardFactory(lexicon: lexicon).card(for: w, mode: deck.mode, explanation: deck.explanationLang)
    }

    func cards(keys: [String], deck: Deck) -> [WordCard] {
        let words = lexicon.words(keys: keys.filter { !$0.hasPrefix("custom:") })
        let factory = CardFactory(lexicon: lexicon)
        return keys.compactMap { k in
            if let w = words[k] { return factory.card(for: w, mode: deck.mode, explanation: deck.explanationLang) }
            return customWord(key: k).map(CardFactory.card(for:))
        }
    }

    /// Deck for a word key when the caller has none (search, favorites): the first deck that studies
    /// that language, preferring one that already holds the word.
    func bestDeck(for key: String) -> Deck? {
        let lang = Lang(rawValue: String(key.prefix { $0 != ":" }))
        let all = decks()
        if let d = all.first(where: { state(deck: $0, key: key) != nil }) { return d }
        if let c = customWord(key: key) { return deck(id: c.deckID) }
        return all.first { $0.studyLang == lang }
    }

    // MARK: stats

    func logs(since: Date) -> [ReviewLog] {
        (try? context.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.reviewedAt >= since },
                                                       sortBy: [SortDescriptor(\.reviewedAt)]))) ?? []
    }

    func learnedCount(deck: Deck) -> Int {
        let id = deck.id
        let review = CardState.review.rawValue
        return (try? context.fetchCount(FetchDescriptor<ReviewState>(
            predicate: #Predicate { $0.deckID == id && $0.stateRaw == review }))) ?? 0
    }

    func seenCount(deck: Deck) -> Int {
        let id = deck.id
        return (try? context.fetchCount(FetchDescriptor<ReviewState>(predicate: #Predicate { $0.deckID == id }))) ?? 0
    }

    func streak() -> Int {
        let since = calendar.date(byAdding: .day, value: -400, to: now()) ?? .distantPast
        let days = Set(logs(since: since).map { calendar.startOfDay(for: $0.reviewedAt) })
        return StatsMath.streak(reviewDays: days, today: now(), calendar: calendar)
    }
}
