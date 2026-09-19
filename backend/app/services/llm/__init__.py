from ...config import get_settings
from .base import LLMProvider
from .gemini_provider import GeminiProvider
from .mock import MockProvider
from .openai_provider import OpenAIProvider


def get_provider() -> LLMProvider:
    settings = get_settings()
    if settings.llm_provider == "gemini":
        return GeminiProvider()
    if settings.llm_provider == "openai":
        return OpenAIProvider()
    return MockProvider()


__all__ = [
    "LLMProvider",
    "GeminiProvider",
    "MockProvider",
    "OpenAIProvider",
    "get_provider",
]
