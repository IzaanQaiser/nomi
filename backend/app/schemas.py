from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ProjectCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ProjectUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ProjectOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    name: str
    created_at: datetime


class SourceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    project_id: str
    kind: str
    title: str
    status: str
    error: str | None = None
    created_at: datetime


class TextSourceCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    content: str = Field(min_length=1)


class NoteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    project_id: str
    title: str
    page_index: int
    strokes_json: str
    updated_at: datetime


class NoteUpsert(BaseModel):
    id: str | None = None
    title: str = "Untitled"
    page_index: int = 0
    strokes_json: str = ""


class Citation(BaseModel):
    source_id: str
    source_title: str
    chunk_id: str
    snippet: str
    score: float


class ChatRequest(BaseModel):
    question: str = Field(min_length=1)


class ChatResponse(BaseModel):
    answer: str
    citations: list[Citation]


class ClassroomHistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=4000)


class ClassroomRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2000)
    history: list[ClassroomHistoryMessage] = []
    # Optional handoff from live tutoring later (stuck problem, page notes, etc.).
    prompt_context: str | None = Field(default=None, max_length=4000)


class ClassroomSuggestionsResponse(BaseModel):
    suggestions: list[str]


class ClassroomPrepareRequest(BaseModel):
    topic: str = Field(min_length=1, max_length=2000)
    prompt_context: str | None = Field(default=None, max_length=4000)


class ClassroomBoardCue(BaseModel):
    kind: Literal["diagram", "equation", "list", "none"] = "none"
    instruction: str = ""


class ClassroomLessonBeat(BaseModel):
    index: int
    title: str
    speaking: str
    board: ClassroomBoardCue = ClassroomBoardCue()


class ClassroomLessonSource(BaseModel):
    source_id: str
    source_title: str
    kind: str = "text"


class ClassroomPassage(BaseModel):
    source_id: str
    source_title: str
    chunk_id: str
    content: str
    score: float


class ClassroomLessonOut(BaseModel):
    in_scope: bool
    topic: str
    title: str = ""
    reason: str | None = None
    summary: str = ""
    beats: list[ClassroomLessonBeat] = []
    sources: list[ClassroomLessonSource] = []
    citations: list[Citation] = []
    passages: list[ClassroomPassage] = []
    grounding: str = "empty"


class ShadowRequest(BaseModel):
    # Base64-encoded PNG/JPEG of the active canvas region.
    image_base64: str
    # What the student is working on (problem statement / context), optional.
    problem_context: str | None = None
    # Short text-only memory of recent watch/talk turns on this page.
    # Cheap: no prior images. Caps are enforced server-side.
    recent_context: list[str] = []


class ShadowResponse(BaseModel):
    status: str  # "ok" | "interrupt"
    hint: str | None = None
    # Optional short celebration when they fixed a previously called-out mistake.
    note: str | None = None
    reasoning: str | None = None
    # Problem statement used for retrieval (inferred off the page if omitted).
    problem: str | None = None
    # How sources were injected: "full" | "retrieval" | "empty".
    grounding: str | None = None


class InferProblemRequest(BaseModel):
    # Base64-encoded PNG/JPEG of the current page.
    image_base64: str


class InferProblemResponse(BaseModel):
    problem: str


class TalkRequest(BaseModel):
    image_base64: str
    # What the student said. Empty string means they opened the mic and went
    # silent — the tutor should cut in.
    utterance: str = ""
    problem_context: str | None = None
    recent_context: list[str] = []


class TalkResponse(BaseModel):
    reply: str
    problem: str | None = None
    grounding: str | None = None


class SolutionRequest(BaseModel):
    image_base64: str
    problem_context: str | None = None
    recent_context: list[str] = []
    # The repeated nudge the student kept hitting (helps the model target the reveal).
    mistake_summary: str | None = None


class SolutionResponse(BaseModel):
    solution: str
    problem: str | None = None
    grounding: str | None = None


# ---- Exam prep ---------------------------------------------------------------

class ExamQuestion(BaseModel):
    number: str            # "1", "2a", ...
    prompt: str
    marks: int
    # Suggested blank writing lines to leave under the question on the PDF.
    answer_lines: int = 6


class ExamSection(BaseModel):
    title: str
    instructions: str | None = None
    questions: list[ExamQuestion]


class ExamOut(BaseModel):
    title: str
    duration_minutes: int
    total_marks: int
    instructions: str | None = None
    sections: list[ExamSection]


class GradedQuestion(BaseModel):
    number: str
    awarded: int
    marks: int
    feedback: str
    # The right answer (short questions) or the gist of the correct approach and
    # where the student went wrong (long questions).
    correct_answer: str = ""


class ExamGradeRequest(BaseModel):
    # The exam that was sat, plus one base64 page image per filled notebook page.
    exam: ExamOut
    page_images_base64: list[str] = []


class ExamGradeResponse(BaseModel):
    awarded: int
    total: int
    summary: str
    questions: list[GradedQuestion]
