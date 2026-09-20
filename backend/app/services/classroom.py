from __future__ import annotations

import json
import math
import re

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import (
    ChatResponse,
    Citation,
    ClassroomBoardCue,
    ClassroomBoardFrame,
    ClassroomBoardPoint,
    ClassroomClearBoardAction,
    ClassroomDrawArrowAction,
    ClassroomDrawAxesAction,
    ClassroomDrawLineAction,
    ClassroomDrawRectangleAction,
    ClassroomHighlightAction,
    ClassroomHistoryMessage,
    ClassroomLessonBeat,
    ClassroomLessonOut,
    ClassroomLessonSource,
    ClassroomPassage,
    ClassroomPlotPolylineAction,
    ClassroomWriteTextAction,
)
from .llm import get_provider
from .llm.base import LLMProvider
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
    "Each board action uses normalized coordinates from 0 to 1 with origin at "
    "the TOP-LEFT of the board. Actions run in array order and persist across "
    "beats until a clear action. Every action must include reveal_at, a number "
    "from 0 to 1 representing the fraction through that beat's speaking text "
    "when the action should appear. Put an action at the moment its idea is "
    "first introduced and keep reveal_at values nondecreasing in array order. "
    "Use only these exact action shapes: write_text "
    "{type,reveal_at,text,position:{x,y},style}; draw_line "
    "{type,reveal_at,start:{x,y},end:{x,y},style}; draw_arrow "
    "{type,reveal_at,start:{x,y},end:{x,y}}; draw_rectangle "
    "{type,reveal_at,frame:{x,y,width,height},style}; draw_axes "
    "{type,reveal_at,frame:{x,y,width,height},x_label,y_label}; plot_polyline "
    "{type,reveal_at,points:[{x,y}],style}; highlight "
    "{type,reveal_at,frame:{x,y,width,height}}; or clear {type,reveal_at}. "
    "write_text style must be heading, body, equation, label, or emphasis. "
    "Line and polyline style must be solid or dashed. Rectangle style must be "
    "outline or filled. Frame x/y is its top-left corner; width/height extend "
    "right and down and must remain inside the board. write_text position is "
    "the text's top-left anchor. "
    "Never include IDs; the server assigns them. "
    "Respond with STRICT JSON only, no prose and no code fences, matching:\n"
    '{"in_scope": bool, "topic": str, "title": str, "reason": str|null, '
    '"summary": str, "beats": [{"title": str, "speaking": str, '
    '"board": {"kind": "diagram"|"equation"|"list"|"none", "instruction": str, '
    '"actions": [object]}}]}'
)

_SUGGEST_SYSTEM = (
    "Identify three useful, distinct concepts a student could learn from the "
    "provided course material. Return only a JSON array of exactly three short "
    "topic names, each two to five words. Do not include numbering or commentary."
)

_BOARD_REPAIR_SYSTEM = (
    "You are repairing the executable whiteboard commands for an existing "
    "grounded lesson. Return a JSON object with one `beats` item for every "
    "requested beat index. Each item is {index: integer, actions: [object]}. "
    "Do not rewrite the lesson and do not return prose. Create the actual "
    "visuals described by the beat rather than writing an instruction to draw "
    "them. Use normalized coordinates from 0 to 1 with top-left origin. Every "
    "action needs reveal_at from 0 to 1, nondecreasing within that beat. Use "
    "only: write_text {type,reveal_at,text,position:{x,y},style}; draw_line "
    "{type,reveal_at,start:{x,y},end:{x,y},style}; draw_arrow "
    "{type,reveal_at,start:{x,y},end:{x,y}}; draw_rectangle "
    "{type,reveal_at,frame:{x,y,width,height},style}; draw_axes "
    "{type,reveal_at,frame:{x,y,width,height},x_label,y_label}; plot_polyline "
    "{type,reveal_at,points:[{x,y}],style}; highlight "
    "{type,reveal_at,frame:{x,y,width,height}}; clear {type,reveal_at}. "
    "Use heading/body/equation/label/emphasis text styles, solid/dashed line "
    "styles, and outline/filled rectangle styles. Never include action IDs."
)

_BOARD_KINDS = {"diagram", "equation", "list", "none"}
_MAX_BEATS = 6
_MAX_BOARD_ACTIONS_PER_BEAT = 12
_MAX_POLYLINE_POINTS = 24
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
    user += f"Teach from the course context below.\n<<<CONTEXT>>>\n{context}\n<<<END>>>"
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


def _coordinate(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    return min(1.0, max(0.0, number))


def _point(value: object) -> ClassroomBoardPoint | None:
    if not isinstance(value, dict):
        return None
    x, y = _coordinate(value.get("x")), _coordinate(value.get("y"))
    if x is None or y is None:
        return None
    return ClassroomBoardPoint(x=x, y=y)


def _frame(value: object) -> ClassroomBoardFrame | None:
    if not isinstance(value, dict):
        return None
    x, y = _coordinate(value.get("x")), _coordinate(value.get("y"))
    width, height = _coordinate(value.get("width")), _coordinate(value.get("height"))
    if x is None or y is None or width is None or height is None:
        return None
    width, height = min(width, 1.0 - x), min(height, 1.0 - y)
    if width <= 0.005 or height <= 0.005:
        return None
    return ClassroomBoardFrame(x=x, y=y, width=width, height=height)


def _short_text(value: object, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _normalize_board_actions(raw: object, beat_index: int) -> list:
    if not isinstance(raw, list):
        return []
    actions: list = []
    requested_reveals: list[float | None] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        action_type = str(item.get("type") or "").strip().lower()
        action_id = f"b{beat_index}-a{len(actions)}"
        previous_count = len(actions)

        if action_type == "write_text":
            text = _short_text(item.get("text"), 240)
            position = _point(item.get("position"))
            style = str(item.get("style") or "body").strip().lower()
            if style not in {"heading", "body", "equation", "label", "emphasis"}:
                style = "body"
            if text and position:
                actions.append(
                    ClassroomWriteTextAction(
                        id=action_id,
                        type="write_text",
                        reveal_at=0,
                        text=text,
                        position=position,
                        style=style,
                    )
                )
        elif action_type == "draw_line":
            start, end = _point(item.get("start")), _point(item.get("end"))
            style = str(item.get("style") or "solid").strip().lower()
            if style not in {"solid", "dashed"}:
                style = "solid"
            if start and end and start != end:
                actions.append(
                    ClassroomDrawLineAction(
                        id=action_id,
                        type="draw_line",
                        reveal_at=0,
                        start=start,
                        end=end,
                        style=style,
                    )
                )
        elif action_type == "draw_arrow":
            start, end = _point(item.get("start")), _point(item.get("end"))
            if start and end and start != end:
                actions.append(
                    ClassroomDrawArrowAction(
                        id=action_id,
                        type="draw_arrow",
                        reveal_at=0,
                        start=start,
                        end=end,
                    )
                )
        elif action_type == "draw_rectangle":
            frame = _frame(item.get("frame"))
            style = str(item.get("style") or "outline").strip().lower()
            if style not in {"outline", "filled"}:
                style = "outline"
            if frame:
                actions.append(
                    ClassroomDrawRectangleAction(
                        id=action_id,
                        type="draw_rectangle",
                        reveal_at=0,
                        frame=frame,
                        style=style,
                    )
                )
        elif action_type == "draw_axes":
            frame = _frame(item.get("frame"))
            if frame:
                actions.append(
                    ClassroomDrawAxesAction(
                        id=action_id,
                        type="draw_axes",
                        reveal_at=0,
                        frame=frame,
                        x_label=_short_text(item.get("x_label"), 32),
                        y_label=_short_text(item.get("y_label"), 32),
                    )
                )
        elif action_type == "plot_polyline":
            raw_points = (
                item.get("points") if isinstance(item.get("points"), list) else []
            )
            points = [
                point
                for value in raw_points[:_MAX_POLYLINE_POINTS]
                if (point := _point(value))
            ]
            style = str(item.get("style") or "solid").strip().lower()
            if style not in {"solid", "dashed"}:
                style = "solid"
            if len(points) >= 2:
                actions.append(
                    ClassroomPlotPolylineAction(
                        id=action_id,
                        type="plot_polyline",
                        reveal_at=0,
                        points=points,
                        style=style,
                    )
                )
        elif action_type == "highlight":
            frame = _frame(item.get("frame"))
            if frame:
                actions.append(
                    ClassroomHighlightAction(
                        id=action_id,
                        type="highlight",
                        reveal_at=0,
                        frame=frame,
                    )
                )
        elif action_type == "clear":
            actions.append(
                ClassroomClearBoardAction(
                    id=action_id,
                    type="clear",
                    reveal_at=0,
                )
            )

        if len(actions) > previous_count:
            requested_reveals.append(_coordinate(item.get("reveal_at")))

        if len(actions) == _MAX_BOARD_ACTIONS_PER_BEAT:
            break

    # Model timing is advisory. Missing timing gets a stable spread across the
    # narration and decreasing timing is raised to preserve command ordering.
    last_reveal = 0.0
    denominator = max(1, len(actions) - 1)
    for index, action in enumerate(actions):
        fallback = 0.08 + (0.84 * index / denominator)
        requested = requested_reveals[index]
        reveal_at = min(
            0.96, max(last_reveal, requested if requested is not None else fallback)
        )
        action.reveal_at = round(reveal_at, 3)
        last_reveal = reveal_at
    return actions


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
        beat_index = len(beats)
        actions = _normalize_board_actions(board_raw.get("actions"), beat_index)
        beats.append(
            ClassroomLessonBeat(
                index=beat_index,
                title=title,
                speaking=speaking,
                board=ClassroomBoardCue(
                    kind=kind,
                    instruction=instruction,
                    actions=actions,
                ),
            )
        )
        if len(beats) == _MAX_BEATS:
            break
    return beats


def _repair_missing_board_actions(
    provider: LLMProvider,
    beats: list[ClassroomLessonBeat],
    topic: str,
    context: str,
) -> tuple[list[ClassroomLessonBeat], bool]:
    """Fill missing executable board commands without rewriting lesson content."""
    total_actions = sum(len(beat.board.actions) for beat in beats)
    target_indices = {
        beat.index
        for beat in beats
        if not beat.board.actions
        and (total_actions == 0 or beat.board.kind != "none" or beat.board.instruction)
    }
    if not target_indices:
        return beats, True

    requested = [
        {
            "index": beat.index,
            "title": beat.title,
            "speaking": beat.speaking,
            "kind": beat.board.kind,
            "instruction": beat.board.instruction,
        }
        for beat in beats
        if beat.index in target_indices
    ]
    user = (
        f"Topic: {topic}\n\n"
        f"Beats requiring executable board actions:\n{json.dumps(requested)}\n\n"
        f"Course context:\n<<<CONTEXT>>>\n{context[:12_000]}\n<<<END>>>"
    )
    try:
        data = _extract_json(provider.chat(_BOARD_REPAIR_SYSTEM, user, json_mode=True))
    except (ValueError, json.JSONDecodeError):
        return beats, False

    raw_repairs = data.get("beats")
    if not isinstance(raw_repairs, list):
        return beats, False
    repairs = {
        item.get("index"): item.get("actions")
        for item in raw_repairs
        if isinstance(item, dict)
        and not isinstance(item.get("index"), bool)
        and isinstance(item.get("index"), int)
    }
    for beat in beats:
        if beat.index not in target_indices:
            continue
        actions = _normalize_board_actions(repairs.get(beat.index), beat.index)
        if actions:
            beat.board.actions = actions

    repaired = all(beat.board.actions for beat in beats if beat.index in target_indices)
    return beats, repaired


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
        data = _extract_json(provider.chat(_PREPARE_SYSTEM, user, json_mode=True))
    except (ValueError, json.JSONDecodeError):
        return _out_of_scope(
            cleaned,
            "I couldn't prepare that lesson. Try a more specific topic "
            "from your sources.",
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
            or "That isn’t covered in this project’s sources. "
            "Pick a topic from the course.",
            ctx,
        )

    beats, board_ready = _repair_missing_board_actions(
        provider,
        beats,
        cleaned,
        context,
    )
    if not board_ready or not any(beat.board.actions for beat in beats):
        return _out_of_scope(
            cleaned,
            "I couldn't build a reliable whiteboard for that lesson. Please try again.",
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
