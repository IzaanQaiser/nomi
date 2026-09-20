from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .db import init_db
from .routers import chat, exam, notes, projects, shadow, sources
from .routers.sources import recover_pending_sources


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    if not settings.uses_supabase_storage:
        os.makedirs(settings.storage_dir, exist_ok=True)
    init_db()
    recover_pending_sources()
    yield


app = FastAPI(title="AI Notes Backend", version="0.1.0", lifespan=lifespan)

# Permissive CORS for local dev (iPad simulator hitting localhost).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(projects.router)
app.include_router(sources.router)
app.include_router(notes.router)
app.include_router(chat.router)
app.include_router(shadow.router)
app.include_router(exam.router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "provider": get_settings().llm_provider}
