from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Note, Project
from ..schemas import NoteOut, NoteUpsert

router = APIRouter(prefix="/projects/{project_id}/notes", tags=["notes"])


def _require_project(db: Session, project_id: str) -> Project:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "Project not found")
    return project


@router.get("", response_model=list[NoteOut])
def list_notes(project_id: str, db: Session = Depends(get_db)) -> list[Note]:
    _require_project(db, project_id)
    return (
        db.query(Note)
        .filter(Note.project_id == project_id)
        .order_by(Note.page_index.asc())
        .all()
    )


@router.put("", response_model=NoteOut)
def upsert_note(
    project_id: str, body: NoteUpsert, db: Session = Depends(get_db)
) -> Note:
    _require_project(db, project_id)
    note: Note | None = None
    if body.id:
        note = db.get(Note, body.id)
        if note is not None and note.project_id != project_id:
            raise HTTPException(404, "Note not found")
    if note is None:
        note = Note(project_id=project_id)
        db.add(note)

    note.title = body.title
    note.page_index = body.page_index
    note.strokes_json = body.strokes_json
    db.commit()
    db.refresh(note)
    return note
