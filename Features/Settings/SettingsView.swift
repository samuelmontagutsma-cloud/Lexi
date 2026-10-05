import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingKey.speechRate, store: AppGroup.defaults) private var speechRate = 0.9
    @AppStorage(SettingKey.spanishVoice, store: AppGroup.defaults) private var spanishVoice = "es-MX"
    @AppStorage(SettingKey.reminderCount, store: AppGroup.defaults) private var reminderCount = 3
    @AppStorage(SettingKey.reminderStart, store: AppGroup.defaults) private var reminderStart = 9 * 60
    @AppStorage(SettingKey.reminderEnd, store: AppGroup.defaults) private var reminderEnd = 21 * 60
    @AppStorage(SettingKey.reminderDeckID, store: AppGroup.defaults) private var reminderDeckID = ""
    @AppStorage(SettingKey.widgetInterval, store: AppGroup.defaults) private var widgetInterval = 60
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    @State private var exportDoc: TextDocument?
    @State private var importing = false
    @State private var pendingRestore: Data?
    @State private var message: String?
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Study") {
                    NavigationLink { DeckListView() } label: { Label("Decks", systemImage: "rectangle.stack") }
                    NavigationLink { CollectionsView() } label: { Label("Collections", systemImage: "folder") }
                    Toggle(isOn: Binding(get: { model.useTraditional }, set: { model.useTraditional = $0 })) {
                        Label("Traditional Chinese characters", systemImage: "character.zh")
                    }
                }

                Section("Audio") {
                    VStack(alignment: .leading) {
                        Text("Speech speed: \(Int((speechRate * 100).rounded())) %")
                        Slider(value: $speechRate, in: 0.5...1.25, step: 0.05)
                    }
                    Picker("Spanish voice", selection: $spanishVoice) {
                        Text("Mexico (es-MX)").tag("es-MX")
                        Text("Spain (es-ES)").tag("es-ES")
                    }
                    Button("Test voice") { Speech.shared.speak("Hola, ¿cómo estás?", lang: .es) }
                }

                Section {
                    Stepper(value: $reminderCount, in: 0...10) {
                        Text(reminderCount == 0 ? String(localized: "No reminders") : String(localized: "\(reminderCount) reminders per day"))
                    }
                    if reminderCount > 0 {
                        MinuteOfDayPicker(title: "From", minute: $reminderStart)
                        MinuteOfDayPicker(title: "To", minute: $reminderEnd)
                        Picker("Words from", selection: $reminderDeckID) {
                            Text("Current deck").tag("")
                            ForEach(decks) { d in Text("\(d.flag) \(d.title)").tag(d.id.uuidString) }
                        }
                    }
                    if notificationsDenied {
                        Button("Notifications are off. Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: { Text("Reminders") } footer: {
                    Text("iOS allows 64 scheduled notifications per app, so Lexi plans about 6 days ahead and refreshes each time you open it.")
                }

                Section("Widgets") {
                    Picker("Change word every", selection: $widgetInterval) {
                        ForEach([15, 30, 60, 120, 240, 480, 1440], id: \.self) { m in
                            Text(m < 60 ? "\(m) min" : m == 1440 ? String(localized: "day") : "\(m / 60) h").tag(m)
                        }
                    }
                }

                Section("Appearance") {
                    NavigationLink { ThemePickerView(embedded: true) } label: {
                        LabeledContent("Theme", value: model.theme.name)
                    }
                }

                Section {
                    Button("Export backup (JSON)") {
                        do { exportDoc = TextDocument(text: try Transfer.backupJSON(context: context)) }
                        catch { message = error.localizedDescription }
                    }
                    Button("Restore from backup") { importing = true }
                } header: { Text("Backup") } footer: {
                    Text("Restore replaces all decks, progress, favorites, collections and custom words on this phone.")
                }

                if let message { Section { Text(message).font(.callout) } }

                Section {
                    NavigationLink("Credits and licenses") { CreditsView() }
                    if let built = Lexicon.shared.meta("built_at") {
                        LabeledContent("Word database", value: String(built.prefix(10)))
                    }
                    if let err = LexiStore.lastError {
                        Text("Storage error: \(err)").font(.caption).foregroundStyle(.red)
                    }
                    if !AppGroup.isShared {
                        Text("App Group not available: widgets cannot read your progress.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await checkNotifications() }
            .onChange(of: reminderCount) { _, n in
                if n > 0 { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); await checkNotifications() } }
            }
            .onDisappear {
                if reminderEnd < reminderStart { reminderEnd = reminderStart }
                Task { await Reminders.reschedule(container: LexiStore.shared) }
                WidgetBridge.reload()
            }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                          document: exportDoc, contentType: .json,
                          defaultFilename: "lexi-backup-\(Date.now.formatted(.iso8601.year().month().day())).json") { r in
                if case .success = r { message = String(localized: "Backup saved.") }
                exportDoc = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
                guard case .success(let url) = r else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingRestore = try? Data(contentsOf: url)
            }
            .confirmationDialog("Replace all data with this backup?", isPresented: Binding(
                get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
                Button("Restore", role: .destructive) {
                    guard let data = pendingRestore else { return }
                    do {
                        message = try Transfer.restore(json: data, context: context)
                        model.deckID = nil
                        model.themeID = AppGroup.defaults.string(forKey: SettingKey.themeID) ?? model.themeID
                        model.refresh()
                    } catch { message = String(localized: "Restore failed: \(error.localizedDescription)") }
                    pendingRestore = nil
                }
            }
        }
    }

    private func checkNotifications() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = s.authorizationStatus == .denied && reminderCount > 0
    }
}

struct ThemePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var photo: PhotosPickerItem?
    @AppStorage(SettingKey.customBackground, store: AppGroup.defaults) private var hasBackground = false

    var body: some View {
        let content = ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 14) {
                ForEach(Theme.all) { t in
                    ThemeSwatch(theme: t, selected: t.id == model.themeID) { model.themeID = t.id; WidgetBridge.reload() }
                }
            }
            .padding()
            VStack(spacing: 12) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Use my own background image", systemImage: "photo")
                }
                if hasBackground {
                    Button("Remove background image", role: .destructive) {
                        try? FileManager.default.removeItem(at: SettingsStore.customBackgroundURL)
                        hasBackground = false
                        model.backgroundVersion += 1
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Themes")
        .onChange(of: photo) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data),
                      let jpg = downscaled(img).jpegData(compressionQuality: 0.85) else { return }
                try? jpg.write(to: SettingsStore.customBackgroundURL, options: .atomic)
                hasBackground = true
                model.backgroundVersion += 1
            }
        }

        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    /// Keeps the file small (≤ 1600 px long side) so the widget can load it within its memory limit.
    private func downscaled(_ img: UIImage) -> UIImage {
        let maxSide: CGFloat = 1600
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height))
        guard k < 1 else { return img }
        let size = CGSize(width: s.width * k, height: s.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

struct CollectionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WordCollection.name) private var collections: [WordCollection]
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New collection", text: $newName)
                    Button("Add") {
                        guard let n = newName.nilIfBlank else { return }
                        context.insert(WordCollection(name: n))
                        try? context.save()
                        newName = ""
                    }
                }
            }
            Section {
                ForEach(collections) { c in
                    NavigationLink {
                        WordListView(title: c.name, keys: StudyService(context: context).keys(in: c))
                    } label: {
                        LabeledContent(c.name, value: "\(StudyService(context: context).keys(in: c).count)")
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        let c = collections[i]
                        let s = StudyService(context: context)
                        for k in s.keys(in: c) { s.setMembership(k, collection: c, member: false) }
                        context.delete(c)
                    }
                    try? context.save()
                }
            }
        }
        .navigationTitle("Collections")
    }
}

struct CreditsView: View {
    var body: some View {
        List {
            Section {
                Text("Lexi is a personal, offline app. Word data comes from these free sources. Text from Wiktionary and CC-CEDICT is shared under CC BY-SA 4.0: you may share and adapt it with attribution, under the same license.")
                    .font(.callout)
            }
            Section("Sources") {
                ForEach(Lexicon.shared.credits(), id: \.self) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name).font(.headline)
                        Text(c.license).font(.subheadline)
                        Text(c.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Spaced repetition") {
                Text("FSRS-6 algorithm, ported from py-fsrs (MIT License), open-spaced-repetition.")
            }
        }
        .navigationTitle("Credits")
    }
}
