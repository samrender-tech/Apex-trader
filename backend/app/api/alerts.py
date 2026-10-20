"""Watchlists and price alerts."""
from __future__ import annotations

from datetime import datetime
from decimal import Decimal

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, model_validator

from ..core import db
from .deps import Principal, current_principal

router = APIRouter(tags=["watchlist & alerts"])


# =====================================================================
# WATCHLIST
# =====================================================================
@router.get("/watchlist")
async def get_watchlist(p: Principal = Depends(current_principal)):
    """
    The caller's watchlists with live quotes.

    No user_id predicate: Row Level Security scopes this to the caller.
    """
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT * FROM social.v_watchlist
             ORDER BY is_default DESC, watchlist_name, position, symbol;""")
    rows = db.rows(recs)

    lists: dict[int, dict] = {}
    for r in rows:
        wl = lists.setdefault(r["watchlist_id"], {
            "watchlist_id": r["watchlist_id"],
            "name": r["watchlist_name"],
            "is_default": r["is_default"],
            "items": [],
        })
        if r["instrument_id"] is not None:
            wl["items"].append({k: r[k] for k in (
                "instrument_id", "symbol", "name", "kind", "sector", "currency",
                "trades_24x7", "last_price", "prev_close", "bid", "ask",
                "day_volume", "change_pct", "market_open", "position", "note")})
    return list(lists.values())


class WatchItem(BaseModel):
    symbol: str = Field(min_length=1, max_length=20)
    watchlist_id: int | None = None
    note: str | None = Field(default=None, max_length=200)


@router.post("/watchlist/items", status_code=201)
async def add_to_watchlist(body: WatchItem, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        iid = await conn.fetchval(
            "SELECT instrument_id FROM reference.instrument WHERE symbol=upper($1)",
            body.symbol)
        if iid is None:
            raise HTTPException(404, f"{body.symbol.upper()} is not listed. "
                                     "Search for it first, then import it.")
        wid = body.watchlist_id or await conn.fetchval(
            "SELECT watchlist_id FROM social.watchlist WHERE is_default LIMIT 1")
        if wid is None:
            wid = await conn.fetchval("""
                INSERT INTO social.watchlist (user_id,name,is_default)
                VALUES ($1,'My watchlist',TRUE) RETURNING watchlist_id;""", p.user_id)
        try:
            await conn.execute("""
                INSERT INTO social.watchlist_item (watchlist_id,instrument_id,position,note)
                VALUES ($1,$2,
                        COALESCE((SELECT max(position)+1 FROM social.watchlist_item
                                   WHERE watchlist_id=$1), 0), $3)
                ON CONFLICT (watchlist_id,instrument_id) DO UPDATE SET note=EXCLUDED.note;
            """, wid, iid, body.note)
        except asyncpg.PostgresError as exc:
            raise HTTPException(400, str(exc).splitlines()[0]) from exc
    return {"watchlist_id": wid, "instrument_id": iid, "symbol": body.symbol.upper()}


@router.delete("/watchlist/items/{symbol}", status_code=200)
async def remove_from_watchlist(symbol: str, watchlist_id: int | None = None,
                                p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        res = await conn.execute("""
            DELETE FROM social.watchlist_item wi
             USING reference.instrument i, social.watchlist w
             WHERE wi.instrument_id = i.instrument_id
               AND wi.watchlist_id  = w.watchlist_id
               AND i.symbol = upper($1)
               AND ($2::bigint IS NULL OR w.watchlist_id = $2);""", symbol, watchlist_id)
    return {"symbol": symbol.upper(), "result": res}


# =====================================================================
# PRICE ALERTS
# =====================================================================
@router.get("/alerts")
async def list_alerts(active_only: bool = Query(False),
                      p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT a.alert_id, a.kind::text AS kind, a.threshold, a.reference_price,
                   a.note, a.is_active, a.repeat_alert, a.created_at, a.expires_at,
                   a.last_fired_at, a.fire_count,
                   i.symbol, i.instrument_id, i.currency,
                   q.last_price,
                   CASE a.kind
                     WHEN 'above' THEN q.last_price - a.threshold
                     WHEN 'below' THEN a.threshold - q.last_price
                   END AS distance
              FROM risk.price_alert a
              JOIN reference.instrument i USING (instrument_id)
              LEFT JOIN market.quote q ON q.instrument_id = a.instrument_id
             WHERE a.archived_at IS NULL
               AND ($1::boolean IS NOT TRUE OR a.is_active)
             ORDER BY a.is_active DESC, a.created_at DESC;""", active_only)
        fires = await conn.fetch("""
            SELECT f.fire_id, f.alert_id, f.fired_at, f.price, f.detail,
                   i.symbol
              FROM risk.alert_fire f
              JOIN risk.price_alert a USING (alert_id)
              JOIN reference.instrument i USING (instrument_id)
             WHERE a.archived_at IS NULL
             ORDER BY f.fired_at DESC LIMIT 50;""")
    return {"alerts": db.rows(recs), "recent_fires": db.rows(fires)}


class AlertIn(BaseModel):
    symbol: str = Field(min_length=1, max_length=20)
    kind: str = Field(pattern="^(above|below|pct_move_up|pct_move_down)$")
    threshold: Decimal = Field(gt=0, decimal_places=8)
    note: str | None = Field(default=None, max_length=200)
    repeat_alert: bool = False
    expires_at: datetime | None = None

    @model_validator(mode="after")
    def sane_threshold(self):
        if self.kind.startswith("pct_move") and self.threshold > 100:
            raise ValueError("a percentage move above 100% is almost certainly a mistake")
        return self


@router.post("/alerts", status_code=201)
async def create_alert(body: AlertIn, p: Principal = Depends(current_principal)):
    """
    Create a price alert.

    For a percentage alert the current price is captured as the reference
    at creation time, so the alert measures a move from a fixed point
    rather than from a baseline that drifts with the market.
    """
    async with db.acquire(p.user_id) as conn:
        row = await conn.fetchrow("""
            SELECT i.instrument_id, q.last_price
              FROM reference.instrument i
              LEFT JOIN market.quote q ON q.instrument_id = i.instrument_id
             WHERE i.symbol = upper($1);""", body.symbol)
        if row is None:
            raise HTTPException(404, f"{body.symbol.upper()} is not listed")
        if body.kind.startswith("pct_move") and row["last_price"] is None:
            raise HTTPException(400, "no current price to measure a percentage move from")

        try:
            alert_id = await conn.fetchval("""
                INSERT INTO risk.price_alert
                    (user_id, instrument_id, kind, threshold, reference_price,
                     note, repeat_alert, expires_at)
                VALUES ($1,$2,$3::risk.alert_kind,$4,$5,$6,$7,$8)
                RETURNING alert_id;""",
                p.user_id, row["instrument_id"], body.kind, body.threshold,
                row["last_price"] if body.kind.startswith("pct_move") else None,
                body.note, body.repeat_alert, body.expires_at)
        except asyncpg.PostgresError as exc:
            raise HTTPException(400, str(exc).splitlines()[0]) from exc

    return {"alert_id": alert_id, "symbol": body.symbol.upper(),
            "kind": body.kind, "threshold": str(body.threshold),
            "reference_price": str(row["last_price"]) if row["last_price"] else None}


@router.delete("/alerts/{alert_id}", status_code=200)
async def delete_alert(alert_id: int, p: Principal = Depends(current_principal)):
    """
    Remove an alert.

    An alert that never fired is deleted. One that HAS fired is archived
    instead, because risk.alert_fire is append-only and still references
    it -- see migration 025. Either way it disappears from the caller's
    list and stops being evaluated; the difference is only whether the
    notification history survives, and it should.
    """
    async with db.acquire(p.user_id) as conn:
        outcome = await conn.fetchval("SELECT risk.remove_alert($1)", alert_id)
    if outcome == "not_found":
        raise HTTPException(404, "alert not found")
    return {"alert_id": alert_id, "removed": True, "outcome": outcome}


@router.post("/alerts/evaluate")
async def evaluate_now(p: Principal = Depends(current_principal)):
    """Force an evaluation sweep. The worker does this every cycle."""
    async with db.acquire_admin() as conn:
        fired = await conn.fetchval("SELECT risk.evaluate_price_alerts()")
    return {"fired": fired}
