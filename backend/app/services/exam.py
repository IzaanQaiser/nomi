from __future__ import annotations

import json

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import (
    ExamGradeResponse,
    ExamOut,
    GradedQuestion,
)
from .llm import get_provider
from .retrieval import gather_context

_GEN_SYSTEM = (
    "You are an experienced university exam setter. Using ONLY the student's "
    "course material (lecture notes, past exams, assignments) provided below, "
    "write a realistic practice exam that resembles the style, difficulty and "
    "topic mix of this course's past exams. Cover the important concepts; do "
    "not invent material that is not supported by the sources. "
    "Estimate a sensible duration at roughly 1.5 minutes per mark, rounded to a "
    "clean number of minutes. For each question set answer_lines to the blank "
    "writing space it deserves (2-4 for short answers, 8-16 for long/worked "
    "problems). "
    "Respond with STRICT JSON only, no prose and no code fences, matching:\n"
    '{"title": str, "duration_minutes": int, "total_marks": int, '
    '"instructions": str, "sections": [{"title": str, "instructions": str, '
    '"questions": [{"number": str, "prompt": str, "marks": int, '
    '"answer_lines": int}]}]}'
)

_GRADE_SYSTEM = (
    "You are grading a student's handwritten exam. You are given the exam "
    "(as JSON) and a transcription of what the student wrote. Grade fairly and "
    "consistently and award partial credit. Grade EVERY question in the exam; if "
    "an answer is blank, award 0 and say it was not attempted. Never award more "
    "than a question's marks. "
    "For each question: 'feedback' says what was missing or wrong (one or two "
    "sentences). 'correct_answer' gives the right answer — for short questions "
    "state it concisely; for long or worked questions give the gist of the "
    "correct approach and where the student went wrong (2-3 sentences), not a "
    "full worked solution. "
    "Respond with STRICT JSON only matching:\n"
    '{"awarded": int, "total": int, "summary": str, "questions": '
    '[{"number": str, "awarded": int, "marks": int, "feedback": str, '
    '"correct_answer": str}]}'
)

_TRANSCRIBE_SYSTEM = (
    "You transcribe handwritten exam pages. Read the student's handwriting and "
    "output plain text, preserving question numbers exactly as written. If a "
    "region is blank, say so. Do not solve or grade anything."
)


def _extract_json(raw: str) -> dict:
    """Pull the first JSON object out of a model response (tolerates fences)."""
    text = raw.strip()
    if text.startswith("```"):
        text = text.strip("`")
        # drop a leading language hint like "json\n"
        if "\n" in text:
            text = text.split("\n", 1)[1]
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("no JSON object in model output")
    return json.loads(text[start : end + 1])


def generate_exam(db: Session, project_id: str) -> ExamOut:
    """Draft a likely exam from the project's sources."""
    settings = get_settings()
    provider = get_provider()

    # Pull broad coverage of the course material, not just a narrow top-K.
    ctx = gather_context(
        db,
        project_id,
        "past exam questions, assignments, key concepts and problems",
        provider,
        max(settings.top_k * 4, 16),
    )
    source_context = "\n\n".join(ctx.blocks) if ctx.blocks else ""
    if len(source_context) > 12000:
        source_context = source_context[:12000]

    user = (
        "Course material:\n"
        f"{source_context or '(no sources available — write a reasonable exam for the course topic)'}\n\n"
        "Write the practice exam now as strict JSON."
    )
    raw = provider.chat(_GEN_SYSTEM, user)
    data = _extract_json(raw)
    exam = ExamOut.model_validate(data)

    # Keep total_marks/duration coherent even if the model drifted.
    computed = sum(q.marks for s in exam.sections for q in s.questions)
    if computed > 0:
        exam.total_marks = computed
    if exam.duration_minutes <= 0:
        exam.duration_minutes = max(20, round(exam.total_marks * 1.5 / 5) * 5)
    return exam


def grade_exam(
    db: Session,
    project_id: str,
    exam: ExamOut,
    page_images_base64: list[str],
) -> ExamGradeResponse:
    """Transcribe the filled pages, then grade against the exam."""
    provider = get_provider()

    transcripts: list[str] = []
    for i, image in enumerate(page_images_base64):
        try:
            text = provider.vision(
                _TRANSCRIBE_SYSTEM, f"Transcribe exam page {i + 1}.", image
            )
            transcripts.append(f"--- Page {i + 1} ---\n{text}")
        except Exception:  # noqa: BLE001 - a bad page shouldn't sink grading
            transcripts.append(f"--- Page {i + 1} ---\n(could not read this page)")

    transcript = "\n\n".join(transcripts) if transcripts else "(no pages submitted)"
    user = (
        "Exam (JSON):\n"
        f"{exam.model_dump_json()}\n\n"
        "Student's transcribed answers:\n"
        f"{transcript}\n\n"
        "Grade the exam now as strict JSON."
    )
    raw = provider.chat(_GRADE_SYSTEM, user)
    data = _extract_json(raw)
    result = ExamGradeResponse.model_validate(data)

    # Trust the per-question marks over the model's own totals: clamp each award
    # to its max and derive the overall score so the header always matches the
    # question-by-question breakdown.
    for q in result.questions:
        q.awarded = max(0, min(q.awarded, q.marks))
    result.awarded = sum(q.awarded for q in result.questions)
    result.total = exam.total_marks if exam.total_marks > 0 else sum(
        q.marks for q in result.questions
    )
    return result
