from __future__ import annotations

from sqlalchemy.orm import Session

from ..config import get_settings
from ..schemas import ChatResponse, Citation
from .llm import get_provider
from .retrieval import gather_context

_SYSTEM = (
    "You are a focused study assistant. Answer ONLY using the provided context "
    "from the student's sources. If the answer is not contained in the context, "
    "say you couldn't find it in their sources. Be concise and cite specifics."
)


def _build_user_prompt(question: str, context_blocks: list[str]) -> str:
    context = "\n\n---\n\n".join(context_blocks)
    return (
        f"Question: {question}\n\n"
        "Use only the context between the markers below.\n"
        f"<<<CONTEXT>>>\n{context}\n<<<END>>>"
    )


def answer_question(db: Session, project_id: str, question: str) -> ChatResponse:
    settings = get_settings()
    provider = get_provider()

    ctx = gather_context(db, project_id, question, provider, settings.top_k)

    if not ctx.blocks:
        return ChatResponse(
            answer=(
                "I couldn't find anything about that in your sources. "
                "Add a source covering this topic and try again."
            ),
            citations=[],
        )

    answer = provider.chat(_SYSTEM, _build_user_prompt(question, ctx.blocks))

    # In full-context mode every chunk is "used"; cap citations for a tidy UI.
    cited = ctx.hits if ctx.mode == "retrieval" else ctx.hits[: settings.top_k]
    citations = [
        Citation(
            source_id=h.source.id,
            source_title=h.source.title,
            chunk_id=h.chunk.id,
            snippet=h.chunk.content[:240],
            score=round(h.score, 4),
        )
        for h in cited
    ]
    return ChatResponse(answer=answer, citations=citations)
