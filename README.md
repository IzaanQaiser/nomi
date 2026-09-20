# Nomi

> A quieter way to learn.

Nomi is an iPad-first learning workspace that turns a student's own course
material into organized projects, handwritten notebooks, grounded study tools,
and narrated classroom lessons.

Instead of acting like a generic chatbot, Nomi works inside a project. Every
answer, lesson, exam, and tutoring interaction is scoped to the PDFs, DOCX files,
images, and notes that belong to that project.

## What Nomi does

- **Projects** keep each course or subject isolated, with its own notebooks and
  source material.
- **Notebooks** provide a native PencilKit canvas for handwritten study notes.
- **Project context** ingests `.pdf`, `.docx`, and `.png` files, chunks their
  content, embeds it once, and retrieves only relevant passages later.
- **Classroom** builds a source-grounded slide lesson, narrates it, advances the
  slides automatically, and lets the student pause to ask Nomi a question.
- **Exam prep** generates and grades practice exams from the active project's
  material.
- **Shadow tutoring** can inspect the current work and give a short nudge without
  immediately revealing the solution.
- **Grounded chat** answers questions with citations back to the project's real
  sources.

The product is designed around one constraint: AI should stay close to the
student's work and course material instead of becoming a separate destination.

## Product flow

```mermaid
flowchart LR
    A[Create a project] --> B[Add course sources]
    B --> C[Take handwritten notes]
    B --> D[Start a Classroom lesson]
    B --> E[Generate a practice exam]
    C --> F[Ask or enable Shadow tutoring]
    D --> G[Pause and ask Nomi]
    F --> H[Grounded response]
    G --> H
    E --> H
```

## Architecture

```mermaid
flowchart TB
    subgraph iPad[SwiftUI iPad app]
        Projects[Projects and sources]
        Notes[PencilKit notebooks]
        Classroom[Narrated Classroom]
        Exams[Exam prep]
        Shadow[Shadow tutor]
    end

    API[FastAPI API]
    Retrieval[Project-scoped retrieval]
    Provider[LLM provider\nOpenAI · Gemini · Mock]
    DB[(Postgres + pgvector\nor local SQLite)]
    Files[(Supabase Storage\nor local files)]

    Projects & Notes & Classroom & Exams & Shadow --> API
    API --> Retrieval
    Retrieval --> DB
    API --> Files
    API --> Provider
    Provider --> API
```

The iOS client never receives database credentials or an LLM API key. It talks
only to the FastAPI service over HTTP(S). The backend owns ingestion, retrieval,
model calls, storage, and project isolation.

## Repository layout

```text
.
├── backend/                 FastAPI app, retrieval, providers, and tests
│   ├── app/
│   │   ├── routers/         HTTP endpoints
│   │   ├── services/        Classroom, exam, RAG, Shadow, and ingestion logic
│   │   └── services/llm/    OpenAI, Gemini, and deterministic mock providers
│   └── tests/
├── ios/                     Native iPad app
│   ├── Sources/AINotes/
│   │   ├── App/             App shell, onboarding, and shared styling
│   │   ├── Features/        Projects, notes, Classroom, exams, and Shadow
│   │   └── Networking/      API client and wire DTOs
│   ├── AINotes.xcodeproj/
│   └── project.yml          XcodeGen project definition
├── supabase/                Postgres/pgvector schema and local Supabase config
├── docs/                    Static product site deployed with GitHub Pages
└── Dockerfile               Production backend image from the repo root
```

## Stack

| Layer | Technology |
| --- | --- |
| iPad app | SwiftUI, PencilKit, PDFKit, AVFoundation, Speech |
| API | Python 3.11, FastAPI, Pydantic, SQLAlchemy |
| Retrieval | Project-scoped chunking, embeddings, cosine similarity, pgvector |
| Production data | Supabase Postgres + private Storage |
| Local data | SQLite + local file storage |
| AI providers | OpenAI, Gemini, or deterministic mock |
| Deployment | Docker, Railway-compatible runtime, GitHub Pages for `docs/` |

## Quick start

### Prerequisites

- macOS with Xcode and the iOS 17 SDK
- Python 3.11+
- An LLM key for real model behavior, or no key when using the mock provider
- Optional: XcodeGen if you change `ios/project.yml`
- Optional: Supabase CLI for the complete local production-style stack

### 1. Run the backend

```bash
git clone https://github.com/IzaanQaiser/nomi.git
cd nomi/backend

python3 -m venv .venv
source .venv/bin/activate
pip install --only-binary=:all: -r requirements.txt

cp .env.example .env
# LLM_PROVIDER=mock works without external credentials.

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Confirm it is healthy:

```bash
curl http://localhost:8000/health
```

Then open [http://localhost:8000/docs](http://localhost:8000/docs) for the
interactive OpenAPI documentation.

### 2. Run the iPad app

1. Open `ios/AINotes.xcodeproj` in Xcode.
2. Select the `AINotes` scheme.
3. Choose an iPad simulator or a provisioned physical iPad.
4. Build and run.

The simulator can use `http://localhost:8000`. A physical iPad should use a
stable HTTPS deployment. The app's backend URL can be changed at runtime from
Backend Settings, so switching environments does not require rebuilding.

If `ios/project.yml` changes, regenerate the checked-in project with:

```bash
cd ios
xcodegen generate
```

## Configuration

Copy `backend/.env.example` to `backend/.env`. Never commit the resulting file.

### Local, keyless development

```dotenv
LLM_PROVIDER=mock
DATABASE_URL=sqlite:///./ainotes.db
STORAGE_DIR=./storage
```

The mock provider is deterministic and is the fastest way to exercise API and
UI plumbing without spending tokens or depending on an external service.

### OpenAI

```dotenv
LLM_PROVIDER=openai
OPENAI_API_KEY=...
OPENAI_EMBED_MODEL=text-embedding-3-small
OPENAI_CHAT_MODEL=gpt-4o-mini
OPENAI_VISION_MODEL=gpt-4o-mini
EMBED_DIM=768
```

### Gemini

```dotenv
LLM_PROVIDER=gemini
GEMINI_API_KEY=...
GEMINI_EMBED_MODEL=gemini-embedding-001
GEMINI_CHAT_MODEL=gemini-2.5-flash
GEMINI_VISION_MODEL=gemini-2.5-flash
EMBED_DIM=768
```

Do not change embedding providers or dimensions for an existing collection
without re-ingesting its sources. Stored vectors must match the active embedding
model.

### Supabase production data

```dotenv
DATABASE_URL=postgresql://postgres.PROJECT_REF:DB_PASSWORD@POOLER_HOST:6543/postgres
SUPABASE_URL=https://PROJECT_REF.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
SUPABASE_STORAGE_BUCKET=sources
```

The service-role key belongs only in the backend environment. Apply the SQL in
`supabase/migrations/` before starting the API against Postgres.

## How grounding works

1. A source is uploaded to one project.
2. The backend extracts its text, creates overlapping chunks, and stores an
   embedding for each chunk.
3. At request time, the backend embeds the question and retrieves only chunks
   with the same `project_id`.
4. Retrieved text is sent to the configured model with the current task's
   instructions.
5. APIs return citations or source metadata built from real database rows.

`project_id` is stored directly on every chunk and is always part of retrieval.
That is the primary boundary preventing material from one course from leaking
into another.

## Classroom

Classroom turns a topic into a deterministic lesson protocol rather than asking
the iPad to render arbitrary model output.

- `GET /projects/{project_id}/classroom/suggestions` proposes three short topics
  from the project's sources.
- `POST /projects/{project_id}/classroom/prepare` validates scope and returns a
  bounded sequence of narrated slide beats.
- The iPad renders those beats with native SwiftUI layouts and advances as
  narration completes.
- `POST /projects/{project_id}/classroom/teach` answers a student's interruption
  using the current slide, recent exchange history, and project context.

Slides use a small, validated layout vocabulary (`title`, `concept`, `equation`,
`bullets`, `steps`, and `checkpoint`). Unknown or malformed model fields do not
become executable UI.

## API overview

| Area | Endpoints |
| --- | --- |
| Health | `GET /health` |
| Projects | `GET/POST /projects`, `GET/PATCH/DELETE /projects/{id}` |
| Sources | `GET /projects/{id}/sources`, `POST .../text`, `POST .../file`, `DELETE .../{source_id}` |
| Source files | `GET /projects/{id}/sources/{source_id}/file` |
| Notes | `GET/PUT /projects/{id}/notes` |
| Grounded chat | `POST /projects/{id}/chat` |
| Classroom | `GET .../classroom/suggestions`, `POST .../prepare`, `POST .../teach` |
| Shadow tutor | `POST .../shadow`, `POST .../shadow/talk`, `POST .../shadow/solution` |
| Exams | `POST .../exam/generate`, `POST .../exam/grade` |

The generated FastAPI docs are the source of truth for request and response
bodies.

## Tests and verification

Run backend tests:

```bash
cd backend
source .venv/bin/activate
pytest -q
```

Run the backend smoke test:

```bash
cd backend
source .venv/bin/activate
python smoke_test.py
```

Build the iOS target without code signing:

```bash
xcodebuild \
  -project ios/AINotes.xcodeproj \
  -scheme AINotes \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a production-style Supabase integration check, see
[`backend/README.md`](backend/README.md).

## Deployment

The root `Dockerfile` builds only the API and is suitable for Railway or another
container platform:

```bash
docker build -t nomi-backend .
docker run --env-file backend/.env -p 8000:8000 nomi-backend
```

In production:

1. Configure the provider and Supabase variables in the host's secret manager.
2. Deploy the root Dockerfile.
3. Verify `/health` and one project-scoped source request.
4. Set the iOS `BackendBaseURL` or save the URL in Backend Settings.
5. Never ship provider, database, or Supabase service-role secrets in the app.

## Development notes

- The repository intentionally keeps a mock provider so core flows remain
  testable when external AI services are unavailable.
- The checked-in Xcode project is the file Xcode builds; `ios/project.yml` is
  its XcodeGen source definition.
- Local SQLite tables are created automatically. Hosted Postgres is migration
  owned and fails fast if the expected schema is unavailable.
- Source deletion removes its chunks and stored file through the backend; do not
  manipulate production storage independently of the API.
- Existing uncommitted work may be present during active development. Keep
  changes scoped and do not reset unrelated files.

## Project status

Nomi is under active development. APIs and lesson protocols may evolve while
the product is being shaped. When changing a backend response, update its Swift
DTO in the same change and preserve optional decoding where older deployments
may still be in flight.
