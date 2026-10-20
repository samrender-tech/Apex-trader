"""Compliance and operations endpoints. Requires a privileged role."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..core import db
from .deps import Principal, current_principal, require_compliance

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/alerts")
async def alerts(
    state: str = Query("open"),
    severity: str | None = None,
    limit: int = Query(100, le=500),
    p: Principal = Depends(require_compliance),
):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT * FROM analytics.v_alert_queue
             WHERE ($1::text = 'all' OR state::text = $1)
               AND ($2::text IS NULL OR severity::text = $2)
             ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1
                                    WHEN 'medium' THEN 2 ELSE 3 END,
                      detected_at DESC
             LIMIT $3;""", state, severity, limit)
    return db.rows(recs)


class AlertReview(BaseModel):
    state: str = Field(pattern="^(investigating|escalated|dismissed|confirmed)$")
    note: str | None = None


@router.patch("/alerts/{alert_id}")
async def review_alert(alert_id: int, body: AlertReview,
                       p: Principal = Depends(require_compliance)):
    """
    Record a review decision.

    The UPDATE is picked up by the generic audit trigger, so who changed
    an alert's state, when, and from what to what is permanently recorded
    in audit.activity_log -- which is itself append-only.
    """
    async with db.acquire(p.user_id) as conn:
        rec = await conn.fetchrow("""
            UPDATE surveil.alert
               SET state=$2::surveil.alert_state, reviewed_by=$3,
                   reviewed_at=now(), review_note=$4
             WHERE alert_id=$1
            RETURNING alert_id, rule_code, state::text, reviewed_at;""",
            alert_id, body.state, p.user_id, body.note)
    if rec is None:
        raise HTTPException(404, "alert not found")
    return db.row(rec)


@router.post("/surveillance/scan")
async def run_scans(p: Principal = Depends(require_compliance)):
    """Run the full surveillance suite on demand. Idempotent (deduped)."""
    async with db.acquire_admin() as conn:
        recs = await conn.fetch("SELECT * FROM surveil.run_all_scans()")
    return db.rows(recs)


@router.get("/audit/{table_name}/{row_key}")
async def row_history(table_name: str, row_key: str,
                      p: Principal = Depends(require_compliance)):
    """Full field-level change history of one row."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("SELECT * FROM audit.row_history($1,$2)", table_name, row_key)
    return db.rows(recs)


@router.get("/health")
async def health(p: Principal = Depends(require_compliance)):
    """Every structural invariant, checked live."""
    async with db.acquire_admin() as conn:
        recs = await conn.fetch("SELECT * FROM ops.health_check()")
    data = db.rows(recs)
    # Only FAIL means the system is structurally broken. ATTENTION (e.g.
    # an open critical surveillance alert) and WARN are advisory -- a
    # correctly-working venue WILL have open alerts.
    failures = [r for r in data if r["status"] == "FAIL"]
    return {
        "all_passing": not failures,
        "failures": failures,
        "advisories": [r for r in data if r["status"] not in ("PASS", "FAIL")],
        "checks": data,
    }


@router.get("/risk/margin-calls")
async def margin_calls(p: Principal = Depends(require_compliance)):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT mc.*, a.account_no, u.full_name
              FROM risk.margin_call mc
              JOIN trading.account a USING (account_id)
              LEFT JOIN identity.app_user u USING (user_id)
             WHERE mc.cured_at IS NULL ORDER BY mc.issued_at DESC;""")
    return db.rows(recs)


class HaltIn(BaseModel):
    symbol: str
    minutes: int = Field(default=5, ge=1, le=1440)
    reason: str = Field(default="manual",
                        pattern="^(price_band|volatility|news_pending|manual|circuit_breaker)$")
    detail: str | None = None


@router.post("/risk/halt", status_code=201)
async def halt_instrument(body: HaltIn, p: Principal = Depends(require_compliance)):
    """
    Suspend trading in an instrument.

    Overlapping halts are impossible: a GiST exclusion constraint on
    (instrument_id, time range) rejects them at the storage layer.
    """
    async with db.acquire_admin() as conn:
        iid = await conn.fetchval(
            "SELECT instrument_id FROM reference.instrument WHERE symbol=upper($1)", body.symbol)
        if iid is None:
            raise HTTPException(404, f"unknown symbol {body.symbol}")
        try:
            rec = await conn.fetchrow("""
                INSERT INTO risk.trading_halt
                    (instrument_id, halted_until, reason, detail, created_by)
                VALUES ($1, now() + make_interval(mins => $2::int),
                        $3::risk.halt_reason, $4, $5)
                RETURNING halt_id, halted_from, halted_until;""",
                iid, body.minutes, body.reason, body.detail, p.user_id)
        except Exception as exc:
            if "no_overlapping_halts" in str(exc):
                raise HTTPException(409, f"{body.symbol} is already halted for an overlapping window")
            raise
    return db.row(rec)


@router.delete("/risk/halt/{halt_id}", status_code=200)
async def lift_halt(halt_id: int, p: Principal = Depends(require_compliance)):
    async with db.acquire_admin() as conn:
        rec = await conn.fetchrow("""
            UPDATE risk.trading_halt SET halted_until = now()
             WHERE halt_id=$1 AND halted_until > now()
            RETURNING halt_id, halted_until;""", halt_id)
    if rec is None:
        raise HTTPException(404, "no active halt with that id")
    return db.row(rec)


@router.post("/ops/end-of-day")
async def end_of_day(p: Principal = Depends(require_compliance)):
    """Expire orders, roll candles, snapshot NAV, margin sweep, scans, refresh."""
    async with db.acquire_admin() as conn:
        await conn.execute("CALL ops.end_of_day()")
        rec = await conn.fetchrow("""
            SELECT job_name, started_at, finished_at, succeeded, detail, duration
              FROM ops.job_run WHERE job_name='end_of_day'
             ORDER BY run_id DESC LIMIT 1;""")
    return db.row(rec)


@router.post("/ops/process-copy-queue")
async def process_copy_queue(batch: int = Query(100, le=1000),
                             p: Principal = Depends(require_compliance)):
    async with db.acquire_admin() as conn:
        rec = await conn.fetchrow("SELECT * FROM social.process_copy_queue($1)", batch)
    return db.row(rec)


@router.get("/ops/stats")
async def ops_stats(p: Principal = Depends(require_compliance)):
    async with db.acquire_admin() as conn:
        sizes = await conn.fetch("SELECT * FROM ops.v_table_sizes LIMIT 15")
        idx = await conn.fetch("SELECT * FROM ops.v_index_usage LIMIT 20")
        slow = await conn.fetch("SELECT * FROM ops.v_slow_queries LIMIT 15")
        jobs = await conn.fetch("""
            SELECT job_name, started_at, succeeded, duration, detail
              FROM ops.job_run ORDER BY run_id DESC LIMIT 10;""")
    return {"table_sizes": db.rows(sizes), "index_usage": db.rows(idx),
            "slow_queries": db.rows(slow), "recent_jobs": db.rows(jobs)}
