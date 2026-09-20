from __future__ import annotations

import httpx

from ...config import get_settings
from .base import LLMProvider

_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"


class GeminiProvider(LLMProvider):
    """Google Gemini provider (embeddings + chat + vision).

    Uses the Generative Language REST API. The API key is sent via the
    `x-goog-api-key` header (kept out of URLs/logs).
    """

    def __init__(self) -> None:
        self.settings = get_settings()
        if not self.settings.gemini_api_key:
            raise RuntimeError(
                "LLM_PROVIDER=gemini but GEMINI_API_KEY is not set. "
                "Set it in backend/.env or use LLM_PROVIDER=mock for keyless dev."
            )
        self._headers = {"x-goog-api-key": self.settings.gemini_api_key}

    @property
    def embedding_dim(self) -> int:
        return self.settings.embed_dim

    def embed(self, texts: list[str], *, for_query: bool = False) -> list[list[float]]:
        model = self.settings.gemini_embed_model
        url = f"{_BASE_URL}/models/{model}:batchEmbedContents"
        task = "RETRIEVAL_QUERY" if for_query else "RETRIEVAL_DOCUMENT"
        dim = self.settings.embed_dim
        vectors: list[list[float]] = []
        # Keep batches modest so a large PDF doesn't blow the request size.
        batch_size = 32
        with httpx.Client(timeout=60) as client:
            for start in range(0, len(texts), batch_size):
                batch = texts[start : start + batch_size]
                payload = {
                    "requests": [
                        {
                            "model": f"models/{model}",
                            "content": {"parts": [{"text": t}]},
                            "taskType": task,
                            "outputDimensionality": dim,
                        }
                        for t in batch
                    ]
                }
                resp = client.post(url, headers=self._headers, json=payload)
                resp.raise_for_status()
                data = resp.json()
                vectors.extend(item["values"] for item in data["embeddings"])
        return vectors

    def chat(
        self,
        system: str,
        user: str,
        *,
        json_mode: bool = False,
        json_schema: dict | None = None,
    ) -> str:
        return self._generate(
            model=self.settings.gemini_chat_model,
            system=system,
            parts=[{"text": user}],
            temperature=0.2,
            json_mode=json_mode or json_schema is not None,
        )

    def vision(
        self, system: str, user: str, image_base64: str, *, json_mode: bool = False
    ) -> str:
        return self._generate(
            model=self.settings.gemini_vision_model,
            system=system,
            parts=[
                {"text": user},
                {"inlineData": {"mimeType": "image/png", "data": image_base64}},
            ],
            temperature=0.1,
            json_mode=json_mode,
        )

    def _generate(
        self,
        model: str,
        system: str,
        parts: list[dict],
        temperature: float,
        json_mode: bool = False,
    ) -> str:
        url = f"{_BASE_URL}/models/{model}:generateContent"
        gen: dict = {"temperature": temperature}
        if json_mode:
            gen["responseMimeType"] = "application/json"
        payload = {
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": gen,
        }
        with httpx.Client(timeout=120) as client:
            resp = client.post(url, headers=self._headers, json=payload)
            resp.raise_for_status()
            data = resp.json()

        candidates = data.get("candidates", [])
        if not candidates:
            return ""
        content_parts = candidates[0].get("content", {}).get("parts", [])
        return "".join(p.get("text", "") for p in content_parts).strip()
