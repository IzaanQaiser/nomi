from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from sqlalchemy import inspect
from sqlalchemy.orm import Session

from ..models import Chunk, Source


def embedding_to_blob(vec: list[float]) -> bytes:
    return np.asarray(vec, dtype=np.float32).tobytes()


def blob_to_embedding(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32)


def embedding_for_db(db: Session, vec: list[float]) -> bytes | list[float]:
    """Return the representation expected by the active database."""
    if inspect(db.get_bind()).dialect.name == "postgresql":
        return vec
    return embedding_to_blob(vec)


@dataclass
class Hit:
    chunk: Chunk
    source: Source
    score: float


class VectorStore:
    """Project-scoped pgvector search, with exact NumPy search for SQLite tests."""

    def __init__(self, db: Session) -> None:
        self.db = db

    def search(self, project_id: str, query_vec: list[float], top_k: int) -> list[Hit]:
        if inspect(self.db.get_bind()).dialect.name == "postgresql":
            distance = Chunk.embedding.cosine_distance(query_vec)
            rows = (
                self.db.query(Chunk, Source, (1 - distance).label("score"))
                .join(Source, Chunk.source_id == Source.id)
                .filter(
                    Chunk.project_id == project_id,
                    Source.project_id == project_id,
                    Source.status == "ready",
                )
                .order_by(distance)
                .limit(max(1, min(top_k, 50)))
                .all()
            )
            return [
                Hit(chunk=chunk, source=source, score=float(score))
                for chunk, source, score in rows
            ]

        rows = (
            self.db.query(Chunk, Source)
            .join(Source, Chunk.source_id == Source.id)
            .filter(Chunk.project_id == project_id, Source.status == "ready")
            .all()
        )
        if not rows:
            return []

        q = np.asarray(query_vec, dtype=np.float32)
        q_norm = np.linalg.norm(q) or 1.0
        q = q / q_norm

        scored: list[Hit] = []
        for chunk, source in rows:
            emb = blob_to_embedding(chunk.embedding)
            if emb.size != q.size:
                continue  # skip leftover rows from a previous embedding size
            denom = np.linalg.norm(emb) or 1.0
            score = float(np.dot(q, emb) / denom)
            scored.append(Hit(chunk=chunk, source=source, score=score))

        scored.sort(key=lambda h: h.score, reverse=True)
        return scored[:top_k]
