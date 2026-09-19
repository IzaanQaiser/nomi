from __future__ import annotations

import hashlib
import math
import re

from ...config import get_settings
from .base import LLMProvider

_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokens(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


class MockProvider(LLMProvider):
    """Keyless, deterministic provider for local dev and tests.

    - Embeddings are a hashed bag-of-words projected into a fixed space, so
      texts that share vocabulary have higher cosine similarity. This makes
      retrieval behave sensibly without any API calls.
    - Chat/vision return deterministic, structured stand-in responses.
    """

    @property
    def embedding_dim(self) -> int:
        return get_settings().embed_dim

    def embed(self, texts: list[str], *, for_query: bool = False) -> list[list[float]]:
        vectors: list[list[float]] = []
        dim = self.embedding_dim
        for text in texts:
            vec = [0.0] * dim
            for tok in _tokens(text):
                h = int(hashlib.md5(tok.encode()).hexdigest(), 16)
                idx = h % dim
                sign = 1.0 if (h >> 8) & 1 else -1.0
                vec[idx] += sign
            norm = math.sqrt(sum(v * v for v in vec)) or 1.0
            vectors.append([v / norm for v in vec])
        return vectors

    def chat(self, system: str, user: str) -> str:
        # Heuristic: the RAG service embeds retrieved context between markers.
        context = ""
        if "<<<CONTEXT>>>" in user and "<<<END>>>" in user:
            context = user.split("<<<CONTEXT>>>", 1)[1].split("<<<END>>>", 1)[0].strip()
        if not context:
            return (
                "I couldn't find anything about that in your sources. "
                "Try adding a source that covers this topic."
            )
        snippet = context[:400].replace("\n", " ")
        return f"[mock answer grounded in your sources] Based on your notes: {snippet}"

    def vision(
        self, system: str, user: str, image_base64: str, *, json_mode: bool = False
    ) -> str:
        # Infer-problem pass: we can't actually read the image, so stay honest.
        if "Identify the single problem" in system or "What problem is on this page" in user:
            return "unknown"
        if "live tutor sitting next to the student" in system:
            said = ""
            if 'The student said: "' in user:
                said = user.split('The student said: "', 1)[1].split('"', 1)[0]
            if not said or "silent" in user.lower():
                return "Looks like you paused — want a nudge on the next step?"
            if any(w in said.lower() for w in ("stuck", "help", "hint", "confused", "idk")):
                return "You're close. Look back at the method in your notes and try the next small step — I won't spoil it."
            return f"Got it. Let's stay with what you just said: {said[:120]}"
        # Analyze pass: if the prompt already contains retrieved source text,
        # acknowledge grounding so the pipeline is testable without a key.
        has_sources = (
            "Relevant material from their course sources:" in user
            and "(none available)" not in user
        )
        reasoning = (
            "mock: analyzed page with source grounding"
            if has_sources
            else "mock: analyzed page with no source context"
        )
        return (
            '{"status": "ok", "hint": null, "reasoning": "' + reasoning + '"}'
        )
