import Foundation
import SwiftData
import FSRS

enum StudyMode: String, Codable, CaseIterable, Sendable {
    case dictionary   // word, definition and example in one language
    case learn        // target-language word + translation into the explanation language
}

/// A study deck: one mode + one language (or pair), with its own level, topics and daily goal.
@Model
final class Deck {
    @Attribute(.unique) var id: UUID
    var modeRaw: String
    var studyLangRaw: String
    var explanationLangRaw: String
    var minLevel: Int
    var categories: [String]
    var dailyNewWords: Int
    var targetRetention: Double
    var showTargetDefinition: Bool
    var useTraditional: Bool
    var createdAt: Date
    var sortIndex: Int

    init(mode: StudyMode, study: Lang, explanation: Lang, minLevel: Int = 1, categories: [String] = [],
         dailyNewWords: Int = 5, targetRetention: Double = 0.90, sortIndex: Int = 0) {
        id = UUID()
        modeRaw = mode.rawValue
        studyLangRaw = study.rawValue
        explanationLangRaw = explanation.rawValue
        self.minLevel = minLevel
        self.categories = categories
        self.dailyNewWords = dailyNewWords
        self.targetRetention = targetRetention
        showTargetDefinition = false
        useTraditional = false
        createdAt = .now
        self.sortIndex = sortIndex
    }

    var mode: StudyMode { StudyMode(rawValue: modeRaw) ?? .dictionary }
    var studyLang: Lang { Lang(rawValue: studyLangRaw) ?? .en }
    var explanationLang: Lang { Lang(rawValue: explanationLangRaw) ?? .en }

    var title: String {
        switch mode {
        case .dictionary: return studyLang.displayName
        case .learn: return "\(studyLang.displayName) → \(explanationLang.displayName)"
        }
    }
    var shortTitle: String {
        mode == .dictionary ? studyLang.rawValue.uppercased()
            : "\(studyLang.rawValue.uppercased())→\(explanationLang.rawValue.uppercased())"
    }
    var flag: String { studyLang.flag }

    /// Decks offered by this build (scope approved 2026-10-04).
    static let supportedKinds: [(StudyMode, Lang, Lang)] = [
        (.dictionary, .en, .en), (.dictionary, .es, .es), (.learn, .zh, .en), (.learn, .zh, .es),
    ]
}

/// FSRS memory state of one word in one deck.
@Model
final class ReviewState {
    /// "deckID|wordKey" (compound unique key; #Unique needs iOS 18).
    @Attribute(.unique) var id: String
    var deckID: UUID
    var wordKey: String
    var stateRaw: Int
    var step: Int?
    var stability: Double?
    var difficulty: Double?
    var due: Date
    var lastReview: Date?
    var reps: Int
    var lapses: Int
    var introducedAt: Date

    init(deckID: UUID, wordKey: String, now: Date = .now) {
        id = "\(deckID.uuidString)|\(wordKey)"
        self.deckID = deckID
        self.wordKey = wordKey
        stateRaw = CardState.learning.rawValue
        step = 0
        due = now
        reps = 0
        lapses = 0
        introducedAt = now
    }

    var card: FSRSCard {
        get {
            var c = FSRSCard(due: due)
            c.state = CardState(rawValue: stateRaw) ?? .learning
            c.step = step
            c.stability = stability
            c.difficulty = difficulty
            c.lastReview = lastReview
            c.reps = reps
            c.lapses = lapses
            return c
        }
        set {
            stateRaw = newValue.state.rawValue
            step = newValue.step
            stability = newValue.stability
            difficulty = newValue.difficulty
            due = newValue.due
            lastReview = newValue.lastReview
            reps = newValue.reps
            lapses = newValue.lapses
        }
    }

    var isLearned: Bool { stateRaw == CardState.review.rawValue }
}

/// One graded answer. Feeds stats (reviews per day, retention rate) and the "mistakes" practice set.
@Model
final class ReviewLog {
    var deckID: UUID
    var wordKey: String
    var rating: Int
    var reviewedAt: Date
    var responseMs: Int
    var priorStateRaw: Int
    var source: String

    init(deckID: UUID, wordKey: String, rating: Rating, reviewedAt: Date, responseMs: Int, priorState: CardState?, source: String) {
        self.deckID = deckID
        self.wordKey = wordKey
        self.rating = rating.rawValue
        self.reviewedAt = reviewedAt
        self.responseMs = responseMs
        priorStateRaw = priorState?.rawValue ?? 0
        self.source = source
    }
}

/// Per-word user flags, shared by all decks.
@Model
final class UserWord {
    @Attribute(.unique) var wordKey: String
    var favorite: Bool
    var alreadyKnow: Bool
    var collectionIDs: [UUID]
    var updatedAt: Date

    init(wordKey: String) {
        self.wordKey = wordKey
        favorite = false
        alreadyKnow = false
        collectionIDs = []
        updatedAt = .now
    }
}

@Model
final class WordCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = .now
    }
}

/// A word the user adds. Key: "custom:<uuid>". Belongs to one deck.
@Model
final class CustomWord {
    @Attribute(.unique) var id: UUID
    var deckID: UUID
    var langRaw: String
    var lemma: String
    var pos: String?
    var pronunciation: String?
    var definition: String
    var example: String?
    var translation: String?
    var createdAt: Date

    init(deckID: UUID, lang: Lang, lemma: String, definition: String) {
        id = UUID()
        self.deckID = deckID
        langRaw = lang.rawValue
        self.lemma = lemma
        self.definition = definition
        createdAt = .now
    }

    var key: String { "custom:\(id.uuidString)" }
    var lang: Lang { Lang(rawValue: langRaw) ?? .en }
}

enum LexiStore {
    static let schema = Schema([Deck.self, ReviewState.self, ReviewLog.self, UserWord.self,
                                WordCollection.self, CustomWord.self])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            config = ModelConfiguration(schema: schema, url: AppGroup.containerURL.appendingPathComponent("Lexi.store"))
        }
        return try ModelContainer(for: schema, configurations: config)
    }

    /// One container per process (app or widget extension).
    static let shared: ModelContainer = {
        do { return try makeContainer() } catch {
            // A broken store must not crash the widget; fall back to memory and surface the error in Settings.
            lastError = error.localizedDescription
            return try! makeContainer(inMemory: true)
        }
    }()
    nonisolated(unsafe) static var lastError: String?
}
