"""Copy-trading: strategies, leaderboard, subscriptions."""
from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from ..core import db
from .deps import Principal, current_principal

router = APIRouter(prefix="/social", tags=["social"])


@router.get("/leaderboard")
async def leaderboard(limit: int = Query(20, le=100),
                      p: Principal = Depends(current_principal)):
    """
    Ranked strategies, read from a materialized view.

    Sharpe, volatility and max drawdown are computed from real NAV
    history by window functions; the matview means the dashboard does not
    recompute them on every page load.
    """
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT * FROM analytics.mv_strategy_leaderboard
             WHERE visibility = 'public'
             ORDER BY sharpe_rank LIMIT $1;""", limit)
    return db.rows(recs)


@router.get("/strategies")
async def my_strategies(p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        mine = await conn.fetch(
            "SELECT * FROM social.strategy WHERE owner_user_id=$1", p.user_id)
        subs = await conn.fetch("""
            SELECT cs.*, s.name, s.slug, s.fee_bps, u.full_name AS leader
              FROM social.copy_subscription cs
              JOIN social.strategy s USING (strategy_id)
              JOIN identity.app_user u ON u.user_id = s.owner_user_id
             WHERE cs.account_id IN (SELECT account_id FROM trading.account
                                      WHERE user_id = $1);""", p.user_id)
    return {"owned": db.rows(mine), "subscriptions": db.rows(subs)}


class StrategyIn(BaseModel):
    name: str = Field(min_length=3, max_length=80)
    slug: str = Field(min_length=3, max_length=60, pattern="^[a-z0-9][a-z0-9-]+$")
    description: str | None = None
    visibility: str = Field(default="public", pattern="^(private|followers|public)$")
    fee_bps: int = Field(default=0, ge=0, le=5000)


@router.post("/strategies", status_code=201)
async def publish_strategy(body: StrategyIn, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        acct = p.account_id or await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
            p.user_id)
        try:
            sid = await conn.fetchval("""
                INSERT INTO social.strategy
                    (owner_user_id,source_account_id,name,slug,description,visibility,fee_bps)
                VALUES ($1,$2,$3,$4,$5,$6::social.visibility,$7)
                RETURNING strategy_id;""",
                p.user_id, acct, body.name, body.slug, body.description,
                body.visibility, body.fee_bps)
        except asyncpg.UniqueViolationError:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "that slug is taken, or this account already has a strategy")
    return {"strategy_id": sid}


class SubscribeIn(BaseModel):
    strategy_id: int
    allocation_pct: int = Field(default=25, gt=0, le=100)
    max_trade_notional: int = Field(default=10_000, gt=0)


@router.post("/subscribe", status_code=201)
async def subscribe(body: SubscribeIn, p: Principal = Depends(current_principal)):
    """
    Start copying a strategy.

    From here on, a fill by the leader enqueues a fan-out job which a
    worker drains with FOR UPDATE SKIP LOCKED. The leader's own order is
    never blocked by a follower's risk check.
    """
    async with db.acquire(p.user_id) as conn:
        acct = p.account_id or await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
            p.user_id)
        try:
            sub = await conn.fetchval("""
                INSERT INTO social.copy_subscription
                    (strategy_id,account_id,allocation_pct,max_trade_notional)
                VALUES ($1,$2,$3,$4)
                ON CONFLICT (strategy_id,account_id) DO UPDATE
                   SET allocation_pct=EXCLUDED.allocation_pct,
                       max_trade_notional=EXCLUDED.max_trade_notional,
                       status='active', cancelled_at=NULL
                RETURNING subscription_id;""",
                body.strategy_id, acct, body.allocation_pct, body.max_trade_notional)
        except asyncpg.PostgresError as exc:
            raise HTTPException(400, str(exc).splitlines()[0])
    return {"subscription_id": sub}


@router.delete("/subscribe/{subscription_id}", status_code=200)
async def unsubscribe(subscription_id: int, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        n = await conn.execute("""
            UPDATE social.copy_subscription
               SET status='cancelled', cancelled_at=now()
             WHERE subscription_id=$1;""", subscription_id)
    return {"subscription_id": subscription_id, "result": n}


@router.get("/strategies/{strategy_id}/fanout")
async def fanout_report(strategy_id: int, p: Principal = Depends(current_principal)):
    """Which follower orders each leader fill produced, and the slippage."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("SELECT * FROM analytics.copy_fanout_report($1)", strategy_id)
    return db.rows(recs)
