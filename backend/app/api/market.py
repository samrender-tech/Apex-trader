"""Market data: instruments, quotes, candles, order book, the tape."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

from fastapi import APIRouter, Depends, HTTPException, Query

import asyncpg
from pydantic import BaseModel, Field

from ..core import db
from ..core.config import get_settings
from ..feed.factory import build_search_feed
from .deps import Principal, current_principal

router = APIRouter(prefix="/market", tags=["market"])

# How far back a provider will serve MINUTE bars. Yahoo and Finnhub both
# sit around a week; past that they only offer coarser resolutions, which
# cannot go into market.candle_1m without corrupting every aggregate
# built on top of it.
MINUTE_HISTORY_DAYS = 7


def _d(x, places: int = 8) -> Decimal:
    """Exact Decimal. A float here would violate the tick-size check."""
    return Decimal(str(x)).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)

# Chart intervals -> the PostgreSQL interval handed to market.candles().
INTERVALS = {
    "1m": "1 minute", "5m": "5 minutes", "15m": "15 minutes",
    "30m": "30 minutes", "1h": "1 hour", "4h": "4 hours",
    "1d": "1 day", "1w": "1 week",
}


@router.get("/instruments")
async def list_instruments(
    q: str | None = Query(None, description="fuzzy symbol/name search"),
    sector: str | None = None,
    limit: int = Query(100, le=500),
    p: Principal = Depends(current_principal),
):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT i.instrument_id, i.symbol, i.name, i.sector, i.industry,
                   i.currency, i.tick_size, i.lot_size, i.price_band_pct,
                   i.is_shortable, e.code AS exchange,
                   -- The asset class and its session rule. The UI needs
                   -- both: it groups the tape by class, and it must not
                   -- tell someone the market is closed when they are
                   -- looking at a coin.
                   i.kind::text AS kind, i.trades_24x7,
                   reference.is_instrument_open(i.instrument_id) AS market_open,
                   q.last_price, q.prev_close, q.bid, q.ask, q.day_volume,
                   ROUND((q.last_price - q.prev_close)
                         / NULLIF(q.prev_close,0) * 100, 4) AS change_pct
              FROM reference.instrument i
              JOIN reference.exchange e USING (exchange_id)
              LEFT JOIN market.quote q ON q.instrument_id = i.instrument_id
             WHERE i.is_tradable
               -- Trigram similarity, so "appl" and "aple" both find AAPL.
               AND ($1::text IS NULL OR i.symbol ILIKE '%'||$1||'%'
                                     OR i.name   ILIKE '%'||$1||'%')
               AND ($2::text IS NULL OR i.sector = $2)
             ORDER BY i.symbol
             LIMIT $3;
        """, q, sector, limit)
    return db.rows(recs)


@router.get("/quote/{symbol}")
async def get_quote(symbol: str, p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        rec = await conn.fetchrow(
            "SELECT * FROM market.quote_enriched WHERE symbol = upper($1)", symbol)
    if rec is None:
        raise HTTPException(404, f"no quote for {symbol}")
    return db.row(rec)


@router.get("/candles/{symbol}")
async def get_candles(
    symbol: str,
    interval: str = Query("5m", description="|".join(INTERVALS)),
    days: int = Query(30, ge=1, le=400),
    indicators: bool = Query(False, description="include SMA/Bollinger/RSI"),
    p: Principal = Depends(current_principal),
):
    """
    OHLCV for charting.

    Every interval is aggregated from the SAME 1-minute base table by
    market.candles(), so a 1h bar can never disagree with the 60 minute
    bars inside it.
    """
    if interval not in INTERVALS:
        raise HTTPException(400, f"interval must be one of {sorted(INTERVALS)}")

    fn = "market.candles_with_indicators" if indicators else "market.candles"
    start = datetime.now(timezone.utc) - timedelta(days=days)

    async with db.acquire(p.user_id) as conn:
        iid = await conn.fetchval(
            "SELECT instrument_id FROM reference.instrument WHERE symbol = upper($1)", symbol)
        if iid is None:
            raise HTTPException(404, f"unknown symbol {symbol}")
        recs = await conn.fetch(
            f"SELECT * FROM {fn}($1, ($2::text)::interval, $3, now())",
            iid, INTERVALS[interval], start)

    return {"symbol": symbol.upper(), "interval": interval,
            "count": len(recs), "candles": db.rows(recs)}


@router.get("/book/{symbol}")
async def get_book(
    symbol: str,
    depth: int = Query(10, ge=1, le=50),
    p: Principal = Depends(current_principal),
):
    """Depth-of-market ladder with cumulative size per level."""
    async with db.acquire(p.user_id) as conn:
        iid = await conn.fetchval(
            "SELECT instrument_id FROM reference.instrument WHERE symbol = upper($1)", symbol)
        if iid is None:
            raise HTTPException(404, f"unknown symbol {symbol}")

        bids = await conn.fetch("""
            SELECT price, visible_qty, order_count, cumulative_qty, cumulative_notional
              FROM trading.v_book_depth
             WHERE instrument_id=$1 AND side='buy' AND level_rank <= $2
             ORDER BY level_rank;""", iid, depth)
        asks = await conn.fetch("""
            SELECT price, visible_qty, order_count, cumulative_qty, cumulative_notional
              FROM trading.v_book_depth
             WHERE instrument_id=$1 AND side='sell' AND level_rank <= $2
             ORDER BY level_rank;""", iid, depth)
        quote = await conn.fetchrow(
            "SELECT * FROM market.quote_enriched WHERE instrument_id=$1", iid)

    return {"symbol": symbol.upper(), "quote": db.row(quote),
            "bids": db.rows(bids), "asks": db.rows(asks)}


@router.get("/trades/{symbol}")
async def get_tape(
    symbol: str,
    limit: int = Query(50, le=500),
    p: Principal = Depends(current_principal),
):
    """The public tape: recent prints, counterparties anonymised."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT e.execution_id, e.executed_at, e.price, e.quantity, e.aggressor_side
              FROM trading.execution e
              JOIN reference.instrument i USING (instrument_id)
             WHERE i.symbol = upper($1)
             ORDER BY e.executed_at DESC, e.execution_id DESC
             LIMIT $2;
        """, symbol, limit)
    return db.rows(recs)


@router.get("/movers")
async def get_movers(p: Principal = Depends(current_principal)):
    """Top gainers/losers/most-active for the market overview screen."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT i.symbol, i.name, i.sector, i.kind::text AS kind,
                   i.trades_24x7, q.last_price, q.prev_close,
                   q.day_volume,
                   ROUND((q.last_price-q.prev_close)/NULLIF(q.prev_close,0)*100,4) AS change_pct
              FROM market.quote q
              JOIN reference.instrument i USING (instrument_id)
             WHERE i.is_tradable AND q.prev_close IS NOT NULL
             ORDER BY abs((q.last_price-q.prev_close)/NULLIF(q.prev_close,0)) DESC NULLS LAST;
        """)
    data = db.rows(recs)
    gainers = sorted([r for r in data if float(r["change_pct"] or 0) > 0],
                     key=lambda r: -float(r["change_pct"]))[:5]
    losers = sorted([r for r in data if float(r["change_pct"] or 0) < 0],
                    key=lambda r: float(r["change_pct"]))[:5]
    active = sorted(data, key=lambda r: -float(r["day_volume"] or 0))[:5]
    return {"gainers": gainers, "losers": losers, "most_active": active}


@router.get("/halts")
async def get_halts(p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT h.halt_id, i.symbol, h.halted_from, h.halted_until,
                   h.reason, h.detail, h.reference_price
              FROM risk.trading_halt h
              JOIN reference.instrument i USING (instrument_id)
             WHERE h.halted_until > now()
             ORDER BY h.halted_from DESC;
        """)
    return db.rows(recs)


@router.get("/fx")
async def fx_board(p: Principal = Depends(current_principal)):
    """Live FX board. Cross rates are derived, so no pair can contradict another."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("SELECT * FROM analytics.v_fx_board")
    return db.rows(recs)


@router.get("/fx/history/{code}")
async def fx_history(code: str, days: int = Query(45, ge=1, le=400),
                     p: Principal = Depends(current_principal)):
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT as_of, rate FROM reference.fx_rate
             WHERE base_ccy='USD' AND quote_ccy=upper($1)
               AND as_of > now() - make_interval(days => $2::int)
             ORDER BY as_of;""", code, days)
    return {"currency": code.upper(), "points": db.rows(recs)}


@router.get("/sectors")
async def sector_performance(p: Principal = Depends(current_principal)):
    """Sector roll-up for the market overview."""
    async with db.acquire(p.user_id) as conn:
        recs = await conn.fetch("""
            SELECT i.sector,
                   count(*)                                          AS instruments,
                   round(avg((q.last_price - q.prev_close)
                        / NULLIF(q.prev_close,0) * 100), 4)          AS avg_change_pct,
                   sum(q.day_volume)                                 AS volume,
                   round(sum(q.last_price * COALESCE(i.shares_outstanding,0))/1e9, 1) AS mcap_bn
              FROM reference.instrument i
              JOIN market.quote q USING (instrument_id)
             WHERE i.is_tradable AND q.prev_close IS NOT NULL
             GROUP BY i.sector ORDER BY avg_change_pct DESC NULLS LAST;""")
    return db.rows(recs)


# =====================================================================
# SEARCH -- local first, then the provider.
# =====================================================================
@router.get("/search")
async def search(
    q: str = Query(..., min_length=1, max_length=40),
    include_remote: bool = Query(True, description="also search the data provider"),
    limit: int = Query(12, le=40),
    p: Principal = Depends(current_principal),
):
    """
    Find an instrument.

    Two tiers. Locally listed instruments come first and are tradable
    immediately; results from the data provider are marked `listed:false`
    and can be imported with POST /market/import.

    The local search is a trigram match on symbol AND name, so "aple",
    "apple" and "AAPL" all find the same row.
    """
    async with db.acquire(p.user_id) as conn:
        local = await conn.fetch("""
            SELECT i.instrument_id, i.symbol, i.name, i.kind::text AS kind,
                   i.sector, i.currency, i.trades_24x7, e.code AS exchange,
                   q.last_price, q.prev_close,
                   ROUND((q.last_price-q.prev_close)/NULLIF(q.prev_close,0)*100,4) AS change_pct,
                   GREATEST(similarity(i.symbol, upper($1)), similarity(i.name, $1)) AS score
              FROM reference.instrument i
              JOIN reference.exchange e USING (exchange_id)
              LEFT JOIN market.quote q ON q.instrument_id = i.instrument_id
             WHERE i.is_tradable
               AND (i.symbol ILIKE '%'||$1||'%' OR i.name ILIKE '%'||$1||'%'
                    OR similarity(i.name, $1) > 0.2)
             ORDER BY (i.symbol ILIKE $1||'%') DESC, score DESC, i.symbol
             LIMIT $2;
        """, q, limit)

    results = [{**r, "listed": True} for r in db.rows(local)]
    known = {r["symbol"] for r in results}

    if include_remote and get_settings().allow_instrument_import and len(results) < limit:
        feed = build_search_feed()
        if feed is not None:
            try:
                for hit in await feed.search(q, limit=limit):
                    if hit["symbol"] in known:
                        continue
                    results.append({**hit, "listed": False, "instrument_id": None,
                                    "last_price": None, "change_pct": None})
                    if len(results) >= limit:
                        break
            except Exception as exc:          # provider problems must not break search
                log_detail = str(exc).splitlines()[0][:120]
                results.append({"symbol": None, "name": None, "listed": None,
                                "provider_error": log_detail})
            finally:
                await feed.aclose()

    return [r for r in results if r.get("symbol")]


class ImportIn(BaseModel):
    symbol: str = Field(min_length=1, max_length=20)
    backfill_days: int = Field(default=30, ge=0, le=400)


@router.post("/import", status_code=201)
async def import_instrument(body: ImportIn, p: Principal = Depends(current_principal)):
    """
    List a symbol this venue does not carry yet.

    Fetches the provider's metadata and price history, creates the
    instrument with microstructure rules appropriate to its asset class,
    backfills candles, and seeds a quote -- after which it is tradable
    like any other instrument.
    """
    s = get_settings()
    if not s.allow_instrument_import:
        raise HTTPException(403, "instrument import is disabled on this deployment")

    sym = body.symbol.strip().upper()
    feed = build_search_feed()
    if feed is None:
        raise HTTPException(503, "no search-capable data provider configured")

    try:
        async with db.acquire_admin() as conn:
            existing = await conn.fetchval(
                "SELECT instrument_id FROM reference.instrument WHERE symbol=$1", sym)
            if existing:
                return {"instrument_id": existing, "symbol": sym, "created": False,
                        "message": "already listed"}

            count = await conn.fetchval("SELECT count(*) FROM reference.instrument")
            if count >= s.max_instruments:
                raise HTTPException(
                    409, f"instrument limit reached ({s.max_instruments})")

            profile = await feed.profile(sym)
            quote = await feed.quote(sym)
            if quote is None:
                raise HTTPException(404, f"provider has no usable price for {sym}")

            is_crypto = sym.endswith(("-USD", "-USDT", "-EUR")) or \
                        profile.get("instrument_type") == "cryptocurrency"
            px = float(quote.last_price)

            # Microstructure chosen from the asset class and price level:
            # a sub-dollar coin cannot have a 0.01 tick, and crypto needs
            # fractional lots and a far wider band.
            if is_crypto:
                lot, tick, band, kind = Decimal("0.00000001"), \
                    (Decimal("0.00001") if px < 1 else Decimal("0.01")), 40, "crypto"
                ex_code = "CRYPTO"
            else:
                lot, tick, band, kind = Decimal("1"), Decimal("0.01"), 20, \
                    ("etf" if profile.get("instrument_type") == "etf" else "equity")
                ex_code = "XNAS"

            ex_id = await conn.fetchval(
                "SELECT exchange_id FROM reference.exchange WHERE code=$1", ex_code)

            iid = await conn.fetchval("""
                INSERT INTO reference.instrument
                    (symbol, exchange_id, name, kind, sector, industry, currency,
                     lot_size, tick_size, price_band_pct, is_shortable,
                     trades_24x7, metadata)
                VALUES ($1,$2,$3,$4::reference.instrument_kind,$5,$6,$7,
                        $8::qty_amt,$9::price_amt,$10,$11,$12,$13::jsonb)
                RETURNING instrument_id;
            """, sym, ex_id, profile.get("name") or sym, kind,
                 "Digital Assets" if is_crypto else None,
                 "Cryptocurrency" if is_crypto else None,
                 profile.get("currency", "USD"),
                 lot, tick, band, not is_crypto, is_crypto,
                 json.dumps({"imported_by": p.user_id, "provider": feed.name,
                             "exchange": profile.get("exchange")}))

            # Backfill candles so the chart is not empty on first view.
            #
            # Resolution "1", not "5". market.candle_1m is the ONE base
            # table -- every other interval is aggregated from it by
            # market.candles(), which is what guarantees a 1h bar can
            # never disagree with the 60 minute bars inside it. Writing
            # five-minute bars into minute buckets breaks that guarantee
            # silently: each bucket would hold a bar covering five times
            # its own span, the four minutes between would be missing,
            # and every aggregate above it would be wrong while still
            # looking plausible.
            #
            # Minute data costs range: providers serve roughly a week of
            # it against two months of five-minute bars. A week is the
            # honest limit, so cap rather than quietly change resolution.
            days = min(body.backfill_days, MINUTE_HISTORY_DAYS)
            bars_written = 0
            if days > 0:
                end = datetime.now(timezone.utc)
                start = end - timedelta(days=days)
                bars = await feed.candles(sym, start, end, "1")
                rows = [(iid, b.ts.replace(second=0, microsecond=0),
                         _d(b.open), _d(b.high), _d(b.low), _d(b.close),
                         _d(b.volume, 8), max(int(b.volume // 90), 1),
                         _d((b.high + b.low + b.close) / 3, 8),
                         # 'backfill': loaded history, which the ingestion
                         # worker's tick roller must never overwrite. It
                         # matters most for a 24x7 instrument, whose
                         # history runs right up to the current minute and
                         # so overlaps the roller's window. See 023.
                         "backfill")
                        for b in bars]
                if rows:
                    await conn.copy_records_to_table(
                        "candle_1m", schema_name="market", records=rows,
                        columns=["instrument_id","bucket_start","open","high","low",
                                 "close","volume","trade_count","vwap","source"])
                    bars_written = len(rows)

            await conn.execute("""
                INSERT INTO market.quote
                    (instrument_id,last_price,prev_close,reference_price,
                     day_open,day_high,day_low,day_volume)
                VALUES ($1,$2,$3,$2,$2,$2,$2,0)
                ON CONFLICT (instrument_id) DO UPDATE SET last_price=$2;
            """, iid, _d(px, 8), _d(quote.prev_close or px, 8))

        return {"instrument_id": iid, "symbol": sym, "name": profile.get("name"),
                "kind": kind, "currency": profile.get("currency"),
                "last_price": px, "candles_backfilled": bars_written,
                "backfill_days": days, "tick_size": str(tick),
                "lot_size": str(lot), "created": True}
    except HTTPException:
        raise
    except asyncpg.PostgresError as exc:
        raise HTTPException(400, str(exc).splitlines()[0]) from exc
    finally:
        await feed.aclose()
