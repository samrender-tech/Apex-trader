"""
Chooses the market-data provider.

Default order of preference:

  1. yahoo      -- no API key, global coverage, real company search,
                   and crypto. Unofficial, so it can break without notice.
  2. finnhub    -- official and supported, but needs a key and the free
                   tier is US equities only.
  3. simulator  -- deterministic GBM; always available, needs no network.

The point of the abstraction is that the rest of the system cannot tell
which one is behind it. That is what lets the project demo offline.
"""
from __future__ import annotations

import logging

from ..core.config import get_settings
from .base import MarketDataFeed
from .finnhub import FinnhubFeed
from .simulator import SimulatedFeed
from .yahoo import YahooFeed

log = logging.getLogger(__name__)


def build_feed() -> MarketDataFeed:
    s = get_settings()
    want = (s.feed_provider or "auto").lower()

    if want == "simulator":
        return SimulatedFeed()

    if want == "yahoo":
        log.info("market data: Yahoo Finance (no API key)")
        return YahooFeed()

    if want == "finnhub":
        if not s.finnhub_api_key:
            raise RuntimeError(
                "APEX_FEED_PROVIDER=finnhub but APEX_FINNHUB_API_KEY is not set")
        log.info("market data: Finnhub (live)")
        return FinnhubFeed(s.finnhub_api_key)

    if want == "auto":
        # A supplied key is an explicit signal that Finnhub is wanted.
        if s.finnhub_api_key:
            log.info("market data: Finnhub (API key present)")
            return FinnhubFeed(s.finnhub_api_key)
        log.info("market data: Yahoo Finance (no key configured)")
        return YahooFeed()

    raise RuntimeError(f"unknown feed provider: {s.feed_provider!r}")


def build_search_feed() -> MarketDataFeed | None:
    """
    A provider that can search by company name.

    Only Yahoo offers this usefully, so instrument search uses Yahoo even
    when the price feed is something else. Returns None if search is
    disabled.
    """
    s = get_settings()
    if not s.allow_instrument_import:
        return None
    return YahooFeed()
