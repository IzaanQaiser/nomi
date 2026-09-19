"""Re-embed every stored PDF with the current LLM provider.

Run after switching mock → gemini (old mock vectors are the wrong size):

    .venv/bin/python reingest.py
"""

from __future__ import annotations

import sys

from app.config import get_settings
from app.db import SessionLocal, init_db
from app.models import Chunk, Source
from app.services.file_store import read_file
from app.services.ingest import extract_pdf_text, ingest_source


def main() -> int:
    settings = get_settings()
    if settings.llm_provider == "gemini" and not settings.gemini_api_key:
        print("GEMINI_API_KEY is empty. Put the key in backend/.env and retry.")
        return 1

    init_db()
    db = SessionLocal()
    try:
        sources = db.query(Source).filter(Source.kind == "pdf").all()
        if not sources:
            print("No PDF sources to re-ingest.")
            return 0
        for source in sources:
            path = source.storage_path
            print(f"→ {source.title} ({source.id[:8]}…) status={source.status}")
            if not path:
                source.status = "error"
                source.error = "PDF file missing; please re-upload."
                db.commit()
                print("  missing file")
                continue
            db.query(Chunk).filter(Chunk.source_id == source.id).delete()
            db.commit()
            try:
                text = extract_pdf_text(read_file(path))
            except Exception as exc:  # noqa: BLE001
                source.status = "error"
                source.error = f"PDF file missing: {exc}"[:500]
                db.commit()
                print("  missing file")
                continue
            ingest_source(db, source, text)
            db.refresh(source)
            n = db.query(Chunk).filter(Chunk.source_id == source.id).count()
            print(f"  {source.status}  chunks={n}  {source.error or ''}")
    finally:
        db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
