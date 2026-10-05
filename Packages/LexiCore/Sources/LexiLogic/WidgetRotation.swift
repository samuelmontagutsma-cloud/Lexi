import Foundation

/// Time-based word rotation for widgets.
/// Time is cut into slots of `interval` minutes since 1970. A slot number plus a per-deck offset
/// ("Next" adds 1) picks the word, so every widget of a deck agrees and a reload does not reshuffle.
public enum WidgetRotation {
    public static let minimumInterval = 15   // minutes; WidgetKit refresh budget makes shorter useless

    public struct Slot: Equatable, Sendable {
        public let date: Date
        public let slot: Int
    }

    /// Timeline entries from `now`: the current slot (dated `now`) and the following slot starts.
    /// Covers about one day, at least 2 and at most `maxEntries` entries.
    public static func schedule(now: Date, intervalMinutes: Int, maxEntries: Int = 96) -> [Slot] {
        let minutes = max(minimumInterval, intervalMinutes)
        let length = Double(minutes * 60)
        let first = Int((now.timeIntervalSince1970 / length).rounded(.down))
        let n = max(2, min(maxEntries, 1440 / minutes + 1))
        return (0..<n).map { i in
            Slot(date: i == 0 ? now : Date(timeIntervalSince1970: Double(first + i) * length), slot: first + i)
        }
    }

    /// Index into a candidate list of `count` words. Safe for any sign of slot/offset.
    public static func index(slot: Int, offset: Int, count: Int) -> Int {
        precondition(count > 0)
        let m = (slot &+ offset) % count
        return m < 0 ? m + count : m
    }
}
