import AVFoundation
import PencilKit
import SwiftUI

/// Drives the live "shadowing" tutor: watches the canvas, decides when to send
/// the page for analysis, and publishes what the mascot should say.
///
/// Trigger policy (hybrid): analyze shortly after the user *pauses*, plus a
/// periodic safety check during long continuous writing. Guards keep it cheap
/// and non-naggy: cooldown between calls, a minimum amount of ink, skip when the
/// drawing hasn't meaningfully changed, and never overlap requests.
@MainActor
final class ShadowingEngine: ObservableObject {
    enum State: Equatable {
        case off          // disabled
        case idle         // watching, nothing to say
        case thinking     // analysis in flight
        case onTrack      // last check looked fine
        case hint(String) // interrupt with a nudge
        case listening(String) // live transcript (may be empty)
        case reply(String)     // spoken tutor turn
    }

    @Published private(set) var state: State = .off
    var isEnabled: Bool { if case .off = state { return false } else { return true } }

    /// Set by the canvas layer: renders the active page (ink + background) to an
    /// image no wider than `maxWidth` points.
    var snapshotProvider: ((_ maxWidth: CGFloat) -> UIImage?)?

    private let projectId: String

    // Tuning (long cooldown so a free Gemini key isn't drained by watching)
    private let pauseDelay: TimeInterval = 4.0     // quiet time before a check
    private let cooldown: TimeInterval = 60        // min seconds between auto-checks
    private let longWritingWindow: TimeInterval = 90  // safety check while writing nonstop
    private let minStrokes = 3

    // Bookkeeping
    private var lastActivity = Date.distantPast
    private var lastAnalyzed = Date.distantPast
    private var continuousStart: Date?
    private var strokeCount = 0
    private var analyzedStrokeCount = -1
    private var inFlight = false
    private var timer: Timer?
    private var onTrackResetWork: DispatchWorkItem?
    private let voice = VoiceListener()
    private let speaker = AVSpeechSynthesizer()
    private let speechDelegate = SpeechFinishDelegate()
    private lazy var nativeVoice: AVSpeechSynthesisVoice? = Self.pickNativeVoice()

    // Source grounding: the problem is read off the page once per page and
    // cached, then sent with every check so the backend can retrieve the
    // project's sources and ground its hints (NotebookLM-style).
    private var activePage = 0
    private var problemContext: String?

    init(projectId: String) {
        self.projectId = projectId
        speaker.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor in self?.speechDidFinish() }
        }
    }

    /// Called when the visible page changes; forces a fresh problem inference.
    func setActivePage(_ index: Int) {
        guard index != activePage else { return }
        activePage = index
        problemContext = nil
    }

    // MARK: Control

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ on: Bool) {
        if on {
            guard !isEnabled else { return }
            state = .idle
            startTimer()
        } else {
            voice.cancel()
            speaker.stopSpeaking(at: .immediate)
            state = .off
            stopTimer()
        }
    }

    func dismissHint() {
        speaker.stopSpeaking(at: .immediate)
        if case .listening = state {
            voice.cancel()
            inFlight = false
        }
        switch state {
        case .hint, .reply, .listening: state = isEnabled ? .idle : .off
        default: break
        }
    }

    /// Hold/tap the mic: listen until the user goes silent, then talk back.
    func startListening() {
        speaker.stopSpeaking(at: .immediate)
        if case .off = state { setEnabled(true) }
        // A leftover hint/reply must not block the mic (and used to crash when
        // we started recording on a .playback audio session).
        switch state {
        case .thinking:
            return
        case .hint, .reply, .listening:
            voice.cancel()
            inFlight = false
            state = .idle
        default:
            break
        }
        voice.onPartial = { [weak self] text in
            self?.state = .listening(text)
        }
        voice.onFinished = { [weak self] text in
            self?.submitUtterance(text)
        }
        voice.onError = { [weak self] message in
            self?.inFlight = false
            self?.state = .reply(message)
        }
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.voice.requestAccess()
            guard allowed else {
                self.state = .reply("Allow microphone and speech recognition to talk to the tutor.")
                return
            }
            // Let TTS / playback fully release the session before recording.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try self.voice.start()
                self.inFlight = true
                self.state = .listening("")
            } catch {
                self.inFlight = false
                self.state = .reply(error.localizedDescription)
            }
        }
    }

    private func speechDidFinish() {
        switch state {
        case .hint, .reply:
            state = isEnabled ? .idle : .off
        default:
            break
        }
    }

    func cancelListening() {
        voice.cancel()
        inFlight = false
        if isEnabled { state = .idle }
    }

    /// Called on every drawing change from the active canvas.
    func noteDrawingChanged(strokeCount: Int) {
        guard isEnabled else { return }
        lastActivity = Date()
        self.strokeCount = max(strokeCount, 0)
        if continuousStart == nil { continuousStart = lastActivity }
    }

    // MARK: Timer loop

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isEnabled, !inFlight else { return }
        if case .listening = state { return }
        if case .reply = state { return }
        if case .hint = state { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalyzed) >= cooldown else { return }
        guard strokeCount >= minStrokes, strokeCount != analyzedStrokeCount else { return }

        let paused = lastActivity > lastAnalyzed
            && now.timeIntervalSince(lastActivity) >= pauseDelay
        let longWriting = continuousStart.map { now.timeIntervalSince($0) >= longWritingWindow } ?? false

        if paused || longWriting { analyze() }
    }

    private func submitUtterance(_ text: String) {
        guard let image = snapshotProvider?(1024), let png = image.pngData() else {
            inFlight = false
            state = isEnabled ? .idle : .off
            return
        }
        state = .thinking
        let base64 = png.base64EncodedString()
        let projectId = self.projectId
        let cachedProblem = problemContext
        let page = activePage
        Task { [weak self] in
            do {
                let resp = try await APIClient.shared.talk(
                    projectId: projectId,
                    imageBase64: base64,
                    utterance: text,
                    problemContext: cachedProblem
                )
                await MainActor.run {
                    if let problem = resp.problem {
                        self?.cacheProblem(problem, page: page)
                    }
                    self?.finish(with: .reply(resp.reply))
                    self?.speak(resp.reply)
                }
            } catch {
                await MainActor.run {
                    self?.finish(with: .reply("I couldn't hear that. Try again?"))
                }
            }
        }
    }

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: trimmed)
        // New Siri / Apple Intelligence voices are not exposed to third-party
        // apps. Use the best downloadable Spoken Content voice instead.
        if let nativeVoice, nativeVoice.quality == .premium || nativeVoice.quality == .enhanced {
            utterance.voice = nativeVoice
        } else {
            utterance.prefersAssistiveTechnologySettings = true
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.93
        utterance.pitchMultiplier = 1.02
        utterance.preUtteranceDelay = 0.05
        speaker.speak(utterance)
    }

    /// Best *allowed* on-device English voice. Apple blocks Siri voice IDs
    /// from AVSpeechSynthesizer even if they're installed for Siri itself.
    private static func pickNativeVoice() -> AVSpeechSynthesisVoice? {
        let preferredNames = ["Ava", "Samantha", "Zoe", "Nicky", "Susan"]
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.identifier.localizedCaseInsensitiveContains("siri")
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, String) {
            let quality: Int
            switch voice.quality {
            case .premium: quality = 0
            case .enhanced: quality = 1
            default: quality = 2
            }
            let named = preferredNames.firstIndex { voice.name.contains($0) } ?? preferredNames.count
            return (quality, named, voice.identifier)
        }
        return english.min(by: { score($0) < score($1) })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func analyze() {
        guard let image = snapshotProvider?(1024), let png = image.pngData() else { return }
        inFlight = true
        state = .thinking
        lastAnalyzed = Date()
        analyzedStrokeCount = strokeCount
        continuousStart = nil

        let base64 = png.base64EncodedString()
        let projectId = self.projectId
        let cachedProblem = problemContext
        let page = activePage
        Task { [weak self] in
            do {
                // First check on a page sends no problem; the backend reads it
                // off the image, retrieves sources, then analyzes. Later checks
                // reuse the cached problem so we skip the extra vision pass.
                let resp = try await APIClient.shared.shadow(
                    projectId: projectId, imageBase64: base64, problemContext: cachedProblem
                )
                await MainActor.run {
                    if let problem = resp.problem {
                        self?.cacheProblem(problem, page: page)
                    }
                    self?.apply(resp)
                }
            } catch {
                await MainActor.run { self?.finish(with: .idle) }
            }
        }
    }

    private func cacheProblem(_ problem: String, page: Int) {
        guard page == activePage else { return }   // ignore if the user moved on
        problemContext = problem
    }

    private func apply(_ resp: ShadowResponse) {
        if resp.status == "interrupt", let hint = resp.hint, !hint.isEmpty {
            finish(with: .hint(hint))
            speak(hint)
        } else {
            finish(with: .onTrack)
            scheduleOnTrackReset()
        }
    }

    private func finish(with newState: State) {
        inFlight = false
        guard isEnabled else { state = .off; return }
        state = newState
    }

    /// "Looks good" is transient; fade back to idle so the bubble doesn't linger.
    private func scheduleOnTrackReset() {
        onTrackResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .onTrack = self.state { self.state = .idle }
        }
        onTrackResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// AVSpeechSynthesizerDelegate has to be an NSObject; keep it off the engine.
private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
