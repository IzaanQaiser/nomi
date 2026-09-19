from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import get_settings

settings = get_settings()

# SQLite needs cross-thread access for FastAPI. Supabase's transaction pooler
# (port 6543) cannot safely share Psycopg server-side prepared statements.
if settings.database_url.startswith("sqlite"):
    connect_args = {"check_same_thread": False}
elif settings.database_url.startswith("postgresql"):
    connect_args = {"prepare_threshold": None}
else:
    connect_args = {}

engine = create_engine(
    settings.database_url,
    connect_args=connect_args,
    pool_pre_ping=not settings.database_url.startswith("sqlite"),
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    # Import models so they register on Base.metadata before create_all.
    from . import models  # noqa: F401

    if settings.database_url.startswith("sqlite"):
        Base.metadata.create_all(bind=engine)
        return

    # Hosted Postgres is migration-owned. This also fails fast when credentials
    # or networking are wrong instead of serving requests against a half-schema.
    from sqlalchemy import text

    with engine.connect() as connection:
        connection.execute(text("select 1 from public.projects limit 1"))
