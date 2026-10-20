"""
Yahoo adapter parsing tests, against recorded response shapes.

The live endpoints are unofficial and may be unreachable (corporate
proxies and CI sandboxes commonly block them), so the PARSING is tested
against payloads shaped exactly like Yahoo's real responses -- including
the things that actually break naive clients:

  * `null` padding inside the OHLCV arrays for non-trading minutes
  * a `high` that is lower than the `close` in a malformed bar
  * zero / missing prices for an unknown symbol
  * crypto results in search, which Yahoo labels CRYPTOCURRENCY

Run:  .venv/bin/python backend/tests/test_yahoo_parsing.py
"""
from __future__ import annotations

import asyncio
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.feed.yahoo import YahooFeed  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(cond), detail))
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))


# --- payloads shaped like the real thing -----------------------------
CHART_OK = {"chart": {"result": [{
    "meta": {"currency": "USD", "symbol": "AAPL", "exchangeName": "NMS",
             "instrumentType": "EQUITY", "regularMarketPrice": 227.52,
             "chartPreviousClose": 225.77, "regularMarketOpen": 226.01,
             "regularMarketDayHigh": 228.34, "regularMarketDayLow": 225.12,
             "regularMarketTime": 1729180800,
             "exchangeTimezoneName": "America/New_York",
             "longName": "Apple Inc."},
    "timestamp": [1729170000, 1729170060, 1729170120, 1729170180],
    "indicators": {"quote": [{
        # Yahoo pads non-trading minutes with nulls -- a naive client
        # crashes or inserts zeroes here.
        "open":   [226.01, None, 226.40, 226.55],
        "high":   [226.30, None, 226.52, 226.20],   # last bar: high < close
        "low":    [225.90, None, 226.31, 226.44],
        "close":  [226.22, None, 226.48, 226.61],
        "volume": [120400, None, 98300, 110250],
    }]},
}], "error": None}}

CHART_UNKNOWN = {"chart": {"result": [{
    "meta": {"currency": "USD", "symbol": "ZZZZ", "regularMarketPrice": 0},
    "timestamp": [], "indicators": {"quote": [{}]},
}], "error": None}}

CHART_EMPTY = {"chart": {"result": None,
                         "error": {"code": "Not Found", "description": "No data found"}}}

SEARCH = {"quotes": [
    {"symbol": "AAPL", "shortname": "Apple Inc.", "longname": "Apple Inc.",
     "quoteType": "EQUITY", "exchDisp": "NASDAQ", "sector": "Technology",
     "industry": "Consumer Electronics"},
    {"symbol": "BTC-USD", "shortname": "Bitcoin USD", "quoteType": "CRYPTOCURRENCY",
     "exchDisp": "CCC"},
    {"symbol": "APLE", "shortname": "Apple Hospitality REIT", "quoteType": "EQUITY",
     "exchDisp": "NYSE"},
    {"symbol": "SOMEFUTURE", "quoteType": "FUTURE", "exchDisp": "CME"},
], "news": []}


class MockYahoo(YahooFeed):
    """Same class, with the HTTP layer replaced."""
    def __init__(self, routes):
        super().__init__()
        self._routes = routes
        self.calls: list[str] = []

    async def _get(self, url, params=None, *, with_crumb=False, _retry=True):
        self.calls.append(url)
        for key, payload in self._routes.items():
            if key in url:
                return payload
        return None


async def main() -> int:
    print("\n--- quote parsing ---")
    f = MockYahoo({"/v8/finance/chart/": CHART_OK})
    q = await f.quote("AAPL")
    check("quote returned", q is not None)
    check("last price parsed", q and abs(q.last_price - 227.52) < 1e-9, str(q.last_price))
    check("previous close parsed", q and abs(q.prev_close - 225.77) < 1e-9)
    check("day high/low parsed", q and q.day_high == 228.34 and q.day_low == 225.12)
    check("timestamp is timezone-aware", q and q.ts.tzinfo is not None)
    await f.aclose()

    print("\n--- an unknown symbol must not produce a zero price ---")
    f = MockYahoo({"/v8/finance/chart/": CHART_UNKNOWN})
    check("zero price rejected", await f.quote("ZZZZ") is None,
          "a 0 would violate the price_amt domain")
    await f.aclose()

    f = MockYahoo({"/v8/finance/chart/": CHART_EMPTY})
    check("error payload handled", await f.quote("NOPE") is None)
    await f.aclose()

    f = MockYahoo({})
    check("unreachable host returns None, does not raise", await f.quote("AAPL") is None)
    await f.aclose()

    print("\n--- candle parsing ---")
    f = MockYahoo({"/v8/finance/chart/": CHART_OK})
    end = datetime.now(timezone.utc)
    cs = await f.candles("AAPL", end - timedelta(hours=1), end, "1")
    check("null-padded bars are skipped", len(cs) == 3, f"{len(cs)} of 4 rows kept")
    check("every bar is OHLC-coherent",
          all(c.high >= max(c.open, c.close) and c.low <= min(c.open, c.close) for c in cs),
          "malformed high clamped rather than rejected")
    check("volumes parsed", all(c.volume >= 0 for c in cs))
    check("timestamps ascending", all(cs[i].ts < cs[i+1].ts for i in range(len(cs)-1)))
    await f.aclose()

    print("\n--- company search ---")
    f = MockYahoo({"/v1/finance/search": SEARCH})
    rs = await f.search("apple")
    syms = [r["symbol"] for r in rs]
    check("equities returned", "AAPL" in syms and "APLE" in syms, ", ".join(syms))
    check("crypto returned", "BTC-USD" in syms)
    check("crypto is labelled crypto",
          next(r["kind"] for r in rs if r["symbol"] == "BTC-USD") == "crypto")
    check("futures filtered out", "SOMEFUTURE" not in syms,
          "this venue does not list derivatives")
    check("company name carried", rs[0]["name"] == "Apple Inc.")
    await f.aclose()

    print("\n--- profile ---")
    f = MockYahoo({"/v8/finance/chart/": CHART_OK})
    p = await f.profile("AAPL")
    check("currency parsed", p["currency"] == "USD")
    check("name parsed", p["name"] == "Apple Inc.")
    check("timezone parsed", p["timezone"] == "America/New_York")
    await f.aclose()

    failed = [n for n, ok, _ in RESULTS if not ok]
    print("\n" + "=" * 58)
    print(f"  {len(RESULTS) - len(failed)}/{len(RESULTS)} Yahoo parsing checks passed")
    for n in failed:
        print(f"    FAILED: {n}")
    print("=" * 58)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
