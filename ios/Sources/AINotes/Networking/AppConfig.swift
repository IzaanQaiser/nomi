import Foundation

enum AppConfigError: LocalizedError {
    case invalidBackendURL

    var errorDescription: String? {
        "Enter a complete backend URL, such as https://api.example.com."
    }
}

enum AppConfig {
    private static let overrideKey = "backendBaseURLOverride"
    private static let bundledKey = "BackendBaseURL"

    /// Runtime overrides make development server changes possible without a
    /// rebuild. Info.plist BackendBaseURL is the default for device installs.
    static var baseURL: URL? {
        if let saved = UserDefaults.standard.string(forKey: overrideKey),
           let url = normalizedURL(from: saved) {
            return url
        }

        if let bundled = Bundle.main.object(forInfoDictionaryKey: bundledKey) as? String,
           let url = normalizedURL(from: bundled) {
            return url
        }

        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:8000")
        #else
        return URL(string: "http://172.20.10.2:8000")
        #endif
    }

    static var configuredURLString: String {
        if let saved = UserDefaults.standard.string(forKey: overrideKey), !saved.isEmpty {
            return saved
        }
        return (Bundle.main.object(forInfoDictionaryKey: bundledKey) as? String) ?? ""
    }

    static func saveBackendURL(_ value: String) throws {
        guard let url = normalizedURL(from: value) else {
            throw AppConfigError.invalidBackendURL
        }
        UserDefaults.standard.set(url.absoluteString, forKey: overrideKey)
    }

    private static func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }
}
