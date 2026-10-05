import SwiftUI
import SwiftData

@main
struct LexiApp: App {
    @State private var model = AppModel()
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refresh()
                Task { await Reminders.reschedule(container: LexiStore.shared) }
            }
            if phase == .background { WidgetBridge.reload() }
        }
    }
}

/// App-wide UI state.
@MainActor
@Observable
final class AppModel {
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
