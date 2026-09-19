import AVFoundation
import Foundation
import Speech

/// On-device speech capture with a silence cutoff.
///
/// Start listening, then either:
/// - the user talks and then goes quiet for `silenceGap` → we treat that as
///   end-of-turn and hand back the transcript, or
/// - they stay quiet for `emptyTimeout` → we hand back an empty string so the
///   tutor can cut in.
@MainActor
final class VoiceListener: NSObject {
    var onPartial: ((String) -> Void)?
    var onFinished: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let silenceGap: TimeInterval = 1.4
    private let emptyTimeout: TimeInterval = 2.6

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var emptyTimer: Timer?
    private var transcript = ""
    private var finishing = false
    private var hasTap = false

    var isListening: Bool { audioEngine.isRunning }

    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let mic = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return speech && mic
    }

    /// Flip the shared audio session from playback (TTS) to record.
    func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.isOtherAudioPlaying || session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func start() throws {
        stop(emit: false)
        finishing = false
        transcript = ""
        audioEngine = AVAudioEngine()

        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "VoiceListener", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available."]
            )
        }

        try prepareSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        var input = audioEngine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount <= 0 {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioEngine = AVAudioEngine()
            try prepareSession()
            input = audioEngine.inputNode
            format = input.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "VoiceListener", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Mic isn't ready. Tap the mic again."]
            )
        }
        // nil format = hardware format; passing a stale 0Hz format crashes.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        hasTap = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.finishing else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onPartial?(self.transcript)
                    self.armSilenceTimer()
                    if result.isFinal { self.finish(self.transcript) }
                    return
                }
                if error != nil {
                    if !self.transcript.isEmpty {
                        self.finish(self.transcript)
                    } else if !self.finishing {
                        self.finishing = true
                        self.stop(emit: false)
                        self.onError?("I couldn't hear that. Try the mic again.")
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        armEmptyTimer()
    }

    func cancel() {
        stop(emit: false)
    }

    private func armSilenceTimer() {
        emptyTimer?.invalidate()
        emptyTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceGap, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finish(self.transcript)
            }
        }
    }

    private func armEmptyTimer() {
        emptyTimer?.invalidate()
        emptyTimer = Timer.scheduledTimer(withTimeInterval: emptyTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transcript.isEmpty else { return }
                self.finish("")
            }
        }
    }

    private func finish(_ text: String) {
        guard !finishing else { return }
        finishing = true
        stop(emit: false)
        onFinished?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stop(emit: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil
        emptyTimer?.invalidate()
        emptyTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        request = nil
        // Don't cancel() the task — that can crash after a category change.
        task = nil
        if emit { onFinished?(transcript) }
    }
}
