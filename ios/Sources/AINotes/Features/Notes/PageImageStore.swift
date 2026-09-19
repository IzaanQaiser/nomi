import Foundation
import UIKit

/// Persists pasted images on notebook pages (separate from PencilKit ink).
enum PageImageStore {
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var fileName: String

        var frame: CGRect {
            get { CGRect(x: x, y: y, width: width, height: height) }
            set {
                x = newValue.origin.x
                y = newValue.origin.y
                width = newValue.size.width
                height = newValue.size.height
            }
        }
    }

    private static var baseDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pdf-notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func metaURL(key: String) -> URL {
        baseDir.appendingPathComponent("\(key).images.json")
    }

    private static func imagesDir(key: String) -> URL {
        let dir = baseDir.appendingPathComponent("\(key)-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(key: String) -> [Int: [Item]] {
        let url = metaURL(key: key)
        guard let raw = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [Item]].self, from: raw)
        else { return [:] }
        var result: [Int: [Item]] = [:]
        for (k, items) in dict {
            if let page = Int(k) { result[page] = items }
        }
        return result
    }

    static func save(_ pages: [Int: [Item]], key: String) {
        var dict: [String: [Item]] = [:]
        for (page, items) in pages {
            dict[String(page)] = items
        }
        let url = metaURL(key: key)
        if let raw = try? JSONEncoder().encode(dict) {
            try? raw.write(to: url, options: .atomic)
        }
    }

    static func imageURL(key: String, fileName: String) -> URL {
        imagesDir(key: key).appendingPathComponent(fileName)
    }

    static func saveImage(_ image: UIImage, key: String, fileName: String) {
        let url = imageURL(key: key, fileName: fileName)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadImage(key: String, fileName: String) -> UIImage? {
        let url = imageURL(key: key, fileName: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(key: String, fileName: String) {
        let url = imageURL(key: key, fileName: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll(key: String) {
        try? FileManager.default.removeItem(at: metaURL(key: key))
        let directory = imagesDir(key: key)
        try? FileManager.default.removeItem(at: directory)
    }
}
