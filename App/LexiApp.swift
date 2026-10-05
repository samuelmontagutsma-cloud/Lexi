import SwiftUI
import SwiftData
import UserNotifications

@main
struct LexiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SettingsStore.registerDefaults()
        LexiStore.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(LexiStore.shared)
                .onOpenURL { model.handle($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Apply "Got it" taps from widgets before anything reads the schedule.
                if WidgetActionQueue.apply(context: LexiStore.shared.mainContext) > 0 { WidgetBridge.reload() }
                model.refresh()
                Task { await Reminders.reschedule(container: LexiStore.shared) }
            }
            if phase == .background { WidgetBridge.reload() }
        }
    }
}

/// App-wide UI state.
/// A word to open in a sheet (from a widget or a notification).
struct OpenWord: Identifiable, Hashable {
    let key: String
    var id: String { key }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var deckID: UUID? {
        didSet { AppGroup.defaults.set(deckID?.uuidString, forKey: SettingKey.feedDeckID) }
    }
    var themeID: String {
        didSet { AppGroup.defaults.set(themeID, forKey: SettingKey.themeID) }
    }
    var useTraditional: Bool {
        didSet { AppGroup.defaults.set(useTraditional, forKey: SettingKey.useTraditionalGlobal) }
    }
    var onboardingDone: Bool {
        didSet { AppGroup.defaults.set(onboardingDone, forKey: SettingKey.onboardingDone) }
    }
    var backgroundVersion = 0
    var openWord: OpenWord?
    var showStats = false
    /// Bumped when learning data changes outside the current screen (grades, imports, deck edits).
    var refreshToken = 0

    init() {
        let d = AppGroup.defaults
        deckID = d.string(forKey: SettingKey.feedDeckID).flatMap(UUID.init(uuidString:))
        themeID = d.string(forKey: SettingKey.themeID) ?? Theme.classic.id
        useTraditional = d.bool(forKey: SettingKey.useTraditionalGlobal)
        onboardingDone = d.bool(forKey: SettingKey.onboardingDone)
    }

    var theme: Theme { Theme.byID(themeID) }

    func refresh() { refreshToken &+= 1 }

    func open(key: String, deck: UUID?) {
        if let deck { deckID = deck }
        openWord = OpenWord(key: key)
    }

    /// lexi://word?key=en:lucid&deck=<uuid> · lexi://stats · lexi://open
    func handle(_ url: URL) {
        guard url.scheme == "lexi", onboardingDone else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "word":
            guard let key = items.first(where: { $0.name == "key" })?.value else { return }
            open(key: key, deck: items.first(where: { $0.name == "deck" })?.value.flatMap(UUID.init(uuidString:)))
        case "stats":
            showStats = true
        default:
            break
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !Lexicon.shared.isAvailable {
                ContentUnavailableView("Word database missing", systemImage: "exclamationmark.triangle",
                                       description: Text("Reinstall the app. The bundled lexicon could not be opened."))
            } else if model.onboardingDone {
                FeedView()
            } else {
                OnboardingView()
            }
        }
        .tint(model.theme.accent)
        .preferredColorScheme(model.theme.scheme)
        .fontDesign(model.theme.design)
    }
}
