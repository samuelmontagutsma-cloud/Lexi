import AVFoundation

/// Offline text-to-speech with the system voices (en-US, es-MX/es-ES, zh-CN).
@MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

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
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Self.voiceCode(for: lang))
        let scale = rateScale ?? AppGroup.defaults.double(forKey: SettingKey.speechRate)
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(scale > 0 ? scale : 0.9)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        self.onFinish = onFinish
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.onFinish?()
            self.onFinish = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
