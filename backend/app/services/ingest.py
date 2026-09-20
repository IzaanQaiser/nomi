from __future__ import annotations

import base64
import re
from io import BytesIO
from xml.etree import ElementTree
from zipfile import BadZipFile, ZipFile

from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import Chunk, Source
from .llm import get_provider
from .vector_store import embedding_for_db

_HEADING_RE = re.compile(r"^(#{1,6}\s+|[A-Z][A-Z0-9 .,:;/\-]{8,}$)")
_WS_RE = re.compile(r"[ \t]+")


def extract_pdf_text(document: str | bytes) -> str:
    from pypdf import PdfReader

    reader = PdfReader(BytesIO(document) if isinstance(document, bytes) else document)
    parts = [(page.extract_text() or "") for page in reader.pages]
    return "\n\n".join(parts)


def extract_docx_text(document: bytes) -> str:
    """Extract paragraph text from a Word document without executing macros."""
    try:
        with ZipFile(BytesIO(document)) as archive:
            if archive.getinfo("word/document.xml").file_size > 10 * 1024 * 1024:
                raise ValueError("DOCX document text is too large")
            xml = archive.read("word/document.xml")
    except (BadZipFile, KeyError) as exc:
        raise ValueError("Invalid DOCX document") from exc

    root = ElementTree.fromstring(xml)
    namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    paragraphs: list[str] = []
    for paragraph in root.findall(".//w:p", namespace):
        text = "".join(node.text or "" for node in paragraph.findall(".//w:t", namespace))
        if text.strip():
            paragraphs.append(text.strip())
    return "\n\n".join(paragraphs)


def extract_png_text(document: bytes) -> str:
    """Use the configured vision provider as OCR for an uploaded PNG."""
    if not document.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Invalid PNG image")
    return get_provider().vision(
        "You are a precise OCR system. Return only the legible text in reading order.",
        "Transcribe every legible word, equation, heading, and label in this image. "
        "Do not summarize or add commentary.",
        base64.b64encode(document).decode("ascii"),
    ).strip()


def extract_source_text(kind: str, document: bytes) -> str:
    if kind == "pdf":
        return extract_pdf_text(document)
    if kind == "docx":
        return extract_docx_text(document)
    if kind == "png":
        return extract_png_text(document)
    raise ValueError(f"Unsupported source kind: {kind}")


def _normalize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [_WS_RE.sub(" ", line).strip() for line in text.split("\n")]
    return "\n".join(lines).strip()


def _paragraphs(text: str) -> list[str]:
    """Split on blank lines, keeping headings attached to the following block."""
    raw = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    if not raw:
        return []
    merged: list[str] = []
    pending_heading: str | None = None
    for para in raw:
        if _HEADING_RE.match(para) and "\n" not in para:
            pending_heading = para
            continue
        if pending_heading:
            merged.append(f"{pending_heading}\n{para}")
            pending_heading = None
        else:
            merged.append(para)
    if pending_heading:
        merged.append(pending_heading)
    return merged


def chunk_text(text: str, chunk_tokens: int, overlap: int) -> list[str]:
    """Pack paragraphs into overlapping chunks of ~chunk_tokens words.

    Paragraph-aware packing keeps definitions, worked examples, and problem
    statements together — closer to NotebookLM-style adaptive chunking than
    slicing on a raw word window.
    """
    text = _normalize(text)
    paras = _paragraphs(text)
    words_per_chunk = max(1, int(chunk_tokens * 1.3))
    overlap_words = max(0, int(overlap * 1.3))

    source_words: list[str] = []
    if paras:
        for para in paras:
            source_words.extend(para.split())
    else:
        source_words = [w for w in text.split() if w]

    if not source_words:
        return []

    chunks: list[str] = []
    start = 0
    n = len(source_words)
    while start < n:
        end = min(n, start + words_per_chunk)
        piece = " ".join(source_words[start:end]).strip()
        if piece:
            chunks.append(piece)
        if end >= n:
            break
        start = max(start + 1, end - overlap_words)
    return chunks


def ingest_source(db: Session, source: Source, raw_text: str) -> None:
    """Chunk + embed a source once. Query-time work never re-embeds the course."""
    try:
        settings = get_settings()
        provider = get_provider()
        pieces = chunk_text(raw_text, settings.chunk_tokens, settings.chunk_overlap)
        if not pieces:
            source.status = "error"
            source.error = "No extractable text found in source."
            db.commit()
            return

        embeddings = provider.embed(pieces, for_query=False)
        db.query(Chunk).filter(Chunk.source_id == source.id).delete()
        for ordinal, (content, emb) in enumerate(zip(pieces, embeddings)):
            db.add(
                Chunk(
                    source_id=source.id,
                    project_id=source.project_id,
                    ordinal=ordinal,
                    content=content,
                    embedding=embedding_for_db(db, emb),
                )
            )
        source.status = "ready"
        source.error = None
        db.commit()
    except Exception as exc:  # noqa: BLE001 - surface ingestion failures to UI
        db.rollback()
        source.status = "error"
        source.error = str(exc)[:500]
        db.commit()
