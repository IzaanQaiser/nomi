from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class ProjectCreate(BaseModel):
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


class ShadowRequest(BaseModel):
    # Base64-encoded PNG/JPEG of the active canvas region.
    image_base64: str
    # What the student is working on (problem statement / context), optional.
    problem_context: str | None = None


class ShadowResponse(BaseModel):
    status: str  # "ok" | "interrupt"
    hint: str | None = None
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


class TalkResponse(BaseModel):
    reply: str
    problem: str | None = None
    grounding: str | None = None
