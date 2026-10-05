import SwiftUI
import FSRS
import LexiLogic

/// Four-option question. One view serves five games:
/// word → meaning, meaning → word, listening (hear → word), fill in the blank, tone trainer (zh).
struct ChoiceQuestionView: View {
    @Environment(AppModel.self) private var model
    let session: GameSession
    let card: WordCard
    let kind: GameKind

    @State private var options: [String] = []
    @State private var answer = ""
    @State private var picked: String?
    @State private var start = Date()

    var body: some View {
        VStack(spacing: 22) {
            Text(instruction).font(.subheadline).foregroundStyle(model.theme.secondary)
            prompt.frame(maxWidth: .infinity, minHeight: 160)
            VStack(spacing: 12) {
                ForEach(options, id: \.self) { o in
                    Button { choose(o) } label: {
                        Text(o).font(kind == .toneTrainer ? .title2 : .body)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .padding(.horizontal, 8)
                            .background(color(for: o), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(picked != nil)
                    .accessibilityAddTraits(picked != nil && o == answer ? .isSelected : [])
                }
            }
            if picked != nil && picked != answer {
                Button("Next") { session.record(card, correct: false, seconds: elapsed, kind: kind) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Spacer()
        }
        .onAppear(perform: setUp)
    }

    private var elapsed: Double { Date().timeIntervalSince(start) }

    private var instruction: LocalizedStringKey {
        switch kind {
        case .meaningToWord: return "Pick the word"
        case .listening: return "Which word do you hear?"
        case .fillBlank: return "Fill in the blank"
        case .toneTrainer: return "Pick the correct tones"
        default: return "Pick the meaning"
        }
    }

    @ViewBuilder
    private var prompt: some View {
        switch kind {
        case .wordToMeaning:
            VStack(spacing: 8) {
                Text(card.headword(traditional: model.useTraditional)).font(model.theme.word(40))
                if let p = card.pronunciation, card.lang == .zh { Text(p).foregroundStyle(model.theme.secondary) }
            }
        case .meaningToWord:
            Text(card.meaning).font(.title3).multilineTextAlignment(.center).lineLimit(5)
        case .listening:
            Button { Speech.shared.speak(card.lemma, lang: card.lang) } label: {
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 54))
            }
            .accessibilityLabel(Text("Play again"))
        case .fillBlank:
            VStack(spacing: 10) {
                Text(blanked).font(.title3).multilineTextAlignment(.center)
                if let t = card.examples.first?.translation { Text(t).font(.callout).foregroundStyle(model.theme.secondary) }
            }
        case .toneTrainer:
            VStack(spacing: 10) {
                Text(card.headword(traditional: model.useTraditional)).font(model.theme.word(48))
                Button { Speech.shared.speak(card.lemma, lang: .zh) } label: {
                    Label("Listen", systemImage: "speaker.wave.2.fill")
                }
            }
        default:
            EmptyView()
        }
    }

    private var blanked: String {
        guard let ex = card.examples.first?.text else { return "" }
        let w = model.useTraditional ? (card.traditional ?? card.lemma) : card.lemma
        return TextMatch.blank(ex, word: card.lemma, isChinese: card.lang == .zh)
            ?? TextMatch.blank(ex, word: w, isChinese: card.lang == .zh) ?? ex
    }

    private func setUp() {
        start = .now
        switch kind {
        case .toneTrainer:
            answer = card.pronunciation ?? ""
            options = Pinyin.toneOptions(answerMarked: answer).shuffled()
        case .wordToMeaning:
            answer = shortened(card.meaning)
            options = session.options(for: card, showWords: false).map { shortened($0.meaning) }
        default:
            answer = card.headword(traditional: model.useTraditional)
            options = session.options(for: card, showWords: true).map { $0.headword(traditional: model.useTraditional) }
        }
        if kind == .listening || kind == .toneTrainer {
            Task { @MainActor in try? await Task.sleep(for: .seconds(0.3)); Speech.shared.speak(card.lemma, lang: card.lang) }
        }
    }

    private func shortened(_ s: String) -> String { s.count > 120 ? String(s.prefix(117)) + "…" : s }

    private func choose(_ o: String) {
        let t = elapsed
        picked = o
        if o == answer {
            if kind != .listening { Speech.shared.speak(card.lemma, lang: card.lang) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(0.7));
                session.record(card, correct: true, seconds: t, kind: kind)
            }
        }
    }

    private func color(for o: String) -> Color {
        guard let picked else { return model.theme.background2.opacity(0.9) }
        if o == answer { return .green.opacity(0.35) }
        if o == picked { return .red.opacity(0.35) }
        return model.theme.background2.opacity(0.5)
    }
}

/// Type the word from its meaning (or from audio). zh accepts pinyin with or without tone numbers,
/// tone marks, or the characters.
struct SpellingQuestionView: View {
    @Environment(AppModel.self) private var model
    let session: GameSession
    let card: WordCard

    @State private var typed = ""
    @State private var fromAudio = false
    @State private var hint = 0
    @State private var checked: Bool?
    @State private var accentNote = false
    @State private var start = Date()
    @FocusState private var focused: Bool

    private var target: String {
        card.lang == .zh ? (card.pronunciation ?? card.lemma) : card.lemma
    }

    var body: some View {
        VStack(spacing: 20) {
            Picker("Prompt", selection: $fromAudio) {
                Text("Meaning").tag(false)
                Text("Audio").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(checked != nil)

            Group {
                if fromAudio {
                    Button { Speech.shared.speak(card.lemma, lang: card.lang) } label: {
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 50))
                    }
                    .accessibilityLabel(Text("Play the word"))
                } else {
                    VStack(spacing: 6) {
                        Text(card.meaning).font(.title3).multilineTextAlignment(.center).lineLimit(5)
                        if card.lang == .zh { Text(card.headword(traditional: model.useTraditional)).font(.title) }
                    }
                }
            }
            .frame(minHeight: 120)

            Text(card.lang == .zh ? "Type the pinyin (tone numbers optional)" : "Type the word")
                .font(.caption).foregroundStyle(model.theme.secondary)
            TextField("", text: $typed)
                .font(.title2)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(model.theme.background2.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                .focused($focused)
                .onSubmit(check)
                .disabled(checked != nil)

            if hint > 0 && checked == nil {
                Text(String(target.prefix(hint)) + String(repeating: "·", count: max(0, target.count - hint)))
                    .font(.title3.monospaced()).foregroundStyle(model.theme.secondary)
            }

            if let checked {
                VStack(spacing: 6) {
                    Label(checked ? String(localized: "Correct") : String(localized: "Not quite"),
                          systemImage: checked ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(checked ? .green : .red).font(.headline)
                    Text(card.lang == .zh ? "\(card.lemma)  \(card.pronunciation ?? "")" : card.lemma).font(.title2.bold())
                    if accentNote { Text("Check the accents.").font(.caption) }
                }
                Button("Next") {
                    session.record(card, correct: checked, seconds: answerSeconds, kind: .spelling,
                                   answerLength: target.count, usedHint: hint > 0)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                HStack {
                    Button("Hint") { hint = min(target.count, hint + 1) }.buttonStyle(.bordered)
                    Button("Check", action: check).buttonStyle(.borderedProminent)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.large)
            }
            Spacer()
        }
        .onAppear {
            start = .now
            focused = true
        }
        .onChange(of: fromAudio) { _, audio in if audio { Speech.shared.speak(card.lemma, lang: card.lang) } }
    }

    @State private var answerSeconds: Double = 0

    private func check() {
        guard checked == nil, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        answerSeconds = Date().timeIntervalSince(start)
        let ok: Bool
        if card.lang == .zh {
            let t = typed.trimmingCharacters(in: .whitespaces)
            ok = t == card.lemma || t == card.traditional
                || (card.pronunciation.map { Pinyin.matches(typed: t, answerMarked: $0) } ?? false)
        } else {
            ok = TextMatch.equal(typed, card.lemma)
            accentNote = ok && TextMatch.accentOnly(typed, card.lemma)
        }
        checked = ok
        Speech.shared.speak(card.lemma, lang: card.lang)
    }
}

/// Six pairs, timed. Each word is graded by the time to match it (per-pair thresholds) and whether
/// the first try was right.
struct MatchingGameView: View {
    @Environment(AppModel.self) private var model
    let session: GameSession

    @State private var left: [WordCard] = []
    @State private var right: [WordCard] = []
    @State private var selLeft: String?
    @State private var selRight: String?
    @State private var matched: Set<String> = []
    @State private var missed: Set<String> = []
    @State private var wrongFlash: Set<String> = []
    @State private var start = Date()
    @State private var lastMatch = Date()
    @State private var pairTimes: [String: Double] = [:]
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Match the pairs").font(.headline)
                Spacer()
                Label(Duration.seconds(now.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)),
                      systemImage: "timer").monospacedDigit()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 10) {
                    ForEach(left) { c in tile(c.headword(traditional: model.useTraditional), id: c.key, isLeft: true) }
                }
                VStack(spacing: 10) {
                    ForEach(right) { c in tile(shortMeaning(c), id: c.key, isLeft: false) }
                }
            }
            Spacer()
        }
        .onAppear {
            let cards = Array(session.cards.prefix(6))
            left = cards.shuffled()
            right = cards.shuffled()
            start = .now
            lastMatch = .now
        }
        .onReceive(timer) { now = $0 }
    }

    private func shortMeaning(_ c: WordCard) -> String {
        let m = c.shortMeaning
        return m.count > 60 ? String(m.prefix(57)) + "…" : m
    }

    private func tile(_ text: String, id: String, isLeft: Bool) -> some View {
        let done = matched.contains(id)
        let selected = isLeft ? selLeft == id : selRight == id
        return Button {
            if isLeft { selLeft = id } else { selRight = id }
            tryMatch()
        } label: {
            Text(text).font(isLeft ? .title3 : .callout)
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(.horizontal, 6)
                .background(bg(done: done, selected: selected, wrong: wrongFlash.contains(id)), in: RoundedRectangle(cornerRadius: 12))
                .opacity(done ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(done)
    }

    private func bg(done: Bool, selected: Bool, wrong: Bool) -> Color {
        if wrong { return .red.opacity(0.4) }
        if done { return .green.opacity(0.3) }
        if selected { return model.theme.accent.opacity(0.35) }
        return model.theme.background2.opacity(0.9)
    }

    private func tryMatch() {
        guard let l = selLeft, let r = selRight else { return }
        if l == r {
            matched.insert(l)
            pairTimes[l] = Date().timeIntervalSince(lastMatch)
            lastMatch = .now
            if let c = left.first(where: { $0.key == l }) { Speech.shared.speak(c.lemma, lang: c.lang) }
        } else {
            missed.insert(l); missed.insert(r)
            wrongFlash = [l, r]
            Task { @MainActor in try? await Task.sleep(for: .seconds(0.5)); wrongFlash = [] }
        }
        selLeft = nil
        selRight = nil
        if matched.count == left.count { finish() }
    }

    private func finish() {
        for c in left {
            session.record(c, correct: !missed.contains(c.key), seconds: pairTimes[c.key] ?? 10,
                           kind: .matching, advance: false)
        }
    }
}
