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
    let note: String?
    let reasoning: String?
    let problem: String?
    let grounding: String?

    enum CodingKeys: String, CodingKey {
        case status, hint, note, reasoning, problem, grounding
    }

    init(
        status: String,
        hint: String?,
        note: String? = nil,
        reasoning: String?,
        problem: String?,
        grounding: String?
    ) {
        self.status = status
        self.hint = hint
        self.note = note
        self.reasoning = reasoning
        self.problem = problem
        self.grounding = grounding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        grounding = try c.decodeIfPresent(String.self, forKey: .grounding)
    }
}

struct InferProblemResponse: Codable, Hashable {
    let problem: String
}

struct TalkResponse: Codable, Hashable {
    let reply: String
    let problem: String?
    let grounding: String?
}

struct SolutionResponse: Codable, Hashable {
    let solution: String
    let problem: String?
    let grounding: String?
}
