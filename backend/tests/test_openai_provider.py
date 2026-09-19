from types import SimpleNamespace
from unittest.mock import patch

from app.services.llm.openai_provider import OpenAIProvider


class _Response:
    def __init__(self, body: dict) -> None:
        self._body = body

    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict:
        return self._body


class _Client:
    requests: list[dict] = []

    def __init__(self, *, timeout: int) -> None:
        self.timeout = timeout

    def __enter__(self) -> "_Client":
        return self

    def __exit__(self, *args: object) -> None:
        pass

    def post(self, url: str, *, headers: dict, json: dict) -> _Response:
        self.requests.append({"url": url, "headers": headers, "json": json})
        if url.endswith("/embeddings"):
            return _Response({"data": [{"embedding": [0.0] * json["dimensions"]}]})
        return _Response({"choices": [{"message": {"content": "{}"}}]})


def _provider() -> OpenAIProvider:
    provider = OpenAIProvider.__new__(OpenAIProvider)
    provider.settings = SimpleNamespace(
        embed_dim=768,
        openai_embed_model="text-embedding-3-small",
        openai_vision_model="gpt-4o-mini",
    )
    provider._headers = {"Authorization": "Bearer test-key"}
    return provider


def test_embeddings_request_configured_database_dimension() -> None:
    _Client.requests = []
    provider = _provider()

    with patch("app.services.llm.openai_provider.httpx.Client", _Client):
        vectors = provider.embed(["course notes"])

    assert provider.embedding_dim == 768
    assert len(vectors[0]) == 768
    assert _Client.requests[0]["json"] == {
        "model": "text-embedding-3-small",
        "input": ["course notes"],
        "dimensions": 768,
    }


def test_vision_json_mode_requests_json_response() -> None:
    _Client.requests = []
    provider = _provider()

    with patch("app.services.llm.openai_provider.httpx.Client", _Client):
        result = provider.vision("system", "analyze", "aW1hZ2U=", json_mode=True)

    assert result == "{}"
    assert _Client.requests[0]["json"]["response_format"] == {
        "type": "json_object"
    }
