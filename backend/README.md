# AI Notes Backend (FastAPI)

RAG backend for the AI note-taking app. Projects hold disjoint sources; chat is
always scoped to a single project, so context never leaks across projects.

## Quick start

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install --only-binary=:all: -r requirements.txt

# Runs keyless with a deterministic mock LLM provider by default.
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Open http://localhost:8000/docs for the interactive API.

## Stable iPad connection

Do not hardcode a Mac or hotspot IP in the app. For a physical device, deploy
this directory to a container host and give it one stable HTTPS URL. A generic
`Dockerfile` is included and works with services such as Railway, Render, Fly,
or a VM/container platform.

Configure these environment variables on the host:

```text
LLM_PROVIDER=openai
OPENAI_API_KEY=...
OPENAI_EMBED_MODEL=text-embedding-3-small
OPENAI_CHAT_MODEL=gpt-4o-mini
OPENAI_VISION_MODEL=gpt-4o-mini
EMBED_DIM=768
DATABASE_URL=postgresql://postgres.PROJECT_REF:DB_PASSWORD@POOLER_HOST:6543/postgres
SUPABASE_URL=https://PROJECT_REF.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
SUPABASE_STORAGE_BUCKET=sources
```

The service-role key stays on the backend. The iPad only calls the backend's
HTTPS URL and never receives database credentials. SQLite and local files stay
available as the zero-config development/test fallback.

After deployment, open **Backend Settings** in the iPad app, paste the HTTPS
URL, and tap **Save and Test Connection**. The saved URL can be changed without
rebuilding the app. A release build may alternatively set `BackendBaseURL` in
its Info.plist/build configuration.

### Using a real LLM

```bash
cp .env.example .env
# set LLM_PROVIDER=openai and OPENAI_API_KEY=sk-...
```

## Smoke test

```bash
source .venv/bin/activate
python smoke_test.py
```

To verify the complete local Supabase path (Postgres, pgvector, private Storage,
and deletion cleanup), start Supabase and run:

```bash
eval "$(supabase status -o env)"
DATABASE_URL="$DB_URL" SUPABASE_URL="$API_URL" \
  SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" RUN_SUPABASE_INTEGRATION=1 \
  .venv/bin/python supabase_smoke_test.py
```

Existing SQLite data can be imported once after the production variables are
configured:

```bash
.venv/bin/python migrate_sqlite_to_supabase.py --source ainotes.db
```

## Endpoints

- `GET  /health`
- `GET/POST /projects`, `GET/DELETE /projects/{id}`
- `GET /projects/{id}/sources`, `POST .../sources/text`, `POST .../sources/pdf`
- `GET/PUT /projects/{id}/notes`
- `POST /projects/{id}/chat` -> grounded answer + citations
- `GET /projects/{id}/classroom/suggestions` -> three course-grounded topic names
- `POST /projects/{id}/classroom/prepare` -> in-scope lesson plan (beats, sources, passages)
- `POST /projects/{id}/classroom/teach` -> a short spoken answer about the current slide, with optional history and lesson `prompt_context`
- `POST /projects/{id}/shadow` -> live tutor analysis (image + context)

### Classroom lesson protocol v1

`classroom/prepare` returns `lesson_protocol_version: 1`. Every in-scope lesson
has 4 to 8 beats. Each beat contains spoken narration (`speaking`) and a
deterministic `slide` with a layout of `title`, `concept`, `equation`,
`bullets`, `steps`, `diagram`, or `checkpoint`. Every slide, including title
pages, must carry 3 to 5 teaching bullets in `slide.bullets`. Diagram slides
require Mermaid syntax (`flowchart`, `stateDiagram`, or `sequenceDiagram`).
Equation slides require an equation and checkpoint slides require a question.
The server sanitizes bounded fields, fills missing bullets from other slide
text when possible, and drops malformed or coordinate-based board output
before returning the lesson. Out-of-scope topics return no beats.

## Architecture notes

- `app/services/vector_store.py` uses indexed pgvector cosine search on Postgres
  and retains exact NumPy search only for SQLite development/tests.
- `app/services/llm/` is a provider abstraction: `mock` (keyless, deterministic)
  and `openai`. Add others by implementing `LLMProvider`.
- Every `chunk` row carries `project_id`; retrieval filters on it, guaranteeing
  disjoint context between projects.
