from __future__ import annotations

import json
import re

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import (
    ChatResponse,
    Citation,
    ClassroomHistoryMessage,
    ClassroomLessonBeat,
    ClassroomLessonOut,
    ClassroomLessonSource,
    ClassroomPassage,
    ClassroomSlide,
)
from .llm import get_provider
from .retrieval import RetrievedContext, gather_context

_TEACH_SYSTEM = (
    "You are Nomi teaching inside a student's project classroom. The student "
    "just interrupted the current slide with a question. Answer only that "
    "question, like a professor pausing mid-lecture. Use only the provided "
    "course context and the current lesson moment. Keep the answer short "
    "enough to speak: a few sentences, one concrete point, no recap of the "
    "whole lecture. Do not restart the lesson, do not generate slides, and "
    "do not invent facts. If the sources do not support the answer, say so "
    "plainly."
)

_PREPARE_SYSTEM = (
    "You are Nomi acting as a lesson planner, not a graphic designer. "
    "Prepare a classroom mini-lecture from the student's course sources only. "
    "Decide if the requested topic is actually covered by those sources. "
    "If it is not, in_scope must be false, beats must be empty, and reason "
    "should be one short sentence. If it is, produce 4 to 8 coherent teaching "
    "beats a later step can play and pause. Build intuition before "
    "details. Stay grounded in the retrieved sources and do not invent facts. "
    "Each beat has spoken narration (`speaking`) and a visual slide. "
    "EVERY slide MUST include 3 to 5 teaching bullets in `slide.bullets`. "
    "Each bullet is one complete sentence of at least 12 words, with a verb, "
    "ending in a period, that a student could copy as notes. Never use labels, "
    "noun stubs, or colon fragments such as 'Input: Desired output'. Write "
    "the idea out: 'The input is the desired output the loop is trying to "
    "reach.' This includes title, concept, equation, diagram, steps, and "
    "checkpoint slides. Title-slide bullets preview what the lesson will cover. "
    "Equation-slide bullets explain what the symbols mean and when to use it. "
    "Diagram-slide bullets say what to read from the picture. Checkpoint "
    "bullets are hints for thinking, not the answer. Never leave bullets empty, "
    "never write vague bullets like 'key idea' or 'see diagram', and do not "
    "paste the narration verbatim into the bullets. Keep titles short. Choose "
    "layouts intentionally: title, concept, equation, bullets, steps, diagram, "
    "or checkpoint. Use a diagram only when a relationship genuinely needs a "
    "picture. Mermaid must be simple and robust: prefer flowchart LR or TD. "
    "Node IDs must be CamelCase with no spaces. Put labels in quotes, e.g. "
    "A[\"Desired output\"] --> B[\"Measured output\"]. No subgraphs, classDef, "
    "click, style, HTML, SVG, or coordinates. At most 8 nodes. Produce "
    "Mermaid syntax only. Include a useful checkpoint beat when appropriate. "
    "Respond with STRICT JSON only, no prose and no code fences, matching:\n"
    '{"in_scope": bool, "topic": str, "title": str, "reason": str|null, '
    '"summary": str, "beats": [{"title": str, "speaking": str, '
    '"slide": {"layout": "title"|"concept"|"equation"|"bullets"|"steps"'
    '|"diagram"|"checkpoint", "title": str, "subtitle": str, "body": str, '
    '"bullets": [str], "equation": str, "caption": str, "callout": str, '
    '"steps": [str], "mermaid": str, "question": str}}]}'
)

_SUGGEST_SYSTEM = (
    "Identify three useful, distinct concepts a student could learn from the "
    "provided course material. Return only a JSON array of exactly three short "
    "topic names, each two to five words. Do not include numbering or commentary."
)

_SLIDE_LAYOUTS = {
    "title",
    "concept",
    "equation",
    "bullets",
    "steps",
    "diagram",
    "checkpoint",
}
_MIN_BEATS = 4
_MAX_BEATS = 8
_MIN_BULLETS = 3
_MAX_BULLETS = 6
_MIN_BULLET_WORDS = 6
_MAX_STEPS = 8
_MAX_BULLET_CHARS = 220
_MAX_STEP_CHARS = 160
_MAX_TITLE_CHARS = 80
_MAX_SUBTITLE_CHARS = 120
_MAX_BODY_CHARS = 400
_MAX_CAPTION_CHARS = 180
_MAX_CALLOUT_CHARS = 180
_MAX_EQUATION_CHARS = 200
_MAX_QUESTION_CHARS = 240
_MAX_SPEAKING_CHARS = 800
_MAX_MERMAID_CHARS = 2500
_MAX_PASSAGE_CHARS = 1600
_MAX_PASSAGES_CHARS = 16_000

_JSON_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)
_MERMAID_FENCE_RE = re.compile(
    r"^```(?:mermaid)?\s*|\s*```$", re.IGNORECASE | re.MULTILINE
)
_MERMAID_START_RE = re.compile(
    r"^(flowchart|graph|statediagram(?:-v2)?|sequencediagram)\b",
    re.IGNORECASE,
)
_FORBIDDEN_VISUAL_RE = re.compile(
    r"<(svg|html|body|script|iframe)\b", re.IGNORECASE
)
_LABEL_BULLET_RE = re.compile(
    r"^([A-Za-z][A-Za-z0-9+\-/\s()]{0,28}):\s+(\S.*)$"
)
_MERMAID_ARROW_RE = re.compile(
    r"(\s*(?:-->|---|==>|-\.->|<-->|o--|x--|--o|--x)\s*(?:\|[^|]*\|\s*)?)"
)
_MERMAID_DROP_LINE_RE = re.compile(
    r"^\s*(classDef|click|style|linkStyle|class|accTitle|accDescr)\b",
    re.IGNORECASE,
)
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
    for message in history[-6:]:
        content = " ".join(message.content.split())[:800]
        if not content or total + len(content) > 3600:
            continue
        label = "Student" if message.role == "user" else "Nomi"
        lines.append(f"{label}: {content}")
        total += len(content)
    return "\n".join(lines)


def _retrieval_query(question: str, prompt_context: str | None) -> str:
    extra = " ".join((prompt_context or "").split())[:800]
    if extra:
        return f"{question}\n{extra}"
    return question


def teach(
    db: Session,
    project_id: str,
    question: str,
    history: list[ClassroomHistoryMessage] | None = None,
    prompt_context: str | None = None,
) -> ChatResponse:
    settings = get_settings()
    provider = get_provider()
    cleaned_question = " ".join((question or "").split())[:2000]
    extra = " ".join((prompt_context or "").split())[:4000]
    ctx = gather_context(
        db,
        project_id,
        _retrieval_query(cleaned_question, extra),
        provider,
        settings.top_k,
    )

    if not ctx.blocks:
        return ChatResponse(
            answer=(
                "I don’t have project material for that yet. Add a relevant "
                "source to this project, then I can teach it from your course."
            ),
            citations=[],
        )

    recent = _history_text(history or [])
    context = "\n\n---\n\n".join(ctx.blocks)
    user = (
        f"Student question: {cleaned_question}\n\n"
        f"Recent classroom conversation:\n{recent or '(none)'}\n\n"
    )
    if extra:
        user += f"Current lesson moment:\n{extra}\n\n"
    user += (
        "Answer from the course context below. Stay with this slide; "
        "do not restart the lecture.\n"
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


def _short_text(value: object, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _string_list(value: object, *, max_items: int, max_len: int) -> list[str]:
    if isinstance(value, str) and value.strip():
        raw_items: list[object] = [value]
    elif isinstance(value, list):
        raw_items = value
    else:
        return []
    items: list[str] = []
    seen: set[str] = set()
    for item in raw_items:
        text = _short_text(item, max_len)
        key = text.lower()
        if not text or key in seen:
            continue
        seen.add(key)
        items.append(text)
        if len(items) == max_items:
            break
    return items


def _normalize_mermaid(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    text = _MERMAID_FENCE_RE.sub("", text).strip()
    if not text or len(text) > _MAX_MERMAID_CHARS:
        return ""
    if _FORBIDDEN_VISUAL_RE.search(text):
        return ""
    lowered = text.lower()
    if "reveal_at" in lowered or "draw_arrow" in lowered or "write_text" in lowered:
        return ""
    first_line = next((line.strip() for line in text.splitlines() if line.strip()), "")
    if not _MERMAID_START_RE.match(first_line):
        return ""
    return _repair_mermaid(text)


def _repair_mermaid(text: str) -> str:
    lines = text.splitlines()
    if not lines:
        return text
    header = next((line for line in lines if line.strip()), "")
    kind = header.strip().split()[0].lower() if header else ""
    repaired: list[str] = []
    seen_header = False
    for line in lines:
        if not seen_header:
            repaired.append(line)
            if line.strip():
                seen_header = True
            continue
        if kind in {"flowchart", "graph"}:
            if _MERMAID_DROP_LINE_RE.match(line):
                continue
            repaired.append(_repair_flowchart_line(line))
        else:
            repaired.append(line)
    return "\n".join(repaired)


def _repair_flowchart_line(line: str) -> str:
    stripped = line.strip()
    if not stripped or stripped.startswith("%%"):
        return line
    indent = line[: len(line) - len(line.lstrip())]
    parts = _MERMAID_ARROW_RE.split(stripped)
    repaired: list[str] = []
    for index, part in enumerate(parts):
        if index % 2 == 1:
            repaired.append(part)
        elif part.strip():
            repaired.append(_repair_flowchart_node(part.strip()))
        else:
            repaired.append(part)
    return indent + "".join(repaired)


def _repair_flowchart_node(token: str) -> str:
    token = token.strip()
    if not token:
        return token
    token = _quote_shape_labels(token)
    if re.search(r"\s", token) and not re.search(r"[\[\(\{]", token):
        return f"{_safe_node_id(token)}[{_quoted_label(token)}]"
    return token


def _quote_shape_labels(token: str) -> str:
    def replacer(match: re.Match[str]) -> str:
        inner = match.group(1).strip()
        if inner.startswith(("\"", "'")):
            return match.group(0)
        if re.search(r"[\s:()/,=]", inner):
            return f"[{_quoted_label(inner)}]"
        return match.group(0)

    return re.sub(r"\[([^\[\]]+)\]", replacer, token)


def _safe_node_id(label: str) -> str:
    ident = re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_")
    ident = re.sub(r"_+", "_", ident)
    if not ident:
        ident = "N"
    if ident[0].isdigit():
        ident = f"N_{ident}"
    return ident[:48]


def _quoted_label(text: str) -> str:
    return '"' + text.replace('"', "'") + '"'


def _as_sentence(value: str) -> str:
    text = value.strip().rstrip(" -;:,")
    if text and text[-1] not in ".!?":
        text += "."
    return text


def _expand_label_bullet(text: str) -> str:
    match = _LABEL_BULLET_RE.match(text.strip().rstrip("."))
    if not match:
        return _as_sentence(text)
    term = match.group(1).strip()
    rest = match.group(2).strip().rstrip(".")
    if not rest:
        return _as_sentence(text)
    rest_text = rest[0].lower() + rest[1:] if rest[0].isupper() and (
        len(rest) == 1 or not rest[1].isupper()
    ) else rest
    if not rest_text.startswith(("the ", "a ", "an ")):
        rest_text = "the " + rest_text
    return (
        f"The {term.lower()} is {rest_text}, which is the role it plays "
        "in this part of the lesson."
    )


def _is_teaching_sentence(text: str) -> bool:
    if not text or _LABEL_BULLET_RE.match(text.strip().rstrip(".")):
        return False
    return len(text.split()) >= _MIN_BULLET_WORDS and len(text) >= 32


def _sentence_list(value: str, *, max_items: int, max_len: int) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+", value)
    return _string_list(parts, max_items=max_items, max_len=max_len)


def _lengthen_bullet(text: str) -> str:
    sentence = _expand_label_bullet(text)
    if not _is_teaching_sentence(sentence):
        stem = sentence[:-1] if sentence.endswith((".", "!", "?")) else sentence
        sentence = stem + ", and this is a point to keep from the notes."
    return _short_text(sentence, _MAX_BULLET_CHARS)


def _ensure_teaching_bullets(
    bullets: list[str],
    *,
    body: str,
    steps: list[str],
    caption: str,
    callout: str,
    equation: str,
    question: str,
    speaking: str = "",
) -> list[str]:
    extras = [
        item
        for item in (_lengthen_bullet(bullet) for bullet in bullets)
        if _is_teaching_sentence(item)
    ][:_MAX_BULLETS]
    if len(extras) >= _MIN_BULLETS:
        return extras
    for candidate in (
        steps,
        _sentence_list(body, max_items=_MAX_BULLETS, max_len=_MAX_BULLET_CHARS),
        _sentence_list(caption, max_items=_MAX_BULLETS, max_len=_MAX_BULLET_CHARS),
        _sentence_list(callout, max_items=_MAX_BULLETS, max_len=_MAX_BULLET_CHARS),
        _sentence_list(speaking, max_items=_MAX_BULLETS, max_len=_MAX_BULLET_CHARS),
        [equation] if equation else [],
        [question] if question else [],
    ):
        for item in candidate:
            sentence = _lengthen_bullet(item)
            if not _is_teaching_sentence(sentence):
                continue
            extras = _string_list(
                extras + [sentence],
                max_items=_MAX_BULLETS,
                max_len=_MAX_BULLET_CHARS,
            )
            if len(extras) >= _MIN_BULLETS:
                return extras
    original = [_lengthen_bullet(bullet) for bullet in bullets if bullet.strip()]
    return (extras or original)[:_MAX_BULLETS]


def _normalize_slide(
    raw: object, beat_title: str, speaking: str = ""
) -> ClassroomSlide | None:
    if not isinstance(raw, dict):
        return None
    layout = str(raw.get("layout") or "").strip().lower()
    if layout not in _SLIDE_LAYOUTS:
        return None

    title = _short_text(raw.get("title") or beat_title, _MAX_TITLE_CHARS)
    subtitle = _short_text(raw.get("subtitle"), _MAX_SUBTITLE_CHARS)
    body = _short_text(raw.get("body"), _MAX_BODY_CHARS)
    caption = _short_text(raw.get("caption"), _MAX_CAPTION_CHARS)
    callout = _short_text(raw.get("callout"), _MAX_CALLOUT_CHARS)
    equation = _short_text(raw.get("equation"), _MAX_EQUATION_CHARS)
    question = _short_text(raw.get("question"), _MAX_QUESTION_CHARS)
    bullets = _string_list(
        raw.get("bullets"), max_items=_MAX_BULLETS, max_len=_MAX_BULLET_CHARS
    )
    steps = _string_list(
        raw.get("steps"), max_items=_MAX_STEPS, max_len=_MAX_STEP_CHARS
    )
    mermaid = _normalize_mermaid(raw.get("mermaid")) if layout == "diagram" else ""
    bullets = _ensure_teaching_bullets(
        bullets,
        body=body,
        steps=steps,
        caption=caption,
        callout=callout,
        equation=equation,
        question=question,
        speaking=speaking,
    )

    if layout == "diagram" and not mermaid:
        return None
    if layout == "equation" and not equation:
        return None
    if layout == "checkpoint" and not question:
        return None
    if layout == "steps" and not steps:
        return None
    if layout == "title" and not title:
        return None
    if len(bullets) < _MIN_BULLETS:
        return None

    return ClassroomSlide(
        layout=layout,  # type: ignore[arg-type]
        title=title,
        subtitle=subtitle,
        body=body,
        bullets=bullets,
        equation=equation if layout in {"equation", "concept"} else "",
        caption=caption,
        callout=callout,
        steps=steps if layout in {"steps", "concept"} else [],
        mermaid=mermaid if layout == "diagram" else "",
        question=question if layout in {"checkpoint", "concept"} else "",
    )


def _normalize_beats(raw_beats: object) -> list[ClassroomLessonBeat]:
    if not isinstance(raw_beats, list):
        return []
    beats: list[ClassroomLessonBeat] = []
    for item in raw_beats:
        if not isinstance(item, dict):
            continue
        title = _short_text(item.get("title"), _MAX_TITLE_CHARS)
        speaking = _short_text(item.get("speaking"), _MAX_SPEAKING_CHARS)
        if not title or not speaking:
            continue
        slide = _normalize_slide(item.get("slide"), title, speaking)
        if slide is None:
            continue
        if not slide.title:
            slide.title = title
        beats.append(
            ClassroomLessonBeat(
                index=len(beats),
                title=title,
                speaking=speaking,
                slide=slide,
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
    """Ground a topic and return a playable slide lesson, or say it is out of scope."""
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
    if not in_scope:
        return _out_of_scope(
            cleaned,
            reason_text
            or "That isn’t covered in this project’s sources. "
            "Pick a topic from the course.",
            ctx,
        )
    if len(beats) < _MIN_BEATS:
        return _out_of_scope(
            cleaned,
            "I couldn't build a reliable lesson for that topic. Please try again.",
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
