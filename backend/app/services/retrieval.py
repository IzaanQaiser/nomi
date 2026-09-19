from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass

from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import Chunk, Source
from .llm.base import LLMProvider
from .vector_store import Hit, VectorStore

# Cap the in-process query-embedding cache. Shadowing reuses the same problem
# text every few seconds; this avoids a paid embed call on every check.
_QUERY_CACHE_MAX = 256
_query_embed_cache: OrderedDict[str, list[float]] = OrderedDict()


@dataclass
class RetrievedContext:
    blocks: list[str]  # "[Source Title] content" blocks for the prompt
    hits: list[Hit]  # backing chunks (for citations / grounding)
    mode: str  # "full" | "retrieval" | "empty"


def _cached_query_embedding(provider: LLMProvider, query_text: str) -> list[float]:
    key = query_text.strip()
    if key in _query_embed_cache:
        _query_embed_cache.move_to_end(key)
        return _query_embed_cache[key]
    vec = provider.embed([key], for_query=True)[0]
    _query_embed_cache[key] = vec
    if len(_query_embed_cache) > _QUERY_CACHE_MAX:
        _query_embed_cache.popitem(last=False)
    return vec


def _expand_neighbors(db: Session, hits: list[Hit], window: int = 1) -> list[Hit]:
    """Pull ordinal ± window from the same source so a retrieved passage isn't
    cut off mid-derivation. No extra embedding cost — just SQLite reads."""
    if not hits or window <= 0:
        return hits
    wanted: dict[tuple[str, int], Hit] = {}
    for hit in hits:
        wanted[(hit.chunk.source_id, hit.chunk.ordinal)] = hit

    for hit in hits:
        lo = max(0, hit.chunk.ordinal - window)
        hi = hit.chunk.ordinal + window
        neighbors = (
            db.query(Chunk, Source)
            .join(Source, Chunk.source_id == Source.id)
            .filter(
                Chunk.source_id == hit.chunk.source_id,
                Chunk.ordinal >= lo,
                Chunk.ordinal <= hi,
            )
            .all()
        )
        for chunk, source in neighbors:
            key = (chunk.source_id, chunk.ordinal)
            if key not in wanted:
                wanted[key] = Hit(chunk=chunk, source=source, score=hit.score * 0.5)

    ordered = sorted(
        wanted.values(),
        key=lambda h: (h.source.title, h.chunk.ordinal),
    )
    return ordered


def gather_context(
    db: Session,
    project_id: str,
    query_text: str,
    provider: LLMProvider,
    top_k: int,
) -> RetrievedContext:
    """Return source context for a query, scoped to one project.

    Mirrors NotebookLM's cheap hybrid:
      - Small/medium notebook: inject everything in reading order. No query
        embedding, preserves structure across a lecture / problem set.
      - Large notebook: embed the query once (cached) and cosine-search the
        *already stored* chunk vectors, then expand by ±1 neighbor.

    Retrieval is always project-scoped, so notebooks stay disjoint.
    """
    settings = get_settings()
    rows = (
        db.query(Chunk, Source)
        .join(Source, Chunk.source_id == Source.id)
        .filter(Chunk.project_id == project_id, Source.status == "ready")
        .all()
    )
    if not rows:
        return RetrievedContext(blocks=[], hits=[], mode="empty")

    total_chars = sum(len(chunk.content) for chunk, _ in rows)
    budget = settings.full_context_char_budget

    if total_chars <= budget:
        ordered = sorted(rows, key=lambda r: (r[1].title, r[0].ordinal))
        hits = [Hit(chunk=chunk, source=source, score=1.0) for chunk, source in ordered]
        blocks = [f"[{source.title}] {chunk.content}" for chunk, source in ordered]
        return RetrievedContext(blocks=blocks, hits=hits, mode="full")

    query = (query_text or "").strip() or "course material"
    query_vec = _cached_query_embedding(provider, query)
    hits = VectorStore(db).search(project_id, query_vec, top_k)
    hits = _expand_neighbors(db, hits, window=1)
    blocks = [f"[{h.source.title}] {h.chunk.content}" for h in hits]
    return RetrievedContext(blocks=blocks, hits=hits, mode="retrieval")
