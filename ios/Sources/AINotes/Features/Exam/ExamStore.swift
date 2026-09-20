import Foundation

/// Persists the generated exam for a notebook (keyed by its storage id) so
/// Exam Mode can show the timer/nudges and grading can score against it later.
enum ExamStore {
    private static func key(_ storageID: String) -> String { "nomi.exam.\(storageID)" }

    static func save(_ exam: GeneratedExam, storageID: String) {
        if let data = try? JSONEncoder().encode(exam) {
            UserDefaults.standard.set(data, forKey: key(storageID))
        }
    }

    static func load(storageID: String) -> GeneratedExam? {
        guard let data = UserDefaults.standard.data(forKey: key(storageID)) else { return nil }
        return try? JSONDecoder().decode(GeneratedExam.self, from: data)
    }

    static func isExam(storageID: String) -> Bool {
        UserDefaults.standard.data(forKey: key(storageID)) != nil
    }

    static func remove(storageID: String) {
        UserDefaults.standard.removeObject(forKey: key(storageID))
    }
}

/// Tracks a running exam sitting: its deadline (so backgrounding/relaunch keeps
/// the same countdown), completion, and the saved grade for re-viewing.
enum ExamSessionStore {
    private static func deadlineKey(_ id: String) -> String { "nomi.exam.deadline.\(id)" }
    private static func gradeKey(_ id: String) -> String { "nomi.exam.grade.\(id)" }

    /// Returns the existing deadline, or starts one `durationMinutes` from now.
    static func startIfNeeded(storageID: String, durationMinutes: Int) -> Date {
        let d = UserDefaults.standard
        let existing = d.double(forKey: deadlineKey(storageID))
        if existing > 0 { return Date(timeIntervalSince1970: existing) }
        let deadline = Date().addingTimeInterval(Double(max(1, durationMinutes)) * 60)
        d.set(deadline.timeIntervalSince1970, forKey: deadlineKey(storageID))
        return deadline
    }

    static func deadline(storageID: String) -> Date? {
        let v = UserDefaults.standard.double(forKey: deadlineKey(storageID))
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    static func saveGrade(_ grade: ExamGrade, storageID: String) {
        if let data = try? JSONEncoder().encode(grade) {
            UserDefaults.standard.set(data, forKey: gradeKey(storageID))
        }
    }

    static func grade(storageID: String) -> ExamGrade? {
        guard let data = UserDefaults.standard.data(forKey: gradeKey(storageID)) else { return nil }
        return try? JSONDecoder().decode(ExamGrade.self, from: data)
    }

    static func isCompleted(storageID: String) -> Bool {
        grade(storageID: storageID) != nil
    }
}
