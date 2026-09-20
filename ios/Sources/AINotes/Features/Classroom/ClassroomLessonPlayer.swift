import Foundation
import Observation

/// Deterministic runtime for a prepared classroom lesson.
@MainActor
@Observable
final class ClassroomLessonPlayer {
    enum PlaybackState: Equatable {
        case ready
        case playing
        case paused
        case completed
    }

    private(set) var lesson: ClassroomLesson?
    private(set) var currentBeatIndex = 0
    private(set) var narrationProgress = 0.0
    private(set) var playbackState: PlaybackState = .ready
    private(set) var isSpeakingAnswer = false

    private let narrator = ClassroomNarrator()
    private var askHold = false
    private var lessonSpeechInvalidated = false
    private var answerGeneration = 0

    var currentBeat: ClassroomLessonBeat? {
        guard let lesson, lesson.beats.indices.contains(currentBeatIndex) else { return nil }
        return lesson.beats[currentBeatIndex]
    }

    var currentSlide: ClassroomSlide? { currentBeat?.slide }

    var progress: Double {
        guard let lesson, !lesson.beats.isEmpty else { return 0 }
        if playbackState == .completed { return 1 }
        return (Double(currentBeatIndex) + narrationProgress) / Double(lesson.beats.count)
    }

    var positionLabel: String {
        guard let lesson, !lesson.beats.isEmpty else { return "" }
        return "Slide \(min(currentBeatIndex + 1, lesson.beats.count)) of \(lesson.beats.count)"
    }

    var isPlaying: Bool { playbackState == .playing }

    var canMoveBackward: Bool { currentBeatIndex > 0 && !askHold }

    var canMoveForward: Bool {
        guard let lesson, !askHold else { return false }
        return currentBeatIndex < lesson.beats.count - 1
    }

    func load(_ lesson: ClassroomLesson) {
        stopAllSpeech()
        askHold = false
        lessonSpeechInvalidated = false
        self.lesson = lesson
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .ready
    }

    func reset() {
        stopAllSpeech()
        askHold = false
        lessonSpeechInvalidated = false
        lesson = nil
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .ready
    }

    func togglePlayback() {
        guard !askHold else { return }
        switch playbackState {
        case .ready, .paused:
            play()
        case .playing:
            pause()
        case .completed:
            replay()
        }
    }

    func play() {
        guard currentBeat != nil, !askHold else { return }
        playbackState = .playing
        if lessonSpeechInvalidated || !narrator.resume() {
            lessonSpeechInvalidated = false
            narrateCurrentBeat()
        }
    }

    func pause() {
        guard playbackState == .playing else { return }
        narrator.pause()
        playbackState = .paused
    }

    func moveBackward() {
        guard canMoveBackward else { return }
        narrator.stop()
        isSpeakingAnswer = false
        lessonSpeechInvalidated = true
        currentBeatIndex -= 1
        narrationProgress = 0
        playbackState = .paused
    }

    func replay() {
        guard lesson?.beats.isEmpty == false, !askHold else { return }
        narrator.stop()
        isSpeakingAnswer = false
        lessonSpeechInvalidated = false
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .playing
        narrateCurrentBeat()
    }

    /// Pause lesson speech without leaving the current slide.
    func pauseForAsk() {
        askHold = true
        isSpeakingAnswer = false
        if playbackState == .playing {
            pause()
        }
    }

    /// Speak a Q&A answer. Stops any paused lesson utterance so audio cannot overlap.
    func speakAnswer(_ text: String, completion: @escaping () -> Void) {
        askHold = true
        lessonSpeechInvalidated = true
        if playbackState == .playing {
            playbackState = .paused
        }
        answerGeneration += 1
        let generation = answerGeneration
        isSpeakingAnswer = true
        narrator.speak(text) { _ in } completion: { [weak self] in
            guard let self, self.answerGeneration == generation else { return }
            self.isSpeakingAnswer = false
            completion()
        }
    }

    func stopAnswerSpeech() {
        answerGeneration += 1
        if isSpeakingAnswer {
            narrator.stop()
            isSpeakingAnswer = false
            lessonSpeechInvalidated = true
        }
    }

    /// Leave Ask Nomi and continue this same beat. Does not advance or restart the lesson.
    func resumeLessonAfterAsk() {
        askHold = false
        stopAnswerSpeech()
        if playbackState == .completed { return }
        play()
    }

    /// Stop audio without discarding the prepared lesson or current position.
    func stopPlayback() {
        stopAllSpeech()
        lessonSpeechInvalidated = true
        if playbackState == .playing {
            playbackState = .paused
        }
    }

    private func stopAllSpeech() {
        answerGeneration += 1
        isSpeakingAnswer = false
        narrator.stop()
    }

    private func narrateCurrentBeat() {
        guard let beat = currentBeat, !askHold else { return }
        let expectedIndex = currentBeatIndex
        narrator.speak(beat.speaking) { [weak self] progress in
            guard let self,
                  self.playbackState == .playing,
                  !self.askHold,
                  self.currentBeatIndex == expectedIndex else { return }
            self.narrationProgress = min(1, max(self.narrationProgress, progress))
        } completion: { [weak self] in
            guard let self,
                  self.playbackState == .playing,
                  !self.askHold,
                  self.currentBeatIndex == expectedIndex else { return }
            self.advanceAfterNarration()
        }
    }

    private func advanceAfterNarration() {
        guard playbackState == .playing, !askHold else { return }
        if currentBeatIndex < (lesson?.beats.count ?? 0) - 1 {
            currentBeatIndex += 1
            narrationProgress = 0
            narrateCurrentBeat()
        } else {
            complete()
        }
    }

    private func complete() {
        narrator.stop()
        narrationProgress = 1
        playbackState = .completed
    }
}
