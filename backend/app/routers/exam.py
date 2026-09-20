from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Project
from ..schemas import ExamGradeRequest, ExamGradeResponse, ExamOut
from ..services.exam import generate_exam, grade_exam

router = APIRouter(prefix="/projects/{project_id}/exam", tags=["exam"])


def _require_project(project_id: str, db: Session) -> None:
    if db.get(Project, project_id) is None:
        raise HTTPException(404, "Project not found")


@router.post("/generate", response_model=ExamOut)
def generate(project_id: str, db: Session = Depends(get_db)) -> ExamOut:
    _require_project(project_id, db)
    try:
        return generate_exam(db, project_id)
    except Exception as exc:  # noqa: BLE001 - surface a clean 502 to the client
        raise HTTPException(502, f"Couldn't generate an exam: {exc}") from exc


@router.post("/grade", response_model=ExamGradeResponse)
def grade(
    project_id: str, body: ExamGradeRequest, db: Session = Depends(get_db)
) -> ExamGradeResponse:
    _require_project(project_id, db)
    try:
        return grade_exam(db, project_id, body.exam, body.page_images_base64)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"Couldn't grade the exam: {exc}") from exc
