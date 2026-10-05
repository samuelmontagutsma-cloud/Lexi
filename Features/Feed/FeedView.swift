import SwiftUI
import SwiftData
import FSRS
import LexiLogic

/// One page of the feed.
enum FeedItem: Identifiable, Hashable {
    case new(WordCard)
    case review(WordCard)
    case done(dueLeft: Int)

    var id: String {
        switch self {
        case .new(let c): return "n|\(c.key)"
        case .review(let c): return "r|\(c.key)"
        case .done: return "done"
        }
    }
}

enum Sheet: String, Identifiable {
    case practice, search, stats, themes, settings, decks
    var id: String { rawValue }
}

/// Main screen: full-screen vertical pages, one word per page (Vocabulary-style).
/// Order per day: new words up to the daily goal, then due reviews, then a "done" page.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var items: [FeedItem] = []
    @State private var position: String?
    @State private var sheet: Sheet?
    @State private var deck: Deck?

    private var study: StudyService { StudyService(context: context) }

    var body: some View {
        ZStack {
            ThemedBackground()
            if let deck {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            page(item, deck: deck)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $position)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            } else {
                ContentUnavailableView {
                    Label("No decks", systemImage: "rectangle.stack")
                } actions: {
                    Button("Add a deck") { sheet = .decks }
                }
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear(perform: reload)
        .onChange(of: model.deckID) { _, _ in reload() }
        .onChange(of: model.refreshToken) { _, _ in reloadKeepingPosition() }
        .onChange(of: position) { _, id in introduceIfNew(id) }
        .sheet(item: Binding(get: { model.openWord }, set: { model.openWord = $0 }), onDismiss: reloadKeepingPosition) { w in
            NavigationStack {
                WordDetailView(key: w.key)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.openWord = nil } } }
            }
        }
        .onChange(of: model.showStats) { _, show in
            if show { sheet = .stats; model.showStats = false }
        }
        .sheet(item: $sheet, onDismiss: reloadKeepingPosition) { s in
            switch s {
            case .practice: PracticeHomeView()
            case .search: SearchView()
            case .stats: StatsView()
            case .themes: ThemePickerView()
            case .settings: SettingsView()
            case .decks: DeckListView()
            }
        }
    }

    @ViewBuilder
    private func page(_ item: FeedItem, deck: Deck) -> some View {
        switch item {
        case .new(let card):
            WordCardView(card: card, deck: deck, kind: .new) { advance() }
        case .review(let card):
            WordCardView(card: card, deck: deck, kind: .review) { advance() }
        case .done(let dueLeft):
            DailyDoneView(deck: deck, dueLeft: dueLeft,
                          onPractice: { sheet = .practice },
                          onMore: {
                              study.addExtraNewToday(deck: deck, 5)
                              reloadKeepingPosition()
                          })
        }
    }

    // MARK: bars

    private var topBar: some View {
        HStack {
            DeckSwitcher(sheet: $sheet)
            Spacer()
            RoundIconButton(symbol: "gearshape", label: "Settings") { sheet = .settings }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            RoundIconButton(symbol: "graduationcap", label: "Practice", prominent: true) { sheet = .practice }
            Spacer()
            RoundIconButton(symbol: "magnifyingglass", label: "Search") { sheet = .search }
            RoundIconButton(symbol: "chart.bar", label: "Stats") { sheet = .stats }
            RoundIconButton(symbol: "paintbrush", label: "Themes") { sheet = .themes }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: data

    private func reload() {
        deck = study.deck(id: model.deckID)
        if model.deckID == nil, let d = deck { model.deckID = d.id }
        items = buildItems()
        position = items.first?.id
        introduceIfNew(position)
    }

    private func reloadKeepingPosition() {
        let keep = position
        deck = study.deck(id: model.deckID)
        items = buildItems()
        if let keep, items.contains(where: { $0.id == keep }) { position = keep } else { position = items.first?.id }
    }

    private func buildItems() -> [FeedItem] {
        guard let deck else { return [] }
        // New words already introduced today stay in the feed so the day's set is stable.
        let start = Calendar.current.startOfDay(for: .now)
        let todays = study.states(deck: deck).filter { $0.introducedAt >= start && $0.reps == 0 }
            .sorted { $0.introducedAt < $1.introducedAt }.map(\.wordKey)
        let fresh = study.nextNewKeys(deck: deck, count: study.newWordsLeftToday(deck: deck))
        let newKeys = todays + fresh.filter { !todays.contains($0) }
        let due = study.dueKeys(deck: deck, limit: 200).filter { !newKeys.contains($0) }
        let newCards = study.cards(keys: newKeys, deck: deck).map(FeedItem.new)
        let dueCards = study.cards(keys: due, deck: deck).map(FeedItem.review)
        return newCards + dueCards + [.done(dueLeft: 0)]
    }

    private func introduceIfNew(_ id: String?) {
        guard let id, let deck, let item = items.first(where: { $0.id == id }), case .new(let card) = item else { return }
        study.introduce(deck: deck, key: card.key)
        try? context.save()
    }

    private func advance() {
        guard let i = items.firstIndex(where: { $0.id == position }), i + 1 < items.count else { return }
        withAnimation(.snappy) { position = items[i + 1].id }
    }
}

/// Capsule with the deck flag + name; opens a menu to switch decks.
struct DeckSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Binding var sheet: Sheet?
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    var body: some View {
        Menu {
            ForEach(decks) { d in
                Button {
                    model.deckID = d.id
                } label: {
                    Label("\(d.flag) \(d.title)", systemImage: d.id == current?.id ? "checkmark" : "")
                }
            }
            Divider()
            Button { sheet = .decks } label: { Label("Manage decks", systemImage: "slider.horizontal.3") }
        } label: {
            HStack(spacing: 6) {
                Text(current.map { "\($0.flag) \($0.title)" } ?? String(localized: "Decks"))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel(Text("Current deck: \(current?.title ?? "")"))
    }

    private var current: Deck? { decks.first { $0.id == model.deckID } ?? decks.first }
}

struct DailyDoneView: View {
    @Environment(AppModel.self) private var model
    let deck: Deck
    let dueLeft: Int
    let onPractice: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(model.theme.accent)
            Text("Daily goal done").font(.title.bold())
            Text("Practice your words with games, or learn 5 more words today.")
                .multilineTextAlignment(.center).foregroundStyle(model.theme.secondary)
                .padding(.horizontal, 32)
            Button(action: onPractice) {
                Label("Practice", systemImage: "graduationcap").frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button(action: onMore) {
                Label("Learn 5 more words", systemImage: "plus").frame(maxWidth: 260)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .foregroundStyle(model.theme.text)
        .padding()
    }
}
