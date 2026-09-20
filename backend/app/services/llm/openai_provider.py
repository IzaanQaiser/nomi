from __future__ import annotations

import httpx

from ...config import get_settings
from .base import LLMProvider

_BASE_URL = "https://api.openai.com/v1"


class OpenAIProvider(LLMProvider):
    def __init__(self) -> None:
        self.settings = get_settings()
        if not self.settings.openai_api_key:
            raise RuntimeError(
                "LLM_PROVIDER=openai but OPENAI_API_KEY is not set. "
                "Set it in backend/.env or use LLM_PROVIDER=mock."
            )
        self._headers = {"Authorization": f"Bearer {self.settings.openai_api_key}"}

    @property
    def embedding_dim(self) -> int:
        return self.settings.embed_dim

    def embed(self, texts: list[str], *, for_query: bool = False) -> list[list[float]]:
        with httpx.Client(timeout=60) as client:
            resp = client.post(
                f"{_BASE_URL}/embeddings",
                headers=self._headers,
                json={
                    "model": self.settings.openai_embed_model,
                    "input": texts,
                    "dimensions": self.embedding_dim,
                },
            )
            resp.raise_for_status()
            data = resp.json()["data"]
        return [item["embedding"] for item in data]

    def chat(
        self,
        system: str,
        user: str,
        *,
        json_mode: bool = False,
        json_schema: dict | None = None,
    ) -> str:
        payload = {
            "model": self.settings.openai_chat_model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.2,
        }
        if json_schema is not None:
            payload["response_format"] = {
                "type": "json_schema",
                "json_schema": {
                    "name": "nomi_response",
                    "strict": True,
                    "schema": json_schema,
                },
            }
        elif json_mode:
            payload["response_format"] = {"type": "json_object"}

        with httpx.Client(timeout=120) as client:
            resp = client.post(
                f"{_BASE_URL}/chat/completions",
                headers=self._headers,
                json=payload,
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"]

    def vision(
        self, system: str, user: str, image_base64: str, *, json_mode: bool = False
    ) -> str:
        payload = {
            "model": self.settings.openai_vision_model,
            "messages": [
                {"role": "system", "content": system},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": user},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/png;base64,{image_base64}"
                            },
                        },
                    ],
                },
            ],
            "temperature": 0.1,
        }
        if json_mode:
            payload["response_format"] = {"type": "json_object"}

        with httpx.Client(timeout=120) as client:
            resp = client.post(
                f"{_BASE_URL}/chat/completions",
                headers=self._headers,
                json=payload,
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"]
