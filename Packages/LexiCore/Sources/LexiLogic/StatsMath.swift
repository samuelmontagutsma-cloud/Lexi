import Foundation
import FSRS

public enum StatsMath {
    /// Consecutive days with at least one review, ending today (or yesterday, if today has none yet).
    public static func streak(reviewDays: Set<Date>, today: Date, calendar: Calendar) -> Int {
        let days = Set(reviewDays.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: today)
        if !days.contains(day) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day), days.contains(y) else { return 0 }
            day = y
        }
        var n = 0
        while days.contains(day) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    /// Reviews per day for the last `days` days (oldest first), zero-filled.
    public static func perDay(_ dates: [Date], days: Int, today: Date, calendar: Calendar) -> [(day: Date, count: Int)] {
        var counts: [Date: Int] = [:]
        for d in dates { counts[calendar.startOfDay(for: d), default: 0] += 1 }
        let start = calendar.startOfDay(for: today)
        return (0..<days).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: start) else { return nil }
            return (d, counts[d] ?? 0)
        }
    }

    /// True retention: share of reviews of cards in Review state that were not Again.
    /// Learning-step reviews are excluded (they test short-term memory, not retention).
    public static func retention(_ logs: [(priorState: CardState?, rating: Rating)]) -> Double? {
        let r = logs.filter { $0.priorState == .review }
        guard !r.isEmpty else { return nil }
        return Double(r.filter { $0.rating != .again }.count) / Double(r.count)
    }
}

public enum ReminderPlan {
    /// iOS keeps at most 64 pending local notifications per app.
    public static let systemLimit = 64

    /// Times for `perDay` reminders spread evenly from `startMinute` to `endMinute`, for as many whole days
    /// as fit under the system limit (10/day → 6 days = 60).
    public static func fireDates(perDay: Int, startMinute: Int, endMinute: Int, from now: Date,
                                 calendar: Calendar) -> [Date] {
        let n = max(0, min(10, perDay))
        guard n > 0 else { return [] }
        let lo = max(0, min(startMinute, 1439)), hi = max(lo, min(endMinute, 1439))
        let minutes: [Int] = n == 1 ? [lo] : (0..<n).map { lo + Int((Double(hi - lo) * Double($0) / Double(n - 1)).rounded()) }
        let days = systemLimit / n
        var out: [Date] = []
        let today = calendar.startOfDay(for: now)
        for d in 0...days {
            guard let day = calendar.date(byAdding: .day, value: d, to: today) else { continue }
            for m in minutes {
                guard let t = calendar.date(byAdding: .minute, value: m, to: day), t > now else { continue }
                out.append(t)
            }
        }
        return Array(out.prefix(systemLimit))
    }
}
