import Foundation
import SwiftData
import FSRS
import LexiLogic

/// A "Got it" tap on a widget, waiting for the app to apply it.
/// The widget never writes the SwiftData store: two processes writing one store leave the app with
/// stale objects. The app applies the queue (with the original tap time) when it becomes active.
struct WidgetAction: Codable, Equatable, Sendable {
    var deckID: UUID
    var key: String
    var date: Date
}

enum WidgetActionQueue {
    static let defaultsKey = "widgetActions"
    private static let lock = NSLock()

    static func pending(_ d: UserDefaults = AppGroup.defaults) -> [WidgetAction] {
        guard let data = d.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetAction].self, from: data)) ?? []
    }

    static func append(_ a: WidgetAction, _ d: UserDefaults = AppGroup.defaults) {
        lock.lock(); defer { lock.unlock() }
        var all = pending(d)
        all.append(a)
        d.set(try? JSONEncoder().encode(Array(all.suffix(500))), forKey: defaultsKey)
    }

    /// Removes and returns all pending actions.
    static func drain(_ d: UserDefaults = AppGroup.defaults) -> [WidgetAction] {
        lock.lock(); defer { lock.unlock() }
        let all = pending(d)
        d.removeObject(forKey: defaultsKey)
        return all
    }

    /// Applies queued taps to FSRS. Returns the number of grades written.
    /// - word never seen → introduced and graded Good (first exposure with the meaning shown)
    /// - word due at tap time → graded Good
    /// - word seen but not due → no change (an early review would distort the schedule)
    @MainActor
    @discardableResult
    static func apply(context: ModelContext, defaults d: UserDefaults = AppGroup.defaults) -> Int {
        let actions = drain(d).sorted { $0.date < $1.date }
        var graded = 0
        for a in actions {
            let study = StudyService(context: context, now: { a.date })
            guard let deck = study.decks().first(where: { $0.id == a.deckID }) else { continue }
            if let s = study.state(deck: deck, key: a.key), s.reps > 0 || s.lastReview != nil, s.due > a.date { continue }
            study.grade(deck: deck, key: a.key, rating: .good, responseMs: 0, source: .widget)
            graded += 1
        }
        return graded
    }
}

/// Per-deck widget state in the App Group defaults: rotation offset and today's "Got it" words.
enum WidgetState {
    static func offset(_ deck: UUID, _ d: UserDefaults = AppGroup.defaults) -> Int {
        d.integer(forKey: "widgetOffset|\(deck.uuidString)")
    }

    static func bumpOffset(_ deck: UUID, _ d: UserDefaults = AppGroup.defaults) {
        d.set(offset(deck, d) &+ 1, forKey: "widgetOffset|\(deck.uuidString)")
    }

    private static func dayString(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Words acknowledged with "Got it" today; hidden from the widget until tomorrow.
    static func ackedToday(_ deck: UUID, now: Date = .now, calendar: Calendar = .current,
                           _ d: UserDefaults = AppGroup.defaults) -> Set<String> {
        guard let dict = d.dictionary(forKey: "widgetAck|\(deck.uuidString)"),
              dict["day"] as? String == dayString(now, calendar) else { return [] }
        return Set(dict["keys"] as? [String] ?? [])
    }

    static func ack(_ key: String, deck: UUID, now: Date = .now, calendar: Calendar = .current,
                    _ d: UserDefaults = AppGroup.defaults) {
        var keys = ackedToday(deck, now: now, calendar: calendar, d)
        keys.insert(key)
        d.set(["day": dayString(now, calendar), "keys": Array(keys)], forKey: "widgetAck|\(deck.uuidString)")
    }
}

/// Which words a deck's widget rotates through, in priority order:
/// due reviews → today's new words → upcoming new words → recently studied words.
@MainActor
enum WidgetFeed {
    static let maxCandidates = 30

    static func candidates(study: StudyService, deck: Deck, acked: Set<String>) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add<S: Sequence>(_ keys: S) where S.Element == String {
            for k in keys where out.count < maxCandidates && !acked.contains(k) && seen.insert(k).inserted { out.append(k) }
        }
        let states = study.states(deck: deck)
        add(study.dueKeys(deck: deck, limit: 20))
        let start = study.calendar.startOfDay(for: study.now())
        add(states.filter { $0.introducedAt >= start }.sorted { $0.introducedAt < $1.introducedAt }.map(\.wordKey))
        // Upcoming new words. Ask for extra: words acked today are not yet in the store.
        add(study.nextNewKeys(deck: deck, count: max(5, study.newWordsLeftToday(deck: deck)) + acked.count))
        if out.count < 10 {
            add(states.sorted { ($0.lastReview ?? $0.introducedAt) > ($1.lastReview ?? $1.introducedAt) }.prefix(20).map(\.wordKey))
        }
        return out
    }

    /// Streak including widget taps that the app has not applied yet.
    static func streak(study: StudyService) -> Int {
        let since = study.calendar.date(byAdding: .day, value: -400, to: study.now()) ?? .distantPast
        var days = Set(study.logs(since: since).map { study.calendar.startOfDay(for: $0.reviewedAt) })
        for a in WidgetActionQueue.pending() { days.insert(study.calendar.startOfDay(for: a.date)) }
        return StatsMath.streak(reviewDays: days, today: study.now(), calendar: study.calendar)
    }
}
