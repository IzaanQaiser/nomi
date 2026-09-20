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

    private let narrator = ClassroomNarrator()

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

    var canMoveBackward: Bool { currentBeatIndex > 0 }

    var canMoveForward: Bool {
        guard let lesson else { return false }
        return currentBeatIndex < lesson.beats.count - 1
    }

    func load(_ lesson: ClassroomLesson) {
        narrator.stop()
        self.lesson = lesson
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .ready
    }

    func reset() {
        narrator.stop()
        lesson = nil
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .ready
    }

    func togglePlayback() {
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
        guard currentBeat != nil else { return }
        playbackState = .playing
        if !narrator.resume() {
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
        currentBeatIndex -= 1
        narrationProgress = 0
        playbackState = .paused
    }

    func moveForward() {
        guard canMoveForward else {
            complete()
            return
        }
        let wasPlaying = playbackState == .playing
        narrator.stop()
        currentBeatIndex += 1
        narrationProgress = 0
        playbackState = wasPlaying ? .playing : .paused
        if wasPlaying { narrateCurrentBeat() }
    }

    func replay() {
        guard lesson?.beats.isEmpty == false else { return }
        narrator.stop()
        currentBeatIndex = 0
        narrationProgress = 0
        playbackState = .playing
        narrateCurrentBeat()
    }

    /// Stop audio without discarding the prepared lesson or current position.
    func stopPlayback() {
        narrator.stop()
        if playbackState == .playing {
            playbackState = .paused
        }
    }

    private func narrateCurrentBeat() {
        guard let beat = currentBeat else { return }
        let expectedIndex = currentBeatIndex
        narrator.speak(beat.speaking) { [weak self] progress in
            guard let self,
                  self.playbackState == .playing,
                  self.currentBeatIndex == expectedIndex else { return }
            self.narrationProgress = min(1, max(self.narrationProgress, progress))
        } completion: { [weak self] in
            guard let self,
                  self.playbackState == .playing,
                  self.currentBeatIndex == expectedIndex else { return }
            self.advanceAfterNarration()
        }
    }

    private func advanceAfterNarration() {
        guard playbackState == .playing else { return }
        if canMoveForward {
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
