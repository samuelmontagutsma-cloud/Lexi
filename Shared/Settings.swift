import Foundation
import SwiftUI

/// Keys for settings stored in the App Group `UserDefaults` (shared with the widget).
enum SettingKey {
    static let onboardingDone = "onboardingDone"
    static let feedDeckID = "feedDeckID"
    static let themeID = "themeID"
    static let customBackground = "customBackground"      // Bool: file exists in container
    static let speechRate = "speechRate"                  // 0.5 ... 1.25 (× default rate)
    static let spanishVoice = "spanishVoice"              // "es-ES" | "es-MX"
    static let reminderCount = "reminderCount"            // 0 ... 10 per day
    static let reminderStart = "reminderStart"            // minutes after midnight
    static let reminderEnd = "reminderEnd"
    static let reminderDeckID = "reminderDeckID"
    static let widgetInterval = "widgetInterval"          // minutes
    static let useTraditionalGlobal = "useTraditional"
    static let lastNotificationSchedule = "lastNotificationSchedule"
}

enum SettingsStore {
    static var d: UserDefaults { AppGroup.defaults }

    static func registerDefaults() {
        d.register(defaults: [
            SettingKey.themeID: Theme.classic.id,
            SettingKey.speechRate: 0.9,
            SettingKey.spanishVoice: "es-MX",
            SettingKey.reminderCount: 3,
            SettingKey.reminderStart: 9 * 60,
            SettingKey.reminderEnd: 21 * 60,
            SettingKey.widgetInterval: 60,
        ])
    }

    static var widgetIntervalMinutes: Int { max(15, d.integer(forKey: SettingKey.widgetInterval)) }
    static var theme: Theme { Theme.byID(d.string(forKey: SettingKey.themeID) ?? "") }
    static var customBackgroundURL: URL { AppGroup.containerURL.appendingPathComponent("background.jpg") }
}

// MARK: - Themes

struct Theme: Identifiable, Hashable, Sendable {
    enum FontStyle: String, Sendable { case system, serif, rounded, mono }

    let id: String
    let name: String
    let background: Color
    let background2: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let font: FontStyle
    /// nil = follow the system appearance.
    let scheme: ColorScheme?

    var design: Font.Design {
        switch font { case .system: return .default; case .serif: return .serif; case .rounded: return .rounded; case .mono: return .monospaced }
    }

    func word(_ size: CGFloat = 44) -> Font { .system(size: size, weight: .semibold, design: design) }
    func body(_ style: Font.TextStyle = .body) -> Font { .system(style, design: design) }

    static let classic = Theme(id: "classic", name: String(localized: "Classic"),
                               background: Color(.systemBackground), background2: Color(.secondarySystemBackground),
                               text: Color(.label), secondary: Color(.secondaryLabel), accent: .indigo, font: .serif, scheme: nil)
    static let light = Theme(id: "light", name: String(localized: "Light"),
                             background: Color(white: 0.98), background2: Color(white: 0.93),
                             text: Color(white: 0.08), secondary: Color(white: 0.4), accent: .blue, font: .system, scheme: .light)
    static let dark = Theme(id: "dark", name: String(localized: "Dark"),
                            background: Color(white: 0.06), background2: Color(white: 0.13),
                            text: Color(white: 0.95), secondary: Color(white: 0.65), accent: .orange, font: .system, scheme: .dark)
    static let paper = Theme(id: "paper", name: String(localized: "Paper"),
                             background: Color(red: 0.96, green: 0.93, blue: 0.86), background2: Color(red: 0.91, green: 0.87, blue: 0.78),
                             text: Color(red: 0.2, green: 0.16, blue: 0.12), secondary: Color(red: 0.45, green: 0.38, blue: 0.3),
                             accent: Color(red: 0.6, green: 0.25, blue: 0.15), font: .serif, scheme: .light)
    static let ocean = Theme(id: "ocean", name: String(localized: "Ocean"),
                             background: Color(red: 0.05, green: 0.2, blue: 0.33), background2: Color(red: 0.08, green: 0.28, blue: 0.42),
                             text: .white, secondary: Color(red: 0.7, green: 0.85, blue: 0.95), accent: Color(red: 0.4, green: 0.85, blue: 0.9),
                             font: .rounded, scheme: .dark)
    static let forest = Theme(id: "forest", name: String(localized: "Forest"),
                              background: Color(red: 0.11, green: 0.22, blue: 0.16), background2: Color(red: 0.16, green: 0.3, blue: 0.22),
                              text: Color(red: 0.93, green: 0.96, blue: 0.9), secondary: Color(red: 0.7, green: 0.8, blue: 0.68),
                              accent: Color(red: 0.85, green: 0.75, blue: 0.4), font: .serif, scheme: .dark)
    static let sunset = Theme(id: "sunset", name: String(localized: "Sunset"),
                              background: Color(red: 0.98, green: 0.84, blue: 0.72), background2: Color(red: 0.97, green: 0.74, blue: 0.62),
                              text: Color(red: 0.3, green: 0.1, blue: 0.12), secondary: Color(red: 0.5, green: 0.25, blue: 0.25),
                              accent: Color(red: 0.8, green: 0.25, blue: 0.3), font: .rounded, scheme: .light)
    static let rose = Theme(id: "rose", name: String(localized: "Rose"),
                            background: Color(red: 0.99, green: 0.92, blue: 0.94), background2: Color(red: 0.96, green: 0.84, blue: 0.88),
                            text: Color(red: 0.25, green: 0.1, blue: 0.18), secondary: Color(red: 0.5, green: 0.3, blue: 0.4),
                            accent: Color(red: 0.75, green: 0.2, blue: 0.45), font: .serif, scheme: .light)
    static let terminal = Theme(id: "terminal", name: String(localized: "Terminal"),
                                background: .black, background2: Color(white: 0.1),
                                text: Color(red: 0.4, green: 1, blue: 0.5), secondary: Color(red: 0.3, green: 0.7, blue: 0.4),
                                accent: Color(red: 0.4, green: 1, blue: 0.5), font: .mono, scheme: .dark)

    static let all: [Theme] = [.classic, .light, .dark, .paper, .ocean, .forest, .sunset, .rose, .terminal]
    static func byID(_ id: String) -> Theme { all.first { $0.id == id } ?? .classic }
}
