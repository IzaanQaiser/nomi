from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Project
from ..schemas import (
    ChatResponse,
    ClassroomLessonOut,
    ClassroomPrepareRequest,
    ClassroomRequest,
    ClassroomSuggestionsResponse,
)
from ..services.classroom import prepare_lesson, suggest_topics, teach

router = APIRouter(prefix="/projects/{project_id}/classroom", tags=["classroom"])


def _project_or_404(db: Session, project_id: str) -> Project:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "Project not found")
    return project


@router.get("/suggestions", response_model=ClassroomSuggestionsResponse)
def suggestions(
    project_id: str,
    db: Session = Depends(get_db),
) -> ClassroomSuggestionsResponse:
    project = _project_or_404(db, project_id)
    return ClassroomSuggestionsResponse(
        suggestions=suggest_topics(db, project.id, project.name)
    )


@router.post("/prepare", response_model=ClassroomLessonOut)
def classroom_prepare(
    project_id: str,
    body: ClassroomPrepareRequest,
    db: Session = Depends(get_db),
) -> ClassroomLessonOut:
    _project_or_404(db, project_id)
    return prepare_lesson(
        db,
        project_id,
        body.topic,
        prompt_context=body.prompt_context,
    )


@router.post("/teach", response_model=ChatResponse)
def classroom_teach(
    project_id: str,
    body: ClassroomRequest,
    db: Session = Depends(get_db),
) -> ChatResponse:
    _project_or_404(db, project_id)
    return teach(
        db,
        project_id,
        body.question,
        body.history,
        prompt_context=body.prompt_context,
    )
