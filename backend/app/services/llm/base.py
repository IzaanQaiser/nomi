from __future__ import annotations

from abc import ABC, abstractmethod


class LLMProvider(ABC):
    """Provider abstraction so the app is not locked to one vendor.

    Implementations must return unit-comparable embeddings (any consistent
    dimensionality) and plain-text completions.
    """

    @property
    @abstractmethod
    def embedding_dim(self) -> int: ...

    @abstractmethod
    def embed(self, texts: list[str], *, for_query: bool = False) -> list[list[float]]:
        """Return one embedding vector per input text.

        Embeddings are computed once at ingest (`for_query=False`) and stored.
        Query-time embedding (`for_query=True`) is only used when a notebook is
        too large to stuff into context. Providers that support task types
        (Gemini) should distinguish the two for better retrieval quality.
        """

    @abstractmethod
    def chat(
        self,
        system: str,
        user: str,
        *,
        json_mode: bool = False,
        json_schema: dict | None = None,
    ) -> str:
        """Return a completion for a system + user prompt.

        `json_mode` asks providers to enforce JSON at the transport layer.
        `json_schema` requests strict structured output when supported.
        """

    @abstractmethod
    def vision(
        self, system: str, user: str, image_base64: str, *, json_mode: bool = False
    ) -> str:
        """Return a completion given a prompt plus an image (base64)."""
