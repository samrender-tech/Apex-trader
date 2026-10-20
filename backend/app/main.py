"""
Apex Trader API.

Architectural note: these routers are deliberately THIN. Order entry is
one call to engine.submit_order(); risk, matching, settlement and the
double-entry ledger all execute inside that one database transaction.

The alternative -- doing risk in Python, then matching in Python, then
writing balances -- cannot be made atomic across concurrent orders
without either a global lock or a distributed transaction. Pushing the
invariants into the database is what makes the system correct under
concurrency, and it is why there is no ORM here.
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path

from .api import admin, alerts, auth, market, orders, portfolio, social, ws
from .core import db
from .core.config import get_settings
from .feed.worker import worker

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s :: %(message)s")
log = logging.getLogger("apex")


@asynccontextmanager
async def lifespan(app: FastAPI):
    s = get_settings()
    await db.connect()
    await ws.hub.start()
    await worker.start()
    log.info("Apex Trader API ready (feed=%s)", s.feed_provider)
    try:
        yield
    finally:
        await worker.stop()
        await ws.hub.stop()
        await db.disconnect()


settings = get_settings()

app = FastAPI(
    title=settings.api_title,
    version="2.0.0",
    description=(
        "In-database stock exchange: limit-order-book matching engine with "
        "price-time priority, double-entry settlement ledger, pre-trade risk, "
        "market surveillance and copy-trading -- all implemented in PostgreSQL."
    ),
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",")],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

for r in (auth.router, market.router, orders.router, portfolio.router,
          social.router, alerts.router, admin.router, ws.router):
    app.include_router(r, prefix="/api" if r is not ws.router else "")


# =====================================================================
# API CONTRACT VERSION
#
# Bumped whenever a route the dashboard depends on is added or changed.
#
# Why this exists: the frontend is served by this same process from a
# directory on disk, and the two can get out of step -- an old server
# left running while a new frontend is unpacked over it, a stale PID file
# making `api.sh start` report "already running", a second uvicorn still
# holding port 8000 from an earlier session.
#
# The failure mode is vicious because nothing errors. Unregistered /api
# routes fall through to the StaticFiles mount at "/", which answers 404
# "Not Found" to a GET and 405 "Method Not Allowed" to a POST. So a new
# dashboard against an old server does not say "the server is old" --
# it says "Not Found" where search should be, "Not Found" where history
# should be, empty cards on the markets page, "Watchlist failed: Method
# Not Allowed", and empty currency dropdowns. Six unrelated-looking
# faults, one cause.
#
# The frontend compares this number against the one it was built for and
# says so plainly instead of rendering six broken panels.
# =====================================================================
API_CONTRACT = 3


@app.get("/api/health", tags=["ops"])
async def health():
    """Unauthenticated liveness probe."""
    try:
        async with db.acquire_admin() as conn:
            await conn.fetchval("SELECT 1")
            ledger_ok = await conn.fetchval(
                "SELECT bool_and(passed) FROM ledger.verify_integrity()")
        return {"status": "ok", "database": "up", "ledger_balanced": ledger_ok,
                "api_contract": API_CONTRACT,
                **worker.status,
                "websocket_clients": ws.hub.client_count}
    except Exception as exc:
        return JSONResponse(status_code=503, content={
            "status": "degraded", "api_contract": API_CONTRACT, "error": str(exc)})


# ---------------------------------------------------------------------
# Serve the dashboard. Mounted last so it does not shadow /api routes.
# ---------------------------------------------------------------------
FRONTEND = Path(__file__).resolve().parent.parent.parent / "frontend"
if FRONTEND.is_dir():
    app.mount("/", StaticFiles(directory=str(FRONTEND), html=True), name="dashboard")
