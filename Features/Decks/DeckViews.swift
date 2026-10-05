import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LexiLogic

struct DeckListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @State private var confirmDelete: Deck?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(decks) { d in
                        NavigationLink {
                            DeckEditView(deck: d)
                        } label: {
                            DeckRow(deck: d)
                        }
                    }
                    .onMove(perform: move)
                    .onDelete { idx in confirmDelete = idx.first.map { decks[$0] } }
                }
                Section("Add a deck") {
                    ForEach(Array(Deck.supportedKinds.enumerated()), id: \.offset) { _, k in
                        Button {
                            let d = Deck(mode: k.0, study: k.1, explanation: k.2, sortIndex: (decks.last?.sortIndex ?? 0) + 1)
                            context.insert(d)
                            try? context.save()
                        } label: {
                            Label(k.0 == .dictionary ? "\(k.1.flag) \(k.1.displayName)"
                                  : "\(k.1.flag) \(k.1.displayName) → \(k.2.displayName)", systemImage: "plus")
                        }
                    }
                }
            }
            .navigationTitle("Decks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete this deck and its progress?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { d in
                Button("Delete \(d.title)", role: .destructive) { delete(d) }
            }
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var arr = decks
        arr.move(fromOffsets: from, toOffset: to)
        for (i, d) in arr.enumerated() { d.sortIndex = i }
        try? context.save()
    }

    private func delete(_ d: Deck) {
        let id = d.id
        try? context.delete(model: ReviewState.self, where: #Predicate { $0.deckID == id })
        try? context.delete(model: ReviewLog.self, where: #Predicate { $0.deckID == id })
        try? context.delete(model: CustomWord.self, where: #Predicate { $0.deckID == id })
        context.delete(d)
        try? context.save()
        if model.deckID == id { model.deckID = nil }
        model.refresh()
    }
}

struct DeckRow: View {
    @Environment(\.modelContext) private var context
    let deck: Deck

    var body: some View {
        let s = StudyService(context: context)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(deck.flag) \(deck.title)").font(.headline)
            Text("\(Levels.label(lang: deck.studyLang, level: deck.minLevel)) · \(deck.dailyNewWords) new/day · \(s.learnedCount(deck: deck)) learned · \(s.dueCount(deck: deck)) due")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DeckEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Bindable var deck: Deck
    @State private var showAddWord = false
    @State private var importing = false
    @State private var importMessage: String?
    @State private var exportDoc: TextDocument?

    var body: some View {
        Form {
            Section("Level") {
                Picker("Start at", selection: $deck.minLevel) {
                    ForEach(Array(Levels.range(for: deck.studyLang)), id: \.self) { l in
                        Text(Levels.pickerLabel(lang: deck.studyLang, level: l)).tag(l)
                    }
                }
                Text("\(Lexicon.shared.wordCount(lang: deck.studyLang, minLevel: deck.minLevel)) words at this level and above")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Daily goal") {
                Stepper(value: $deck.dailyNewWords, in: 1...50) { Text("\(deck.dailyNewWords) new words per day") }
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Target retention: \(Int((deck.targetRetention * 100).rounded())) %")
                    Slider(value: $deck.targetRetention, in: 0.80...0.95, step: 0.01)
                }
            } header: { Text("Memory") } footer: {
                Text("Higher retention = shorter intervals and more reviews per day. 90 % is the FSRS default.")
            }
            Section("Topics") {
                NavigationLink {
                    CategoryPicker(selection: $deck.categories, lang: deck.studyLang)
                } label: {
                    LabeledContent("Topics", value: deck.categories.isEmpty ? String(localized: "All words")
                                   : deck.categories.map(Categories.name).joined(separator: ", "))
                }
            }
            if deck.studyLang == .zh {
                Section("Chinese") {
                    Toggle("Traditional characters", isOn: Binding(get: { model.useTraditional }, set: { model.useTraditional = $0 }))
                }
            }
            Section {
                NavigationLink("My words (\(StudyService(context: context).customWords(deck: deck).count))") {
                    CustomWordListView(deck: deck)
                }
                Button("Add a word") { showAddWord = true }
                Button("Import words from CSV") { importing = true }
                Button("Export deck words as CSV") { exportDoc = TextDocument(text: Transfer.exportDeckCSV(deck: deck, context: context)) }
            } header: { Text("Custom words") } footer: {
                Text("CSV columns: word, definition, example, translation, pos, pronunciation. Only “word” and “definition” are required.")
            }
            if let importMessage { Section { Text(importMessage).font(.callout) } }
        }
        .navigationTitle(deck.title)
        .onDisappear {
            try? context.save()
            model.refresh()
            WidgetBridge.reload()
        }
        .sheet(isPresented: $showAddWord) { CustomWordForm(deck: deck) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importMessage = Transfer.importCSV(result: result, deck: deck, context: context)
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .commaSeparatedText,
                      defaultFilename: "lexi-\(deck.shortTitle.lowercased()).csv") { _ in exportDoc = nil }
    }
}

struct CategoryPicker: View {
    @Binding var selection: [String]
    let lang: Lang

    var body: some View {
        let counts = Lexicon.shared.categoryCounts(lang: lang)
        List {
            Section {
                Button("All words") { selection = [] }
            } footer: {
                Text("About 1 in 4 words has a topic tag. With topics selected, the deck only shows tagged words.")
            }
            ForEach(Categories.all, id: \.self) { c in
                Button {
                    if let i = selection.firstIndex(of: c) { selection.remove(at: i) } else { selection.append(c) }
                } label: {
                    HStack {
                        Label(Categories.name(c), systemImage: Categories.symbol(c)).foregroundStyle(.primary)
                        Spacer()
                        Text("\(counts[c] ?? 0)").foregroundStyle(.secondary)
                        if selection.contains(c) { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("Topics")
    }
}

struct CustomWordListView: View {
    @Environment(\.modelContext) private var context
    let deck: Deck
    @State private var words: [CustomWord] = []
    @State private var editing: CustomWord?

    var body: some View {
        List {
            ForEach(words) { w in
                Button { editing = w } label: {
                    VStack(alignment: .leading) {
                        Text(w.lemma).font(.headline).foregroundStyle(.primary)
                        Text(w.definition).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { idx in
                for i in idx {
                    let key = words[i].key
                    try? context.delete(model: ReviewState.self, where: #Predicate { $0.wordKey == key })
                    context.delete(words[i])
                }
                try? context.save()
                reload()
            }
        }
        .overlay { if words.isEmpty { ContentUnavailableView("No custom words", systemImage: "square.and.pencil") } }
        .navigationTitle("My words")
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { CustomWordForm(deck: deck, editing: $0) }
    }

    private func reload() { words = StudyService(context: context).customWords(deck: deck) }
}

struct CustomWordForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let deck: Deck
    var editing: CustomWord?
    @State private var lemma = ""
    @State private var definition = ""
    @State private var example = ""
    @State private var translation = ""
    @State private var pos = ""
    @State private var pronunciation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Word", text: $lemma).textInputAutocapitalization(.never)
                    TextField(deck.mode == .learn ? "Meaning" : "Definition", text: $definition, axis: .vertical)
                    TextField("Example sentence (optional)", text: $example, axis: .vertical)
                    if deck.mode == .learn { TextField("Translation (optional)", text: $translation) }
                }
                Section {
                    TextField("Part of speech (optional)", text: $pos).textInputAutocapitalization(.never)
                    TextField(deck.studyLang == .zh ? "Pinyin (optional)" : "Pronunciation (optional)", text: $pronunciation)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(editing == nil ? "Add a word" : "Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(lemma.trimmingCharacters(in: .whitespaces).isEmpty || definition.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let w = editing else { return }
                lemma = w.lemma; definition = w.definition; example = w.example ?? ""
                translation = w.translation ?? ""; pos = w.pos ?? ""; pronunciation = w.pronunciation ?? ""
            }
        }
    }

    private func save() {
        let w = editing ?? CustomWord(deckID: deck.id, lang: deck.studyLang, lemma: "", definition: "")
        w.lemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        w.definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        w.example = example.nilIfBlank
        w.translation = translation.nilIfBlank
        w.pos = pos.nilIfBlank
        var p = pronunciation.nilIfBlank
        if deck.studyLang == .zh, let raw = p, raw.contains(where: \.isNumber) { p = Pinyin.marked(numbered: raw) }
        w.pronunciation = p
        if editing == nil { context.insert(w) }
        try? context.save()
        model.refresh()
        dismiss()
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Plain-text document for file export.
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
