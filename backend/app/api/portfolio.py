"""Portfolio, performance, ledger and blotter endpoints."""
from __future__ import annotations

from datetime import datetime

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from decimal import Decimal

from ..core import db
from .deps import Principal, current_principal

router = APIRouter(prefix="/portfolio", tags=["portfolio"])


async def _own_account(conn, p: Principal, account_id: int | None) -> int:
    if account_id is not None:
        ok = await conn.fetchval(
            "SELECT 1 FROM trading.account WHERE account_id=$1 AND user_id=$2",
            account_id, p.user_id)
        if not ok:
            raise HTTPException(403, "account does not belong to you")
        return account_id
    acct = p.account_id or await conn.fetchval(
        "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
        p.user_id)
    if acct is None:
        raise HTTPException(400, "no trading account")
    return acct


@router.get("/summary")
async def summary(account_id: int | None = None, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        rec = await conn.fetchrow(
            "SELECT * FROM analytics.v_account_summary WHERE account_id=$1", acct)
    return db.row(rec)


@router.get("/positions")
async def positions(account_id: int | None = None, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        recs = await conn.fetch("""
            SELECT * FROM analytics.v_portfolio
             WHERE account_id=$1 ORDER BY market_value DESC;""", acct)
    return db.rows(recs)


@router.get("/blotter")
async def blotter(
    account_id: int | None = None,
    limit: int = Query(100, le=1000),
    p: Principal = Depends(current_principal),
):
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        recs = await conn.fetch("""
            SELECT * FROM analytics.v_blotter
             WHERE account_id=$1 ORDER BY executed_at DESC LIMIT $2;""", acct, limit)
    return db.rows(recs)


@router.get("/equity-curve")
async def equity_curve(
    account_id: int | None = None,
    days: int = Query(180, ge=2, le=1000),
    p: Principal = Depends(current_principal),
):
    """
    Daily NAV with drawdown.

    Reads analytics.account_snapshot, which holds real end-of-session NAV.
    Returns are measured on portfolio VALUE, not cash flow -- buying an
    asset is not a loss.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        curve = await conn.fetch("SELECT * FROM analytics.equity_curve($1,$2)", acct, days)
        stats = await conn.fetchrow("SELECT * FROM analytics.performance_stats($1,$2)", acct, days)
    return {"curve": db.rows(curve), "stats": db.row(stats)}


@router.get("/ledger")
async def ledger_entries(
    account_id: int | None = None,
    limit: int = Query(100, le=500),
    p: Principal = Depends(current_principal),
):
    """
    The account's own postings from the double-entry journal.

    This is the audit trail a trader can self-serve: every movement of
    cash or shares, with the journal entry that caused it.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        recs = await conn.fetch("""
            SELECT pg.posting_id, je.entry_id, je.kind::text AS entry_kind,
                   je.occurred_at, je.description,
                   pg.asset_class::text, i.symbol, pg.amount, pg.memo
              FROM ledger.posting pg
              JOIN ledger.journal_entry je USING (entry_id)
              LEFT JOIN reference.instrument i USING (instrument_id)
             WHERE pg.account_id = $1
             ORDER BY je.occurred_at DESC, pg.posting_id DESC
             LIMIT $2;
        """, acct, limit)
    return db.rows(recs)


@router.get("/as-of")
async def portfolio_as_of(
    at: datetime = Query(..., description="ISO timestamp to reconstruct"),
    account_id: int | None = None,
    p: Principal = Depends(current_principal),
):
    """
    TIME TRAVEL -- the portfolio as it stood at any past instant.

    Possible only because the ledger is append-only: the holdings are
    recomputed by replaying the journal up to `at`. A schema that mutates
    a balance column cannot answer this question at all.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        recs = await conn.fetch("SELECT * FROM ledger.balance_as_of($1,$2)", acct, at)
    return {"as_of": at.isoformat(), "holdings": db.rows(recs)}


@router.get("/currencies")
async def currencies(account_id: int | None = None,
                     p: Principal = Depends(current_principal)):
    """
    Cash held, broken out by currency.

    An account can hold several at once: it is funded in its base
    currency and acquires others when the broker converts to settle a
    trade priced in a different one.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        held = await conn.fetch("SELECT * FROM ledger.cash_by_currency($1)", acct)
        base = await conn.fetchval(
            "SELECT base_currency FROM trading.account WHERE account_id=$1", acct)
        board = await conn.fetch("SELECT * FROM analytics.v_fx_board")
    return {"account_id": acct, "base_currency": base,
            "holdings": db.rows(held), "rates": db.rows(board)}


class ConvertIn(BaseModel):
    from_currency: str = Field(min_length=3, max_length=3)
    to_currency: str = Field(min_length=3, max_length=3)
    amount: Decimal = Field(gt=0, decimal_places=8)
    account_id: int | None = None


@router.post("/convert", status_code=201)
async def convert(body: ConvertIn, p: Principal = Depends(current_principal)):
    """
    Convert between currencies.

    Booked as a four-legged journal entry through the FX desk, so each
    currency balances to zero independently. The rate is read from the
    rate table, not supplied by the client.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, body.account_id)
        try:
            rec = await conn.fetchrow("""
                SELECT entry_id, rate, amount_to
                  FROM ledger.convert_currency($1,$2,$3,$4::money_amt,$5);""",
                acct, body.from_currency.upper(), body.to_currency.upper(),
                body.amount, "Manual conversion from the dashboard")
        except asyncpg.PostgresError as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                str(exc).splitlines()[0]) from exc
    return db.row(rec)


@router.get("/history")
async def history(
    account_id: int | None = None,
    kind: str = Query("all", description="all | buys | sells | cash | fx"),
    symbol: str | None = None,
    days: int = Query(90, ge=1, le=1000),
    limit: int = Query(300, le=2000),
    p: Principal = Depends(current_principal),
):
    """
    Unified transaction history.

    Trades and cash events in one stream, because "what did I actually
    do" spans both. Every row carries the journal entry that settled it,
    so any line can be traced into the ledger.
    """
    async with db.acquire(p.user_id) as conn:
        acct = await _own_account(conn, p, account_id)
        recs = await conn.fetch("""
            WITH trades AS (
                SELECT b.executed_at                       AS at,
                       b.side::text                        AS action,
                       b.symbol,
                       b.quantity, b.price, b.notional, b.fee,
                       b.cash_flow,
                       i.currency                          AS currency,
                       b.was_aggressor,
                       b.order_id, b.settlement_entry_id   AS entry_id,
                       CASE WHEN b.side='buy' THEN 'Bought' ELSE 'Sold' END
                         ||' '||trim(to_char(b.quantity,'FM999999990.######'))
                         ||' '||b.symbol                   AS description
                  FROM analytics.v_blotter b
                  JOIN reference.instrument i ON i.symbol = b.symbol
                 WHERE b.account_id = $1
            ), cash AS (
                SELECT je.occurred_at                      AS at,
                       je.kind::text                       AS action,
                       NULL::text                          AS symbol,
                       NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric,
                       pg.amount                           AS cash_flow,
                       pg.currency,
                       NULL::boolean                       AS was_aggressor,
                       NULL::bigint                        AS order_id,
                       je.entry_id,
                       je.description
                  FROM ledger.posting pg
                  JOIN ledger.journal_entry je USING (entry_id)
                 WHERE pg.account_id = $1
                   AND pg.asset_class = 'cash'
                   AND je.kind <> 'trade_settlement'
            )
            SELECT * FROM (
                SELECT * FROM trades
                 WHERE $2 IN ('all','buys','sells')
                   AND ($2 <> 'buys'  OR action = 'buy')
                   AND ($2 <> 'sells' OR action = 'sell')
                UNION ALL
                SELECT * FROM cash
                 WHERE $2 IN ('all','cash','fx')
                   AND ($2 <> 'fx' OR action = 'fx_conversion')
            ) h
             WHERE h.at > now() - make_interval(days => $3::int)
               AND ($4::text IS NULL OR h.symbol = upper($4))
             ORDER BY h.at DESC
             LIMIT $5;
        """, acct, kind, days, symbol, limit)
    return db.rows(recs)
