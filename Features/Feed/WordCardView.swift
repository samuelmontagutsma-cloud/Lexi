import SwiftUI
import SwiftData
import FSRS
import LexiLogic

/// One full-screen word card.
/// - new: everything visible (first exposure).
/// - review: meaning hidden until "Show"; the user then grades recall (Forgot / Remembered).
/// - detail: everything visible, no grading (search, lists).
struct WordCardView: View {
    enum Kind { case new, review, detail }

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let card: WordCard
    let deck: Deck?
    let kind: Kind
    var onDone: () -> Void = {}

    @State private var revealed = false
    @State private var shownAt = Date()
    @State private var favorite = false
    @State private var known = false
    @State private var showCollections = false
    @State private var shareImage: UIImage?
    @State private var graded = false
    @ScaledMetric(relativeTo: .largeTitle) private var wordSize: CGFloat = 46

    private var theme: Theme { model.theme }
    private var study: StudyService { StudyService(context: context) }
    private var showMeaning: Bool { kind != .review || revealed }
    private var isLearn: Bool { deck?.mode == .learn }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 70)
            VStack(spacing: 14) {
                header
                if showMeaning { meaning.transition(.opacity) } else { revealButton }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 600)
            Spacer(minLength: 20)
            if kind == .review && revealed && !graded { gradeBar } else { actionBar }
            Spacer(minLength: 90)
        }
        .foregroundStyle(theme.text)
        .onAppear {
            shownAt = .now
            favorite = study.isFavorite(card.key)
            known = study.userWord(card.key, create: false)?.alreadyKnow ?? false
        }
        .sheet(isPresented: $showCollections) { CollectionPickerView(wordKey: card.key) }
        .sheet(item: Binding(get: { shareImage.map(ShareImage.init) }, set: { if $0 == nil { shareImage = nil } })) {
            ActivityView(items: [$0.image])
        }
    }

    // MARK: parts

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Chip(text: card.isCustom ? String(localized: "My word") : card.levelLabel)
                if let pos = PartOfSpeech.short(card.pos, in: card.lang) { Chip(text: pos) }
            }
            Text(card.headword(traditional: model.useTraditional))
                .font(.system(size: card.lang == .zh ? wordSize * 1.15 : wordSize, weight: .semibold, design: theme.design))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if card.lang == .zh, let t = card.traditional, t != card.lemma {
                Text(model.useTraditional ? card.lemma : t)
                    .font(.title3).foregroundStyle(theme.secondary)
                    .accessibilityLabel(Text(model.useTraditional ? "Simplified: \(card.lemma)" : "Traditional: \(t)"))
            }
            HStack(spacing: 10) {
                if let p = card.pronunciation, !p.isEmpty {
                    Text(card.lang == .zh ? p : "/\(p.trimmingCharacters(in: CharacterSet(charactersIn: "/[]")))/")
                        .font(.title3).foregroundStyle(theme.secondary)
                }
                Button {
                    Speech.shared.speak(card.lemma, lang: card.lang)
                } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.title3)
                }
                .accessibilityLabel(Text("Play pronunciation"))
            }
        }
    }

    private var revealButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { revealed = true }
        } label: {
            Text("Show meaning").font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                .background(theme.background2.opacity(0.9), in: Capsule())
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var meaning: some View {
        VStack(spacing: 14) {
            if isLearn, !card.translations.isEmpty {
                Text(card.translations.prefix(3).joined(separator: " · "))
                    .font(.title2.weight(.medium)).multilineTextAlignment(.center)
            }
            ForEach(Array(card.definitions.prefix(isLearn ? 1 : 3).enumerated()), id: \.offset) { i, d in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if card.definitions.count > 1 && !isLearn { Text("\(i + 1).").foregroundStyle(theme.secondary) }
                    Text(d.text)
                }
                .font(isLearn ? .body : .title3)
                .foregroundStyle(isLearn ? theme.secondary : theme.text)
                .multilineTextAlignment(.center)
            }
            ForEach(Array(card.examples.prefix(2).enumerated()), id: \.offset) { _, ex in
                VStack(spacing: 4) {
                    Text("“\(ex.text)”").italic()
                    if let tr = ex.translation { Text(tr).font(.callout).foregroundStyle(theme.secondary) }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .onTapGesture { Speech.shared.speak(ex.text, lang: card.lang) }
                .accessibilityHint(Text("Double tap to hear the example"))
            }
            if card.meaningMT || card.exampleMT {
                Label("Machine translated", systemImage: "cpu").font(.caption2).foregroundStyle(theme.secondary)
            }
            if card.usedFallback {
                Label("Shown in English: no data in your language", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(theme.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 30) {
            CardAction(symbol: favorite ? "heart.fill" : "heart", label: favorite ? "Remove favorite" : "Favorite") {
                study.toggleFavorite(card.key)
                favorite.toggle()
            }
            CardAction(symbol: "folder.badge.plus", label: "Add to collection") { showCollections = true }
            if !card.isCustom {
                CardAction(symbol: known ? "checkmark.circle.fill" : "checkmark.circle",
                           label: known ? "Undo already know" : "Already know") {
                    known.toggle()
                    study.setAlreadyKnow(card.key, known)
                    model.refresh()
                    if known { onDone() }
                }
            }
            CardAction(symbol: "square.and.arrow.up", label: "Share") { shareImage = renderShareImage() }
        }
        .font(.title2)
        .foregroundStyle(theme.text)
    }

    private var gradeBar: some View {
        HStack(spacing: 14) {
            Button { grade(remembered: false) } label: {
                Text("Forgot").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.red)
            Button { grade(remembered: true) } label: {
                Text("Remembered").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
    }

    private func grade(remembered: Bool) {
        guard let deck else { return }
        let seconds = Date().timeIntervalSince(shownAt)
        let rating = Grader.rating(kind: .flashcard, correct: remembered, seconds: seconds)
        study.grade(deck: deck, key: card.key, rating: rating, responseMs: Int(seconds * 1000), source: .flashcard)
        graded = true
        WidgetBridge.reload()
        onDone()
    }

    @MainActor
    private func renderShareImage() -> UIImage? {
        let r = ImageRenderer(content: ShareCardView(card: card, theme: theme, useTraditional: model.useTraditional))
        r.scale = 3
        return r.uiImage
    }
}

private struct ShareImage: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

/// The image made by "Share as image".
struct ShareCardView: View {
    let card: WordCard
    let theme: Theme
    let useTraditional: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(card.headword(traditional: useTraditional)).font(theme.word(44))
            if let p = card.pronunciation { Text(p).font(.title3).foregroundStyle(theme.secondary) }
            if let pos = PartOfSpeech.short(card.pos, in: card.lang) { Text(pos).font(.callout.italic()).foregroundStyle(theme.secondary) }
            Text(card.translations.isEmpty ? (card.definitions.first?.text ?? "") : card.translations.prefix(3).joined(separator: " · "))
                .font(.title3).multilineTextAlignment(.center)
            if let ex = card.examples.first {
                Text("“\(ex.text)”").italic().multilineTextAlignment(.center).padding(.top, 4)
                if let t = ex.translation { Text(t).font(.callout).foregroundStyle(theme.secondary).multilineTextAlignment(.center) }
            }
            Text("Lexi").font(.caption.weight(.semibold)).foregroundStyle(theme.secondary).padding(.top, 10)
        }
        .foregroundStyle(theme.text)
        .padding(36)
        .frame(width: 390, height: 520)
        .background(theme.background)
        .environment(\.colorScheme, theme.scheme ?? .light)
    }
}

// MARK: - Small shared components

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }
}

struct CardAction: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .accessibilityLabel(Text(label))
    }
}

struct RoundIconButton: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let label: LocalizedStringKey
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 52, height: 52)
                .foregroundStyle(prominent ? .white : model.theme.text)
                .background(prominent ? AnyShapeStyle(model.theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .accessibilityLabel(Text(label))
    }
}

/// Theme background, or the user's own image with a dimming layer for contrast.
struct ThemedBackground: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            model.theme.background
            if AppGroup.defaults.bool(forKey: SettingKey.customBackground),
               let img = UIImage(contentsOfFile: SettingsStore.customBackgroundURL.path) {
                Image(uiImage: img).resizable().scaledToFill()
                    .overlay(model.theme.background.opacity(0.55))
                    .id(model.backgroundVersion)
            }
        }
        .ignoresSafeArea()
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Add or remove a word from collections; create new collections.
struct CollectionPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WordCollection.name) private var collections: [WordCollection]
    let wordKey: String
    @State private var newName = ""
    @State private var member: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New collection", text: $newName).submitLabel(.done).onSubmit(add)
                        Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(collections) { c in
                        Button {
                            let on = !member.contains(c.id)
                            StudyService(context: context).setMembership(wordKey, collection: c, member: on)
                            if on { member.insert(c.id) } else { member.remove(c.id) }
                        } label: {
                            HStack {
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                if member.contains(c.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                member = Set(StudyService(context: context).userWord(wordKey, create: false)?.collectionIDs ?? [])
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let c = WordCollection(name: name)
        context.insert(c)
        StudyService(context: context).setMembership(wordKey, collection: c, member: true)
        member.insert(c.id)
        newName = ""
    }
}
