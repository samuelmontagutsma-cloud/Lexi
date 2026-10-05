import WidgetKit
import SwiftUI
import SwiftData

/// Lock Screen circle: day streak in the center, today's new-word progress (all decks) as the ring.
struct StreakEntry: TimelineEntry {
    let date: Date
    let streak: Int
    let doneToday: Int
    let goalToday: Int
}

struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry { StreakEntry(date: .now, streak: 0, doneToday: 0, goalToday: 5) }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        Task { @MainActor in completion(Self.current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        Task { @MainActor in
            let e = Self.current()
            // The streak changes at midnight; the app reloads widgets after each study session.
            let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400)).addingTimeInterval(60)
            completion(Timeline(entries: [e], policy: .after(midnight)))
        }
    }

    @MainActor
    static func current() -> StreakEntry {
        let study = StudyService(context: ModelContext(LexiStore.shared))
        let decks = study.decks()
        let done = decks.reduce(0) { $0 + study.introducedToday(deck: $1) }
        let goal = decks.reduce(0) { $0 + $1.dailyNewWords + study.extraNewToday(deck: $1) }
        return StreakEntry(date: .now, streak: WidgetFeed.streak(study: study), doneToday: done, goalToday: max(1, goal))
    }
}

struct LexiStreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LexiStreak", provider: StreakProvider()) { e in
            Gauge(value: Double(min(e.doneToday, e.goalToday)), in: 0...Double(e.goalToday)) {
                Image(systemName: "flame.fill")
            } currentValueLabel: {
                Text("\(e.streak)").font(.title3.bold()).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "lexi://stats"))
            .accessibilityLabel(Text("\(e.streak) day streak, \(e.doneToday) of \(e.goalToday) new words today"))
        }
        .configurationDisplayName("Streak")
        .description("Your day streak, with today's new words as a ring.")
        .supportedFamilies([.accessoryCircular])
    }
}

@main
struct LexiWidgetBundle: WidgetBundle {
    var body: some Widget {
        LexiWordWidget()
        LexiStreakWidget()
    }
}
