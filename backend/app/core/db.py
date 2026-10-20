"""
Database access layer.

Two deliberate choices here:

1. RAW SQL, NO ORM. The database is the product in this project -- the
   matching engine, the double-entry invariant, the risk gate and the
   surveillance rules are all SQL. An ORM would add a translation layer
   whose whole purpose is to hide exactly the thing being built.

2. EVERY request sets `apex.current_user_id` on its connection. That is
   what activates Row Level Security, so the database itself refuses to
   return another tenant's rows. The connection is reset on release, so
   a pooled connection can never leak one user's identity to the next
   request.
"""
from __future__ import annotations

import json
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Any, AsyncIterator

import asyncpg

from .config import get_settings

_pool: asyncpg.Pool | None = None
_admin_pool: asyncpg.Pool | None = None


async def _init_connection(conn: asyncpg.Connection) -> None:
    """Register codecs so JSON/JSONB round-trip as Python objects."""
    await conn.set_type_codec(
        "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")
    await conn.set_type_codec(
        "json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


async def connect() -> None:
    global _pool, _admin_pool
    s = get_settings()
    if _pool is None:
        _pool = await asyncpg.create_pool(
            s.dsn, min_size=s.db_pool_min, max_size=s.db_pool_max,
            init=_init_connection,
            # Clear the tenant GUC when a connection returns to the pool.
            # Without this, request N+1 could inherit request N's identity.
            setup=lambda c: c.execute("SELECT set_config('apex.current_user_id','',false)"),
        )
    if _admin_pool is None:
        # Owner role: used only by the ingestion worker and batch jobs,
        # which legitimately write across all tenants.
        _admin_pool = await asyncpg.create_pool(
            s.admin_dsn, min_size=1, max_size=4, init=_init_connection)


async def disconnect() -> None:
    global _pool, _admin_pool
    for p in (_pool, _admin_pool):
        if p is not None:
            await p.close()
    _pool = _admin_pool = None


@asynccontextmanager
async def acquire(user_id: int | None = None) -> AsyncIterator[asyncpg.Connection]:
    """
    Check out a connection scoped to one user.

    Passing user_id activates RLS for that tenant. Passing None leaves the
    GUC empty, which means RLS returns NOTHING -- failing closed is the
    correct default for a missing identity.
    """
    assert _pool is not None, "db.connect() was not called"
    async with _pool.acquire() as conn:
        try:
            await conn.execute(
                "SELECT set_config('apex.current_user_id', $1, false)",
                "" if user_id is None else str(user_id))
            yield conn
        finally:
            await conn.execute("SELECT set_config('apex.current_user_id','',false)")


@asynccontextmanager
async def acquire_admin() -> AsyncIterator[asyncpg.Connection]:
    """Owner-role connection. Bypasses RLS: use only for ingestion/batch."""
    assert _admin_pool is not None, "db.connect() was not called"
    async with _admin_pool.acquire() as conn:
        yield conn


def jsonable(value: Any) -> Any:
    """
    Make asyncpg output JSON-serialisable WITHOUT turning money into float.

    Decimal -> str, deliberately. Serialising a NUMERIC as a JSON float
    would reintroduce the exact binary-rounding problem the NUMERIC
    columns exist to avoid, one layer further out.
    """
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {k: jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    if isinstance(value, asyncpg.Record):
        return {k: jsonable(v) for k, v in value.items()}
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


def rows(records: list[asyncpg.Record]) -> list[dict]:
    return [jsonable(dict(r)) for r in records]


def row(record: asyncpg.Record | None) -> dict | None:
    return jsonable(dict(record)) if record is not None else None
