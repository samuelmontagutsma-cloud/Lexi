import SwiftUI
import SwiftData
import Charts
import FSRS
import LexiLogic

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @State private var range = 30
    @State private var data = StatsData()

    struct StatsData {
        var streak = 0
        var perDay: [(day: Date, count: Int)] = []
        var retention: Double?
        var retentionN = 0
        var totalReviews = 0
        var deckRows: [(deck: Deck, learned: Int, seen: Int, due: Int)] = []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        StatTile(value: "\(data.streak)", label: "Day streak", symbol: "flame.fill")
                        StatTile(value: "\(data.totalReviews)", label: "Reviews", symbol: "checkmark.circle")
                        StatTile(value: data.retention.map { "\(Int(($0 * 100).rounded())) %" } ?? "–",
                                 label: "Retention", symbol: "brain.head.profile")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text("Retention = share of reviews of learned words (not learning steps) that you remembered, over the selected range (n = \(data.retentionN)). Your target is set per deck.")
                }

                Section {
                    Picker("Range", selection: $range) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    Chart(data.perDay, id: \.day) { p in
                        BarMark(x: .value("Day", p.day, unit: .day), y: .value("Reviews", p.count))
                    }
                    .frame(height: 180)
                    .accessibilityLabel(Text("Reviews per day"))
                } header: { Text("Reviews per day") }

                Section("Decks") {
                    ForEach(data.deckRows, id: \.deck.id) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(r.deck.flag) \(r.deck.title)").font(.headline)
                            HStack {
                                Text("\(r.learned) learned")
                                Text("·")
                                Text("\(r.seen) seen")
                                Text("·")
                                Text("\(r.due) due")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: Double(r.learned), total: Double(max(1, Lexicon.shared.wordCount(lang: r.deck.studyLang))))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section("Words") {
                    NavigationLink("Favorites") {
                        WordListView(title: String(localized: "Favorites"), keys: StudyService(context: context).favoriteKeys())
                    }
                    NavigationLink("Recent mistakes") {
                        WordListView(title: String(localized: "Recent mistakes"), keys: StudyService(context: context).mistakeKeys(deck: nil))
                    }
                }
            }
            .navigationTitle("Stats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: load)
            .onChange(of: range) { _, _ in load() }
        }
    }

    private func load() {
        let s = StudyService(context: context)
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -range, to: cal.startOfDay(for: .now)) ?? .distantPast
        let logs = s.logs(since: since)
        var d = StatsData()
        d.streak = s.streak()
        d.perDay = StatsMath.perDay(logs.map(\.reviewedAt), days: range, today: .now, calendar: cal)
        let pairs = logs.map { (priorState: CardState(rawValue: $0.priorStateRaw), rating: Rating(rawValue: $0.rating) ?? .good) }
        d.retention = StatsMath.retention(pairs)
        d.retentionN = pairs.filter { $0.priorState == .review }.count
        d.totalReviews = logs.count
        d.deckRows = decks.map { ($0, s.learnedCount(deck: $0), s.seenCount(deck: $0), s.dueCount(deck: $0)) }
        data = d
    }
}

struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
