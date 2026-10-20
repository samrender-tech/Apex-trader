"""
Finnhub adapter.

Two things worth noting about talking to a real market-data vendor:

  * the free tier is rate limited (~60 calls/minute), so the adapter
    throttles itself rather than discovering the limit via HTTP 429;
  * vendor payloads are untrusted input. Finnhub returns ``c: 0`` for an
    unknown symbol and ``s: "no_data"`` for an empty candle range, so
    every field is validated before it is handed upstream. A zero price
    reaching the database would violate the ``price_amt`` domain.
"""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Sequence

import httpx

from .base import Candle, Quote

log = logging.getLogger(__name__)

BASE_URL = "https://finnhub.io/api/v1"

# Finnhub resolution codes keyed by our own interval names.
RESOLUTION = {"1": "1", "5": "5", "15": "15", "30": "30",
              "60": "60", "D": "D", "W": "W", "M": "M"}


class FinnhubFeed:
    name = "finnhub"

    def __init__(self, api_key: str, *, max_per_minute: int = 55, timeout: float = 10.0):
        if not api_key:
            raise ValueError("FinnhubFeed requires an API key")
        self._key = api_key
        self._client = httpx.AsyncClient(base_url=BASE_URL, timeout=timeout)
        self._min_interval = 60.0 / max_per_minute
        self._last_call = 0.0
        self._lock = asyncio.Lock()

    async def _get(self, path: str, params: dict) -> dict | None:
        """Rate-limited GET. Returns None on any non-fatal failure."""
        async with self._lock:
            gap = time.monotonic() - self._last_call
            if gap < self._min_interval:
                await asyncio.sleep(self._min_interval - gap)
            self._last_call = time.monotonic()

        try:
            r = await self._client.get(path, params={**params, "token": self._key})
        except httpx.RequestError as exc:
            log.warning("finnhub %s unreachable: %s", path, exc)
            return None

        if r.status_code == 429:
            log.warning("finnhub rate limit hit on %s; backing off", path)
            await asyncio.sleep(2.0)
            return None
        if r.status_code in (401, 403):
            # A bad key is a configuration error, not a transient one.
            raise PermissionError(f"finnhub rejected the API key ({r.status_code})")
        if r.status_code >= 400:
            log.warning("finnhub %s returned HTTP %s", path, r.status_code)
            return None

        try:
            return r.json()
        except ValueError:
            log.warning("finnhub %s returned non-JSON", path)
            return None

    async def quote(self, symbol: str) -> Quote | None:
        data = await self._get("/quote", {"symbol": symbol})
        if not data:
            return None

        last = data.get("c")
        # Finnhub signals "symbol unknown" with a zero current price.
        # Letting that through would violate the price_amt > 0 domain.
        if not last or float(last) <= 0:
            log.debug("finnhub returned no usable price for %s", symbol)
            return None

        def pos(key: str) -> float | None:
            v = data.get(key)
            try:
                v = float(v)
            except (TypeError, ValueError):
                return None
            return v if v > 0 else None

        return Quote(
            symbol=symbol,
            last_price=float(last),
            day_open=pos("o"),
            day_high=pos("h"),
            day_low=pos("l"),
            prev_close=pos("pc"),
            ts=datetime.fromtimestamp(data["t"], tz=timezone.utc) if data.get("t") else datetime.now(timezone.utc),
        )

    async def candles(
        self, symbol: str, start: datetime, end: datetime, resolution: str = "1"
    ) -> Sequence[Candle]:
        data = await self._get("/stock/candle", {
            "symbol": symbol,
            "resolution": RESOLUTION.get(resolution, "1"),
            "from": int(start.timestamp()),
            "to": int(end.timestamp()),
        })
        # "no_data" is a normal answer for a quiet range, not an error.
        if not data or data.get("s") != "ok":
            return []

        out: list[Candle] = []
        for t, o, h, l, c, v in zip(
            data.get("t", []), data.get("o", []), data.get("h", []),
            data.get("l", []), data.get("c", []), data.get("v", []),
        ):
            try:
                o, h, l, c, v = float(o), float(h), float(l), float(c), float(v or 0)
            except (TypeError, ValueError):
                continue
            if min(o, h, l, c) <= 0:
                continue
            # Our candle table CHECKs that high is the max and low the
            # min. Vendor data occasionally violates it; clamp rather
            # than let the insert fail the whole batch.
            h = max(h, o, c)
            l = min(l, o, c)
            out.append(Candle(symbol, datetime.fromtimestamp(t, tz=timezone.utc), o, h, l, c, v))
        return out

    async def profile(self, symbol: str) -> dict:
        """Company metadata, used to enrich the instrument master."""
        return await self._get("/stock/profile2", {"symbol": symbol}) or {}

    async def aclose(self) -> None:
        await self._client.aclose()
