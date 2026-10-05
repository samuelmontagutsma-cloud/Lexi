import SwiftUI
import SwiftData
import FSRS
import LexiLogic

/// Which words a practice round uses.
enum PracticeSource: Hashable {
    case due, today, favorites, mistakes, allSeen
    case collection(UUID, String)
    case category(String)

    var title: String {
        switch self {
        case .due: return String(localized: "Due for review")
        case .today: return String(localized: "Today's new words")
        case .favorites: return String(localized: "Favorites")
        case .mistakes: return String(localized: "Mistakes")
        case .allSeen: return String(localized: "All my words")
        case .collection(_, let n): return n
        case .category(let c): return Categories.name(c)
        }
    }
}

enum GameChoice: String, CaseIterable, Identifiable {
    case mixed, wordToMeaning, meaningToWord, matching, spelling, listening, fillBlank, toneTrainer
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mixed: return "Mixed"
        case .wordToMeaning: return "Word → meaning"
        case .meaningToWord: return "Meaning → word"
        case .matching: return "Matching pairs"
        case .spelling: return "Spelling"
        case .listening: return "Listening"
        case .fillBlank: return "Fill in the blank"
        case .toneTrainer: return "Tone trainer"
        }
    }
    var symbol: String {
        switch self {
        case .mixed: return "shuffle"
        case .wordToMeaning: return "text.badge.checkmark"
        case .meaningToWord: return "character.cursor.ibeam"
        case .matching: return "square.grid.2x2"
        case .spelling: return "keyboard"
        case .listening: return "ear"
        case .fillBlank: return "text.insert"
        case .toneTrainer: return "waveform"
        }
    }
}

struct PracticeHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WordCollection.name) private var collections: [WordCollection]
    @State private var source: PracticeSource = .due
    @State private var session: GameSession?
    @State private var emptyMessage: String?

    private var study: StudyService { StudyService(context: context) }

    var body: some View {
        NavigationStack {
            List {
                if let deck = study.deck(id: model.deckID) {
                    Section {
                        Picker("Words", selection: $source) {
                            Text("\(PracticeSource.due.title) (\(study.dueCount(deck: deck)))").tag(PracticeSource.due)
                            Text(PracticeSource.today.title).tag(PracticeSource.today)
                            Text(PracticeSource.mistakes.title).tag(PracticeSource.mistakes)
                            Text(PracticeSource.favorites.title).tag(PracticeSource.favorites)
                            Text(PracticeSource.allSeen.title).tag(PracticeSource.allSeen)
                            ForEach(collections) { c in Text(c.name).tag(PracticeSource.collection(c.id, c.name)) }
                            ForEach(Categories.all, id: \.self) { c in Text(Categories.name(c)).tag(PracticeSource.category(c)) }
                        }
                    } header: { Text("\(deck.flag) \(deck.title)") } footer: {
                        Text("Every answer updates the review schedule. Fast and correct = Easy, slow = Hard, wrong = Again.")
                    }
                    Section("Games") {
                        ForEach(GameChoice.allCases.filter { $0 != .toneTrainer || deck.studyLang == .zh }) { g in
                            Button { start(g, deck: deck) } label: {
                                Label(g.title, systemImage: g.symbol).foregroundStyle(.primary)
                            }
                        }
                    }
                    if let emptyMessage { Section { Text(emptyMessage).foregroundStyle(.secondary) } }
                } else {
                    ContentUnavailableView("No decks", systemImage: "rectangle.stack")
                }
            }
            .navigationTitle("Practice")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $session, onDismiss: { model.refresh(); WidgetBridge.reload() }) { s in
                GameSessionView(session: s)
            }
        }
    }

    private func start(_ game: GameChoice, deck: Deck) {
        let keys = keys(for: source, deck: deck)
        guard !keys.isEmpty else {
            emptyMessage = String(localized: "No words in “\(source.title)” yet. Swipe through new words in the feed first.")
            return
        }
        let n = game == .matching ? 6 : 10
        let cards = study.cards(keys: Array(keys.prefix(game == .matching ? 6 : 40)), deck: deck)
        guard !cards.isEmpty else { return }
        emptyMessage = nil
        session = GameSession(deck: deck, cards: Array(cards.prefix(n)), game: game, context: context)
    }

    private func keys(for source: PracticeSource, deck: Deck) -> [String] {
        let s = study
        let deckKeys = Set(s.states(deck: deck).map(\.wordKey))
        switch source {
        case .due:
            let due = s.dueKeys(deck: deck)
            if !due.isEmpty { return due }
            // Nothing due: practice the most recently studied words instead.
            return s.states(deck: deck).sorted { ($0.lastReview ?? $0.introducedAt) > ($1.lastReview ?? $1.introducedAt) }.map(\.wordKey)
        case .today:
            let start = Calendar.current.startOfDay(for: .now)
            return s.states(deck: deck).filter { $0.introducedAt >= start }.map(\.wordKey)
        case .favorites:
            return s.favoriteKeys().filter { $0.hasPrefix(deck.studyLang.rawValue + ":") || deckKeys.contains($0) }
        case .mistakes:
            return s.mistakeKeys(deck: deck)
        case .allSeen:
            return Array(deckKeys).shuffled()
        case .collection(let id, _):
            guard let c = collections.first(where: { $0.id == id }) else { return [] }
            return s.keys(in: c).filter { $0.hasPrefix(deck.studyLang.rawValue + ":") || deckKeys.contains($0) }
        case .category(let c):
            // Seen words in the topic first, then unseen ones (they get introduced by the game).
            let words = Lexicon.shared.words(lang: deck.studyLang, category: c, limit: 300)
            let seen = words.filter { deckKeys.contains($0.key) }.map(\.key)
            let unseen = words.filter { !deckKeys.contains($0.key) && $0.level >= deck.minLevel }.map(\.key)
            return seen.shuffled() + unseen
        }
    }
}
