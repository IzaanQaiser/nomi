from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Project, Source
from ..schemas import ProjectCreate, ProjectOut
from ..services.file_store import delete_files

router = APIRouter(prefix="/projects", tags=["projects"])


@router.get("", response_model=list[ProjectOut])
def list_projects(db: Session = Depends(get_db)) -> list[Project]:
    return db.query(Project).order_by(Project.created_at.desc()).all()


@router.post("", response_model=ProjectOut, status_code=201)
def create_project(body: ProjectCreate, db: Session = Depends(get_db)) -> Project:
    project = Project(name=body.name)
    db.add(project)
    db.commit()
    db.refresh(project)
    return project


@router.get("/{project_id}", response_model=ProjectOut)
def get_project(project_id: str, db: Session = Depends(get_db)) -> Project:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "Project not found")
    return project


@router.delete("/{project_id}", status_code=204, response_model=None)
def delete_project(project_id: str, db: Session = Depends(get_db)) -> None:
    project = db.get(Project, project_id)
    if project is None:
        raise HTTPException(404, "Project not found")
    storage_paths = [
        path
        for (path,) in db.query(Source.storage_path)
        .filter(Source.project_id == project_id, Source.storage_path.is_not(None))
        .all()
        if path
    ]
    # Delete private objects first. A storage failure must not silently orphan
    # user PDFs while the database project disappears.
    try:
        delete_files(storage_paths)
    except Exception as exc:
        raise HTTPException(502, "Could not remove project files") from exc
    db.delete(project)
    db.commit()
