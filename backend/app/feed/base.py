"""
Market-data feed abstraction.

Every provider is reduced to two operations -- fetch a quote, fetch
historical candles -- so the ingestion worker never knows or cares which
vendor is behind it. That is what makes the system demoable with no API
key and no network: the simulator satisfies the same interface.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol, Sequence


@dataclass(frozen=True, slots=True)
class Quote:
    symbol: str
    last_price: float
    day_open: float | None = None
    day_high: float | None = None
    day_low: float | None = None
    prev_close: float | None = None
    ts: datetime | None = None


@dataclass(frozen=True, slots=True)
class Candle:
    symbol: str
    ts: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


class MarketDataFeed(Protocol):
    """Interface every provider adapter implements."""

    name: str

    async def quote(self, symbol: str) -> Quote | None: ...

    async def candles(
        self, symbol: str, start: datetime, end: datetime, resolution: str = "1"
    ) -> Sequence[Candle]: ...

    async def aclose(self) -> None: ...
