import SwiftUI
import SwiftData
import FSRS
import LexiLogic

/// One practice round. Holds the cards, picks a game per card (Mixed) and grades every answer into FSRS.
@MainActor
@Observable
final class GameSession: Identifiable {
    struct Result: Identifiable {
        let id = UUID()
        let card: WordCard
        let correct: Bool
        let rating: Rating
        let kind: GameKind
    }

    let id = UUID()
    let deck: Deck
    let cards: [WordCard]
    let game: GameChoice
    private let context: ModelContext
    /// Extra cards from the same deck level, used as wrong options.
    let distractors: [WordCard]
    private(set) var index = 0
    private(set) var results: [Result] = []
    private(set) var plan: [GameKind] = []

    init(deck: Deck, cards: [WordCard], game: GameChoice, context: ModelContext) {
        self.deck = deck
        self.cards = cards
        self.game = game
        self.context = context
        let lex = Lexicon.shared
        let level = cards.map(\.level).filter { $0 > 0 }.sorted().dropFirst(cards.count / 2).first ?? deck.minLevel
        let pool = lex.randomWords(lang: deck.studyLang, near: level, count: 24, excluding: Set(cards.map(\.key)))
        let factory = CardFactory(lexicon: lex)
        distractors = pool.map { factory.card(for: $0, mode: deck.mode, explanation: deck.explanationLang) }
            .filter { !$0.meaning.isEmpty }
        plan = cards.map { Self.kind(for: $0, game: game) }
    }

    var isFinished: Bool { game == .matching ? !results.isEmpty : index >= cards.count }
    var current: WordCard? { index < cards.count ? cards[index] : nil }
    var currentKind: GameKind { index < plan.count ? plan[index] : .wordToMeaning }
    var correctCount: Int { results.filter(\.correct).count }

    static func kind(for card: WordCard, game: GameChoice) -> GameKind {
        let canBlank = card.examples.first.flatMap {
            TextMatch.blank($0.text, word: card.lemma, isChinese: card.lang == .zh)
        } != nil
        switch game {
        case .wordToMeaning: return .wordToMeaning
        case .meaningToWord: return .meaningToWord
        case .matching: return .matching
        case .spelling: return .spelling
        case .listening: return .listening
        case .fillBlank: return canBlank ? .fillBlank : .wordToMeaning
        case .toneTrainer: return card.lang == .zh && card.pronunciation != nil ? .toneTrainer : .listening
        case .mixed:
            var options: [GameKind] = [.wordToMeaning, .meaningToWord, .listening, .spelling]
            if canBlank { options += [.fillBlank, .fillBlank] }
            if card.lang == .zh, card.pronunciation != nil { options.append(.toneTrainer) }
            return options.randomElement()!
        }
    }

    /// Grades one answer and moves on (except in matching, which records all pairs at the end).
    func record(_ card: WordCard, correct: Bool, seconds: Double, kind: GameKind, answerLength: Int = 0,
                usedHint: Bool = false, advance: Bool = true) {
        let rating = Grader.rating(kind: kind, correct: correct, seconds: seconds, answerLength: answerLength, usedHint: usedHint)
        StudyService(context: context).grade(deck: deck, key: card.key, rating: rating,
                                             responseMs: Int(seconds * 1000), source: kind)
        results.append(Result(card: card, correct: correct, rating: rating, kind: kind))
        if advance { index += 1 }
    }

    /// Wrong options: other cards' meanings (or headwords), never equal to the right one.
    func options(for card: WordCard, count: Int = 4, showWords: Bool) -> [WordCard] {
        let others = (cards + distractors).filter { o in
            o.key != card.key && (showWords ? o.lemma != card.lemma : o.meaning.lowercased() != card.meaning.lowercased())
        }
        var seen = Set<String>()
        let unique = others.shuffled().filter { seen.insert(showWords ? $0.lemma : $0.meaning.lowercased()).inserted }
        return (Array(unique.prefix(count - 1)) + [card]).shuffled()
    }
}

struct GameSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: GameSession

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedBackground()
                Group {
                    if session.isFinished {
                        GameSummaryView(session: session) { dismiss() }
                    } else if session.game == .matching {
                        MatchingGameView(session: session)
                    } else if let card = session.current {
                        question(card: card, kind: session.currentKind)
                            .id("\(session.index)")
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
                    }
                }
                .foregroundStyle(model.theme.text)
                .padding()
                .animation(.snappy, value: session.index)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Speech.shared.stop(); dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                }
                ToolbarItem(placement: .principal) {
                    if !session.isFinished && session.game != .matching {
                        ProgressView(value: Double(session.index), total: Double(session.cards.count)).frame(width: 160)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func question(card: WordCard, kind: GameKind) -> some View {
        switch kind {
        case .wordToMeaning, .meaningToWord, .listening, .fillBlank, .toneTrainer, .flashcard, .matching, .widget:
            ChoiceQuestionView(session: session, card: card, kind: kind)
        case .spelling:
            SpellingQuestionView(session: session, card: card)
        }
    }
}

struct GameSummaryView: View {
    @Environment(AppModel.self) private var model
    let session: GameSession
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("\(session.correctCount) / \(session.results.count)").font(.system(size: 56, weight: .bold, design: .rounded))
            Text("correct").foregroundStyle(model.theme.secondary)
            List(session.results) { r in
                HStack {
                    Image(systemName: r.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.correct ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(r.card.lemma).font(.headline)
                        Text(r.card.shortMeaning).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(ratingName(r.rating)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .scrollContentBackground(.hidden)
            Button("Done", action: onClose).buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func ratingName(_ r: Rating) -> String {
        switch r {
        case .again: return String(localized: "Again")
        case .hard: return String(localized: "Hard")
        case .good: return String(localized: "Good")
        case .easy: return String(localized: "Easy")
        }
    }
}
