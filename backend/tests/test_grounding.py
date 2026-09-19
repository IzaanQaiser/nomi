import os
import unittest
from unittest.mock import patch

os.environ["LLM_PROVIDER"] = "mock"
os.environ["DATABASE_URL"] = "sqlite:///:memory:"

from app.db import Base, SessionLocal, engine, init_db  # noqa: E402
from app.models import Project, Source  # noqa: E402
from app.services.ingest import chunk_text, ingest_source  # noqa: E402
from app.services.llm.mock import MockProvider  # noqa: E402
from app.services.retrieval import gather_context  # noqa: E402
from app.services.shadow import analyze_work, _parse_analyze  # noqa: E402


class ChunkingTests(unittest.TestCase):
    def test_packs_paragraphs_and_overlap(self):
        text = "Intro\n\n" + ("alpha " * 40) + "\n\n" + ("beta " * 40)
        chunks = chunk_text(text, chunk_tokens=30, overlap=5)
        self.assertGreaterEqual(len(chunks), 2)
        self.assertTrue(any("alpha" in c for c in chunks))
        self.assertTrue(any("beta" in c for c in chunks))

    def test_empty(self):
        self.assertEqual(chunk_text("   \n\n", 80, 10), [])


class GroundingTests(unittest.TestCase):
    def setUp(self):
        Base.metadata.drop_all(bind=engine)
        init_db()
        self.db = SessionLocal()
        self.project = Project(name="Calc")
        self.db.add(self.project)
        self.db.commit()
        self.db.refresh(self.project)

    def tearDown(self):
        self.db.close()

    def _ready_source(self, title: str, body: str) -> Source:
        source = Source(
            project_id=self.project.id, kind="text", title=title, status="pending"
        )
        self.db.add(source)
        self.db.commit()
        self.db.refresh(source)
        ingest_source(self.db, source, body)
        self.db.refresh(source)
        self.assertEqual(source.status, "ready", source.error)
        return source

    def test_small_notebook_uses_full_context(self):
        self._ready_source(
            "Lecture 3",
            "The quadratic formula is x = (-b ± sqrt(b^2 - 4ac)) / 2a. "
            "Complete the square when a = 1.",
        )
        ctx = gather_context(
            self.db, self.project.id, "quadratic formula", MockProvider(), top_k=3
        )
        self.assertEqual(ctx.mode, "full")
        self.assertTrue(any("quadratic formula" in b for b in ctx.blocks))

    def test_large_notebook_retrieves_relevant_chunks(self):
        self._ready_source("Algebra", "Solve linear equations by isolating x. " * 20)
        self._ready_source(
            "Quadratics",
            "Use the quadratic formula x = (-b ± sqrt(b^2 - 4ac)) / 2a. " * 20,
        )
        fake = type("S", (), {"full_context_char_budget": 50, "top_k": 3})()
        with patch("app.services.retrieval.get_settings", return_value=fake):
            ctx = gather_context(
                self.db, self.project.id, "quadratic formula", MockProvider(), top_k=3
            )
        self.assertEqual(ctx.mode, "retrieval")
        blob = " ".join(ctx.blocks).lower()
        self.assertIn("quadratic", blob)

    def test_shadow_injects_sources_into_vision_prompt(self):
        self._ready_source(
            "Lecture 3",
            "When completing the square, move the constant first, then add (b/2)^2.",
        )
        resp = analyze_work(
            self.db,
            self.project.id,
            image_base64="dGVzdA==",
            problem_context="complete the square for x^2 + 6x = 7",
        )
        self.assertEqual(resp.status, "ok")
        self.assertEqual(resp.grounding, "full")
        self.assertIn("source grounding", resp.reasoning or "")
        self.assertIn("complete the square", resp.problem or "")

    def test_talk_silence_cuts_in(self):
        self._ready_source("Lecture 3", "Move the constant, then add (b/2)^2.")
        from app.services.shadow import talk_with_student
        resp = talk_with_student(
            self.db,
            self.project.id,
            image_base64="dGVzdA==",
            utterance="",
            problem_context="complete the square",
        )
        self.assertTrue(resp.reply)
        self.assertIn("paused", resp.reply.lower())

    def test_talk_stuck(self):
        self._ready_source("Lecture 3", "Move the constant, then add (b/2)^2.")
        from app.services.shadow import talk_with_student
        resp = talk_with_student(
            self.db,
            self.project.id,
            image_base64="dGVzdA==",
            utterance="hmm I'm stuck",
            problem_context="complete the square",
        )
        self.assertIn("step", resp.reply.lower())

    def test_empty_project_reports_empty_grounding(self):
        resp = analyze_work(
            self.db, self.project.id, image_base64="dGVzdA==", problem_context="anything"
        )
        self.assertEqual(resp.grounding, "empty")
        self.assertIn("no source context", resp.reasoning or "")

    def test_shadow_accepts_recent_context(self):
        self._ready_source(
            "Lecture 3",
            "When completing the square, move the constant first, then add (b/2)^2.",
        )
        resp = analyze_work(
            self.db,
            self.project.id,
            image_base64="dGVzdA==",
            problem_context="complete the square",
            recent_context=[
                "Watch: called out mistake — check the sign on (b/2)^2",
                "Student said: \"does this look right?\"",
            ],
        )
        self.assertEqual(resp.status, "ok")
        self.assertEqual(resp.grounding, "full")


class JsonParseTests(unittest.TestCase):
    def test_fenced_json(self):
        raw = '```json\n{"status": "interrupt", "hint": "check the sign", "reasoning": "x"}\n```'
        data = _parse_analyze(raw)
        self.assertEqual(data["status"], "interrupt")
        self.assertEqual(data["hint"], "check the sign")

    def test_format_recent_caps_lines(self):
        from app.services.shadow import _format_recent

        text = _format_recent(
            [f"line {i} " + ("x" * 300) for i in range(10)]
        )
        self.assertIn("Recent tutoring", text)
        # Soft cap keeps more than the old 5-line window.
        self.assertEqual(text.count("\n- "), 10)
        # Each bullet is truncated
        self.assertNotIn("x" * 250, text)


if __name__ == "__main__":
    unittest.main()
