from __future__ import annotations

import os
import uuid
from functools import lru_cache
from pathlib import Path

from supabase import Client, create_client

from ..config import get_settings


def _safe_filename(filename: str) -> str:
    name = Path(filename or "upload.pdf").name
    return "".join(c if c.isalnum() or c in ".-_" else "_" for c in name)


@lru_cache
def _supabase() -> Client:
    settings = get_settings()
    if not settings.uses_supabase_storage:
        raise RuntimeError("Supabase Storage is not configured")
    return create_client(settings.supabase_url, settings.supabase_service_role_key)


def save_source_file(
    project_id: str, filename: str, content: bytes, content_type: str
) -> str:
    settings = get_settings()
    object_path = f"{project_id}/{uuid.uuid4().hex}_{_safe_filename(filename)}"
    if settings.uses_supabase_storage:
        _supabase().storage.from_(settings.supabase_storage_bucket).upload(
            path=object_path,
            file=content,
            file_options={"content-type": content_type, "upsert": "false"},
        )
        return object_path

    path = Path(settings.storage_dir) / object_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return str(path)


def save_pdf(project_id: str, filename: str, content: bytes) -> str:
    """Backward-compatible wrapper for older callers."""
    return save_source_file(project_id, filename, content, "application/pdf")


def read_file(storage_path: str) -> bytes:
    settings = get_settings()
    if settings.uses_supabase_storage:
        return _supabase().storage.from_(settings.supabase_storage_bucket).download(storage_path)
    path = Path(storage_path).resolve()
    root = Path(settings.storage_dir).resolve()
    if not path.is_relative_to(root):
        raise ValueError("Local storage path is outside STORAGE_DIR")
    return path.read_bytes()


def file_exists(storage_path: str) -> bool:
    """Check authoritative object metadata (downloads may briefly hit a cache)."""
    settings = get_settings()
    if settings.uses_supabase_storage:
        path = Path(storage_path)
        rows = _supabase().storage.from_(settings.supabase_storage_bucket).list(
            path=str(path.parent) if str(path.parent) != "." else None,
            options={"search": path.name},
        )
        return any(row.get("name") == path.name for row in rows)
    path = Path(storage_path).resolve()
    root = Path(settings.storage_dir).resolve()
    return path.is_relative_to(root) and path.is_file()


def delete_files(storage_paths: list[str]) -> None:
    paths = [path for path in storage_paths if path]
    if not paths:
        return
    settings = get_settings()
    if settings.uses_supabase_storage:
        _supabase().storage.from_(settings.supabase_storage_bucket).remove(paths)
        return
    for path in paths:
        resolved = Path(path).resolve()
        root = Path(settings.storage_dir).resolve()
        if not resolved.is_relative_to(root):
            raise ValueError("Local storage path is outside STORAGE_DIR")
        try:
            os.remove(resolved)
        except FileNotFoundError:
            pass
