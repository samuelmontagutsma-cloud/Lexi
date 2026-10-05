import SwiftUI
import SwiftData

/// Look up any word in the bundled lexicon (en, es, zh: word, pinyin with or without tones, traditional,
/// or a translation).
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var lang: Lang?
    @State private var results: [LexWord] = []

    var body: some View {
        NavigationStack {
            List {
                Picker("Language", selection: $lang) {
                    Text("All").tag(Lang?.none)
                    ForEach(Lang.allCases) { l in Text(l.displayName).tag(Lang?.some(l)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(results, id: \.key) { w in
                    NavigationLink {
                        WordDetailView(key: w.key)
                    } label: {
                        SearchRow(word: w)
                    }
                }
            }
            .overlay {
                if !text.isEmpty && results.isEmpty { ContentUnavailableView.search(text: text) }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Word, pinyin or translation"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(text)|\(lang?.rawValue ?? "")") {
                try? await Task.sleep(for: .milliseconds(150))   // debounce typing
                guard !Task.isCancelled else { return }
                let q = text.filter { !$0.isNumber }             // "qing1" → "qing" (search text has no tones)
                results = Lexicon.shared.search(q, langs: lang.map { [$0] } ?? Lang.allCases)
            }
        }
    }
}

struct SearchRow: View {
    let word: LexWord
    var body: some View {
        let gloss = word.lang == .zh ? Lexicon.shared.translations(wordID: word.id, to: .en).first
            : Lexicon.shared.senses(wordID: word.id).first(where: { $0.defLang == word.lang })?.definition
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(word.lang.flag) \(word.lemma)").font(.headline)
                if let p = word.lang == .zh ? word.pinyin : nil { Text(p).foregroundStyle(.secondary) }
                Spacer()
                Text(Levels.label(lang: word.lang, level: word.level)).font(.caption).foregroundStyle(.secondary)
            }
            if let gloss { Text(gloss).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Full card for any word, in the best matching deck (or dictionary/English view if no deck fits).
struct WordDetailView: View {
    @Environment(\.modelContext) private var context
    let key: String

    var body: some View {
        let s = StudyService(context: context)
        let deck = s.bestDeck(for: key)
        let card: WordCard? = deck.flatMap { s.card(key: key, deck: $0) } ?? {
            guard let w = Lexicon.shared.word(key: key) else { return nil }
            return CardFactory(lexicon: .shared).card(for: w, mode: w.lang == .zh ? .learn : .dictionary,
                                                     explanation: w.lang == .zh ? .en : w.lang)
        }()
        ZStack {
            ThemedBackground()
            if let card {
                ScrollView { WordCardView(card: card, deck: deck, kind: .detail).frame(minHeight: 600) }
            } else {
                ContentUnavailableView("Word not found", systemImage: "questionmark")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// List of words (favorites, a collection, mistakes) with links to their cards.
struct WordListView: View {
    let title: String
    let keys: [String]

    var body: some View {
        let words = Lexicon.shared.words(keys: keys)
        List(keys, id: \.self) { k in
            NavigationLink { WordDetailView(key: k) } label: {
                if let w = words[k] { SearchRow(word: w) } else { Text(k.hasPrefix("custom:") ? String(localized: "My word") : k) }
            }
        }
        .overlay { if keys.isEmpty { ContentUnavailableView("No words yet", systemImage: "tray") } }
        .navigationTitle(title)
    }
}
