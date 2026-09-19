import Foundation

// Mirrors the FastAPI Pydantic schemas.

struct Project: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }
}

struct Source: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let kind: String
    let title: String
    let status: String
    let error: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, title, status, error
        case projectId = "project_id"
        case createdAt = "created_at"
    }
}

struct Note: Codable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let title: String
    let pageIndex: Int
    let strokesJSON: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case projectId = "project_id"
        case pageIndex = "page_index"
        case strokesJSON = "strokes_json"
        case updatedAt = "updated_at"
    }
}

struct Citation: Codable, Identifiable, Hashable {
    var id: String { chunkId }
    let sourceId: String
    let sourceTitle: String
    let chunkId: String
    let snippet: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case snippet, score
        case sourceId = "source_id"
        case sourceTitle = "source_title"
        case chunkId = "chunk_id"
    }
}

struct ChatResponse: Codable, Hashable {
    let answer: String
    let citations: [Citation]
}

struct ShadowResponse: Codable, Hashable {
    let status: String
    let hint: String?
    let reasoning: String?
    let problem: String?
    let grounding: String?
}

struct InferProblemResponse: Codable, Hashable {
    let problem: String
}

struct TalkResponse: Codable, Hashable {
    let reply: String
    let problem: String?
    let grounding: String?
}
