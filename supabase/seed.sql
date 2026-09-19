-- Deterministic local-only data for schema and retrieval verification.

insert into public.projects (id, workspace_id, name)
values (
    '00000000000000000000000000000001',
    null,
    'Calculus Demo'
)
on conflict (id) do nothing;

insert into public.sources (
    id,
    project_id,
    workspace_id,
    kind,
    title,
    status
)
values (
    '00000000000000000000000000000002',
    '00000000000000000000000000000001',
    null,
    'text',
    'Derivative Rules',
    'ready'
)
on conflict (id) do nothing;

insert into public.notes (
    id,
    project_id,
    workspace_id,
    title,
    page_index,
    strokes_json
)
values (
    '00000000000000000000000000000003',
    '00000000000000000000000000000001',
    null,
    'Practice Page',
    0,
    '[]'
)
on conflict (id) do nothing;

insert into public.chunks (
    id,
    source_id,
    project_id,
    workspace_id,
    ordinal,
    content,
    embedding
)
values (
    '00000000000000000000000000000004',
    '00000000000000000000000000000002',
    '00000000000000000000000000000001',
    null,
    0,
    'The power rule says d/dx of x raised to n equals n times x raised to n minus one.',
    array_prepend(1::real, array_fill(0::real, array[767]))::extensions.vector(768)
)
on conflict (id) do nothing;
