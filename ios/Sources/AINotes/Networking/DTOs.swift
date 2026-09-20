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

/// Optional entry point into classroom. Live tutoring can later fill `topic`
/// and `promptContext` without changing the classroom screen itself.
struct ClassroomSeed: Hashable {
    var topic: String? = nil
    var promptContext: String? = nil
}

struct ClassroomHistoryMessage: Codable, Hashable {
    let role: String
    let content: String
}

struct ClassroomSuggestionsResponse: Codable, Hashable {
    let suggestions: [String]
}

enum ClassroomSlideLayout: String, Codable, Hashable {
    case title
    case concept
    case equation
    case bullets
    case steps
    case diagram
    case checkpoint
}

struct ClassroomSlide: Codable, Hashable {
    let layout: ClassroomSlideLayout
    let title: String
    let subtitle: String
    let body: String
    let bullets: [String]
    let equation: String
    let caption: String
    let callout: String
    let steps: [String]
    let mermaid: String
    let question: String

    enum CodingKeys: String, CodingKey {
        case layout, title, subtitle, body, bullets, equation, caption, callout, steps, mermaid, question
    }

    init(
        layout: ClassroomSlideLayout,
        title: String = "",
        subtitle: String = "",
        body: String = "",
        bullets: [String] = [],
        equation: String = "",
        caption: String = "",
        callout: String = "",
        steps: [String] = [],
        mermaid: String = "",
        question: String = ""
    ) {
        self.layout = layout
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.bullets = bullets
        self.equation = equation
        self.caption = caption
        self.callout = callout
        self.steps = steps
        self.mermaid = mermaid
        self.question = question
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawLayout = try container.decodeIfPresent(String.self, forKey: .layout) ?? "concept"
        let parsed = ClassroomSlideLayout(rawValue: rawLayout) ?? .concept
        layout = parsed == .diagram ? .bullets : parsed
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        bullets = try container.decodeIfPresent([String].self, forKey: .bullets) ?? []
        equation = try container.decodeIfPresent(String.self, forKey: .equation) ?? ""
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        callout = try container.decodeIfPresent(String.self, forKey: .callout) ?? ""
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        mermaid = try container.decodeIfPresent(String.self, forKey: .mermaid) ?? ""
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
    }
}

struct ClassroomLessonBeat: Codable, Hashable, Identifiable {
    var id: Int { index }
    let index: Int
    let title: String
    let speaking: String
    let slide: ClassroomSlide
}

struct ClassroomLessonSource: Codable, Hashable, Identifiable {
    var id: String { sourceId }
    let sourceId: String
    let sourceTitle: String
    let kind: String

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceId = "source_id"
        case sourceTitle = "source_title"
    }
}

struct ClassroomPassage: Codable, Hashable, Identifiable {
    var id: String { chunkId }
    let sourceId: String
    let sourceTitle: String
    let chunkId: String
    let content: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case content, score
        case sourceId = "source_id"
        case sourceTitle = "source_title"
        case chunkId = "chunk_id"
    }
}

struct ClassroomLesson: Codable, Hashable {
    let lessonProtocolVersion: Int
    let inScope: Bool
    let topic: String
    let title: String
    let reason: String?
    let summary: String
    let beats: [ClassroomLessonBeat]
    let sources: [ClassroomLessonSource]
    let citations: [Citation]
    let passages: [ClassroomPassage]
    let grounding: String

    enum CodingKeys: String, CodingKey {
        case topic, title, reason, summary, beats, sources, citations, passages, grounding
        case lessonProtocolVersion = "lesson_protocol_version"
        case inScope = "in_scope"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lessonProtocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .lessonProtocolVersion
        ) ?? 1
        inScope = try container.decode(Bool.self, forKey: .inScope)
        topic = try container.decode(String.self, forKey: .topic)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        summary = try container.decode(String.self, forKey: .summary)
        beats = try container.decode([ClassroomLessonBeat].self, forKey: .beats)
        sources = try container.decode([ClassroomLessonSource].self, forKey: .sources)
        citations = try container.decode([Citation].self, forKey: .citations)
        passages = try container.decode([ClassroomPassage].self, forKey: .passages)
        grounding = try container.decode(String.self, forKey: .grounding)
    }
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

// MARK: - Exam prep

struct GeneratedExam: Codable, Equatable {
    let title: String
    let durationMinutes: Int
    let totalMarks: Int
    let instructions: String?
    let sections: [ExamSection]

    enum CodingKeys: String, CodingKey {
        case title, instructions, sections
        case durationMinutes = "duration_minutes"
        case totalMarks = "total_marks"
    }
}

struct ExamSection: Codable, Equatable {
    let title: String
    let instructions: String?
    let questions: [ExamQuestion]
}

struct ExamQuestion: Codable, Equatable {
    let number: String
    let prompt: String
    let marks: Int
    let answerLines: Int

    enum CodingKeys: String, CodingKey {
        case number, prompt, marks
        case answerLines = "answer_lines"
    }
}

struct ExamGrade: Codable, Equatable {
    let awarded: Int
    let total: Int
    let summary: String
    let questions: [GradedQuestion]
}

struct GradedQuestion: Codable, Equatable {
    let number: String
    let awarded: Int
    let marks: Int
    let feedback: String
    let correctAnswer: String?

    enum CodingKeys: String, CodingKey {
        case number, awarded, marks, feedback
        case correctAnswer = "correct_answer"
    }
}
