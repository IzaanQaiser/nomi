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
