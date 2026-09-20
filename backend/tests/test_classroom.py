import os
import unittest

os.environ["LLM_PROVIDER"] = "mock"
os.environ["DATABASE_URL"] = "sqlite:///:memory:"

from app.db import Base, SessionLocal, engine, init_db  # noqa: E402
from app.models import Project, Source  # noqa: E402
from app.services.classroom import (  # noqa: E402
    _parse_suggestions,
    prepare_lesson,
    suggest_topics,
    teach,
)
from app.services.ingest import ingest_source  # noqa: E402


class SuggestionParseTests(unittest.TestCase):
    def test_accepts_fenced_json(self):
        raw = '```json\n["Lead compensators", "Root locus", "Nyquist plots"]\n```'
        self.assertEqual(
            _parse_suggestions(raw),
            ["Lead compensators", "Root locus", "Nyquist plots"],
        )

    def test_rejects_short_or_duplicate_lists(self):
        self.assertEqual(_parse_suggestions('["one", "one", "two"]'), [])
        self.assertEqual(_parse_suggestions('["only two", "topics"]'), [])


class ClassroomServiceTests(unittest.TestCase):
    def setUp(self):
        Base.metadata.drop_all(bind=engine)
        init_db()
        self.db = SessionLocal()
        self.project = Project(name="ECE 358")
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

    def test_empty_project_has_no_suggestions(self):
        self.assertEqual(suggest_topics(self.db, self.project.id, self.project.name), [])

    def test_suggests_topics_from_sources(self):
        self._ready_source(
            "Lecture 4",
            "Lead compensators add phase. Lag compensators improve steady-state error. "
            "Root locus shows closed-loop pole movement.",
        )
        topics = suggest_topics(self.db, self.project.id, self.project.name)
        self.assertEqual(len(topics), 3)

    def test_teach_without_sources(self):
        response = teach(self.db, self.project.id, "control theory")
        self.assertIn("Add a relevant source", response.answer)
        self.assertEqual(response.citations, [])

    def test_teach_uses_course_material(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the transient response.",
        )
        response = teach(self.db, self.project.id, "lead compensators")
        self.assertTrue(response.answer)
        self.assertTrue(response.citations)
        self.assertIn("lead", response.answer.lower())

    def test_prepare_without_sources_is_out_of_scope(self):
        lesson = prepare_lesson(self.db, self.project.id, "control theory")
        self.assertFalse(lesson.in_scope)
        self.assertEqual(lesson.beats, [])
        self.assertEqual(lesson.grounding, "empty")

    def test_prepare_in_scope_returns_beats_and_passages(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the transient response.",
        )
        lesson = prepare_lesson(self.db, self.project.id, "lead compensators")
        self.assertTrue(lesson.in_scope)
        self.assertGreaterEqual(len(lesson.beats), 3)
        self.assertTrue(lesson.sources)
        self.assertTrue(lesson.passages)
        self.assertEqual(lesson.grounding, "full")
        self.assertTrue(all(beat.speaking for beat in lesson.beats))

    def test_prepare_unrelated_topic_is_out_of_scope(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the transient response.",
        )
        lesson = prepare_lesson(self.db, self.project.id, "basket weaving")
        self.assertFalse(lesson.in_scope)
        self.assertEqual(lesson.beats, [])
        self.assertTrue(lesson.reason)
