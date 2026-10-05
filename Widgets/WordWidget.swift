import WidgetKit
import SwiftUI
import SwiftData
import AppIntents
import LexiLogic

struct WordEntry: TimelineEntry {
    let date: Date
    let card: WordCard?
    let deckID: UUID?
    let deckTitle: String
    let dueCount: Int
    let streak: Int
    let theme: Theme
    let useTraditional: Bool
    /// Shown instead of a word (no deck yet, empty deck).
    let message: String?
}

@MainActor
enum WidgetData {
    static func entries(deckID: UUID?, now: Date = .now) -> [WordEntry] {
        let theme = SettingsStore.theme
        let trad = AppGroup.defaults.bool(forKey: SettingKey.useTraditionalGlobal)
        let study = StudyService(context: ModelContext(LexiStore.shared))
        let fallbackID = AppGroup.defaults.string(forKey: SettingKey.feedDeckID).flatMap(UUID.init(uuidString:))
        guard let deck = study.deck(id: deckID ?? fallbackID) else {
            return [WordEntry(date: now, card: nil, deckID: nil, deckTitle: "Lexi", dueCount: 0, streak: 0,
                              theme: theme, useTraditional: trad, message: String(localized: "Open Lexi to set up a deck"))]
        }
        let acked = WidgetState.ackedToday(deck.id, now: now)
        let keys = WidgetFeed.candidates(study: study, deck: deck, acked: acked)
        let due = study.dueKeys(deck: deck, limit: 999).filter { !acked.contains($0) }.count
        let streak = WidgetFeed.streak(study: study)
        let title = "\(deck.flag) \(deck.title)"
        guard !keys.isEmpty else {
            return [WordEntry(date: now, card: nil, deckID: deck.id, deckTitle: title, dueCount: due, streak: streak,
                              theme: theme, useTraditional: trad, message: String(localized: "All done for today"))]
        }
        let slots = WidgetRotation.schedule(now: now, intervalMinutes: SettingsStore.widgetIntervalMinutes)
        let offset = WidgetState.offset(deck.id)
        let picked = slots.map { keys[WidgetRotation.index(slot: $0.slot, offset: offset, count: keys.count)] }
        let cards = Dictionary(study.cards(keys: Array(Set(picked)), deck: deck).map { ($0.key, $0) },
                               uniquingKeysWith: { a, _ in a })
        return zip(slots, picked).map { slot, key in
            WordEntry(date: slot.date, card: cards[key], deckID: deck.id, deckTitle: title, dueCount: due,
                      streak: streak, theme: theme, useTraditional: trad, message: cards[key] == nil ? String(localized: "Open Lexi") : nil)
        }
    }

    /// A real word for the widget gallery preview (no invented content).
    nonisolated static func preview() -> WordEntry {
        let lex = Lexicon.shared
        let w = lex.newWords(lang: .en, minLevel: 3, categories: [], limit: 1) { _ in false }.first
        let card = w.map { CardFactory(lexicon: lex).card(for: $0, mode: .dictionary, explanation: .en) }
        return WordEntry(date: .now, card: card, deckID: nil, deckTitle: "🇺🇸 \(Lang.en.displayName)", dueCount: 0,
                         streak: 0, theme: SettingsStore.theme, useTraditional: false, message: card == nil ? "Lexi" : nil)
    }
}

struct WordProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WordEntry {
        WidgetData.preview()
    }

    func snapshot(for configuration: SelectDeckIntent, in context: Context) async -> WordEntry {
        if context.isPreview { return WidgetData.preview() }
        let id = configuration.deck.flatMap { UUID(uuidString: $0.id) }
        return await MainActor.run { WidgetData.entries(deckID: id).first ?? WidgetData.preview() }
    }

    func timeline(for configuration: SelectDeckIntent, in context: Context) async -> Timeline<WordEntry> {
        let id = configuration.deck.flatMap { UUID(uuidString: $0.id) }
        let entries = await MainActor.run { WidgetData.entries(deckID: id) }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

struct LexiWordWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LexiWord", intent: SelectDeckIntent.self, provider: WordProvider()) { entry in
            WordWidgetView(entry: entry)
        }
        .configurationDisplayName("Word")
        .description("A word from your deck. Speak it, mark it as known, or go to the next word.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryRectangular])
    }
}

// MARK: - Views

struct WordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: WordEntry

    private var theme: Theme { entry.theme }
    private var isAccessory: Bool {
        [.accessoryInline, .accessoryRectangular, .accessoryCircular].contains(family)
    }
    /// Lock Screen and StandBy night mode tint everything; use system colors there.
    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if isAccessory { Color.clear } else { theme.background }
            }
            .widgetURL(url)
    }

    @ViewBuilder
    private var content: some View {
        if let card = entry.card {
            switch family {
            case .accessoryInline: inline(card)
            case .accessoryRectangular: rectangular(card)
            case .systemSmall: small(card)
            case .systemMedium: medium(card)
            default: large(card)
            }
        } else {
            VStack(spacing: 4) {
                if !isAccessory { Text(entry.deckTitle).font(.caption).foregroundStyle(secondary) }
                Text(entry.message ?? "Lexi").font(isAccessory ? .caption : .headline)
            }
            .foregroundStyle(primary)
        }
    }

    private var primary: Color { fullColor && !isAccessory ? theme.text : .primary }
    private var secondary: Color { fullColor && !isAccessory ? theme.secondary : .secondary }
    private var accent: Color { fullColor && !isAccessory ? theme.accent : .primary }

    private var url: URL? {
        guard let card = entry.card else { return URL(string: "lexi://open") }
        var c = URLComponents()
        c.scheme = "lexi"
        c.host = "word"
        c.queryItems = [URLQueryItem(name: "key", value: card.key)] + (entry.deckID.map { [URLQueryItem(name: "deck", value: $0.uuidString)] } ?? [])
        return c.url
    }

    private func word(_ card: WordCard) -> String { card.headword(traditional: entry.useTraditional) }

    private func meaning(_ card: WordCard, max: Int) -> String {
        let m = card.translations.isEmpty ? (card.definitions.first?.text ?? "") : card.translations.prefix(3).joined(separator: "; ")
        return m.count > max ? String(m.prefix(max - 1)) + "…" : m
    }

    private func pronunciation(_ card: WordCard) -> String? {
        guard let p = card.pronunciation, !p.isEmpty else { return nil }
        return card.lang == .zh ? p : "/\(p.trimmingCharacters(in: CharacterSet(charactersIn: "/[]")))/"
    }

    // Lock Screen

    private func inline(_ card: WordCard) -> some View {
        Text("\(word(card)) · \(meaning(card, max: 40))")
    }

    private func rectangular(_ card: WordCard) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(word(card)).font(.headline).widgetAccentable().lineLimit(1)
                if card.lang == .zh, let p = card.pronunciation { Text(p).font(.caption2).lineLimit(1) }
            }
            Text(meaning(card, max: 70)).font(.caption).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Home Screen / StandBy

    private func small(_ card: WordCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(word(card)).font(.system(size: card.lang == .zh ? 30 : 24, weight: .semibold, design: theme.design))
                .minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(primary)
            if let p = pronunciation(card) { Text(p).font(.caption2).foregroundStyle(secondary).lineLimit(1) }
            Text(meaning(card, max: 70)).font(.caption).foregroundStyle(primary).lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                speakButton(card)
                Spacer()
                nextButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ card: WordCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(word(card)).font(.system(size: card.lang == .zh ? 32 : 26, weight: .semibold, design: theme.design))
                    .minimumScaleFactor(0.5).lineLimit(1)
                if let p = pronunciation(card) { Text(p).font(.caption).foregroundStyle(secondary).lineLimit(1) }
                Spacer()
                if let pos = PartOfSpeech.short(card.pos, in: card.lang) { Text(pos).font(.caption.italic()).foregroundStyle(secondary) }
            }
            .foregroundStyle(primary)
            Text(meaning(card, max: 120)).font(.subheadline).foregroundStyle(primary).lineLimit(2)
            Spacer(minLength: 0)
            buttonRow(card)
        }
    }

    private func large(_ card: WordCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.deckTitle).font(.caption.weight(.semibold))
                Spacer()
                if entry.dueCount > 0 { Text("\(entry.dueCount) due").font(.caption) }
                if entry.streak > 0 { Label("\(entry.streak)", systemImage: "flame.fill").font(.caption) }
            }
            .foregroundStyle(secondary)
            Text(word(card)).font(.system(size: card.lang == .zh ? 44 : 36, weight: .semibold, design: theme.design))
                .minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(primary)
            HStack(spacing: 8) {
                if let p = pronunciation(card) { Text(p).font(.callout) }
                if let pos = PartOfSpeech.short(card.pos, in: card.lang) { Text(pos).font(.callout.italic()) }
                Text(card.levelLabel).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(secondary.opacity(0.15), in: Capsule())
            }
            .foregroundStyle(secondary)
            Text(meaning(card, max: 160)).font(.body).foregroundStyle(primary).lineLimit(3)
            if let ex = card.examples.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(ex.text)”").font(.callout.italic()).lineLimit(3)
                    if let t = ex.translation { Text(t).font(.caption).foregroundStyle(secondary).lineLimit(2) }
                }
                .foregroundStyle(primary)
            }
            if card.meaningMT || card.exampleMT {
                Label("Machine translated", systemImage: "cpu").font(.caption2).foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            buttonRow(card)
        }
    }

    // Buttons

    private func buttonRow(_ card: WordCard) -> some View {
        HStack(spacing: 10) {
            speakButton(card, label: true)
            if let id = entry.deckID {
                Button(intent: GotItIntent(deckID: id, wordKey: card.key)) {
                    Label("Got it", systemImage: "checkmark").font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(accent)
            }
            nextButton
        }
        .buttonStyle(.bordered)
    }

    private func speakButton(_ card: WordCard, label: Bool = false) -> some View {
        Button(intent: SpeakWordIntent(text: card.lemma, lang: card.lang)) {
            if label {
                Label("Speak", systemImage: "speaker.wave.2.fill").font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            } else {
                Image(systemName: "speaker.wave.2.fill").font(.caption)
            }
        }
        .tint(accent)
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("Speak"))
    }

    @ViewBuilder
    private var nextButton: some View {
        if let id = entry.deckID {
            Button(intent: NextWordIntent(deckID: id)) {
                Image(systemName: "arrow.right").font(.caption.weight(.semibold))
            }
            .tint(accent)
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Next word"))
        }
    }
}
