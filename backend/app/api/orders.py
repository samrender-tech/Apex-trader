"""Order entry and management. Thin wrappers over engine.submit_order."""
from __future__ import annotations

from decimal import Decimal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, model_validator

from ..core import db
from .deps import Principal, current_principal

router = APIRouter(prefix="/orders", tags=["orders"])


class OrderIn(BaseModel):
    """
    Order entry payload.

    Prices and quantities are Decimal, NOT float. Pydantic parses a JSON
    number straight into Decimal, which asyncpg then binds to NUMERIC
    exactly. Using float here would send 174.729999999999989768... to the
    database and the engine's tick-size check would (correctly) reject a
    price the user typed as 174.73.
    """
    symbol: str = Field(min_length=1, max_length=20)
    side: str = Field(pattern="^(buy|sell)$")
    kind: str = Field(default="limit",
                      pattern="^(market|limit|stop|stop_limit|trailing_stop|iceberg)$")
    quantity: Decimal = Field(gt=0, decimal_places=8)
    limit_price: Decimal | None = Field(default=None, gt=0, decimal_places=8)
    stop_price: Decimal | None = Field(default=None, gt=0, decimal_places=8)
    trail_pct: Decimal | None = Field(default=None, gt=0, le=100)
    display_qty: Decimal | None = Field(default=None, gt=0)
    tif: str = Field(default="day", pattern="^(day|gtc|ioc|fok)$")
    client_order_id: UUID | None = None
    account_id: int | None = None

    @model_validator(mode="after")
    def check_shape(self):
        """
        Mirror the database's order-shape grammar so obvious mistakes get
        a 422 with a clear message instead of a generic SQL rejection.
        The CHECK constraint in the schema remains the real authority.
        """
        needs_limit = {"limit", "stop_limit", "iceberg"}
        needs_stop = {"stop", "stop_limit"}
        if self.kind in needs_limit and self.limit_price is None:
            raise ValueError(f"{self.kind} orders require limit_price")
        if self.kind in needs_stop and self.stop_price is None:
            raise ValueError(f"{self.kind} orders require stop_price")
        if self.kind == "trailing_stop" and self.trail_pct is None:
            raise ValueError("trailing_stop orders require trail_pct")
        if self.kind == "iceberg" and self.display_qty is None:
            raise ValueError("iceberg orders require display_qty")
        if self.kind == "market" and (self.limit_price or self.stop_price):
            raise ValueError("market orders must not carry a price")
        if self.kind == "market" and self.tif == "gtc":
            raise ValueError("a market order cannot be good-till-cancelled")
        if self.display_qty and self.display_qty > self.quantity:
            raise ValueError("display_qty cannot exceed quantity")
        return self


async def _resolve_account(conn, p: Principal, requested: int | None) -> int:
    """Pick the account to trade, and verify the caller actually owns it."""
    if requested is not None:
        owned = await conn.fetchval(
            "SELECT 1 FROM trading.account WHERE account_id=$1 AND user_id=$2",
            requested, p.user_id)
        if not owned:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "account does not belong to you")
        return requested
    acct = p.account_id or await conn.fetchval(
        "SELECT account_id FROM trading.account WHERE user_id=$1 ORDER BY account_id LIMIT 1",
        p.user_id)
    if acct is None:
        raise HTTPException(400, "no trading account for this user")
    return acct


@router.post("", status_code=201)
async def place_order(body: OrderIn, p: Principal = Depends(current_principal)):
    """
    Submit an order.

    Validation, pre-trade risk, matching, settlement and the stop cascade
    all happen inside ONE call to engine.submit_order, which means one
    transaction. There is no window in which an order is half-processed.

    A rejected order returns 200 with status='rejected' and a reason --
    not an HTTP error. A risk rejection is a normal business outcome and
    the client needs the reason text, so it is not an exception.
    """
    async with db.acquire(p.user_id) as conn:
        account_id = await _resolve_account(conn, p, body.account_id)
        iid = await conn.fetchval(
            "SELECT instrument_id FROM reference.instrument WHERE symbol=upper($1)", body.symbol)
        if iid is None:
            raise HTTPException(404, f"unknown symbol {body.symbol}")

        try:
            rec = await conn.fetchrow("""
                SELECT order_id, status::text AS status, filled_qty,
                       avg_fill_price, reject_reason
                  FROM engine.submit_order(
                       $1::bigint, $2::int, $3::trading.order_side,
                       $4::trading.order_kind, $5::qty_amt, $6::numeric, $7::numeric,
                       $8::trading.time_in_force, $9::numeric, $10::numeric, $11::uuid);
            """, account_id, iid, body.side, body.kind, body.quantity,
                 body.limit_price, body.stop_price, body.tif,
                 body.trail_pct, body.display_qty, body.client_order_id)
        except asyncpg.PostgresError as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                str(exc).splitlines()[0]) from exc

        result = db.row(rec) or {}
        fills = await conn.fetch("""
            SELECT e.execution_id, e.executed_at, e.price, e.quantity,
                   e.aggressor_side,
                   CASE WHEN e.buy_order_id = $1 THEN e.buy_fee ELSE e.sell_fee END AS fee
              FROM trading.execution e
             WHERE e.buy_order_id = $1 OR e.sell_order_id = $1
             ORDER BY e.execution_id;
        """, result.get("order_id"))

    result["fills"] = db.rows(fills)
    result["accepted"] = result.get("status") != "rejected"
    return result


@router.get("")
async def list_orders(
    open_only: bool = Query(False),
    symbol: str | None = None,
    limit: int = Query(100, le=500),
    p: Principal = Depends(current_principal),
):
    """
    List the caller's orders.

    No user_id predicate is needed: Row Level Security scopes this to the
    caller's own accounts automatically.
    """
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT o.order_id, o.client_order_id, o.account_id, i.symbol,
                   o.side::text, o.kind::text, o.tif::text,
                   o.quantity, o.filled_qty, o.leaves_qty,
                   o.limit_price, o.stop_price, o.trail_pct, o.display_qty,
                   o.avg_fill_price, o.status::text, o.stop_armed,
                   o.reject_reason, o.placed_at, o.updated_at, o.expires_at
              FROM trading.trade_order o
              JOIN reference.instrument i USING (instrument_id)
             WHERE ($1::boolean IS NOT TRUE
                    OR o.status IN ('pending_new','working','partially_filled'))
               AND ($2::text IS NULL OR i.symbol = upper($2))
             ORDER BY o.placed_at DESC, o.order_id DESC
             LIMIT $3;
        """, open_only, symbol, limit)
    return db.rows(recs)


@router.get("/{order_id}")
async def get_order(order_id: int, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        rec = await conn.fetchrow("""
            SELECT o.*, i.symbol FROM trading.trade_order o
              JOIN reference.instrument i USING (instrument_id)
             WHERE o.order_id = $1;""", order_id)
        if rec is None:
            # RLS makes "not yours" indistinguishable from "not found",
            # which is the correct behaviour: no existence oracle.
            raise HTTPException(404, "order not found")
        fills = await conn.fetch("""
            SELECT execution_id, executed_at, price, quantity, aggressor_side
              FROM trading.execution
             WHERE buy_order_id=$1 OR sell_order_id=$1 ORDER BY execution_id;""", order_id)
        lineage = await conn.fetch("SELECT * FROM analytics.order_lineage($1)", order_id)
    return {"order": db.row(rec), "fills": db.rows(fills), "lineage": db.rows(lineage)}


@router.delete("/{order_id}", status_code=200)
async def cancel_order(order_id: int, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        account_id = await conn.fetchval(
            "SELECT account_id FROM trading.trade_order WHERE order_id=$1", order_id)
        if account_id is None:
            raise HTTPException(404, "order not found")
        try:
            # The ownership check is passed down so the database enforces
            # it too, not just this endpoint.
            new_status = await conn.fetchval(
                "SELECT engine.cancel_order($1,$2)", order_id, account_id)
        except asyncpg.PostgresError as exc:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                str(exc).splitlines()[0]) from exc
    return {"order_id": order_id, "status": new_status}


@router.post("/cancel-all", status_code=200)
async def cancel_all(symbol: str | None = None, p: Principal = Depends(current_principal)):
    """Panic button: pull every working order."""
    cancelled = []
    async with db.acquire(p.user_id) as conn:
        ids = await conn.fetch("""
            SELECT o.order_id FROM trading.trade_order o
              JOIN reference.instrument i USING (instrument_id)
             WHERE o.status IN ('pending_new','working','partially_filled')
               AND ($1::text IS NULL OR i.symbol = upper($1));
        """, symbol)
        for r in ids:
            try:
                await conn.fetchval("SELECT engine.cancel_order($1)", r["order_id"])
                cancelled.append(r["order_id"])
            except asyncpg.PostgresError:
                continue
    return {"cancelled": cancelled, "count": len(cancelled)}
