from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Project
from ..schemas import ChatRequest, ChatResponse
from ..services.rag import answer_question

router = APIRouter(prefix="/projects/{project_id}/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
def chat(
    project_id: str, body: ChatRequest, db: Session = Depends(get_db)
) -> ChatResponse:
    if db.get(Project, project_id) is None:
        raise HTTPException(404, "Project not found")
    return answer_question(db, project_id, body.question)
