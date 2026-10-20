"""
Yahoo Finance adapter.

No API key, global coverage, and a genuinely good company-name search --
which is why it is the default provider here. The trade-off is that these
endpoints are UNOFFICIAL: they are what finance.yahoo.com itself calls,
they are undocumented, and they have changed without notice before (the
cookie/crumb requirement appeared in 2023 and broke every client).

So this adapter is written defensively:

  * every field is validated before it leaves the adapter, because a
    zero or null price would violate the price_amt domain downstream;
  * a cookie + crumb is obtained lazily and refreshed on 401/403;
  * any failure returns None rather than raising, so the ingestion loop
    degrades instead of dying;
  * the factory falls back to the simulator if Yahoo is unreachable.

If you need a supported contract with an SLA, use the Finnhub adapter
instead -- set APEX_FEED_PROVIDER=finnhub and supply a key.
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

CHART_URL  = "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}"
SEARCH_URL = "https://query2.finance.yahoo.com/v1/finance/search"
QUOTE_URL  = "https://query1.finance.yahoo.com/v7/finance/quote"
CRUMB_URL  = "https://query1.finance.yahoo.com/v1/test/getcrumb"
COOKIE_URL = "https://fc.yahoo.com"

# Our interval names -> Yahoo's. Yahoo caps intraday history by interval
# (1m is 7 days max), which the range table below respects.
INTERVAL = {"1": "1m", "5": "5m", "15": "15m", "30": "30m",
            "60": "1h", "D": "1d", "W": "1wk", "M": "1mo"}

MAX_RANGE = {"1m": "7d", "5m": "60d", "15m": "60d", "30m": "60d",
             "1h": "730d", "1d": "max", "1wk": "max", "1mo": "max"}

BROWSER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36")


class YahooFeed:
    name = "yahoo"

    def __init__(self, *, timeout: float = 15.0, max_per_minute: int = 120):
        self._client = httpx.AsyncClient(
            timeout=timeout,
            headers={"User-Agent": BROWSER_UA, "Accept": "application/json"},
            follow_redirects=True,
        )
        self._crumb: str | None = None
        self._crumb_at: float = 0.0
        self._lock = asyncio.Lock()
        self._min_interval = 60.0 / max_per_minute
        self._last_call = 0.0

    # ---------------------------------------------------------------- auth
    async def _ensure_crumb(self) -> str | None:
        """
        Yahoo requires a session cookie plus a matching 'crumb' token on
        some endpoints. Both are fetched lazily and cached for an hour.
        """
        if self._crumb and (time.monotonic() - self._crumb_at) < 3600:
            return self._crumb
        async with self._lock:
            if self._crumb and (time.monotonic() - self._crumb_at) < 3600:
                return self._crumb
            try:
                await self._client.get(COOKIE_URL)          # sets the cookie
                r = await self._client.get(CRUMB_URL)
                if r.status_code == 200 and r.text and "<" not in r.text:
                    self._crumb = r.text.strip()
                    self._crumb_at = time.monotonic()
                    log.debug("yahoo crumb acquired")
            except httpx.RequestError as exc:
                log.debug("yahoo crumb unavailable (%s); continuing without", exc)
                self._crumb = None
        return self._crumb

    async def _throttle(self) -> None:
        gap = time.monotonic() - self._last_call
        if gap < self._min_interval:
            await asyncio.sleep(self._min_interval - gap)
        self._last_call = time.monotonic()

    async def _get(self, url: str, params: dict | None = None,
                   *, with_crumb: bool = False, _retry: bool = True) -> dict | None:
        await self._throttle()
        p = dict(params or {})
        if with_crumb:
            crumb = await self._ensure_crumb()
            if crumb:
                p["crumb"] = crumb
        try:
            r = await self._client.get(url, params=p)
        except httpx.RequestError as exc:
            log.warning("yahoo unreachable (%s): %s", url, exc)
            return None

        if r.status_code in (401, 403) and _retry:
            # Almost always a stale crumb. Drop it and try once more.
            self._crumb = None
            return await self._get(url, params, with_crumb=with_crumb, _retry=False)
        if r.status_code == 429:
            log.warning("yahoo rate limited; backing off")
            await asyncio.sleep(2.0)
            return None
        if r.status_code >= 400:
            log.debug("yahoo %s returned HTTP %s", url, r.status_code)
            return None
        try:
            return r.json()
        except ValueError:
            return None

    # ---------------------------------------------------------------- data
    async def quote(self, symbol: str) -> Quote | None:
        """
        One quote, read from the chart endpoint's meta block.

        The v7 /quote endpoint is the obvious choice but is the one Yahoo
        most often gates behind the crumb; the chart endpoint carries the
        same numbers and is far more reliable.
        """
        data = await self._get(CHART_URL.format(symbol=symbol),
                               {"interval": "1d", "range": "5d"})
        meta = (((data or {}).get("chart") or {}).get("result") or [{}])[0].get("meta")
        if not meta:
            return None

        last = meta.get("regularMarketPrice")
        try:
            last = float(last)
        except (TypeError, ValueError):
            return None
        if last <= 0:
            return None

        def pos(key: str) -> float | None:
            v = meta.get(key)
            try:
                v = float(v)
            except (TypeError, ValueError):
                return None
            return v if v > 0 else None

        ts = meta.get("regularMarketTime")
        return Quote(
            symbol=symbol,
            last_price=last,
            day_open=pos("regularMarketOpen") or pos("chartPreviousClose"),
            day_high=pos("regularMarketDayHigh"),
            day_low=pos("regularMarketDayLow"),
            prev_close=pos("chartPreviousClose") or pos("previousClose"),
            ts=(datetime.fromtimestamp(ts, tz=timezone.utc)
                if isinstance(ts, (int, float)) else datetime.now(timezone.utc)),
        )

    async def candles(self, symbol: str, start: datetime, end: datetime,
                      resolution: str = "1") -> Sequence[Candle]:
        iv = INTERVAL.get(resolution, "1m")
        data = await self._get(CHART_URL.format(symbol=symbol), {
            "interval": iv,
            "period1": int(start.timestamp()),
            "period2": int(end.timestamp()),
            "includePrePost": "false",
        })
        result = (((data or {}).get("chart") or {}).get("result") or [None])[0]
        if not result:
            return []

        stamps = result.get("timestamp") or []
        q = ((result.get("indicators") or {}).get("quote") or [{}])[0]
        opens, highs = q.get("open") or [], q.get("high") or []
        lows, closes = q.get("low") or [], q.get("close") or []
        vols = q.get("volume") or []

        out: list[Candle] = []
        for i, t in enumerate(stamps):
            try:
                o, h, l, c = (float(opens[i]), float(highs[i]),
                              float(lows[i]), float(closes[i]))
            except (IndexError, TypeError, ValueError):
                continue          # Yahoo pads gaps with nulls
            if min(o, h, l, c) <= 0:
                continue
            try:
                v = float(vols[i] or 0)
            except (IndexError, TypeError, ValueError):
                v = 0.0
            # market.candle_1m CHECKs that high is the max and low the min;
            # clamp rather than let one bad bar fail the whole insert.
            out.append(Candle(symbol, datetime.fromtimestamp(t, tz=timezone.utc),
                              o, max(h, o, c), min(l, o, c), c, v))
        return out

    async def search(self, query: str, limit: int = 10) -> list[dict]:
        """
        Company-name search. This is the capability Finnhub's free tier
        does not really offer, and it is what makes 'search for a company
        and start trading it' possible.
        """
        data = await self._get(SEARCH_URL, {
            "q": query, "quotesCount": limit, "newsCount": 0,
            "enableFuzzyQuery": "true", "quotesQueryId": "tss_match_phrase_query",
        })
        out: list[dict] = []
        for q in (data or {}).get("quotes", []) or []:
            sym = (q.get("symbol") or "").strip().upper()
            qt = q.get("quoteType")
            if not sym or qt not in ("EQUITY", "ETF", "INDEX", "MUTUALFUND", "CRYPTOCURRENCY"):
                continue
            out.append({
                "symbol": sym,
                "name": q.get("longname") or q.get("shortname") or sym,
                "exchange": q.get("exchDisp") or q.get("exchange") or "",
                # Yahoo says CRYPTOCURRENCY; our instrument_kind calls it crypto.
                "kind": "crypto" if qt == "CRYPTOCURRENCY"
                        else (qt or "EQUITY").lower(),
                "is_crypto": qt == "CRYPTOCURRENCY",
                "sector": q.get("sector") or None,
                "industry": q.get("industry") or None,
            })
            if len(out) >= limit:
                break
        return out

    async def profile(self, symbol: str) -> dict:
        """Metadata used when importing a new instrument."""
        data = await self._get(CHART_URL.format(symbol=symbol),
                               {"interval": "1d", "range": "1d"})
        meta = (((data or {}).get("chart") or {}).get("result") or [{}])[0].get("meta") or {}
        return {
            "currency": (meta.get("currency") or "USD").upper(),
            "exchange": meta.get("exchangeName") or meta.get("fullExchangeName") or "",
            "name": meta.get("longName") or meta.get("shortName") or symbol,
            "instrument_type": (meta.get("instrumentType") or "EQUITY").lower(),
            "timezone": meta.get("exchangeTimezoneName") or "America/New_York",
        }

    async def aclose(self) -> None:
        await self._client.aclose()
