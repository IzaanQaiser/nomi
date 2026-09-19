-- AI Notes initial Supabase schema.
-- IDs remain text so the current FastAPI response contracts do not change.

create extension if not exists vector with schema extensions;

create table public.projects (
    id text primary key default replace(gen_random_uuid()::text, '-', ''),
    workspace_id uuid null,
    name text not null check (length(trim(name)) > 0),
    created_at timestamptz not null default now()
);

create table public.sources (
    id text primary key default replace(gen_random_uuid()::text, '-', ''),
    project_id text not null references public.projects(id) on delete cascade,
    workspace_id uuid null,
    kind text not null check (kind in ('pdf', 'text')),
    title text not null check (length(trim(title)) > 0),
    storage_path text null,
    status text not null default 'pending' check (status in ('pending', 'ready', 'error')),
    error text null,
    created_at timestamptz not null default now(),
    constraint pdf_sources_have_storage_path
        check (kind <> 'pdf' or storage_path is not null)
);

create table public.notes (
    id text primary key default replace(gen_random_uuid()::text, '-', ''),
    project_id text not null references public.projects(id) on delete cascade,
    workspace_id uuid null,
    title text not null default 'Untitled',
    page_index integer not null default 0 check (page_index >= 0),
    strokes_json text not null default '',
    updated_at timestamptz not null default now()
);

create table public.chunks (
    id text primary key default replace(gen_random_uuid()::text, '-', ''),
    source_id text not null references public.sources(id) on delete cascade,
    project_id text not null references public.projects(id) on delete cascade,
    workspace_id uuid null,
    ordinal integer not null default 0 check (ordinal >= 0),
    content text not null check (length(content) > 0),
    embedding extensions.vector(768) not null,
    constraint chunks_source_ordinal_unique unique (source_id, ordinal)
);

create index projects_workspace_id_idx on public.projects(workspace_id);
create index projects_created_at_idx on public.projects(created_at desc);

create index sources_project_id_idx on public.sources(project_id);
create index sources_workspace_id_idx on public.sources(workspace_id);
create index sources_project_status_idx on public.sources(project_id, status);

create index notes_project_id_idx on public.notes(project_id);
create index notes_workspace_id_idx on public.notes(workspace_id);
create index notes_project_page_idx on public.notes(project_id, page_index);

create index chunks_source_id_idx on public.chunks(source_id);
create index chunks_project_id_idx on public.chunks(project_id);
create index chunks_workspace_id_idx on public.chunks(workspace_id);
create index chunks_project_source_idx on public.chunks(project_id, source_id);
create index chunks_embedding_hnsw_idx
    on public.chunks using hnsw (embedding extensions.vector_cosine_ops);

-- Keep note timestamps correct even if a future client writes directly.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger notes_set_updated_at
before update on public.notes
for each row execute function public.set_updated_at();

-- Backend-facing similarity query. Retrieval is always scoped to a project.
create or replace function public.match_chunks(
    query_embedding extensions.vector(768),
    match_project_id text,
    match_count integer default 5
)
returns table (
    id text,
    source_id text,
    project_id text,
    ordinal integer,
    content text,
    similarity double precision
)
language sql
stable
set search_path = ''
as $$
    select
        c.id,
        c.source_id,
        c.project_id,
        c.ordinal,
        c.content,
        1 - (c.embedding operator(extensions.<=>) query_embedding) as similarity
    from public.chunks c
    join public.sources s on s.id = c.source_id
    where c.project_id = match_project_id
      and s.project_id = match_project_id
      and s.status = 'ready'
    order by c.embedding operator(extensions.<=>) query_embedding
    limit least(greatest(match_count, 1), 50);
$$;

-- Block direct anonymous Data API access until app accounts and policies exist.
alter table public.projects enable row level security;
alter table public.sources enable row level security;
alter table public.notes enable row level security;
alter table public.chunks enable row level security;

-- Original PDFs live in a private Storage bucket; Postgres stores their paths.
insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'sources',
    'sources',
    false,
    52428800,
    array['application/pdf']::text[]
)
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;
