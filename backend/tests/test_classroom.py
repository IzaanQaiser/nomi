import os
import unittest
from unittest.mock import patch

os.environ["LLM_PROVIDER"] = "mock"
os.environ["DATABASE_URL"] = "sqlite:///:memory:"

from app.db import Base, SessionLocal, engine, init_db  # noqa: E402
from app.models import Project, Source  # noqa: E402
from app.schemas import ClassroomHistoryMessage  # noqa: E402
from app.services.classroom import (  # noqa: E402
    _normalize_beats,
    _parse_suggestions,
    prepare_lesson,
    suggest_topics,
    teach,
)
from app.services.ingest import ingest_source  # noqa: E402
from app.services.llm.mock import MockProvider  # noqa: E402

_NOTES = [
    "The first teaching point is a complete sentence a student can copy.",
    "The second teaching point names a consequence from the course notes.",
    "The third teaching point tells the student when this idea is used.",
    "The fourth teaching point contrasts this with the nearby wrong picture.",
    "The fifth teaching point is a check the student can say out loud.",
    "The sixth teaching point points back to the source instead of a slogan.",
]


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
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "The picture",
                    "speaking": "A loop makes the relationship visible.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": "flowchart LR\n  Ref --> Plant --> Output",
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "The relation",
                    "speaking": "Write the transfer function next.",
                    "slide": {
                        "layout": "equation",
                        "title": "G(s)",
                        "equation": "G(s) = Y(s)/U(s)",
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "Check",
                    "speaking": "Restate the idea before we continue.",
                    "slide": {
                        "layout": "checkpoint",
                        "title": "Pause",
                        "question": "What does the plant do?",
                        "bullets": _NOTES,
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 4)
        self.assertEqual([beat.index for beat in beats], [0, 1, 2, 3])
        self.assertEqual(beats[0].slide.layout, "concept")
        self.assertEqual(beats[1].slide.layout, "bullets")
        self.assertEqual(beats[1].slide.mermaid, "")
        self.assertEqual(beats[2].slide.equation, "G(s) = Y(s)/U(s)")
        self.assertEqual(beats[3].slide.question, "What does the plant do?")
        self.assertTrue(all(beat.slide.title for beat in beats))
        self.assertTrue(all(len(beat.slide.bullets) >= 5 for beat in beats))

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
                        "bullets": _NOTES,
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 1)
        self.assertEqual(beats[0].title, "Valid concept")
        self.assertEqual(beats[0].slide.layout, "concept")
        self.assertEqual(len(beats[0].slide.bullets), 6)

    def test_diagram_slides_become_bullet_slides(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Empty diagram",
                    "speaking": "A diagram with no notes should not survive.",
                    "slide": {"layout": "diagram", "title": "Loop"},
                },
                {
                    "title": "Good diagram",
                    "speaking": "This used to be a flowchart slide.",
                    "slide": {
                        "layout": "diagram",
                        "title": "Loop",
                        "mermaid": "```mermaid\nflowchart LR\n  A --> B\n```",
                        "bullets": _NOTES,
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 1)
        self.assertEqual(beats[0].title, "Good diagram")
        self.assertEqual(beats[0].slide.layout, "bullets")
        self.assertEqual(beats[0].slide.mermaid, "")
        self.assertGreaterEqual(len(beats[0].slide.bullets), 5)

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
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "Good checkpoint",
                    "speaking": "Try this check.",
                    "slide": {
                        "layout": "checkpoint",
                        "title": "Check",
                        "question": "What does K do?",
                        "bullets": _NOTES,
                    },
                },
            ]
        )
        self.assertEqual([beat.title for beat in beats], ["Good equation", "Good checkpoint"])
        self.assertEqual(beats[0].slide.equation, "G(s) = K / s")
        self.assertEqual(beats[1].slide.question, "What does K do?")
        self.assertGreaterEqual(len(beats[0].slide.bullets), 5)
        self.assertGreaterEqual(len(beats[1].slide.bullets), 5)

    def test_label_bullets_become_full_sentences(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Loop",
                    "speaking": "Walk through the loop using the notes.",
                    "slide": {
                        "layout": "concept",
                        "title": "The Feedback Loop",
                        "bullets": [
                            "Input: Desired output",
                            "Output: Measured output",
                            "Error: Difference between input and output",
                            "Plant: System being controlled",
                            "Feedback: Path that closes the loop",
                        ],
                    },
                }
            ]
        )
        self.assertEqual(len(beats), 1)
        bullets = beats[0].slide.bullets
        self.assertGreaterEqual(len(bullets), 5)
        for bullet in bullets:
            self.assertGreaterEqual(len(bullet.split()), 6)
            self.assertTrue(bullet.endswith("."))
            self.assertFalse(
                bullet.lower().startswith(("input:", "output:", "error:"))
            )
        self.assertTrue(any("desired output" in bullet.lower() for bullet in bullets))

    def test_every_layout_keeps_teaching_bullets(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Title",
                    "speaking": "Here is the map for the lesson.",
                    "slide": {"layout": "title", "title": "Lead", "bullets": _NOTES},
                },
                {
                    "title": "Equation",
                    "speaking": "Here is the relation.",
                    "slide": {
                        "layout": "equation",
                        "title": "G(s)",
                        "equation": "G(s) = K / s",
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "Concept",
                    "speaking": "Here is the idea.",
                    "slide": {
                        "layout": "concept",
                        "title": "Lead",
                        "body": "Adds phase near crossover.",
                        "bullets": _NOTES,
                    },
                },
                {
                    "title": "Steps",
                    "speaking": "Here is the method.",
                    "slide": {
                        "layout": "steps",
                        "title": "Method",
                        "steps": ["Find crossover", "Add phase", "Check margin"],
                        "bullets": _NOTES,
                    },
                },
            ]
        )
        self.assertEqual(len(beats), 4)
        for beat in beats:
            self.assertEqual(beat.slide.bullets, _NOTES)

    def test_missing_bullets_are_recovered_from_other_slide_text(self):
        beats = _normalize_beats(
            [
                {
                    "title": "Recovered concept",
                    "speaking": "The body still has the teaching points.",
                    "slide": {
                        "layout": "concept",
                        "title": "Feedback",
                        "body": (
                            "Feedback compares output with the reference. "
                            "The error is what the controller actually sees. "
                            "Without that comparison, the loop is open. "
                            "The plant turns the command into a measured output. "
                            "A later path can send that output back for comparison."
                        ),
                    },
                },
                {
                    "title": "Title with no notes",
                    "speaking": "A title slide still needs teaching bullets.",
                    "slide": {"layout": "title", "title": "Lead compensators"},
                },
            ]
        )
        self.assertEqual(len(beats), 1)
        self.assertEqual(beats[0].title, "Recovered concept")
        self.assertGreaterEqual(len(beats[0].slide.bullets), 5)

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
        self.assertLessEqual(len(beats[0].slide.bullets[0]), 220)


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

    def test_teach_uses_current_slide_context_and_history(self):
        self._ready_source(
            "Compensators",
            "A lead compensator increases phase margin and speeds the "
            "transient response.",
        )
        captured: dict[str, str] = {}

        class CapturingProvider(MockProvider):
            def chat(self, system, user, *, json_mode=False, json_schema=None):
                captured["system"] = system
                captured["user"] = user
                return super().chat(
                    system, user, json_mode=json_mode, json_schema=json_schema
                )

        with patch(
            "app.services.classroom.get_provider",
            return_value=CapturingProvider(),
        ):
            response = teach(
                self.db,
                self.project.id,
                "why does the zero matter?",
                history=[
                    ClassroomHistoryMessage(
                        role="user", content="What is a lead compensator?"
                    ),
                    ClassroomHistoryMessage(
                        role="assistant",
                        content="It adds a zero and a farther pole to add phase.",
                    ),
                ],
                prompt_context=(
                    "Lesson topic: lead compensators\n"
                    "Current beat: The relation\n"
                    "Current slide layout: equation\n"
                    "Current slide title: Key relation\n"
                    "Slide equation: G(s) = K (s + z) / (s + p)\n"
                    "Current narration: Apply it to one example from the notes."
                ),
            )
        self.assertTrue(response.answer)
        self.assertTrue(response.citations)
        self.assertIn("interrupted", captured["system"])
        self.assertIn("do not restart", captured["system"].lower())
        self.assertIn("Student question: why does the zero matter?", captured["user"])
        self.assertIn("Current slide title: Key relation", captured["user"])
        self.assertIn("Slide equation: G(s) = K (s + z) / (s + p)", captured["user"])
        self.assertIn("What is a lead compensator?", captured["user"])
        self.assertNotIn("board.actions", captured["user"])
        self.assertNotIn("reveal_at", captured["user"])

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
        self.assertTrue(all(len(beat.slide.bullets) >= 5 for beat in lesson.beats))
        self.assertFalse(any(beat.slide.layout == "diagram" for beat in lesson.beats))
        self.assertFalse(any(beat.slide.mermaid for beat in lesson.beats))
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
