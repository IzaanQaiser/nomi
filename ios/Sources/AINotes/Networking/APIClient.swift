import Foundation
import OSLog

enum APIError: LocalizedError {
    case backendNotConfigured
    case badStatus(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "No backend URL is configured. Open Backend Settings and enter your HTTPS API URL."
        case let .badStatus(code, body):
            if body.contains("trycloudflare.com") || body.contains("Bad Gateway") || body.lowercased().contains("<html") {
                return "Server error \(code): Cloudflare tunnel couldn't reach the Mac backend. Make sure uvicorn and cloudflared are both running."
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Server error \(code): \(trimmed.prefix(180))"
        case let .decoding(msg): return "Decoding failed: \(msg)"
        }
    }
}

/// Thin async wrapper over the FastAPI backend.
actor APIClient {
    static let shared = APIClient()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AINotes",
        category: "Backend"
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12   // fail fast instead of hanging
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Chat / shadowing / embeddings can take a while (vision + retrieval).
    private let llmSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }

    // MARK: Projects

    func listProjects() async throws -> [Project] {
        try await get("/projects")
    }

    func getProject(id: String) async throws -> Project {
        try await get("/projects/\(id)")
    }

    func createProject(name: String) async throws -> Project {
        try await post("/projects", body: ["name": name])
    }

    func updateProject(id: String, name: String) async throws -> Project {
        var req = try request(path: "/projects/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        return try decode(try await send(req))
    }

    func deleteProject(id: String) async throws {
        _ = try await send(try request(path: "/projects/\(id)", method: "DELETE"))
    }

    // MARK: Sources

    func listSources(projectId: String) async throws -> [Source] {
        try await get("/projects/\(projectId)/sources")
    }

    func addTextSource(projectId: String, title: String, content: String) async throws -> Source {
        try await post(
            "/projects/\(projectId)/sources/text",
            body: ["title": title, "content": content]
        )
    }

    func uploadPDF(projectId: String, fileURL: URL) async throws -> Source {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = try request(path: "/projects/\(projectId)/sources/pdf", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: application/pdf\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let data = try await send(req, session: llmSession)
        return try decode(data)
    }

    func deleteSource(projectId: String, sourceId: String) async throws {
        _ = try await send(
            try request(path: "/projects/\(projectId)/sources/\(sourceId)", method: "DELETE")
        )
    }

    func downloadSourcePDF(projectId: String, sourceId: String) async throws -> Data {
        try await send(
            try request(path: "/projects/\(projectId)/sources/\(sourceId)/file", method: "GET"),
            session: llmSession
        )
    }

    // MARK: Notes

    func listNotes(projectId: String) async throws -> [Note] {
        try await get("/projects/\(projectId)/notes")
    }

    func saveNote(projectId: String, id: String?, title: String, pageIndex: Int, strokesJSON: String) async throws -> Note {
        var body: [String: Any] = [
            "title": title,
            "page_index": pageIndex,
            "strokes_json": strokesJSON,
        ]
        if let id { body["id"] = id }
        var req = try request(path: "/projects/\(projectId)/notes", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try decode(try await send(req))
    }

    // MARK: Chat / Shadow

    func chat(projectId: String, question: String) async throws -> ChatResponse {
        try await post("/projects/\(projectId)/chat", body: ["question": question], session: llmSession)
    }

    func shadow(
        projectId: String,
        imageBase64: String,
        problemContext: String?,
        recentContext: [String] = []
    ) async throws -> ShadowResponse {
        var body: [String: Any] = ["image_base64": imageBase64]
        if let problemContext { body["problem_context"] = problemContext }
        if !recentContext.isEmpty { body["recent_context"] = recentContext }
        return try await post("/projects/\(projectId)/shadow", body: body, session: llmSession)
    }

    /// One-shot: read the problem statement off the current page (used to ground
    /// later shadowing analysis in the project's sources).
    func inferProblem(projectId: String, imageBase64: String) async throws -> InferProblemResponse {
        try await post("/projects/\(projectId)/shadow/infer-problem", body: ["image_base64": imageBase64], session: llmSession)
    }

    func checkHealth() async throws -> String {
        let health: HealthResponse = try await get("/health")
        return "Connected (\(health.provider))"
    }

    func talk(
        projectId: String,
        imageBase64: String,
        utterance: String,
        problemContext: String?,
        recentContext: [String] = []
    ) async throws -> TalkResponse {
        var body: [String: Any] = [
            "image_base64": imageBase64,
            "utterance": utterance,
        ]
        if let problemContext { body["problem_context"] = problemContext }
        if !recentContext.isEmpty { body["recent_context"] = recentContext }
        return try await post("/projects/\(projectId)/shadow/talk", body: body, session: llmSession)
    }

    func revealSolution(
        projectId: String,
        imageBase64: String,
        problemContext: String?,
        recentContext: [String] = [],
        mistakeSummary: String?
    ) async throws -> SolutionResponse {
        var body: [String: Any] = ["image_base64": imageBase64]
        if let problemContext { body["problem_context"] = problemContext }
        if !recentContext.isEmpty { body["recent_context"] = recentContext }
        if let mistakeSummary { body["mistake_summary"] = mistakeSummary }
        return try await post("/projects/\(projectId)/shadow/solution", body: body, session: llmSession)
    }

    // MARK: Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try decode(try await send(try request(path: path, method: "GET")))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], session: URLSession? = nil) async throws -> T {
        var req = try request(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try decode(try await send(req, session: session ?? self.session))
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let baseURL = AppConfig.baseURL else {
            throw APIError.backendNotConfigured
        }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        return req
    }

    private func send(_ req: URLRequest, session: URLSession? = nil) async throws -> Data {
        let method = req.httpMethod ?? "REQUEST"
        let url = req.url?.absoluteString ?? "<missing URL>"
        logger.info("\(method, privacy: .public) \(url, privacy: .public)")

        do {
            let (data, response) = try await (session ?? self.session).data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.badStatus(-1, "No HTTP response")
            }
            logger.info("\(method, privacy: .public) \(url, privacy: .public) -> \(http.statusCode)")
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch {
            logger.error("\(method, privacy: .public) \(url, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

private struct EmptyResponse: Decodable {}

private struct HealthResponse: Decodable {
    let status: String
    let provider: String
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// The backend emits ISO-8601 timestamps, sometimes with fractional seconds
    /// and sometimes without a timezone; parse leniently.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss",
            ]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            for fmt in formats {
                formatter.dateFormat = fmt
                if let date = formatter.date(from: string) { return date }
            }
            return Date()
        }
    }
}
