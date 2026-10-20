"""
Deterministic market simulator.

This exists so the project is fully demonstrable with no API key, no
network and no market hours -- which matters for a graded demo and for
CI. It is not a toy random walk: prices follow geometric Brownian motion
with per-symbol drift and volatility, plus occasional volatility regime
switches and jump events, so the resulting candles have the fat tails and
volatility clustering that make charts and the surveillance rules
behave realistically.

Seeded from the symbol name, so every run produces the SAME history --
reproducibility matters when you are demonstrating a result.
"""
from __future__ import annotations

import math
import random
from datetime import datetime, timedelta, timezone
from typing import Sequence

from .base import Candle, Quote

# Per-symbol character: (starting price, annual drift, annual volatility)
PROFILES: dict[str, tuple[float, float, float]] = {
    "AAPL": (195.0, 0.12, 0.26), "MSFT": (420.0, 0.14, 0.24),
    "GOOGL": (178.0, 0.11, 0.28), "AMZN": (185.0, 0.13, 0.32),
    "NVDA": (122.0, 0.35, 0.52), "META": (505.0, 0.18, 0.36),
    "TSLA": (245.0, 0.05, 0.58), "JPM": (205.0, 0.08, 0.22),
    "V": (285.0, 0.10, 0.20),    "WMT": (78.0, 0.07, 0.17),
    "SPY": (545.0, 0.09, 0.14),  "QQQ": (470.0, 0.12, 0.19),
    "NFLX": (690.0, 0.16, 0.34), "AMD": (152.0, 0.22, 0.48),
    "INTC": (31.0, -0.08, 0.38), "DIS": (95.0, 0.04, 0.27),

    # Crypto: an order of magnitude more volatile than equities, which is
    # why these instruments carry 30-50% price bands rather than 20%.
    "BTC-USD":  (67000.0, 0.45, 0.62),
    "ETH-USD":   (3300.0, 0.40, 0.75),
    "SOL-USD":    (165.0, 0.55, 1.05),
    "XRP-USD":      (0.62, 0.20, 0.95),
    "ADA-USD":      (0.44, 0.15, 0.98),
    "DOGE-USD":     (0.13, 0.10, 1.25),
    "AVAX-USD":    (28.50, 0.30, 1.00),
    "LINK-USD":    (14.80, 0.25, 0.88),
}

# Crypto never closes, so its simulated clock runs every minute of the
# year rather than only during a 390-minute session.
CRYPTO_MINUTES_PER_YEAR = 365 * 24 * 60

TRADING_MINUTES_PER_YEAR = 252 * 390   # 390 minutes in a US session


class SimulatedFeed:
    name = "simulator"

    def __init__(self, seed: int = 20260101):
        self._seed = seed
        self._state: dict[str, float] = {}

    def _profile(self, symbol: str) -> tuple[float, float, float]:
        if symbol in PROFILES:
            return PROFILES[symbol]
        # Unknown symbol: derive a stable pseudo-profile from its name so
        # the same symbol always behaves the same way.
        rng = random.Random(f"{self._seed}:{symbol}")
        return (rng.uniform(20, 400), rng.uniform(-0.05, 0.25), rng.uniform(0.15, 0.55))

    @staticmethod
    def _is_crypto(symbol: str) -> bool:
        return symbol.upper().endswith(("-USD", "-USDT", "-EUR"))

    def _walk(self, symbol: str, minutes: int, *, start_price: float | None = None
              ) -> list[tuple[int, float]]:
        """Generate `minutes` GBM steps. Deterministic per (seed, symbol)."""
        p0, mu, sigma = self._profile(symbol)
        price = start_price if start_price is not None else p0
        rng = random.Random(f"{self._seed}:{symbol}:walk")

        crypto = self._is_crypto(symbol)
        dt = 1.0 / (CRYPTO_MINUTES_PER_YEAR if crypto else TRADING_MINUTES_PER_YEAR)
        drift_term = (mu - 0.5 * sigma ** 2) * dt
        vol_regime = 1.0
        path: list[tuple[int, float]] = []

        for i in range(minutes):
            # Volatility clustering: the regime persists, then switches.
            if rng.random() < 0.004:
                vol_regime = rng.choice([0.6, 0.85, 1.0, 1.4, 2.1])

            shock = rng.gauss(0.0, 1.0) * sigma * vol_regime * math.sqrt(dt)

            # Rare jumps (earnings, news) give the distribution fat tails.
            # Crypto jumps more often and harder.
            jump_p   = 0.0012 if crypto else 0.00035
            jump_mag = (0.02, 0.09) if crypto else (0.012, 0.045)
            if rng.random() < jump_p:
                shock += rng.choice([-1, 1]) * rng.uniform(*jump_mag)

            price *= math.exp(drift_term + shock)
            # A sub-dollar coin must not be floored at 0.50 like a stock.
            price = max(price, 1e-6 if crypto else 0.5)
            # Deliberately NOT rounded here. Rounding every step to 2
            # decimals quantises a 0.13 coin into ~13 distinguishable
            # price levels, so DOGE's whole walk came out as a staircase
            # and its candles had high == low. Rounding belongs at the
            # point of emission, where the caller knows the tick size.
            path.append((i, price))

        return path

    async def candles(
        self, symbol: str, start: datetime, end: datetime, resolution: str = "1"
    ) -> Sequence[Candle]:
        step = {"1": 1, "5": 5, "15": 15, "30": 30, "60": 60, "D": 390}.get(resolution, 1)
        total_minutes = max(int((end - start).total_seconds() // 60), 1)
        path = self._walk(symbol, total_minutes)

        out: list[Candle] = []
        rng = random.Random(f"{self._seed}:{symbol}:bars")

        for base in range(0, len(path) - step + 1, step):
            chunk = [p for _, p in path[base:base + step]]
            if not chunk:
                continue
            o, c = chunk[0], chunk[-1]
            dp = self._decimals(o)
            # Intrabar range extends beyond open/close, as real bars do.
            hi = max(chunk) * (1 + rng.uniform(0.0, 0.0012))
            lo = min(chunk) * (1 - rng.uniform(0.0, 0.0012))
            ts = start + timedelta(minutes=base)

            # Volume is higher when the bar moved more -- range/volume
            # correlation is what makes the volume-anomaly rule meaningful.
            move = abs(c - o) / o if o else 0
            vol = round(rng.uniform(800, 4200) * (1 + move * 45) * step)

            out.append(Candle(symbol, ts.replace(second=0, microsecond=0),
                              round(o, dp), round(max(hi, o, c), dp),
                              round(min(lo, o, c), dp), round(c, dp), float(vol)))
        return out

    @staticmethod
    def _decimals(price: float) -> int:
        """Significant decimals for a price of this magnitude.

        A single `round(x, 2)` is an equity habit. Applied to a 0.13 coin
        it throws away most of the price, and applied to its quote stream
        it makes every poll report the identical price -- which is how
        crypto ended up with flat charts and a mark that never moved.
        """
        if price >= 100:
            return 2
        if price >= 1:
            return 4
        if price >= 0.01:
            return 6
        return 8

    async def quote(self, symbol: str) -> Quote | None:
        """One step forward from the last simulated price."""
        p0, mu, sigma = self._profile(symbol)
        crypto = self._is_crypto(symbol)
        last = self._state.get(symbol, p0)
        dt = 1.0 / (CRYPTO_MINUTES_PER_YEAR if crypto
                    else TRADING_MINUTES_PER_YEAR)
        rng = random.Random()
        floor = 1e-6 if crypto else 0.5
        nxt = max(floor, last * math.exp((mu - 0.5*sigma**2)*dt
                                         + rng.gauss(0, 1) * sigma * math.sqrt(dt)))
        self._state[symbol] = nxt
        dp = self._decimals(nxt)
        return Quote(symbol=symbol, last_price=round(nxt, dp),
                     prev_close=round(last, dp), ts=datetime.now(timezone.utc))

    def prime(self, symbol: str, price: float) -> None:
        """Seed the live walk from the last stored close."""
        self._state[symbol] = price

    async def aclose(self) -> None:
        return None
