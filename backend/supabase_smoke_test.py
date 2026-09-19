"""Exercise the backend against local Supabase Postgres, pgvector, and Storage.

Run from the repository root with:

    eval "$(supabase status -o env)"
    DATABASE_URL="$DB_URL" SUPABASE_URL="$API_URL" \
      SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
      RUN_SUPABASE_INTEGRATION=1 backend/.venv/bin/python backend/supabase_smoke_test.py
"""

from __future__ import annotations

import os

if os.environ.get("RUN_SUPABASE_INTEGRATION") != "1":
    raise SystemExit("Set RUN_SUPABASE_INTEGRATION=1 to run this destructive-cleanup smoke test")

os.environ["LLM_PROVIDER"] = "mock"
os.environ["FULL_CONTEXT_CHAR_BUDGET"] = "10"
for required in ("DATABASE_URL", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"):
    if not os.environ.get(required):
        raise SystemExit(f"Missing {required}")

from fastapi.testclient import TestClient

from app.db import SessionLocal
from app.main import app
from app.models import Source
from app.services.file_store import file_exists, read_file, save_pdf


def main() -> None:
    object_path: str | None = None
    project_id: str | None = None
    with TestClient(app) as client:
        project = client.post("/projects", json={"name": "Supabase smoke test"})
        project.raise_for_status()
        project_id = project.json()["id"]

        source = client.post(
            f"/projects/{project_id}/sources/text",
            json={
                "title": "Vector test",
                "content": (
                    "Gradient descent follows the negative gradient to minimize a loss function. "
                    * 20
                ),
            },
        )
        source.raise_for_status()
        assert source.json()["status"] == "ready", source.text

        chat = client.post(
            f"/projects/{project_id}/chat",
            json={"question": "How does gradient descent minimize loss?"},
        )
        chat.raise_for_status()
        assert chat.json()["citations"], chat.text

        object_path = save_pdf(project_id, "storage-check.pdf", b"%PDF-1.4\n% storage smoke test\n")
        assert read_file(object_path).startswith(b"%PDF-1.4")
        with SessionLocal() as db:
            db.add(
                Source(
                    project_id=project_id,
                    kind="pdf",
                    title="Storage cleanup test",
                    storage_path=object_path,
                    status="error",
                    error="Smoke fixture",
                )
            )
            db.commit()

        deleted = client.delete(f"/projects/{project_id}")
        assert deleted.status_code == 204, deleted.text
        assert client.get(f"/projects/{project_id}").status_code == 404
        assert not file_exists(object_path), "Project deletion left its Storage object behind"
    print("SUPABASE POSTGRES + PGVECTOR + PRIVATE STORAGE SMOKE TEST PASSED")


if __name__ == "__main__":
    main()
