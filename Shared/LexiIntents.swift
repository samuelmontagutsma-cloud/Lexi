import AppIntents
import SwiftData
import WidgetKit

// Compiled into both the app and the widget extension.

/// A deck the user can pick for a widget instance.
struct DeckEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    static var defaultQuery = DeckQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct DeckQuery: EntityQuery {
    @MainActor
    static func all() -> [DeckEntity] {
        StudyService(context: ModelContext(LexiStore.shared)).decks()
            .map { DeckEntity(id: $0.id.uuidString, title: "\($0.flag) \($0.title)") }
    }

    func entities(for identifiers: [String]) async throws -> [DeckEntity] {
        await MainActor.run { Self.all().filter { identifiers.contains($0.id) } }
    }

    func suggestedEntities() async throws -> [DeckEntity] {
        await MainActor.run { Self.all() }
    }

    func defaultResult() async -> DeckEntity? {
        await MainActor.run { Self.all().first }
    }
}

/// Widget configuration: one deck per widget instance. Empty = the deck open in the app.
struct SelectDeckIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose deck"
    static var description = IntentDescription("Pick the deck this widget shows words from.")

    @Parameter(title: "Deck")
    var deck: DeckEntity?

    init() {}
}

/// "Next": show the next word in this deck's rotation (all widgets of the deck move together).
struct NextWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Next word"
    static var isDiscoverable = false

    @Parameter(title: "Deck")
    var deckID: String

    init() {}
    init(deckID: UUID) { self.deckID = deckID.uuidString }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: deckID) { WidgetState.bumpOffset(id) }
        return .result()
    }
}

/// "Got it": the user knows this word. Queued for the app, which grades it Good in FSRS.
struct GotItIntent: AppIntent {
    static var title: LocalizedStringResource = "Got it"
    static var isDiscoverable = false

    @Parameter(title: "Deck")
    var deckID: String

    @Parameter(title: "Word")
    var wordKey: String

    init() {}
    init(deckID: UUID, wordKey: String) {
        self.deckID = deckID.uuidString
        self.wordKey = wordKey
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: deckID) else { return .result() }
        WidgetActionQueue.append(WidgetAction(deckID: id, key: wordKey, date: .now))
        WidgetState.ack(wordKey, deck: id)
        // When the system runs this in the app process, apply now; in the widget process the app
        // applies the queue the next time it becomes active.
        if Bundle.main.bundleURL.pathExtension != "appex" {
            await MainActor.run { _ = WidgetActionQueue.apply(context: LexiStore.shared.mainContext) }
        }
        return .result()
    }
}

/// "Speak": say the word aloud. AudioPlaybackIntent lets the system run it in the app process in the
/// background (Info.plist UIBackgroundModes = audio), where audio playback is allowed.
struct SpeakWordIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Speak word"
    static var isDiscoverable = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Language")
    var lang: String

    init() {}
    init(text: String, lang: Lang) {
        self.text = text
        self.lang = lang.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await Speech.shared.speakAndWait(text, lang: Lang(rawValue: lang) ?? .en)
        return .result()
    }
}
