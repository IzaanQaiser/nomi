from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_BACKEND_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    # Always load backend/.env, even if uvicorn is started from another cwd.
    model_config = SettingsConfigDict(
        env_file=_BACKEND_DIR / ".env", extra="ignore"
    )

    # LLM
    llm_provider: str = "gemini"  # "gemini" | "openai" | "mock"

    # Google Gemini
    gemini_api_key: str = ""
    gemini_embed_model: str = "gemini-embedding-001"
    gemini_chat_model: str = "gemini-2.5-flash"
    gemini_vision_model: str = "gemini-2.5-flash"

    # OpenAI (alternative provider)
    openai_api_key: str = ""
    openai_embed_model: str = "text-embedding-3-small"
    openai_chat_model: str = "gpt-4o-mini"
    openai_vision_model: str = "gpt-4o-mini"

    # Storage / DB (resolved relative to the backend folder)
    database_url: str = f"sqlite:///{_BACKEND_DIR / 'ainotes.db'}"
    storage_dir: str = str(_BACKEND_DIR / "storage")
    supabase_url: str = ""
    supabase_service_role_key: str = ""
    supabase_storage_bucket: str = "sources"

    # Retrieval / chunking
    top_k: int = 5
    chunk_tokens: int = 800
    chunk_overlap: int = 120
    full_context_char_budget: int = 48_000
    embed_dim: int = 768

    @field_validator("storage_dir")
    @classmethod
    def _abs_storage(cls, value: str) -> str:
        path = Path(value)
        if path.is_absolute():
            return str(path)
        return str((_BACKEND_DIR / path).resolve())

    @field_validator("database_url")
    @classmethod
    def _abs_sqlite(cls, value: str) -> str:
        # Supabase shows a generic Postgres URL. SQLAlchemy needs the psycopg
        # driver name explicitly so we never fall back to the old psycopg2.
        if value.startswith("postgres://"):
            return "postgresql+psycopg://" + value[len("postgres://") :]
        if value.startswith("postgresql://"):
            return "postgresql+psycopg://" + value[len("postgresql://") :]
        prefix = "sqlite:///"
        if value == "sqlite:///:memory:":
            return value
        if not value.startswith(prefix) or value.startswith("sqlite:////"):
            return value
        rest = value[len(prefix) :]
        if rest.startswith("/"):
            return value
        return prefix + str((_BACKEND_DIR / rest).resolve())

    @property
    def uses_postgres(self) -> bool:
        return self.database_url.startswith("postgresql")

    @property
    def uses_supabase_storage(self) -> bool:
        return bool(self.supabase_url and self.supabase_service_role_key)


@lru_cache
def get_settings() -> Settings:
    return Settings()
