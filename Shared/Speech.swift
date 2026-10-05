import AVFoundation

/// Offline text-to-speech with the system voices (en-US, es-MX/es-ES, zh-CN).
@MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var current: ObjectIdentifier?

    override init() {
        super.init()
        synth.delegate = self
    }

    static func voiceCode(for lang: Lang) -> String {
        switch lang {
        case .en: return "en-US"
        case .es: return AppGroup.defaults.string(forKey: SettingKey.spanishVoice) ?? "es-MX"
        case .zh: return "zh-CN"
        }
    }

    /// True when the device has a voice for the language (iOS ships en/es/zh voices by default).
    static func hasVoice(for lang: Lang) -> Bool {
        AVSpeechSynthesisVoice(language: voiceCode(for: lang)) != nil
    }

    func speak(_ text: String, lang: Lang, rateScale: Double? = nil, onFinish: (() -> Void)? = nil) {
        guard !text.isEmpty else { onFinish?(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Self.voiceCode(for: lang))
        let scale = rateScale ?? AppGroup.defaults.double(forKey: SettingKey.speechRate)
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(scale > 0 ? scale : 0.9)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        // A stopped utterance reports didCancel later; it must not end the new utterance's wait.
        let previous = self.onFinish
        self.onFinish = onFinish
        current = ObjectIdentifier(u)
        previous?()
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// Speaks and returns when speech ends (or after `timeout` seconds). Used by the widget "Speak" intent,
    /// which must keep the process alive until the audio is done.
    func speakAndWait(_ text: String, lang: Lang, timeout: Double = 10) async {
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let finish = {
                guard !once.done else { return }
                once.done = true
                cont.resume()
            }
            speak(text, lang: lang, onFinish: finish)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                finish()
            }
        }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard id == current else { return }
        let f = onFinish
        onFinish = nil
        current = nil
        f?()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.finished(id) }
    }
}
