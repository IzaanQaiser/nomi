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

/// Normalized board coordinate. `(0, 0)` is top-left and `(1, 1)` is bottom-right.
struct ClassroomBoardPoint: Codable, Hashable {
    let x: Double
    let y: Double
}

struct ClassroomBoardFrame: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ClassroomWriteTextAction: Codable, Hashable {
    let id: String
    let type: String
    let text: String
    let position: ClassroomBoardPoint
    let style: String
}

struct ClassroomDrawLineAction: Codable, Hashable {
    let id: String
    let type: String
    let start: ClassroomBoardPoint
    let end: ClassroomBoardPoint
    let style: String
}

struct ClassroomDrawArrowAction: Codable, Hashable {
    let id: String
    let type: String
    let start: ClassroomBoardPoint
    let end: ClassroomBoardPoint
}

struct ClassroomDrawRectangleAction: Codable, Hashable {
    let id: String
    let type: String
    let frame: ClassroomBoardFrame
    let style: String
}

struct ClassroomDrawAxesAction: Codable, Hashable {
    let id: String
    let type: String
    let frame: ClassroomBoardFrame
    let xLabel: String
    let yLabel: String

    enum CodingKeys: String, CodingKey {
        case id, type, frame
        case xLabel = "x_label"
        case yLabel = "y_label"
    }
}

struct ClassroomPlotPolylineAction: Codable, Hashable {
    let id: String
    let type: String
    let points: [ClassroomBoardPoint]
    let style: String
}

struct ClassroomHighlightAction: Codable, Hashable {
    let id: String
    let type: String
    let frame: ClassroomBoardFrame
}

struct ClassroomClearBoardAction: Codable, Hashable {
    let id: String
    let type: String
}

/// Closed board protocol understood by this app version. Unknown future
/// operations remain decodable but are ignored by the renderer.
enum ClassroomBoardAction: Codable, Hashable, Identifiable {
    case writeText(ClassroomWriteTextAction)
    case drawLine(ClassroomDrawLineAction)
    case drawArrow(ClassroomDrawArrowAction)
    case drawRectangle(ClassroomDrawRectangleAction)
    case drawAxes(ClassroomDrawAxesAction)
    case plotPolyline(ClassroomPlotPolylineAction)
    case highlight(ClassroomHighlightAction)
    case clear(ClassroomClearBoardAction)
    case unsupported(id: String, type: String)

    private enum CodingKeys: String, CodingKey { case id, type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "write_text": self = .writeText(try ClassroomWriteTextAction(from: decoder))
        case "draw_line": self = .drawLine(try ClassroomDrawLineAction(from: decoder))
        case "draw_arrow": self = .drawArrow(try ClassroomDrawArrowAction(from: decoder))
        case "draw_rectangle": self = .drawRectangle(try ClassroomDrawRectangleAction(from: decoder))
        case "draw_axes": self = .drawAxes(try ClassroomDrawAxesAction(from: decoder))
        case "plot_polyline": self = .plotPolyline(try ClassroomPlotPolylineAction(from: decoder))
        case "highlight": self = .highlight(try ClassroomHighlightAction(from: decoder))
        case "clear": self = .clear(try ClassroomClearBoardAction(from: decoder))
        default:
            self = .unsupported(
                id: try container.decodeIfPresent(String.self, forKey: .id) ?? "unsupported-\(type)",
                type: type
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .writeText(action): try action.encode(to: encoder)
        case let .drawLine(action): try action.encode(to: encoder)
        case let .drawArrow(action): try action.encode(to: encoder)
        case let .drawRectangle(action): try action.encode(to: encoder)
        case let .drawAxes(action): try action.encode(to: encoder)
        case let .plotPolyline(action): try action.encode(to: encoder)
        case let .highlight(action): try action.encode(to: encoder)
        case let .clear(action): try action.encode(to: encoder)
        case let .unsupported(id, type):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
        }
    }

    var id: String {
        switch self {
        case let .writeText(action): action.id
        case let .drawLine(action): action.id
        case let .drawArrow(action): action.id
        case let .drawRectangle(action): action.id
        case let .drawAxes(action): action.id
        case let .plotPolyline(action): action.id
        case let .highlight(action): action.id
        case let .clear(action): action.id
        case let .unsupported(id, _): id
        }
    }

    var isClear: Bool {
        if case .clear = self { return true }
        return false
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var previewDescription: String {
        switch self {
        case let .writeText(action): action.text
        case .drawLine: "Draw a line"
        case .drawArrow: "Connect the ideas"
        case .drawRectangle: "Draw a block"
        case let .drawAxes(action):
            [action.xLabel, action.yLabel].filter { !$0.isEmpty }.joined(separator: " / ")
        case .plotPolyline: "Plot the relationship"
        case .highlight: "Highlight this region"
        case .clear: "Clear the board"
        case .unsupported: ""
        }
    }
}

struct ClassroomBoardCue: Codable, Hashable {
    let kind: String
    let instruction: String
    let actions: [ClassroomBoardAction]

    enum CodingKeys: String, CodingKey {
        case kind, instruction, actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        instruction = try container.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        actions = try container.decodeIfPresent([ClassroomBoardAction].self, forKey: .actions) ?? []
    }
}

struct ClassroomLessonBeat: Codable, Hashable, Identifiable {
    var id: Int { index }
    let index: Int
    let title: String
    let speaking: String
    let board: ClassroomBoardCue
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
    let boardProtocolVersion: Int
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
        case boardProtocolVersion = "board_protocol_version"
        case inScope = "in_scope"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boardProtocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .boardProtocolVersion
        ) ?? 0
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
