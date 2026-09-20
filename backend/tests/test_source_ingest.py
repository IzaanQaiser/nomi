from __future__ import annotations

from io import BytesIO
from zipfile import ZIP_DEFLATED, ZipFile

import pytest

from app.services.ingest import extract_docx_text, extract_source_text


def _docx_bytes() -> bytes:
    document_xml = b"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:r><w:t>Course overview</w:t></w:r></w:p>
        <w:p><w:r><w:t>Week one:</w:t></w:r><w:r><w:t> Networks</w:t></w:r></w:p>
      </w:body>
    </w:document>"""
    output = BytesIO()
    with ZipFile(output, "w", ZIP_DEFLATED) as archive:
        archive.writestr("word/document.xml", document_xml)
    return output.getvalue()


def test_extract_docx_text_preserves_paragraphs_and_runs() -> None:
    assert extract_docx_text(_docx_bytes()) == "Course overview\n\nWeek one: Networks"


def test_extract_source_text_rejects_unknown_kind() -> None:
    with pytest.raises(ValueError, match="Unsupported source kind"):
        extract_source_text("pages", b"content")
