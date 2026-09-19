from __future__ import annotations

import json
import re

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import ShadowResponse, TalkResponse
from .llm import get_provider
from .retrieval import gather_context

_ANALYZE_SYSTEM = (
    "You are a live tutor watching a student solve a problem by hand. "
    "You are given an image of their in-progress handwritten work and, when "
    "available, context from their own course sources. Judge whether they are on "
    "track. Prefer the method and conventions used in the course sources when "
    "they are provided. Only interrupt when you are confident they have made a "
    "real error or are heading down a dead end - do NOT interrupt for style, "
    "incomplete-but-correct work, or steps still in progress. Respond with strict "
    'JSON: {"status": "ok" | "interrupt", "hint": string|null, "reasoning": string}. '
    "When status is ok, hint must be null. When status is interrupt, hint is one "
    "short, non-spoiler nudge that points at the mistake without giving the full "
    "solution."
)

_INFER_SYSTEM = (
    "You are looking at a photo of a student's page: it may contain a printed or "
    "handwritten problem plus their work. Identify the single problem they are "
    "currently working on. Reply with just the problem statement or a concise "
    "one-sentence description - no preamble. If you truly cannot tell, reply "
    "exactly with: unknown"
)

_JSON_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)


def infer_problem(image_base64: str) -> str:
    """One cheap vision pass to read the problem off the page.

    The client caches this per page so we don't re-infer on every check; the
    result is the retrieval query that grounds later analysis in sources.
    """
    provider = get_provider()
    raw = provider.vision(_INFER_SYSTEM, "What problem is on this page?", image_base64)
    text = (raw or "").strip()
    return text[:500] if text else "unknown"


def _parse_analyze(raw: str) -> dict | None:
    if not raw:
        return None
    text = _JSON_FENCE_RE.sub("", raw.strip()).strip()
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            return data
    except json.JSONDecodeError:
        pass
    start, end = text.find("{"), text.rfind("}")
    if start >= 0 and end > start:
        try:
            data = json.loads(text[start : end + 1])
            return data if isinstance(data, dict) else None
        except json.JSONDecodeError:
            return None
    return None


def analyze_work(
    db: Session,
    project_id: str,
    image_base64: str,
    problem_context: str | None,
) -> ShadowResponse:
    """Vision + NotebookLM-style source grounding.

    1. Reuse a cached problem statement if the client sent one; otherwise do a
       one-shot vision pass to read it off the page.
    2. Pull this project's sources via hybrid retrieval (full notebook if small,
       top-K + neighbors if large). Embeddings were computed at ingest.
    3. Send the page image + retrieved passages to vision for the actual check.
    """
    settings = get_settings()
    provider = get_provider()

    problem = (problem_context or "").strip()
    if not problem:
        problem = infer_problem(image_base64)

    query = problem if problem.lower() != "unknown" else "course material"
    ctx = gather_context(db, project_id, query, provider, settings.top_k)
    source_context = "\n\n".join(ctx.blocks) if ctx.blocks else ""

    user = (
        f"Problem the student is working on: {problem}\n\n"
        f"Relevant material from their course sources:\n"
        f"{source_context or '(none available)'}\n\n"
        "Analyze the attached image of the student's work and decide if they are on track."
    )

    raw = provider.vision(_ANALYZE_SYSTEM, user, image_base64, json_mode=True)
    data = _parse_analyze(raw)
    if not data:
        return ShadowResponse(
            status="ok",
            hint=None,
            reasoning="unparseable model output",
            problem=problem,
            grounding=ctx.mode,
        )

    status = "interrupt" if data.get("status") == "interrupt" else "ok"
    hint = data.get("hint") if status == "interrupt" else None
    return ShadowResponse(
        status=status,
        hint=hint,
        reasoning=data.get("reasoning"),
        problem=problem,
        grounding=ctx.mode,
    )


_TALK_SYSTEM = (
    "You are a live tutor sitting next to the student. They may speak to you "
    "(a transcript of what they said) or go silent, in which case you should "
    "cut in. You can see their handwritten page and, when provided, their "
    "course sources. Speak in 1-3 short sentences, out loud, as if interrupting "
    "gently. Do not dump the full solution. If they say they are stuck, give a "
    "non-spoiler nudge aimed at the next step. If they went silent and the work "
    "looks fine, a brief check-in is enough. Prefer methods from the sources."
)


def talk_with_student(
    db: Session,
    project_id: str,
    image_base64: str,
    utterance: str,
    problem_context: str | None,
) -> TalkResponse:
    """Conversational turn: page image + what they said (or silence) + sources."""
    settings = get_settings()
    provider = get_provider()

    problem = (problem_context or "").strip()
    if not problem:
        problem = infer_problem(image_base64)

    query = utterance.strip() or (
        problem if problem.lower() != "unknown" else "course material"
    )
    ctx = gather_context(db, project_id, query, provider, settings.top_k)
    source_context = "\n\n".join(ctx.blocks) if ctx.blocks else ""

    said = utterance.strip()
    if said:
        spoken = f'The student said: "{said}"'
    else:
        spoken = (
            "The student opened the mic and stayed silent. Cut in — they may be stuck."
        )

    user = (
        f"Problem the student is working on: {problem}\n\n"
        f"Relevant material from their course sources:\n"
        f"{source_context or '(none available)'}\n\n"
        f"{spoken}\n\n"
        "Look at the attached page and reply to the student."
    )
    raw = provider.vision(_TALK_SYSTEM, user, image_base64)
    reply = (raw or "").strip() or "Want a nudge on the next step?"
    return TalkResponse(reply=reply[:600], problem=problem, grounding=ctx.mode)
