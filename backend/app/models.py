from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from pgvector.sqlalchemy import VECTOR
from sqlalchemy import ForeignKey, LargeBinary, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .config import get_settings
from .db import Base

_settings = get_settings()
_embedding_type = VECTOR(_settings.embed_dim) if _settings.uses_postgres else LargeBinary


def _uuid() -> str:
    return uuid.uuid4().hex


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Project(Base):
    __tablename__ = "projects"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    created_at: Mapped[datetime] = mapped_column(default=_now)

    sources: Mapped[list[Source]] = relationship(
        back_populates="project", cascade="all, delete-orphan"
    )
    notes: Mapped[list[Note]] = relationship(
        back_populates="project", cascade="all, delete-orphan"
    )


class Source(Base):
    __tablename__ = "sources"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    project_id: Mapped[str] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), index=True
    )
    kind: Mapped[str] = mapped_column(String, nullable=False)  # pdf|docx|png|text
    title: Mapped[str] = mapped_column(String, nullable=False)
    storage_path: Mapped[str | None] = mapped_column(String, nullable=True)
    status: Mapped[str] = mapped_column(String, default="pending")  # pending|ready|error
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(default=_now)

    project: Mapped[Project] = relationship(back_populates="sources")
    chunks: Mapped[list[Chunk]] = relationship(
        back_populates="source", cascade="all, delete-orphan"
    )


class Chunk(Base):
    __tablename__ = "chunks"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    source_id: Mapped[str] = mapped_column(
        ForeignKey("sources.id", ondelete="CASCADE"), index=True
    )
    # Denormalized project_id so retrieval is always scoped to one project.
    project_id: Mapped[str] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), index=True, nullable=False
    )
    ordinal: Mapped[int] = mapped_column(default=0)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    embedding: Mapped[Any] = mapped_column(_embedding_type, nullable=False)

    source: Mapped[Source] = relationship(back_populates="chunks")


class Note(Base):
    __tablename__ = "notes"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    workspace_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True)
    project_id: Mapped[str] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), index=True
    )
    title: Mapped[str] = mapped_column(String, default="Untitled")
    page_index: Mapped[int] = mapped_column(default=0)
    # PencilKit PKDrawing serialized (base64) for the MVP.
    strokes_json: Mapped[str] = mapped_column(Text, default="")
    updated_at: Mapped[datetime] = mapped_column(default=_now, onupdate=_now)

    project: Mapped[Project] = relationship(back_populates="notes")
