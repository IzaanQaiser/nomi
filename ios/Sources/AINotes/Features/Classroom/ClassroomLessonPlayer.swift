import Foundation
import Observation

/// Deterministic runtime for a prepared classroom lesson.
///
/// The player deliberately knows nothing about speech or PencilKit. Those
/// systems can observe `currentBeat` and `visibleBeats` later without moving
/// transport logic into the view layer.
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
    private(set) var playbackState: PlaybackState = .ready

    private var advanceTask: Task<Void, Never>?

    var currentBeat: ClassroomLessonBeat? {
        guard let lesson, lesson.beats.indices.contains(currentBeatIndex) else { return nil }
        return lesson.beats[currentBeatIndex]
    }

    /// All beats that should already be represented on Nomi's board.
    /// A future renderer can rebuild its layer from this array after a rewind.
    var visibleBeats: [ClassroomLessonBeat] {
        guard let lesson, !lesson.beats.isEmpty else { return [] }
        return Array(lesson.beats.prefix(currentBeatIndex + 1))
    }

    var progress: Double {
        guard let lesson, !lesson.beats.isEmpty else { return 0 }
        if playbackState == .completed { return 1 }
        return Double(currentBeatIndex + 1) / Double(lesson.beats.count)
    }

    var positionLabel: String {
        guard let lesson, !lesson.beats.isEmpty else { return "" }
        return "Step \(min(currentBeatIndex + 1, lesson.beats.count)) of \(lesson.beats.count)"
    }

    var canMoveBackward: Bool { currentBeatIndex > 0 }

    var canMoveForward: Bool {
        guard let lesson else { return false }
        return currentBeatIndex < lesson.beats.count - 1
    }

    func load(_ lesson: ClassroomLesson) {
        advanceTask?.cancel()
        self.lesson = lesson
        currentBeatIndex = 0
        playbackState = .ready
    }

    func reset() {
        advanceTask?.cancel()
        advanceTask = nil
        lesson = nil
        currentBeatIndex = 0
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
        scheduleAdvance()
    }

    func pause() {
        guard playbackState == .playing else { return }
        advanceTask?.cancel()
        advanceTask = nil
        playbackState = .paused
    }

    func moveBackward() {
        guard canMoveBackward else { return }
        advanceTask?.cancel()
        advanceTask = nil
        currentBeatIndex -= 1
        playbackState = .paused
    }

    func moveForward() {
        guard canMoveForward else {
            complete()
            return
        }
        let wasPlaying = playbackState == .playing
        advanceTask?.cancel()
        advanceTask = nil
        currentBeatIndex += 1
        playbackState = wasPlaying ? .playing : .paused
        if wasPlaying { scheduleAdvance() }
    }

    func replay() {
        guard lesson?.beats.isEmpty == false else { return }
        advanceTask?.cancel()
        currentBeatIndex = 0
        playbackState = .playing
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard let beat = currentBeat else { return }
        let delay = previewDuration(for: beat)
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.advanceAfterPlayback()
        }
    }

    private func advanceAfterPlayback() {
        guard playbackState == .playing else { return }
        if canMoveForward {
            currentBeatIndex += 1
            scheduleAdvance()
        } else {
            complete()
        }
    }

    private func complete() {
        advanceTask?.cancel()
        advanceTask = nil
        playbackState = .completed
    }

    /// Temporary visual-reading cadence. Narration will replace this timer in
    /// the next slice and call `moveForward()` when speech actually finishes.
    private func previewDuration(for beat: ClassroomLessonBeat) -> Double {
        let words = beat.speaking.split(whereSeparator: \.isWhitespace).count
        return min(14, max(6, Double(words) / 3.2))
    }
}
