"""
Real-time push over WebSocket, driven by PostgreSQL LISTEN/NOTIFY.

The API never polls for fills. engine.settle_fill() calls pg_notify() as
part of the SAME TRANSACTION that writes the execution, so a client is
told about a trade only if that trade actually committed -- there is no
window where the UI shows a fill that later rolled back.

One database connection LISTENs; the manager fans each payload out to
every subscribed socket. That keeps connection count independent of how
many browsers are open.
"""
from __future__ import annotations

import asyncio
import json
import logging

import asyncpg
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..core.config import get_settings

log = logging.getLogger(__name__)
router = APIRouter(tags=["realtime"])

CHANNEL = "apex_events"


class EventHub:
    """Fans PostgreSQL notifications out to connected WebSocket clients."""

    def __init__(self) -> None:
        self._clients: set[WebSocket] = set()
        self._conn: asyncpg.Connection | None = None
        self._lock = asyncio.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None

    async def start(self) -> None:
        s = get_settings()
        self._loop = asyncio.get_running_loop()
        # A dedicated connection, not a pool member: a LISTEN must stay
        # open for the process lifetime and must never be handed back.
        self._conn = await asyncpg.connect(s.admin_dsn)
        await self._conn.add_listener(CHANNEL, self._on_notify)
        log.info("listening on PostgreSQL channel %r", CHANNEL)

    def _on_notify(self, _conn, _pid, _channel, payload: str) -> None:
        # asyncpg invokes this from the event loop; schedule the fan-out
        # rather than awaiting inside a sync callback.
        if self._loop is not None:
            self._loop.create_task(self.broadcast(payload))

    async def broadcast(self, payload: str) -> None:
        if not self._clients:
            return
        dead: list[WebSocket] = []
        for ws in list(self._clients):
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self._clients.discard(ws)

    async def register(self, ws: WebSocket) -> None:
        async with self._lock:
            self._clients.add(ws)

    async def unregister(self, ws: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(ws)

    async def stop(self) -> None:
        if self._conn is not None:
            try:
                await self._conn.remove_listener(CHANNEL, self._on_notify)
            finally:
                await self._conn.close()
            self._conn = None

    @property
    def client_count(self) -> int:
        return len(self._clients)


hub = EventHub()


@router.websocket("/ws/stream")
async def stream(ws: WebSocket):
    """
    Live event stream: executions, book updates, stop elections, halts.

    Deliberately carries only PUBLIC market data (prices, sizes, symbols)
    -- never account identifiers -- so it needs no per-socket
    authorisation and cannot leak one trader's activity to another.
    """
    await ws.accept()
    await hub.register(ws)
    await ws.send_text(json.dumps({"type": "hello", "channel": CHANNEL}))
    try:
        while True:
            # Client messages are only used as a keepalive/ping.
            msg = await ws.receive_text()
            if msg == "ping":
                await ws.send_text(json.dumps({"type": "pong"}))
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        log.debug("websocket closed: %s", exc)
    finally:
        await hub.unregister(ws)
