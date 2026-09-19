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
            if isRetiredDevelopmentURL(url) {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            } else {
                return url
            }
        }

        if let bundled = Bundle.main.object(forInfoDictionaryKey: bundledKey) as? String,
           let url = normalizedURL(from: bundled) {
            return url
        }

        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:8000")
        #else
        return nil
        #endif
    }

    static var configuredURLString: String {
        if let saved = UserDefaults.standard.string(forKey: overrideKey),
           let url = normalizedURL(from: saved),
           !isRetiredDevelopmentURL(url) {
            return url.absoluteString
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

    private static func isRetiredDevelopmentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // Drop stale LAN / hotspot / temporary tunnel overrides so installs
        // use the shared Railway BackendBaseURL.
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        if host.hasSuffix(".trycloudflare.com") {
            return true
        }
        return host.hasPrefix("192.168.")
            || host.hasPrefix("172.20.")
            || host.hasPrefix("169.254.")
            || host.hasPrefix("10.")
    }
}
