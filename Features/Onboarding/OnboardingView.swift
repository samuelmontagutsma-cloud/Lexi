import SwiftUI
import SwiftData
import UserNotifications

/// First run: decks → level → topics → daily goal → reminders → theme.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    struct Kind: Hashable { let mode: StudyMode; let study: Lang; let explanation: Lang }

    @State private var step = 0
    @State private var kinds: Set<Kind> = [Kind(mode: .dictionary, study: .en, explanation: .en)]
    @State private var levels: [Lang: Int] = [.en: 3, .es: 2, .zh: 1]
    @State private var categories: Set<String> = []
    @State private var daily = 5
    @State private var reminders = 3
    @State private var startMinute = 9 * 60
    @State private var endMinute = 21 * 60
    @State private var themeID = Theme.classic.id

    private let allKinds: [Kind] = Deck.supportedKinds.map { Kind(mode: $0.0, study: $0.1, explanation: $0.2) }
    private var studyLangs: [Lang] { Lang.allCases.filter { l in kinds.contains { $0.study == l } } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: 6).padding()
                TabView(selection: $step) {
                    decksStep.tag(0)
                    levelStep.tag(1)
                    topicsStep.tag(2)
                    goalStep.tag(3)
                    remindersStep.tag(4)
                    themeStep.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.default, value: step)
                HStack {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Spacer()
                    Button(step == 5 ? "Start learning" : "Next") {
                        if step == 5 { finish() } else { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(kinds.isEmpty)
                }
                .padding()
            }
            .navigationTitle("Welcome to Lexi")
        }
    }

    // MARK: steps

    private var decksStep: some View {
        Form {
            Section {
                ForEach(allKinds, id: \.self) { k in
                    Toggle(isOn: Binding(get: { kinds.contains(k) },
                                         set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(k.study.flag) \(title(k))")
                            Text(k.mode == .dictionary ? "Words, definitions and examples in one language"
                                 : "Learn new words with translations")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("What do you want to study?") } footer: {
                Text("You can add or change decks later in Settings.")
            }
        }
    }

    private var levelStep: some View {
        Form {
            ForEach(studyLangs) { lang in
                Section(lang.displayName) {
                    Picker("Level", selection: Binding(get: { levels[lang] ?? 1 }, set: { levels[lang] = $0 })) {
                        ForEach(Array(Levels.range(for: lang)), id: \.self) { l in
                            Text(Levels.pickerLabel(lang: lang, level: l)).tag(l)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
    }

    private var topicsStep: some View {
        Form {
            Section {
                ForEach(Categories.all, id: \.self) { c in
                    Toggle(isOn: Binding(get: { categories.contains(c) },
                                         set: { if $0 { categories.insert(c) } else { categories.remove(c) } })) {
                        Label(Categories.name(c), systemImage: Categories.symbol(c))
                    }
                }
            } header: { Text("Topics (optional)") } footer: {
                Text("No topic selected = all words, most common first. With topics, only words tagged with those topics appear.")
            }
        }
    }

    private var goalStep: some View {
        Form {
            Section {
                Stepper(value: $daily, in: 1...50) { Text("\(daily) new words per day") }
            } header: { Text("Daily goal") } footer: {
                Text("Reviews of words you already saw come on top of this, as the spaced-repetition schedule asks.")
            }
        }
    }

    private var remindersStep: some View {
        Form {
            Section {
                Stepper(value: $reminders, in: 0...10) {
                    Text(reminders == 0 ? String(localized: "No reminders") : String(localized: "\(reminders) reminders per day"))
                }
                if reminders > 0 {
                    MinuteOfDayPicker(title: "From", minute: $startMinute)
                    MinuteOfDayPicker(title: "To", minute: $endMinute)
                }
            } header: { Text("Reminders") } footer: {
                Text("Each reminder shows one word from your deck.")
            }
        }
    }

    private var themeStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 14) {
                ForEach(Theme.all) { t in
                    ThemeSwatch(theme: t, selected: t.id == themeID) { themeID = t.id }
                }
            }
            .padding()
        }
    }

    private func title(_ k: Kind) -> String {
        k.mode == .dictionary ? k.study.displayName : "\(k.study.displayName) → \(k.explanation.displayName)"
    }

    // MARK: finish

    private func finish() {
        let ordered = allKinds.filter { kinds.contains($0) }
        var first: Deck?
        for (i, k) in ordered.enumerated() {
            let d = Deck(mode: k.mode, study: k.study, explanation: k.explanation,
                         minLevel: levels[k.study] ?? 1, categories: Array(categories).sorted(),
                         dailyNewWords: daily, sortIndex: i)
            context.insert(d)
            first = first ?? d
        }
        try? context.save()
        let d = AppGroup.defaults
        d.set(reminders, forKey: SettingKey.reminderCount)
        d.set(startMinute, forKey: SettingKey.reminderStart)
        d.set(max(startMinute, endMinute), forKey: SettingKey.reminderEnd)
        model.themeID = themeID
        model.deckID = first?.id
        model.onboardingDone = true
        if reminders > 0 {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await Reminders.reschedule(container: LexiStore.shared)
            }
        }
    }
}

struct MinuteOfDayPicker: View {
    let title: LocalizedStringKey
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        }, set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Aa").font(.system(size: 34, weight: .semibold, design: theme.design))
                Text(theme.name).font(.caption)
            }
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? theme.accent : .gray.opacity(0.3), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
