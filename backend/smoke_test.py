"""End-to-end smoke test using FastAPI's TestClient (mock provider, no key).

Run: python smoke_test.py
"""

from __future__ import annotations

import os
import tempfile

# Use a throwaway DB/storage so the test is isolated.
_tmp = tempfile.mkdtemp(prefix="ainotes_smoke_")
os.environ["DATABASE_URL"] = f"sqlite:///{_tmp}/smoke.db"
os.environ["STORAGE_DIR"] = f"{_tmp}/storage"
os.environ["LLM_PROVIDER"] = "mock"

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


def main() -> None:
    with TestClient(app) as client:
        assert client.get("/health").json()["provider"] == "mock"

        # Create project
        proj = client.post("/projects", json={"name": "6.006 Algorithms"}).json()
        pid = proj["id"]
        print("created project", pid)

        # Add a text source and wait for background ingestion.
        src = client.post(
            f"/projects/{pid}/sources/text",
            json={
                "title": "Amortized Analysis",
                "content": (
                    "Amortized analysis averages the running time of operations "
                    "over a worst-case sequence. The aggregate method, the "
                    "accounting method, and the potential method are three "
                    "techniques. Dynamic array append is O(1) amortized."
                ),
            },
        ).json()
        print("source status after enqueue:", src["status"])

        # Background task runs within the TestClient request lifecycle.
        src = client.get(f"/projects/{pid}/sources/{src['id']}").json()
        print("source status now:", src["status"])
        assert src["status"] == "ready", src

        # Ask a grounded question -> should retrieve and cite.
        resp = client.post(
            f"/projects/{pid}/chat",
            json={"question": "What is amortized analysis?"},
        ).json()
        print("answer:", resp["answer"][:120])
        assert resp["citations"], "expected citations"
        assert resp["citations"][0]["source_title"] == "Amortized Analysis"

        # Disjoint context: a second project has no sources -> no leakage.
        proj2 = client.post("/projects", json={"name": "Empty Course"}).json()
        resp2 = client.post(
            f"/projects/{proj2['id']}/chat",
            json={"question": "What is amortized analysis?"},
        ).json()
        assert resp2["citations"] == [], "empty project must not see other sources"
        print("disjoint-context check passed")

        # Notes upsert round-trip.
        note = client.put(
            f"/projects/{pid}/notes",
            json={"title": "Lecture 4", "page_index": 0, "strokes_json": "BASE64=="},
        ).json()
        assert note["title"] == "Lecture 4"
        print("note saved", note["id"])

        # Shadow endpoint: mock returns ok AND reports that sources were injected.
        shadow = client.post(
            f"/projects/{pid}/shadow",
            json={"image_base64": "iVBOR", "problem_context": "amortized analysis of arrays"},
        ).json()
        assert shadow["status"] == "ok"
        assert shadow["grounding"] == "full"
        assert "source grounding" in (shadow.get("reasoning") or "")
        print("shadow status:", shadow["status"], "grounding:", shadow["grounding"])

    print("\nALL SMOKE TESTS PASSED")


if __name__ == "__main__":
    main()
