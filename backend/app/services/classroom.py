from __future__ import annotations

import json
import re

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import (
    ChatResponse,
    Citation,
    ClassroomBoardCue,
    ClassroomHistoryMessage,
    ClassroomLessonBeat,
    ClassroomLessonOut,
    ClassroomLessonSource,
    ClassroomPassage,
)
from .llm import get_provider
from .retrieval import RetrievedContext, gather_context

_TEACH_SYSTEM = (
    "You are Nomi teaching inside a student's project classroom. Use only the "
    "provided course context. Explain the requested idea clearly and build "
    "intuition before details. Keep the lesson focused: a few short paragraphs "
    "or steps, one concrete example when the sources support it, and finish with "
    "one brief check-for-understanding question. Do not claim facts that are not "
    "in the sources. If the material is absent, say so plainly."
)

_PREPARE_SYSTEM = (
    "Prepare a classroom lesson plan from the student's course sources only. "
    "Decide if the requested topic is actually covered by those sources. "
    "If it is not, in_scope must be false, beats must be empty, and reason "
    "should be one short sentence. If it is, produce 4 to 6 teaching beats "
    "a later step can play, pause, rewind, and draw. Do not invent facts. "
    "Respond with STRICT JSON only, no prose and no code fences, matching:\n"
    '{"in_scope": bool, "topic": str, "title": str, "reason": str|null, '
    '"summary": str, "beats": [{"title": str, "speaking": str, '
    '"board": {"kind": "diagram"|"equation"|"list"|"none", "instruction": str}}]}'
)

_SUGGEST_SYSTEM = (
    "Identify three useful, distinct concepts a student could learn from the "
    "provided course material. Return only a JSON array of exactly three short "
    "topic names, each two to five words. Do not include numbering or commentary."
)

_BOARD_KINDS = {"diagram", "equation", "list", "none"}
_MAX_BEATS = 6
_MAX_PASSAGE_CHARS = 1600
_MAX_PASSAGES_CHARS = 16_000

_JSON_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)
_GENERIC_HEADINGS = {
    "contents",
    "table of contents",
    "acknowledgments",
    "references",
    "notation",
    "introduction",
}


def _citations(ctx: RetrievedContext, top_k: int) -> list[Citation]:
    cited = ctx.hits if ctx.mode == "retrieval" else ctx.hits[:top_k]
    return [
        Citation(
            source_id=hit.source.id,
            source_title=hit.source.title,
            chunk_id=hit.chunk.id,
            snippet=hit.chunk.content[:240],
            score=round(hit.score, 4),
        )
        for hit in cited
    ]


def _history_text(history: list[ClassroomHistoryMessage]) -> str:
    lines: list[str] = []
    total = 0
    for message in history[-10:]:
        content = " ".join(message.content.split())[:1200]
        if not content or total + len(content) > 6000:
            continue
        label = "Student" if message.role == "user" else "Nomi"
        lines.append(f"{label}: {content}")
        total += len(content)
    return "\n".join(lines)


def teach(
    db: Session,
    project_id: str,
    question: str,
    history: list[ClassroomHistoryMessage] | None = None,
    prompt_context: str | None = None,
) -> ChatResponse:
    settings = get_settings()
    provider = get_provider()
    ctx = gather_context(db, project_id, question, provider, settings.top_k)

    if not ctx.blocks:
        return ChatResponse(
            answer=(
                "I don’t have project material for that yet. Add a relevant "
                "source to this project, then I can teach it from your course."
            ),
            citations=[],
        )

    recent = _history_text(history or [])
    extra = " ".join((prompt_context or "").split())[:4000]
    context = "\n\n---\n\n".join(ctx.blocks)
    user = (
        f"What the student wants to learn: {question}\n\n"
        f"Recent classroom conversation:\n{recent or '(new lesson)'}\n\n"
    )
    if extra:
        user += f"Extra context from tutoring:\n{extra}\n\n"
    user += (
        "Teach from the course context below.\n"
        f"<<<CONTEXT>>>\n{context}\n<<<END>>>"
    )
    answer = provider.chat(_TEACH_SYSTEM, user).strip()
    return ChatResponse(answer=answer, citations=_citations(ctx, settings.top_k))


def _extract_json(raw: str) -> dict:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if "\n" in text:
            text = text.split("\n", 1)[1]
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in model output")
    return json.loads(text[start : end + 1])


def _passages(ctx: RetrievedContext) -> list[ClassroomPassage]:
    passages: list[ClassroomPassage] = []
    total = 0
    hits = ctx.hits if ctx.mode == "retrieval" else ctx.hits[:8]
    for hit in hits:
        content = hit.chunk.content.strip()
        if not content:
            continue
        clipped = content[:_MAX_PASSAGE_CHARS]
        if total + len(clipped) > _MAX_PASSAGES_CHARS:
            break
        passages.append(
            ClassroomPassage(
                source_id=hit.source.id,
                source_title=hit.source.title,
                chunk_id=hit.chunk.id,
                content=clipped,
                score=round(hit.score, 4),
            )
        )
        total += len(clipped)
    return passages


def _sources_from_context(ctx: RetrievedContext) -> list[ClassroomLessonSource]:
    seen: set[str] = set()
    sources: list[ClassroomLessonSource] = []
    for hit in ctx.hits:
        if hit.source.id in seen:
            continue
        seen.add(hit.source.id)
        sources.append(
            ClassroomLessonSource(
                source_id=hit.source.id,
                source_title=hit.source.title,
                kind=hit.source.kind,
            )
        )
    return sources


def _out_of_scope(
    topic: str,
    reason: str,
    ctx: RetrievedContext | None = None,
) -> ClassroomLessonOut:
    return ClassroomLessonOut(
        in_scope=False,
        topic=topic,
        title="",
        reason=reason,
        summary="",
        beats=[],
        sources=_sources_from_context(ctx) if ctx else [],
        citations=_citations(ctx, 3) if ctx and ctx.hits else [],
        passages=_passages(ctx) if ctx else [],
        grounding=ctx.mode if ctx else "empty",
    )


def _clean_title(value: str, fallback: str) -> str:
    title = " ".join((value or "").split()).strip(" -•.:")[:60]
    return title or fallback


def _normalize_beats(raw_beats: object) -> list[ClassroomLessonBeat]:
    if not isinstance(raw_beats, list):
        return []
    beats: list[ClassroomLessonBeat] = []
    for item in raw_beats:
        if not isinstance(item, dict):
            continue
        title = " ".join(str(item.get("title") or "").split())[:80]
        speaking = " ".join(str(item.get("speaking") or "").split())[:800]
        if not title or not speaking:
            continue
        board_raw = item.get("board") if isinstance(item.get("board"), dict) else {}
        kind = str(board_raw.get("kind") or "none").strip().lower()
        if kind not in _BOARD_KINDS:
            kind = "none"
        instruction = " ".join(str(board_raw.get("instruction") or "").split())[:400]
        beats.append(
            ClassroomLessonBeat(
                index=len(beats),
                title=title,
                speaking=speaking,
                board=ClassroomBoardCue(kind=kind, instruction=instruction),
            )
        )
        if len(beats) == _MAX_BEATS:
            break
    return beats


def prepare_lesson(
    db: Session,
    project_id: str,
    topic: str,
    prompt_context: str | None = None,
) -> ClassroomLessonOut:
    """Ground a topic and return a playable lesson plan, or say it is out of scope."""
    settings = get_settings()
    provider = get_provider()
    cleaned = " ".join((topic or "").split())[:2000]
    ctx = gather_context(db, project_id, cleaned, provider, settings.top_k)

    if not ctx.blocks:
        return _out_of_scope(
            cleaned,
            "I don’t have project material for that yet. Add a relevant source "
            "to this project, then I can teach it from your course.",
        )

    extra = " ".join((prompt_context or "").split())[:4000]
    context = "\n\n---\n\n".join(ctx.blocks)[:20_000]
    user = f"Topic: {cleaned}\n\n"
    if extra:
        user += f"Extra context from tutoring:\n{extra}\n\n"
    user += f"<<<CONTEXT>>>\n{context}\n<<<END>>>"

    try:
        data = _extract_json(provider.chat(_PREPARE_SYSTEM, user))
    except (ValueError, json.JSONDecodeError):
        return _out_of_scope(
            cleaned,
            "I couldn't prepare that lesson. Try a more specific topic from your sources.",
            ctx,
        )

    in_scope = bool(data.get("in_scope"))
    reason = data.get("reason")
    reason_text = " ".join(str(reason).split())[:240] if reason else None
    beats = _normalize_beats(data.get("beats")) if in_scope else []
    if not in_scope or not beats:
        return _out_of_scope(
            cleaned,
            reason_text
            or "That isn’t covered in this project’s sources. Pick a topic from the course.",
            ctx,
        )

    title = _clean_title(str(data.get("title") or ""), cleaned)
    summary = " ".join(str(data.get("summary") or "").split())[:400]
    return ClassroomLessonOut(
        in_scope=True,
        topic=_clean_title(str(data.get("topic") or cleaned), cleaned),
        title=title,
        reason=None,
        summary=summary,
        beats=beats,
        sources=_sources_from_context(ctx),
        citations=_citations(ctx, settings.top_k),
        passages=_passages(ctx),
        grounding=ctx.mode,
    )


def _parse_suggestions(raw: str) -> list[str]:
    text = _JSON_FENCE_RE.sub("", (raw or "").strip()).strip()
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = None
    if not isinstance(value, list):
        return []

    topics: list[str] = []
    for item in value:
        if not isinstance(item, str):
            continue
        topic = " ".join(item.split()).strip(" -•.:")[:60]
        if topic and topic.lower() not in {existing.lower() for existing in topics}:
            topics.append(topic)
        if len(topics) == 3:
            break
    return topics if len(topics) == 3 else []


def _fallback_topics(ctx: RetrievedContext) -> list[str]:
    topics: list[str] = []
    for hit in ctx.hits:
        for raw_line in hit.chunk.content.splitlines()[:12]:
            line = " ".join(raw_line.split()).strip(" -•.:")
            words = line.split()
            if not 2 <= len(words) <= 7 or len(line) > 60:
                continue
            lowered = line.lower()
            if lowered in _GENERIC_HEADINGS or lowered.startswith("chapter "):
                continue
            if lowered not in {topic.lower() for topic in topics}:
                topics.append(line)
            if len(topics) == 3:
                return topics

    for hit in ctx.hits:
        title = re.sub(r"\.(pdf|docx|png)$", "", hit.source.title, flags=re.IGNORECASE)
        title = " ".join(title.replace("_", " ").split())[:60]
        if title and title.lower() not in {topic.lower() for topic in topics}:
            topics.append(title)
        if len(topics) == 3:
            break
    return topics


def suggest_topics(db: Session, project_id: str, project_name: str) -> list[str]:
    settings = get_settings()
    provider = get_provider()
    ctx = gather_context(
        db,
        project_id,
        f"{project_name} central concepts and topics",
        provider,
        settings.top_k,
    )
    if not ctx.blocks:
        return []

    context = "\n\n---\n\n".join(ctx.blocks)[:20_000]
    raw = provider.chat(
        _SUGGEST_SYSTEM,
        f"Course: {project_name}\n\n<<<CONTEXT>>>\n{context}\n<<<END>>>",
    )
    return _parse_suggestions(raw) or _fallback_topics(ctx)
