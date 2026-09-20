import os
import unittest
from unittest.mock import patch

os.environ["LLM_PROVIDER"] = "mock"
os.environ["DATABASE_URL"] = "sqlite:///:memory:"

from app.db import Base, SessionLocal, engine, init_db  # noqa: E402
from app.models import Project, Source  # noqa: E402
from app.services.classroom import (  # noqa: E402
    _normalize_beats,
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


class SlideProtocolTests(unittest.TestCase):
    def test_valid_slides_are_parsed_and_indexed(self):
        beats = _normalize_beats(
            [
                {
                    "title": "The idea",
                    "speaking": "Here is the core definition from the notes.",
                    "slide": {
                        "layout": "concept",
                        "title": "Feedback",
                        "body": "Compare output with the reference.",
                    },
                },
                {
                    "title": "The picture",
                    "speaking": "A loop makes the relationship visible.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": "flowchart LR\n  Ref --> Plant --> Output",
                    },
                },
                {
                    "title": "The relation",
                    "speaking": "Write the transfer function next.",
                    "slide": {
                        "layout": "equation",
                        "title": "G(s)",
                        "equation": "G(s) = Y(s)/U(s)",
                    },
                },
                {
                    "title": "Check",
                    "speaking": "Restate the idea before we continue.",
                    "slide": {
                        "layout": "checkpoint",
                        "title": "Pause",
                        "question": "What does the plant do?",
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 4)
        self.assertEqual([beat.index for beat in beats], [0, 1, 2, 3])
        self.assertEqual(beats[0].slide.layout, "concept")
        self.assertEqual(beats[1].slide.layout, "diagram")
        self.assertIn("flowchart", beats[1].slide.mermaid)
        self.assertEqual(beats[2].slide.equation, "G(s) = Y(s)/U(s)")
        self.assertEqual(beats[3].slide.question, "What does the plant do?")
        self.assertTrue(all(beat.slide.title for beat in beats))

    def test_unsupported_layouts_and_board_payloads_are_dropped(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Old board beat",
                    "speaking": "This should not become a slide.",
                    "board": {
                        "kind": "diagram",
                        "actions": [
                            {
                                "type": "write_text",
                                "text": "Reference",
                                "position": {"x": 0.1, "y": 0.2},
                            }
                        ],
                    },
                },
                {
                    "title": "Unknown layout",
                    "speaking": "Drop malformed layouts instead of guessing.",
                    "slide": {"layout": "poster", "title": "Nope", "body": "x"},
                },
                {
                    "title": "Valid concept",
                    "speaking": "This one is usable.",
                    "slide": {
                        "layout": "concept",
                        "title": "Lead",
                        "body": "Adds phase.",
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 1)
        self.assertEqual(beats[0].title, "Valid concept")
        self.assertEqual(beats[0].slide.layout, "concept")

    def test_diagram_requires_usable_mermaid(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Empty diagram",
                    "speaking": "Missing mermaid should not survive.",
                    "slide": {"layout": "diagram", "title": "Loop"},
                },
                {
                    "title": "SVG diagram",
                    "speaking": "SVG is not mermaid.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": "<svg><rect/></svg>",
                    },
                },
                {
                    "title": "Coordinate dump",
                    "speaking": "Board commands are not mermaid.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": (
                            'flowchart LR\n  write_text {"reveal_at": 0.2}'
                        ),
                    },
                },
                {
                    "title": "Good diagram",
                    "speaking": "This flowchart is usable.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": "```mermaid\nflowchart LR\n  A --> B\n```",
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 1)
        self.assertEqual(beats[0].title, "Good diagram")
        self.assertTrue(beats[0].slide.mermaid.startswith("flowchart"))
        self.assertNotIn("```", beats[0].slide.mermaid)

    def test_equation_and_checkpoint_required_content_is_enforced(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Bare equation",
                    "speaking": "An equation slide needs an equation.",
                    "slide": {"layout": "equation", "title": "G(s)"},
                },
                {
                    "title": "Bare checkpoint",
                    "speaking": "A checkpoint needs a question.",
                    "slide": {"layout": "checkpoint", "title": "Check"},
                },
                {
                    "title": "Empty bullets",
                    "speaking": "Bullet slides need bullets.",
                    "slide": {"layout": "bullets", "title": "Points", "bullets": []},
                },
                {
                    "title": "Good equation",
                    "speaking": "Here is the transfer function.",
                    "slide": {
                        "layout": "equation",
                        "title": "G(s)",
                        "equation": "G(s) = K / s",
                    },
                },
                {
                    "title": "Good checkpoint",
                    "speaking": "Try this check.",
                    "slide": {
                        "layout": "checkpoint",
                        "title": "Check",
                        "question": "What does K do?",
                    },
                },
            ]
        )
        self.assertEqual([beat.title for beat in beats], ["Good equation", "Good checkpoint"])
        self.assertEqual(beats[0].slide.equation, "G(s) = K / s")
        self.assertEqual(beats[1].slide.question, "What does K do?")

    def test_beats_are_capped_and_fields_are_bounded(self):
        raw = [
            {
                "title": f"Beat {index}",
                "speaking": f"Narration {index} " + ("word " * 400),
                "slide": {
                    "layout": "bullets",
                    "title": "Title " + ("long " * 40),
                    "bullets": [f"point {n} " + ("x" * 200) for n in range(12)],
                    "body": "body " + ("y" * 500),
                },
            }
            for index in range(12)
        ]
        beats = _normalize_beats(raw)
        self.assertEqual(len(beats), 8)
        self.assertLessEqual(len(beats[0].speaking), 800)
        self.assertLessEqual(len(beats[0].slide.title), 80)
        self.assertLessEqual(len(beats[0].slide.body), 400)
        self.assertEqual(len(beats[0].slide.bullets), 6)
        self.assertLessEqual(len(beats[0].slide.bullets[0]), 140)


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
        self.assertEqual(
            suggest_topics(self.db, self.project.id, self.project.name), []
        )

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
            "A lead compensator increases phase margin and speeds the "
            "transient response.",
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

    def test_prepare_in_scope_returns_slide_beats_and_passages(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the "
            "transient response.",
        )
        lesson = prepare_lesson(self.db, self.project.id, "lead compensators")
        self.assertTrue(lesson.in_scope)
        self.assertEqual(lesson.lesson_protocol_version, 1)
        self.assertGreaterEqual(len(lesson.beats), 4)
        self.assertLessEqual(len(lesson.beats), 8)
        self.assertTrue(lesson.sources)
        self.assertTrue(lesson.citations)
        self.assertTrue(lesson.passages)
        self.assertEqual(lesson.grounding, "full")
        self.assertTrue(all(beat.speaking for beat in lesson.beats))
        self.assertTrue(all(beat.slide.layout for beat in lesson.beats))
        self.assertTrue(
            any(beat.slide.layout == "diagram" and beat.slide.mermaid for beat in lesson.beats)
        )
        payload = lesson.model_dump()
        self.assertNotIn("board_protocol_version", payload)
        self.assertFalse(any("board" in beat for beat in payload["beats"]))
        self.assertTrue(all("slide" in beat for beat in payload["beats"]))

    def test_prepare_rejects_too_few_usable_slides(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the "
            "transient response.",
        )
        with patch(
            "app.services.classroom._normalize_beats",
            return_value=[],
        ):
            lesson = prepare_lesson(self.db, self.project.id, "lead compensators")
        self.assertFalse(lesson.in_scope)
        self.assertEqual(lesson.beats, [])
        self.assertTrue(lesson.sources)

    def test_prepare_unrelated_topic_is_out_of_scope(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the "
            "transient response.",
        )
        lesson = prepare_lesson(self.db, self.project.id, "basket weaving")
        self.assertFalse(lesson.in_scope)
        self.assertEqual(lesson.beats, [])
        self.assertTrue(lesson.reason)
        self.assertTrue(lesson.sources)
        self.assertTrue(lesson.passages)
