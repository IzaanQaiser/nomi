"""One-time importer from the old SQLite/local-file backend to Supabase.

Configure the target Supabase DATABASE_URL, SUPABASE_URL, and
SUPABASE_SERVICE_ROLE_KEY in backend/.env, then run:

    backend/.venv/bin/python backend/migrate_sqlite_to_supabase.py \
      --source backend/ainotes.db

Rows keep their IDs. PDFs are copied into the private bucket and re-embedded;
compatible text chunks are copied directly. Re-running is safe: existing IDs
are skipped.
"""

from __future__ import annotations

import argparse
import sqlite3
from datetime import datetime
from pathlib import Path

import numpy as np
from app.config import get_settings
from app.db import SessionLocal, init_db
from app.models import Chunk, Note, Project, Source
from app.services.file_store import save_pdf
from app.services.ingest import extract_pdf_text, ingest_source


def _rows(connection: sqlite3.Connection, table: str) -> list[sqlite3.Row]:
    allowed = {"projects", "sources", "notes", "chunks"}
    if table not in allowed:
        raise ValueError(f"Unsupported table: {table}")
    return connection.execute(f"select * from {table}").fetchall()


def _datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="backend/ainotes.db")
    args = parser.parse_args()

    settings = get_settings()
    if not settings.uses_postgres or not settings.uses_supabase_storage:
        print("Configure the target Postgres DATABASE_URL and Supabase Storage variables first.")
        return 1

    source_path = Path(args.source).resolve()
    if not source_path.exists():
        print(f"SQLite database not found: {source_path}")
        return 1

    init_db()
    old = sqlite3.connect(source_path)
    old.row_factory = sqlite3.Row
    db = SessionLocal()
    pdfs_to_reingest: list[tuple[str, str]] = []
    skipped_vectors = 0
    try:
        for row in _rows(old, "projects"):
            if db.get(Project, row["id"]) is None:
                db.add(
                    Project(
                        id=row["id"],
                        name=row["name"],
                        created_at=_datetime(row["created_at"]),
                    )
                )
        db.commit()

        for row in _rows(old, "sources"):
            if db.get(Source, row["id"]) is not None:
                continue
            storage_path = row["storage_path"]
            status = row["status"]
            error = row["error"]
            if row["kind"] == "pdf":
                local_path = Path(storage_path or "")
                if storage_path and not local_path.is_absolute():
                    local_path = source_path.parent / local_path
                if not local_path.is_file():
                    raise FileNotFoundError(f"Missing PDF for {row['title']}: {local_path}")
                storage_path = save_pdf(row["project_id"], local_path.name, local_path.read_bytes())
                status, error = "pending", None
                pdfs_to_reingest.append((row["id"], storage_path))
            db.add(
                Source(
                    id=row["id"], project_id=row["project_id"], kind=row["kind"],
                    title=row["title"], storage_path=storage_path, status=status,
                    error=error, created_at=_datetime(row["created_at"]),
                )
            )
        db.commit()

        for row in _rows(old, "notes"):
            if db.get(Note, row["id"]) is None:
                db.add(
                    Note(
                        id=row["id"], project_id=row["project_id"], title=row["title"],
                        page_index=row["page_index"], strokes_json=row["strokes_json"],
                        updated_at=_datetime(row["updated_at"]),
                    )
                )
        db.commit()

        pdf_ids = {source_id for source_id, _ in pdfs_to_reingest}
        for row in _rows(old, "chunks"):
            if row["source_id"] in pdf_ids or db.get(Chunk, row["id"]) is not None:
                continue
            vector = np.frombuffer(row["embedding"], dtype=np.float32)
            if vector.size != settings.embed_dim:
                skipped_vectors += 1
                continue
            db.add(
                Chunk(
                    id=row["id"], source_id=row["source_id"], project_id=row["project_id"],
                    ordinal=row["ordinal"], content=row["content"], embedding=vector.tolist(),
                )
            )
        db.commit()

        for source_id, storage_path in pdfs_to_reingest:
            source = db.get(Source, source_id)
            if source is not None:
                from app.services.file_store import read_file

                ingest_source(db, source, extract_pdf_text(read_file(storage_path)))

        if skipped_vectors:
            print(
                f"Skipped {skipped_vectors} old wrong-dimension text vectors; "
                "re-add those text sources."
            )
        print("SQLite data migration complete.")
        return 0
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
        old.close()


if __name__ == "__main__":
    raise SystemExit(main())
