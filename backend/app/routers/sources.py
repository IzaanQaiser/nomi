from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from sqlalchemy.orm import Session

from ..db import SessionLocal, get_db
from ..models import Project, Source
from ..schemas import SourceOut, TextSourceCreate
from ..services.file_store import delete_files, read_file, save_pdf
from ..services.ingest import extract_pdf_text, ingest_source

router = APIRouter(prefix="/projects/{project_id}/sources", tags=["sources"])
log = logging.getLogger(__name__)


def _require_project(db: Session, project_id: str) -> Project:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "Project not found")
    return project


def _mark_error(db: Session, source: Source, message: str) -> None:
    source.status = "error"
    source.error = message[:500]
    db.commit()


def _ingest_text_job(source_id: str, raw_text: str) -> None:
    db = SessionLocal()
    try:
        source = db.get(Source, source_id)
        if source is None:
            return
        ingest_source(db, source, raw_text)
    except Exception as exc:
        log.exception("text ingest failed for %s", source_id)
        source = db.get(Source, source_id)
        if source is not None:
            _mark_error(db, source, str(exc))
    finally:
        db.close()


def _ingest_pdf_job(source_id: str, storage_path: str) -> None:
    db = SessionLocal()
    try:
        source = db.get(Source, source_id)
        if source is None:
            return
        try:
            text = extract_pdf_text(read_file(storage_path))
        except Exception as exc:  # noqa: BLE001
            _mark_error(db, source, f"PDF parse failed: {exc}")
            return
        ingest_source(db, source, text)
    except Exception as exc:
        log.exception("pdf ingest failed for %s", source_id)
        source = db.get(Source, source_id)
        if source is not None:
            _mark_error(db, source, str(exc))
    finally:
        db.close()


def recover_pending_sources() -> int:
    """Finish any sources left pending after a crash / dropped background task."""
    db = SessionLocal()
    recovered = 0
    try:
        pending = (
            db.query(Source.id, Source.kind, Source.storage_path)
            .filter(Source.status == "pending")
            .all()
        )
        for sid, kind, path in pending:
            if kind == "pdf":
                if not path:
                    source = db.get(Source, sid)
                    if source is not None:
                        _mark_error(db, source, "PDF file missing; please re-upload.")
                else:
                    _ingest_pdf_job(sid, path)
            else:
                source = db.get(Source, sid)
                if source is not None:
                    _mark_error(
                        db,
                        source,
                        "Text ingest did not finish. Please re-add this source.",
                    )
            recovered += 1
    finally:
        db.close()
    return recovered


@router.get("", response_model=list[SourceOut])
def list_sources(project_id: str, db: Session = Depends(get_db)) -> list[Source]:
    _require_project(db, project_id)
    return (
        db.query(Source)
        .filter(Source.project_id == project_id)
        .order_by(Source.created_at.desc())
        .all()
    )


@router.post("/text", response_model=SourceOut, status_code=201)
async def add_text_source(
    project_id: str,
    body: TextSourceCreate,
    db: Session = Depends(get_db),
) -> Source:
    _require_project(db, project_id)
    source = Source(
        project_id=project_id, kind="text", title=body.title, status="pending"
    )
    db.add(source)
    db.commit()
    db.refresh(source)
    _ingest_text_job(source.id, body.content)
    db.expire_all()
    return db.get(Source, source.id)


@router.post("/pdf", response_model=SourceOut, status_code=201)
async def add_pdf_source(
    project_id: str,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
) -> Source:
    _require_project(db, project_id)
    if file.content_type not in (None, "application/pdf"):
        raise HTTPException(415, "Only PDF uploads are supported")
    content = await file.read()
    if not content:
        raise HTTPException(400, "Uploaded PDF is empty")
    try:
        path = save_pdf(project_id, file.filename or "upload.pdf", content)
    except Exception as exc:
        log.exception("PDF storage upload failed")
        raise HTTPException(502, "Could not store PDF") from exc

    source = Source(
        project_id=project_id,
        kind="pdf",
        title=file.filename or "Uploaded PDF",
        storage_path=path,
        status="pending",
    )
    db.add(source)
    db.commit()
    db.refresh(source)
    _ingest_pdf_job(source.id, path)
    db.expire_all()
    return db.get(Source, source.id)


@router.get("/{source_id}", response_model=SourceOut)
def get_source(project_id: str, source_id: str, db: Session = Depends(get_db)) -> Source:
    source = db.get(Source, source_id)
    if source is None or source.project_id != project_id:
        raise HTTPException(404, "Source not found")
    return source


@router.delete("/{source_id}", status_code=204, response_model=None)
def delete_source(project_id: str, source_id: str, db: Session = Depends(get_db)) -> None:
    source = db.get(Source, source_id)
    if source is None or source.project_id != project_id:
        raise HTTPException(404, "Source not found")

    # Remove private storage first so a storage failure cannot leave an object
    # orphaned after its database row and vector chunks disappear.
    try:
        delete_files([source.storage_path] if source.storage_path else [])
    except Exception as exc:
        raise HTTPException(502, "Could not remove source file") from exc

    db.delete(source)
    db.commit()
