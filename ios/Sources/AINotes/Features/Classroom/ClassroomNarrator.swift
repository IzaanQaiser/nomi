import AVFoundation

/// Native, on-device narration for Classroom lessons.
///
/// The active utterance is tracked by identity so a delayed cancellation
/// callback can never complete a newer lesson beat after a skip or reset.
@MainActor
final class ClassroomNarrator {
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = ClassroomSpeechDelegate()
    private lazy var voice: AVSpeechSynthesisVoice? = Self.pickNativeVoice()
    private var activeUtterance: AVSpeechUtterance?
    private var progress: ((Double) -> Void)?
    private var completion: (() -> Void)?

    init() {
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] utterance, cancelled in
            Task { @MainActor in
                self?.finished(utterance, cancelled: cancelled)
            }
        }
        delegate.onWillSpeak = { [weak self] utterance, range in
            Task { @MainActor in
                self?.willSpeak(utterance, range: range)
            }
        }
    }

    var isPaused: Bool { synthesizer.isPaused }

    func speak(
        _ text: String,
        progress: @escaping (Double) -> Void,
        completion: @escaping () -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            progress(1)
            completion()
            return
        }

        stop()
        configureAudioSession()

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice, voice.quality == .premium || voice.quality == .enhanced {
            utterance.voice = voice
        } else {
            utterance.prefersAssistiveTechnologySettings = true
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.93
        utterance.pitchMultiplier = 1.02
        utterance.preUtteranceDelay = 0.08

        activeUtterance = utterance
        self.progress = progress
        self.completion = completion
        progress(0)
        synthesizer.speak(utterance)
    }

    @discardableResult
    func pause() -> Bool {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return false }
        return synthesizer.pauseSpeaking(at: .word)
    }

    @discardableResult
    func resume() -> Bool {
        guard synthesizer.isPaused else { return false }
        return synthesizer.continueSpeaking()
    }

    func stop() {
        let hadActiveUtterance = activeUtterance != nil
        activeUtterance = nil
        progress = nil
        completion = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if hadActiveUtterance {
            deactivateAudioSession()
        }
    }

    private func finished(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        let progressCallback = progress
        progress = nil
        let callback = completion
        completion = nil
        deactivateAudioSession()
        if !cancelled {
            progressCallback?(1)
            callback?()
        }
    }

    private func willSpeak(_ utterance: AVSpeechUtterance, range: NSRange) {
        guard activeUtterance === utterance else { return }
        let length = max(1, (utterance.speechString as NSString).length)
        let wordStart = min(length, max(0, range.location))
        progress?(Double(wordStart) / Double(length))
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private static func pickNativeVoice() -> AVSpeechSynthesisVoice? {
        let preferredNames = ["Ava", "Samantha", "Zoe", "Nicky", "Susan"]
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en")
                && !$0.identifier.localizedCaseInsensitiveContains("siri")
        }

        func score(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, String) {
            let quality: Int
            switch voice.quality {
            case .premium: quality = 0
            case .enhanced: quality = 1
            default: quality = 2
            }
            let preferred = preferredNames.firstIndex { voice.name.contains($0) }
                ?? preferredNames.count
            return (quality, preferred, voice.identifier)
        }

        return english.min { score($0) < score($1) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

private final class ClassroomSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: ((AVSpeechUtterance, Bool) -> Void)?
    var onWillSpeak: ((AVSpeechUtterance, NSRange) -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onWillSpeak?(utterance, characterRange)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onFinish?(utterance, false)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onFinish?(utterance, true)
    }
}
