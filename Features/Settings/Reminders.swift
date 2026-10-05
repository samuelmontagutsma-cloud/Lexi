import Foundation
import SwiftData
import UserNotifications
import LexiLogic

/// Local notifications, up to 10 per day, each showing one word.
enum Reminders {
    static let idPrefix = "lexi.word."

    @MainActor
    static func reschedule(container: ModelContainer) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let d = AppGroup.defaults
        let count = d.integer(forKey: SettingKey.reminderCount)
        guard count > 0, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let study = StudyService(context: container.mainContext)
        let deckID = d.string(forKey: SettingKey.reminderDeckID).flatMap(UUID.init(uuidString:))
            ?? d.string(forKey: SettingKey.feedDeckID).flatMap(UUID.init(uuidString:))
        guard let deck = study.deck(id: deckID) else { return }
        let dates = ReminderPlan.fireDates(perDay: count, startMinute: d.integer(forKey: SettingKey.reminderStart),
                                           endMinute: d.integer(forKey: SettingKey.reminderEnd), from: .now, calendar: .current)
        // Words: due reviews first (they need practice), then upcoming new words, then words already seen.
        var keys = study.dueKeys(deck: deck, limit: dates.count)
        if keys.count < dates.count { keys += study.nextNewKeys(deck: deck, count: dates.count - keys.count) }
        if keys.count < dates.count { keys += study.states(deck: deck).map(\.wordKey).shuffled().prefix(dates.count - keys.count) }
        guard !keys.isEmpty else { return }
        let cards = study.cards(keys: keys, deck: deck)
        guard !cards.isEmpty else { return }
        for (i, date) in dates.enumerated() {
            let c = cards[i % cards.count]
            let content = UNMutableNotificationContent()
            var title = c.lemma
            if let p = c.pronunciation, c.lang == .zh { title += "  \(p)" }
            content.title = title
            content.body = c.shortMeaning + (c.examples.first.map { "\n“\($0.text)”" } ?? "")
            content.sound = .default
            content.userInfo = ["wordKey": c.key, "deckID": deck.id.uuidString]
            content.threadIdentifier = "lexi-words"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let req = UNNotificationRequest(identifier: "\(idPrefix)\(i)", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}
