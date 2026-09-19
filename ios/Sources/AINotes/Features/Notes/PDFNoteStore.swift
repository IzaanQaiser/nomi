import Foundation

/// Local, on-device persistence for PDF-backed notes.
///
/// For the MVP each project has at most one PDF-backed note. The PDF file is
/// copied into the app's Documents directory, and the per-page PencilKit
/// drawings are stored alongside it as JSON (page index -> base64 PKDrawing).
/// Backend sync of PDF annotations is a follow-up.
enum PDFNoteStore {
    private static func sourceKey(projectId: String) -> String {
        "pdfNoteSource-\(projectId)"
    }

    private static var baseDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pdf-notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func pdfURL(projectId: String) -> URL {
        baseDir.appendingPathComponent("\(projectId).pdf")
    }

    static func hasPDF(projectId: String) -> Bool {
        FileManager.default.fileExists(atPath: pdfURL(projectId: projectId).path)
    }

    /// Copy a picked PDF into local storage, replacing any existing one.
    @discardableResult
    static func importPDF(
        from src: URL,
        projectId: String,
        sourceId: String? = nil
    ) throws -> URL {
        let dest = pdfURL(projectId: projectId)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        clearDrawings(key: "\(projectId)-pdf")
        setSelectedSource(sourceId, projectId: projectId)
        return dest
    }

    @discardableResult
    static func importPDF(data: Data, projectId: String, sourceId: String) throws -> URL {
        let dest = pdfURL(projectId: projectId)
        try data.write(to: dest, options: .atomic)
        clearDrawings(key: "\(projectId)-pdf")
        setSelectedSource(sourceId, projectId: projectId)
        return dest
    }

    static func selectedSourceID(projectId: String) -> String? {
        UserDefaults.standard.string(forKey: sourceKey(projectId: projectId))
    }

    static func removePDF(projectId: String) throws {
        let url = pdfURL(projectId: projectId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        clearDrawings(key: "\(projectId)-pdf")
        setSelectedSource(nil, projectId: projectId)
    }

    private static func setSelectedSource(_ sourceId: String?, projectId: String) {
        let key = sourceKey(projectId: projectId)
        if let sourceId {
            UserDefaults.standard.set(sourceId, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func clearDrawings(key: String) {
        let url = baseDir.appendingPathComponent("\(key).drawings.json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Per-page ink is keyed by a note "variant" (e.g. "<projectId>-paper" or
    /// "<projectId>-pdf") so a project's paper notes and PDF annotations don't
    /// clobber each other.
    static func loadDrawings(key: String) -> [Int: Data] {
        let url = baseDir.appendingPathComponent("\(key).drawings.json")
        guard let raw = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: raw)
        else { return [:] }
        var result: [Int: Data] = [:]
        for (k, b64) in dict {
            if let page = Int(k), let data = Data(base64Encoded: b64) {
                result[page] = data
            }
        }
        return result
    }

    static func saveDrawings(_ drawings: [Int: Data], key: String) {
        let url = baseDir.appendingPathComponent("\(key).drawings.json")
        var dict: [String: String] = [:]
        for (page, data) in drawings {
            dict[String(page)] = data.base64EncodedString()
        }
        if let raw = try? JSONEncoder().encode(dict) {
            try? raw.write(to: url)
        }
    }
}
