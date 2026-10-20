"""
Market-data ingestion worker.

Polls the configured feed, writes ticks, refreshes quotes, rolls candles
and runs the circuit breaker. Runs as a background task inside the API
process for the demo; in production this would be its own deployment.

Writes through the OWNER connection because ingestion legitimately spans
all tenants -- it is not acting on behalf of any user.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

from ..core import db
from ..core.config import get_settings
from .base import MarketDataFeed
from .factory import build_feed

log = logging.getLogger(__name__)

# How far an external mark may sit from this venue's own last traded price
# before it is treated as belonging to a different price universe rather
# than as a market move. 50% is far wider than any real session.
DIVERGENCE_LIMIT = Decimal("0.5")


def money(x, places: int = 2) -> Decimal:
    """Exact Decimal. Never hand a float to a NUMERIC column."""
    return Decimal(str(x)).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def price(x) -> Decimal:
    """
    Quantise a price to a precision that suits its magnitude.

    money(x, 2) was applied to every price in the ingestion path. That is
    correct for a $195 share and wrong for a $0.13 coin: quantising
    DOGE-USD to two decimals rounds a 4% move to nothing, so every poll
    wrote the same price, the chart went flat and the mark never updated.
    """
    d = Decimal(str(x))
    a = abs(d)
    if a >= 100:
        places = 2
    elif a >= 1:
        places = 4
    elif a >= Decimal("0.01"):
        places = 6
    else:
        places = 8
    return d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


class IngestionWorker:
    def __init__(self) -> None:
        self._feed: MarketDataFeed | None = None
        self._task: asyncio.Task | None = None
        self._primed: set[str] = set()
        self._empty_polls = 0
        self._degraded = False
        self._divergent: dict[str, tuple[Decimal, Decimal]] = {}
        self._warned_divergence = False
        self._stop = asyncio.Event()
        self.ticks_written = 0
        self.alerts_fired = 0
        self.last_poll: datetime | None = None

    async def start(self) -> None:
        self._feed = build_feed()
        self._task = asyncio.create_task(self._run(), name="apex-ingestion")
        log.info("ingestion worker started (provider=%s)", self._feed.name)

    async def stop(self) -> None:
        self._stop.set()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        if self._feed is not None:
            await self._feed.aclose()

    async def _run(self) -> None:
        s = get_settings()

        candle_tick = 0
        while not self._stop.is_set():
            try:
                await self._poll_once()
                candle_tick += 1
                # Roll the last few minutes into candles periodically so
                # charts stay current without rebuilding the whole day.
                if candle_tick % 10 == 0:
                    await self._roll_candles()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("ingestion cycle failed; continuing")

            try:
                await asyncio.wait_for(self._stop.wait(), timeout=s.feed_poll_seconds)
            except asyncio.TimeoutError:
                pass

    async def _poll_once(self) -> None:
        """
        One ingestion cycle, batched.

        The first version of this did four sequential round trips per
        instrument -- fetch, upsert quote, insert tick, check the circuit
        breaker -- which is 64 round trips for a 16-name universe, every
        poll. Each one is individually fast, but they are serialised on
        the same event loop the API serves requests from, so a poll cycle
        landing on top of an order visibly delayed it.

        Now the whole cycle is three statements: prices are gathered
        first, then written with UNNEST-based set operations, and the
        circuit breaker runs only for instruments whose price actually
        moved (normally none).
        """
        async with db.acquire_admin() as conn:
            instruments = await conn.fetch("""
                SELECT i.instrument_id, i.symbol, q.last_price, q.reference_price,
                       COALESCE(q.last_price, q.reference_price, c.close) AS anchor
                  FROM reference.instrument i
                  LEFT JOIN market.quote q ON q.instrument_id = i.instrument_id
                  LEFT JOIN LATERAL (
                        SELECT close FROM market.candle_1m
                         WHERE instrument_id = i.instrument_id
                         ORDER BY bucket_start DESC LIMIT 1) c ON TRUE
                 WHERE i.is_tradable ORDER BY i.instrument_id;""")

            # Prime the simulator from stored history so the live walk
            # CONTINUES that history instead of restarting from the
            # profile's opening price.
            #
            # This used to run once, at worker start. That was a real bug:
            # the worker starts with the API, and instruments arrive later
            # -- a reseed, or /market/import adding a symbol on demand.
            # Anything created after start was never primed, so the feed
            # fell back to its default profile; for a symbol with no
            # profile at all it invented one from a hash of the name. That
            # is how ADA-USD, a $0.39 coin, started quoting $57: an
            # unprimed symbol walking from a pseudo-random opening price,
            # which then overwrote the mark and had the price band reject
            # every order on the book. Priming lazily, per symbol, closes
            # the window permanently.
            if hasattr(self._feed, "prime"):
                for inst in instruments:
                    sym = inst["symbol"]
                    if sym in self._primed:
                        continue
                    if inst["anchor"] is not None:
                        self._feed.prime(sym, float(inst["anchor"]))
                        self._primed.add(sym)

            ids: list[int] = []
            prices: list[Decimal] = []
            prev_closes: list[Decimal] = []
            moved: list[int] = []

            for inst in instruments:
                quote = await self._feed.quote(inst["symbol"])
                if quote is None or quote.last_price <= 0:
                    continue

                px = price(quote.last_price)

                # A mark that disagrees with our own tape by this much is
                # not a market move -- it is two different price universes.
                #
                # This happens for a concrete, easy-to-hit reason: the
                # demo seeds from the SIMULATOR, whose META walks around
                # $335, and the API then runs against a LIVE provider,
                # where META is $709. reference_price is what
                # engine.validate_order() anchors the price band on, so
                # adopting the live mark makes the band [567, 851] while
                # the entire order book sits at 335 -- and every single
                # order, on every book, is rejected as "outside the band".
                # Nothing is corrupt and nothing logs an error; the venue
                # just stops accepting trades.
                #
                # So refuse the mark, keep trading, and say so loudly.
                # The real fix is to reseed against the same provider the
                # API runs on, which scripts/seed.py now does.
                venue = inst["last_price"]
                if venue and venue > 0:
                    drift = abs(px - venue) / venue
                    if drift > DIVERGENCE_LIMIT:
                        self._divergent[inst["symbol"]] = (venue, px)
                        continue

                ids.append(inst["instrument_id"])
                prices.append(px)
                prev_closes.append(price(quote.prev_close) if quote.prev_close else px)

                # Only worth re-evaluating the breaker if the reference
                # mark actually moved. Normally this list is empty.
                old = inst["reference_price"]
                if old is None or abs(px - old) / (old or px) > Decimal("0.005"):
                    moved.append(inst["instrument_id"])

            if not ids:
                # The configured provider returned nothing usable for any
                # instrument. That is routine for a live feed -- Yahoo
                # rate limits, a network egress policy blocks it, a key
                # expires -- and the old behaviour was to return quietly
                # and do it again in five seconds, for ever. The symptom
                # is a dashboard whose prices never move and whose feed
                # badge still says "yahoo": the failure is invisible
                # exactly where it matters.
                #
                # After a minute of empty polls, fall back to the
                # simulator and SAY SO. A demo that keeps running on
                # clearly-labelled synthetic prices is more honest than
                # one that silently stops.
                self._empty_polls += 1
                if self._empty_polls >= 12 and not self._degraded:
                    await self._fall_back()
                return

            self._empty_polls = 0

            # The external price is the REFERENCE mark -- it anchors the
            # price band and the circuit breaker. It deliberately does NOT
            # overwrite last_price, which is the last price traded ON THIS
            # VENUE and is our own truth.
            await conn.execute("""
                INSERT INTO market.quote AS q
                      (instrument_id, reference_price, last_price, prev_close,
                       day_open, day_high, day_low, updated_at)
                SELECT v.id, v.px, v.px, v.pc, v.px, v.px, v.px, now()
                  FROM unnest($1::int[], $2::numeric[], $3::numeric[]) AS v(id, px, pc)
                ON CONFLICT (instrument_id) DO UPDATE
                   SET reference_price = EXCLUDED.reference_price,
                       prev_close = COALESCE(q.prev_close, EXCLUDED.prev_close),
                       -- Seed the day range on first sight only. An
                       -- external mark is not a trade, so it must not
                       -- widen a range that fills have established -- but
                       -- leaving the columns NULL on INSERT meant the
                       -- first instrument this worker ever saw had no day
                       -- range at all until something traded in it.
                       day_open = COALESCE(q.day_open, EXCLUDED.day_open),
                       day_high = COALESCE(q.day_high, EXCLUDED.day_high),
                       day_low  = COALESCE(q.day_low,  EXCLUDED.day_low),
                       updated_at = now();
            """, ids, prices, prev_closes)

            # A reference-price update is not a trade. It is recorded as
            # a MARK: it contributes to the candle's OHLC, because it is
            # the best information available about where the instrument
            # is between fills, but is_trade = FALSE keeps it out of
            # volume, trade count and VWAP.
            #
            # It used to be written as volume = 1 with no flag, and the
            # candle builder summed it -- so a live minute bar reported
            # "volume 12" (twelve polls) beside a backfilled bar at
            # 2,500, and VWAP drifted toward a price nothing traded at.
            # See migration 026.
            await conn.execute("""
                INSERT INTO market.tick
                      (instrument_id, ts, price, volume, source, is_trade)
                SELECT v.id, now(), v.px, 0, $3, FALSE
                  FROM unnest($1::int[], $2::numeric[]) AS v(id, px);
            """, ids, prices, self._feed.name)

            if moved:
                await conn.execute("""
                    SELECT risk.check_circuit_breaker(id) FROM unnest($1::int[]) AS id;
                """, moved)

            # Price alerts are evaluated against the prices we just wrote,
            # in the same cycle, and pushed over the same NOTIFY channel
            # the matching engine uses.
            fired = await conn.fetchval("SELECT risk.evaluate_price_alerts()")
            if fired:
                self.alerts_fired += fired
                log.info("price alerts fired: %s", fired)

            self.ticks_written += len(ids)
            self.last_poll = datetime.now(timezone.utc)

            if self._divergent and not self._warned_divergence:
                self._warned_divergence = True
                sample = ", ".join(
                    f"{sym} venue={v} feed={f}"
                    for sym, (v, f) in list(self._divergent.items())[:4])
                log.warning(
                    "%d instrument(s) have a '%s' price more than %.0f%% away from "
                    "this venue's own last traded price. Their marks are being "
                    "IGNORED so the price bands keep containing the order book -- "
                    "adopting them would reject every order on every book. The "
                    "cause is a venue seeded from a different source than the feed "
                    "now running. Fix it by reseeding, which anchors history to "
                    "this feed's prices:  .venv/bin/python scripts/seed.py --reset"
                    "   [%s]",
                    len(self._divergent), self._feed.name if self._feed else "feed",
                    DIVERGENCE_LIMIT * 100, sample)

    async def _fall_back(self) -> None:
        """Swap a dead live feed for the simulator, keeping the prices."""
        from .simulator import SimulatedFeed

        failed = self._feed.name if self._feed else "unknown"
        try:
            if self._feed is not None:
                await self._feed.aclose()
        except Exception:
            log.debug("closing the failed feed raised; continuing")

        self._feed = SimulatedFeed()
        self._degraded = True
        # Everything has to be primed again: the new feed has no state,
        # and priming is what makes it continue the stored history
        # instead of restarting from its own opening prices.
        self._primed.clear()
        log.warning(
            "provider '%s' returned no usable quotes for %d consecutive polls; "
            "falling back to the simulator. Prices from here are synthetic.",
            failed, self._empty_polls)

    @property
    def status(self) -> dict:
        """What the health endpoint and the UI's feed badge report."""
        return {
            "feed": self._feed.name if self._feed else None,
            "degraded": self._degraded,
            "divergent_instruments": sorted(self._divergent),
            "ticks_ingested": self.ticks_written,
            "alerts_fired": self.alerts_fired,
            "last_poll": self.last_poll.isoformat() if self.last_poll else None,
        }

    async def _roll_candles(self) -> None:
        """
        Fold recent ticks into minute bars.

        build_candles_1m() will not overwrite a bar whose source is
        'backfill' (migration 023). That guard is what keeps this from
        eating the tail of a 24x7 instrument's loaded history, which has
        no gap between "history" and "now" to hide in.
        """
        async with db.acquire_admin() as conn:
            now = datetime.now(timezone.utc)
            await conn.fetchval("SELECT market.build_candles_1m($1,$2)",
                                now - timedelta(minutes=15), now + timedelta(minutes=1))


worker = IngestionWorker()
