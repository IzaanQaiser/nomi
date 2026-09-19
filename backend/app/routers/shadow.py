from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Project
from ..schemas import (
    InferProblemRequest,
    InferProblemResponse,
    ShadowRequest,
    ShadowResponse,
    SolutionRequest,
    SolutionResponse,
    TalkRequest,
    TalkResponse,
)
from ..services.shadow import (
    analyze_work,
    infer_problem,
    reveal_solution,
    talk_with_student,
)

router = APIRouter(prefix="/projects/{project_id}/shadow", tags=["shadow"])


def _require_project(project_id: str, db: Session) -> None:
    if db.get(Project, project_id) is None:
        raise HTTPException(404, "Project not found")


@router.post("", response_model=ShadowResponse)
def shadow(
    project_id: str, body: ShadowRequest, db: Session = Depends(get_db)
) -> ShadowResponse:
    _require_project(project_id, db)
    return analyze_work(
        db,
        project_id,
        body.image_base64,
        body.problem_context,
        body.recent_context,
    )


@router.post("/infer-problem", response_model=InferProblemResponse)
def infer_problem_route(
    project_id: str, body: InferProblemRequest, db: Session = Depends(get_db)
) -> InferProblemResponse:
    _require_project(project_id, db)
    return InferProblemResponse(problem=infer_problem(body.image_base64))


@router.post("/talk", response_model=TalkResponse)
def talk(
    project_id: str, body: TalkRequest, db: Session = Depends(get_db)
) -> TalkResponse:
    _require_project(project_id, db)
    return talk_with_student(
        db,
        project_id,
        body.image_base64,
        body.utterance,
        body.problem_context,
        body.recent_context,
    )


@router.post("/solution", response_model=SolutionResponse)
def solution(
    project_id: str, body: SolutionRequest, db: Session = Depends(get_db)
) -> SolutionResponse:
    _require_project(project_id, db)
    return reveal_solution(
        db,
        project_id,
        body.image_base64,
        body.problem_context,
        body.recent_context,
        body.mistake_summary,
    )
