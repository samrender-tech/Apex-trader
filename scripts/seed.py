#!/usr/bin/env python3
"""
Apex Trader demo seeder.

Builds a complete, self-consistent venue: instrument master, a trading
calendar, ~45 sessions of 1-minute candle history, funded traders, a
genuine trade history written through the ledger, reconstructed NAV
snapshots, live book liquidity, published copy-trading strategies, and
deliberately planted market-abuse patterns for the surveillance module
to find.

Connects as the OWNER role (not apex_app) because seeding legitimately
writes across every tenant, which Row Level Security is there to stop.

    python scripts/seed.py [--days 45] [--reset]
"""
from __future__ import annotations

import argparse
import os
import pathlib
import asyncio
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from decimal import Decimal, ROUND_HALF_UP

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import asyncpg  # noqa: E402

from app.core.config import get_settings  # noqa: E402
from app.feed.factory import build_feed  # noqa: E402

ADMIN_DSN = os.environ.get(
    "APEX_ADMIN_DSN", "postgresql://apex:apex_dev_pw@127.0.0.1:5432/apex_trader"
)

SESSION_MINUTES = 390            # 09:30 -> 16:00, US equities
CRYPTO_MINUTES_PER_DAY = 1440    # crypto never closes
CRYPTO_DAYS = 14                 # 1440 bars/day adds up; 14 days is plenty to chart


def money(x, places: int = 2) -> Decimal:
    """
    Convert to an exact Decimal at a fixed scale.

    Never pass a Python float to a NUMERIC column. asyncpg encodes floats
    as float8, and 174.73 is not representable in binary, so the server
    receives 174.729999999999989768... -- which fails a tick-size check
    and would silently corrupt a ledger over enough arithmetic. Decimal
    maps to NUMERIC exactly.
    """
    q = Decimal(1).scaleb(-places)
    return Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP)

RNG = random.Random(20260101)  # reproducible demo

INSTRUMENTS = [
    # symbol, name, sector, industry, shortable, band%
    ("AAPL",  "Apple Inc.",            "Technology",        "Consumer Electronics", True,  20),
    ("MSFT",  "Microsoft Corporation", "Technology",        "Software",             True,  20),
    ("GOOGL", "Alphabet Inc.",         "Technology",        "Internet Services",    True,  20),
    ("AMZN",  "Amazon.com Inc.",       "Consumer Cyclical", "Internet Retail",      True,  20),
    ("NVDA",  "NVIDIA Corporation",    "Technology",        "Semiconductors",       True,  25),
    ("META",  "Meta Platforms Inc.",   "Technology",        "Social Media",         True,  20),
    ("TSLA",  "Tesla Inc.",            "Consumer Cyclical", "Auto Manufacturers",   True,  25),
    ("JPM",   "JPMorgan Chase & Co.",  "Financial Services","Banks",                True,  15),
    ("V",     "Visa Inc.",             "Financial Services","Credit Services",      True,  15),
    ("WMT",   "Walmart Inc.",          "Consumer Defensive","Discount Stores",      False, 15),
    ("NFLX",  "Netflix Inc.",          "Communication",     "Entertainment",        True,  25),
    ("AMD",   "Advanced Micro Devices","Technology",        "Semiconductors",       True,  25),
    ("INTC",  "Intel Corporation",     "Technology",        "Semiconductors",       True,  20),
    ("DIS",   "The Walt Disney Company","Communication",    "Entertainment",        True,  20),
    ("SPY",   "SPDR S&P 500 ETF Trust","Index",             "Broad Market ETF",     True,  10),
    ("QQQ",   "Invesco QQQ Trust",     "Index",             "Nasdaq 100 ETF",       True,  10),
]

# The project team, each funded in a different currency so the
# multi-currency ledger is visible the moment you log in.
# (email, display name, account kind, leverage, base ccy, deposit in THAT ccy, role, shorting)
# The last column is allow_short_selling.
#
# It is FALSE for every demo trader, deliberately. Short selling is a real
# feature here -- the risk gate and the ledger each enforce it
# independently -- but it is the wrong default for the account you sign in
# with first. With it on, selling more shares than you hold does not fail:
# it opens a short, and the holdings table shows -6 MSFT, which reads as a
# bug even though the engine did exactly what the account permitted.
#
# Off by default means over-selling is refused with a message naming what
# you actually hold. To demonstrate shorting, turn it on for one account:
#
#   ./scripts/db.sh psql -c "UPDATE trading.account SET allow_short_selling = TRUE
#                             WHERE account_no = 'APX-000001';"
#
# A cash account still cannot be given it -- short_requires_margin (018)
# refuses at the constraint level, not in application code.
TRADERS = [
    ("samrender@apex.io", "Samrender Singh Saini", "margin", 4.0, "USD",   500_000, "trader",     False),
    ("vartika@apex.io",   "Vartika Chaudhary",     "margin", 3.0, "USD",   400_000, "trader",     False),
    ("paritosh@apex.io",  "Kumar Paritosh",        "margin", 2.0, "GBP",   180_000, "trader",     False),
    ("sam@apex.io",       "Sam Saini",             "cash",   1.0, "INR", 9_000_000, "trader",     False),
    ("ginni@apex.io",     "Ginni Kaur",            "cash",   1.0, "EUR",   120_000, "trader",     False),
    ("pari@apex.io",      "Pari Sharma",           "cash",   1.0, "AED",   300_000, "trader",     False),
    ("compliance@apex.io","Ravi Compliance",       "cash",   1.0, "USD",    10_000, "compliance", False),
    ("admin@apex.io",     "Apex Admin",            "cash",   1.0, "USD",    10_000, "admin",      False),
]

DEMO_PASSWORD = "Apex@2026"


def _dotenv_value(key: str) -> str | None:
    """Read one key from .env without importing the app's settings.

    The seeder needs to know which provider the API will use, and the API
    reads .env. Parsing it here keeps the two from disagreeing about a
    value that decides whether the whole venue is tradable.
    """
    env = pathlib.Path(__file__).resolve().parent.parent / ".env"
    if not env.is_file():
        return None
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            return v.strip().strip('"').strip("'") or None
    return None


def trading_days(end: datetime, n: int) -> list[datetime]:
    """The last n weekdays, oldest first."""
    days, cur = [], end.date()
    while len(days) < n:
        if cur.weekday() < 5:
            days.append(cur)
        cur -= timedelta(days=1)
    return sorted(days)


async def check_schema_current(conn) -> None:
    """
    Refuse to seed a database whose migrations are not up to date.

    Without this the seeder dies on whichever table happens to be missing
    first -- "relation reference.fx_rate does not exist" and a 20-line
    traceback -- which says nothing about the actual problem, that
    `db.sh migrate` was never run. Fail early, and say what to do.
    """
    migrations_dir = Path(__file__).resolve().parent.parent / "db" / "migrations"
    on_disk = sorted(f.name for f in migrations_dir.glob("*.sql"))

    tracked = await conn.fetchval("SELECT to_regclass('ops.schema_migration') IS NOT NULL")
    if not tracked:
        print("\n  ERROR: this database has no migration tracking table.\n"
              "  It has never been migrated with the current scripts.\n\n"
              "  Run this first:\n      ./scripts/db.sh migrate\n")
        raise SystemExit(2)

    applied = {r["filename"] for r in
               await conn.fetch("SELECT filename FROM ops.schema_migration")}
    pending = [m for m in on_disk if m not in applied]

    if pending:
        print(f"\n  ERROR: {len(pending)} migration(s) have not been applied:\n")
        for m in pending:
            print(f"      - {m}")
        print("\n  Seeding now would fail on a missing table. Run:\n"
              "      ./scripts/db.sh migrate\n"
              "  then run this seeder again.\n")
        raise SystemExit(2)

    print(f"  schema up to date ({len(applied)} migrations applied)")


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=45, help="sessions of history to build")
    ap.add_argument("--reset", action="store_true", help="wipe existing demo data first")
    ap.add_argument("--provider", default="simulator",
                    choices=["simulator", "yahoo", "finnhub"],
                    help="where bulk history comes from (default: simulator)")
    ap.add_argument("--anchor", default="auto",
                    choices=["auto", "live", "none"],
                    help="scale simulated history so it ENDS at the live price "
                         "(default: auto -- on whenever the API will run a live feed)")
    args = ap.parse_args()

    # Bulk history comes from the SIMULATOR by default, deliberately.
    #
    # Seeding 45 sessions of 1-minute bars is ~17,500 bars per symbol
    # across two dozen symbols. No public market-data endpoint will serve
    # that -- Yahoo rate limits or blocks it, Finnhub's free tier is 60
    # calls a minute -- and hammering an unofficial endpoint for demo data
    # would be abusive besides.
    #
    # The live providers are for the ONGOING tick feed, which is a handful
    # of calls per cycle. Pass --provider=yahoo to override, knowing that.
    # WHICH PROVIDER WILL THE API RUN ON?
    #
    # This matters more than it looks. The simulator's META walks around
    # $335; the real one is $709. Seed from the simulator, then start the
    # API on a live feed, and the ingestion worker marks
    # market.quote.reference_price at the REAL price -- which is exactly
    # what engine.validate_order() anchors the price band on. The band
    # becomes [567, 851] while the whole order book sits at 335, and every
    # order on every book is rejected as "outside the band". No error, no
    # corruption: the venue simply stops accepting trades.
    #
    # So find out where the API is headed, and anchor the history there.
    api_provider = (os.environ.get("APEX_FEED_PROVIDER_API")
                    or _dotenv_value("APEX_FEED_PROVIDER") or "auto").lower()
    if api_provider == "auto":
        api_provider = "finnhub" if (_dotenv_value("APEX_FINNHUB_API_KEY")
                                     or os.environ.get("APEX_FINNHUB_API_KEY")) else "yahoo"

    anchor = args.anchor
    if anchor == "auto":
        # Only worth doing when the two would otherwise disagree.
        anchor = "live" if (api_provider != "simulator"
                            and args.provider == "simulator") else "none"

    os.environ["APEX_FEED_PROVIDER"] = args.provider
    get_settings.cache_clear()
    feed = build_feed()
    conn = await asyncpg.connect(ADMIN_DSN)
    print(f"connected :: feed provider = {feed.name}")
    if anchor == "live":
        print(f"  history will be anchored to live '{api_provider}' prices "
              f"(the API will run on that feed)")
    await check_schema_current(conn)

    try:
        if args.reset:
            await conn.execute("""
                TRUNCATE trading.execution, ledger.posting, ledger.journal_entry,
                         ledger.balance, trading.position, trading.trade_order,
                         market.tick, market.quote, market.candle_1m,
                         risk.trading_halt, risk.margin_call, surveil.alert,
                         social.copy_link, social.copy_queue, social.copy_subscription,
                         social.follow, social.strategy, analytics.account_snapshot,
                         audit.activity_log, ops.job_run,
                         -- These must be TRUNCATEd, not left to the cascade
                         -- from DELETE FROM identity.app_user. risk.alert_fire
                         -- is append-only (a row trigger refuses DELETE) and
                         -- migration 025 made price_alert's FK RESTRICT so the
                         -- audit trail cannot be cascaded away. TRUNCATE does
                         -- not fire row triggers, which is exactly the escape
                         -- hatch a full reset needs -- and nothing else gets.
                         risk.alert_fire, risk.price_alert,
                         social.watchlist_item, social.watchlist
                CASCADE;
                DELETE FROM trading.account WHERE NOT is_system;
                DELETE FROM identity.app_user;
                DELETE FROM reference.corporate_action;
                -- Keep the far-dated baseline rows (they guarantee a rate
                -- exists for any historical lookup); drop generated history.
                DELETE FROM reference.fx_rate WHERE source <> 'baseline';
                DELETE FROM reference.trading_session;
                DELETE FROM reference.instrument;
                DELETE FROM reference.exchange;
                ALTER SEQUENCE engine.order_seq RESTART WITH 1;
            """)
            print("  reset complete")

        # ---------------- 1. exchange + instruments ----------------
        ex_id = await conn.fetchval("""
            INSERT INTO reference.exchange
                (code,name,country_code,timezone,currency,session_open,session_close)
            VALUES ('XNAS','Nasdaq Stock Market','US','America/New_York','USD','09:30','16:00')
            ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
            RETURNING exchange_id;
        """)
        await conn.execute("""
            INSERT INTO reference.exchange
                (code,name,country_code,timezone,currency,session_open,session_close)
            VALUES ('XNYS','New York Stock Exchange','US','America/New_York','USD','09:30','16:00')
            ON CONFLICT (code) DO NOTHING;
        """)

        for sym, name, sector, industry, shortable, band in INSTRUMENTS:
            await conn.execute("""
                INSERT INTO reference.instrument
                    (symbol,exchange_id,name,sector,industry,currency,
                     tick_size,lot_size,price_band_pct,is_shortable,
                     shares_outstanding,metadata)
                VALUES ($1,$2,$3,$4,$5,'USD',0.01,1,$6,$7,$8,$9)
                ON CONFLICT (exchange_id,symbol) DO UPDATE
                   SET name=EXCLUDED.name, sector=EXCLUDED.sector;
            """, sym, ex_id, name, sector, industry, band, shortable,
                 RNG.randint(500_000_000, 16_000_000_000),
                 '{"feed":"finnhub","asset_class":"equity"}')
        # The reset wiped reference.instrument, which also removed the
        # crypto listings created by migration 022. Put them back from the
        # same definition rather than duplicating it here.
        n_crypto = await conn.fetchval("SELECT reference.ensure_crypto_instruments()")
        print(f"  {len(INSTRUMENTS)} equities + {n_crypto} crypto pairs")

        rows = await conn.fetch(
            "SELECT symbol, instrument_id, trades_24x7 FROM reference.instrument")
        inst = {r["symbol"]: r["instrument_id"] for r in rows}
        crypto_syms = {r["symbol"] for r in rows if r["trades_24x7"]}
        # Microstructure per symbol. Prices must land on the tick grid and
        # quantities on the lot grid, and both differ by three orders of
        # magnitude between an equity and a sub-dollar coin -- so nothing
        # downstream may assume 0.01 / 1.
        micro = {r["symbol"]: (r["tick_size"], r["lot_size"])
                 for r in await conn.fetch(
                     "SELECT symbol, tick_size, lot_size FROM reference.instrument")}

        # ---------------- 2. trading calendar ----------------
        days = trading_days(datetime.now(timezone.utc), args.days)
        await conn.execute("""
            INSERT INTO reference.trading_session
                (exchange_id, session_date, is_trading_day, open_ts, close_ts)
            SELECT e.exchange_id, d::date,
                   EXTRACT(ISODOW FROM d) <= 5,
                   CASE WHEN EXTRACT(ISODOW FROM d) <= 5
                        THEN (d::date + e.session_open) AT TIME ZONE e.timezone END,
                   CASE WHEN EXTRACT(ISODOW FROM d) <= 5
                        THEN (d::date + e.session_close) AT TIME ZONE e.timezone END
              FROM reference.exchange e,
                   generate_series($1::date, $2::date, '1 day') d
            ON CONFLICT (exchange_id, session_date) DO NOTHING;
        """, days[0], days[-1] + timedelta(days=5))
        print(f"  trading calendar :: {days[0]} .. {days[-1]} ({len(days)} sessions)")

        # ---------------- 2b. live price anchors ----------------
        # One quote per symbol from the provider the API will run on --
        # two dozen calls, not the ~440,000 bars that make bulk history
        # impossible to fetch live. Each symbol's simulated walk is then
        # SCALED so its final close lands exactly on the live price.
        #
        # The shape of the history stays synthetic and reproducible; only
        # its level changes. What that buys is continuity: the book, the
        # positions, the candles and the feed all agree, so the price band
        # anchored on reference_price contains the book instead of
        # excluding it, and the chart has no cliff at the right-hand edge
        # where simulated history meets live ticks.
        anchors: dict[str, float] = {}
        if anchor == "live":
            os.environ["APEX_FEED_PROVIDER"] = api_provider
            get_settings.cache_clear()
            live = build_feed()
            try:
                for sym in inst:
                    try:
                        q = await live.quote(sym)
                    except Exception:
                        q = None
                    if q and q.last_price and float(q.last_price) > 0:
                        anchors[sym] = float(q.last_price)
            finally:
                await live.aclose()
            os.environ["APEX_FEED_PROVIDER"] = args.provider
            get_settings.cache_clear()

            if anchors:
                print(f"  {len(anchors)}/{len(inst)} live anchor prices from {api_provider}")
            if len(anchors) < len(inst):
                missing = sorted(set(inst) - set(anchors))
                print(f"    ! no live price for {len(missing)}: {', '.join(missing[:6])}"
                      f"{' ...' if len(missing) > 6 else ''}")
                print("      those keep simulated levels; the worker will refuse a feed "
                      "mark that disagrees with them rather than breaking their books")

        # ---------------- 3. candle history ----------------
        # One continuous price walk per symbol, then sliced across the
        # session minutes of each trading day.
        total_rows = 0
        last_close: dict[str, float] = {}
        for sym, iid in inst.items():
            # Crypto never closes, so its bars run continuously rather than
            # in 390-minute session blocks. Fewer days keeps the row count
            # sane: 1440 bars/day adds up fast.
            is_crypto = sym in crypto_syms
            c_days = min(len(days), CRYPTO_DAYS) if is_crypto else len(days)
            need = (CRYPTO_MINUTES_PER_DAY * c_days) if is_crypto \
                   else (SESSION_MINUTES * len(days))
            anchor = datetime.now(timezone.utc) - timedelta(minutes=need)
            bars = await feed.candles(sym, anchor, datetime.now(timezone.utc), "1")
            if not bars:
                print(f"\n  ERROR: the '{feed.name}' provider returned NO price history "
                      f"for {sym}.\n"
                      f"  Seeding would produce an empty database with no charts.\n\n"
                      f"  If you passed --provider, that provider is unreachable or is\n"
                      f"  rate limiting bulk history. Re-run with the default:\n"
                      f"      .venv/bin/python scripts/seed.py --days {args.days} --reset\n")
                raise SystemExit(3)
            if len(bars) < need * 0.9:
                print(f"    ! {sym}: only {len(bars)} of {need} bars available")
            # Scale the whole series so it ENDS at the live price. Applied
            # to the bars as they are written, so open/high/low/close stay
            # internally consistent and the ohlc_coherent CHECK still holds.
            scale = 1.0
            if sym in anchors and bars:
                last_sim = float(bars[-1].close)
                if last_sim > 0:
                    scale = anchors[sym] / last_sim

            rows = []
            i = 0

            if is_crypto:
                # One continuous run of minutes ending now.
                start = (datetime.now(timezone.utc).replace(second=0, microsecond=0)
                         - timedelta(minutes=need))
                for m in range(need):
                    if i >= len(bars):
                        break
                    b = bars[i]; i += 1
                    ts = start + timedelta(minutes=m)
                    dp = 8
                    o, h, l, c = (money(b.open * scale, dp), money(b.high * scale, dp),
                                  money(b.low * scale, dp), money(b.close * scale, dp))
                    # 'backfill' marks this bar as real loaded history, so
                    # the ingestion worker's tick roller will not overwrite
                    # it. Crypto runs 24x7, so its history reaches the
                    # current minute and the roller's window overlaps it --
                    # without the marker the last bars of every coin were
                    # replaced by a handful of unit ticks.
                    rows.append((iid, ts, o, h, l, c, money(b.volume, 8),
                                 max(int(b.volume // 90), 1),
                                 money((h + l + c) / 3, 8), 'backfill'))
                    last_close[sym] = b.close * scale
                await conn.copy_records_to_table(
                    "candle_1m", schema_name="market", records=rows,
                    columns=["instrument_id", "bucket_start", "open", "high", "low",
                             "close", "volume", "trade_count", "vwap", "source"])
                total_rows += len(rows)
                continue

            for d in days:
                # 09:30 New York == 13:30 UTC (EST) / 13:30 EDT offset
                # handled by storing UTC directly from the session open.
                open_utc = await conn.fetchval(
                    "SELECT open_ts FROM reference.trading_session "
                    "WHERE exchange_id=$1 AND session_date=$2", ex_id, d)
                if open_utc is None:
                    continue
                for m in range(SESSION_MINUTES):
                    if i >= len(bars):
                        break
                    b = bars[i]; i += 1
                    ts = open_utc + timedelta(minutes=m)
                    o, h, l, c = (money(b.open * scale), money(b.high * scale),
                                  money(b.low * scale), money(b.close * scale))
                    vwap = money((h + l + c) / 3, 8)
                    rows.append((iid, ts, o, h, l, c,
                                 money(b.volume, 8),
                                 max(int(b.volume // 90), 1), vwap, 'backfill'))
                    last_close[sym] = b.close * scale

            await conn.copy_records_to_table(
                "candle_1m", schema_name="market", records=rows,
                columns=["instrument_id", "bucket_start", "open", "high", "low",
                         "close", "volume", "trade_count", "vwap", "source"])
            total_rows += len(rows)
        print(f"  {total_rows:,} 1-minute candles across {len(inst)} instruments")

        # ---------------- 3b. FX rate history ----------------
        # The rate table is a TIME SERIES, so a trade settled three weeks
        # ago is converted at that day's rate rather than today's. Without
        # this, valuing history silently applies a look-ahead rate.
        fx_rows = []
        for ccy, start in (("INR", 83.25), ("EUR", 0.9210), ("GBP", 0.7880),
                           ("JPY", 149.30), ("AED", 3.6725), ("SGD", 1.3420),
                           ("AUD", 1.5180), ("CAD", 1.3640), ("CHF", 0.8810)):
            rate = start
            for d in days:
                # Pegged currencies barely move; floating ones drift.
                vol = 0.0004 if ccy == "AED" else 0.004
                rate *= (1 + RNG.gauss(0, vol))
                fx_rows.append((
                    "USD", ccy,
                    datetime.combine(d, datetime.min.time(), tzinfo=timezone.utc)
                        + timedelta(hours=13, minutes=30),
                    money(rate, 10), "simulated"))
        await conn.copy_records_to_table(
            "fx_rate", schema_name="reference", records=fx_rows,
            columns=["base_ccy", "quote_ccy", "as_of", "rate", "source"])
        print(f"  {len(fx_rows):,} FX rate points across "
              f"{len({r[1] for r in fx_rows})} currency pairs")

        # ---------------- 4. live quotes ----------------
        # prev_close must be the close of the session BEFORE the last one.
        # Anchoring it to "before today" breaks whenever the last session
        # is not today -- on a weekend every instrument then reports a 0.00%
        # day change, because prev_close and last_price are the same bar.
        last_session_open = await conn.fetchval(
            "SELECT open_ts FROM reference.trading_session "
            "WHERE exchange_id=$1 AND session_date=$2", ex_id, days[-1])

        for sym, iid in inst.items():
            px = last_close.get(sym)
            if px is None:
                continue
            # Crypto has no session open to measure "yesterday" from, so
            # its previous close is simply 24 hours back.
            cutoff = (datetime.now(timezone.utc) - timedelta(days=1)
                      if sym in crypto_syms else last_session_open)
            prev = await conn.fetchval("""
                SELECT c.close FROM market.candle_1m c
                 WHERE c.instrument_id=$1
                   AND c.bucket_start < $2
                 ORDER BY c.bucket_start DESC LIMIT 1;""", iid, cutoff)
            await conn.execute("""
                INSERT INTO market.quote
                    (instrument_id,last_price,prev_close,reference_price,
                     day_open,day_high,day_low,day_volume)
                VALUES ($1,$2,$3,$2,$2,$2,$2,0)
                ON CONFLICT (instrument_id) DO UPDATE
                   SET last_price=$2, prev_close=$3, reference_price=$2,
                       -- The day columns matter here too. The ingestion
                       -- worker may already have created this row (it
                       -- runs in the API process, which does not stop
                       -- while the seeder works) and its INSERT leaves
                       -- day_open/high/low NULL. Taking the conflict
                       -- branch and not setting them left the quote strip
                       -- reading "Day —" for any instrument the worker
                       -- happened to touch first.
                       day_open  = COALESCE(market.quote.day_open,  $2),
                       day_high  = GREATEST(COALESCE(market.quote.day_high, $2), $2),
                       day_low   = LEAST(COALESCE(market.quote.day_low,  $2), $2);
            """, iid, money(px, 8), money(prev if prev is not None else px, 8))
        print("  live quotes primed")

        # ---------------- 5. users, accounts, funding ----------------
        bank = await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE system_code='EXTERNAL_CASH'")
        float_acct = await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE system_code='SECURITY_FLOAT'")
        mm_acct = await conn.fetchval(
            "SELECT account_id FROM trading.account WHERE system_code='MARKET_MAKER'")

        # Every setup entry is backdated to the day BEFORE the first
        # session. Without this the deposits carry now() while the trades
        # are backdated, so the journal says traders bought stock before
        # their money arrived -- which makes every reconstructed NAV
        # before today negative and every performance statistic garbage.
        setup_at = datetime.combine(days[0] - timedelta(days=1),
                                    datetime.min.time(), tzinfo=timezone.utc)

        accounts: dict[str, int] = {}
        deposits_usd: dict[str, Decimal] = {}
        for email, name, kind, lev, ccy, deposit, role, shorts in TRADERS:
            uid = await conn.fetchval("""
                INSERT INTO identity.app_user
                    (email,password_hash,full_name,role,kyc_state,kyc_verified_at,country_code)
                VALUES ($1, identity.hash_password($2), $3, $4::identity.user_role,
                        'verified', now(), 'IN')
                ON CONFLICT (lower(email)) DO UPDATE SET full_name=EXCLUDED.full_name
                RETURNING user_id;
            """, email, DEMO_PASSWORD, name, role)
            acct = await conn.fetchval("""
                INSERT INTO trading.account
                    (account_no,user_id,kind,leverage,base_currency,allow_short_selling)
                VALUES ('APX-'||lpad($1::bigint::text,6,'0'), $1::bigint,
                        $2::trading.account_kind, $3::numeric, $4, $5)
                ON CONFLICT (account_no) DO UPDATE
                   SET kind=EXCLUDED.kind, base_currency=EXCLUDED.base_currency
                RETURNING account_id;
            """, uid, kind, lev, ccy, shorts)
            accounts[email] = acct

            # Funded in their OWN currency: the deposit entry is booked in
            # INR for a rupee account, not converted on the way in.
            await conn.execute("""
                SELECT ledger.post_entry('deposit', $1,
                    ARRAY[ ROW($2::bigint,'cash',NULL,$3::money_amt,'bank debit')::ledger.leg,
                           ROW($4::bigint,'cash',NULL,$5::money_amt,'account credit')::ledger.leg ],
                    NULL, NULL, $6::timestamptz, NULL, $7);
            """, f"Initial funding for {name}", bank, -deposit, acct, deposit, setup_at, ccy)

            deposits_usd[email] = await conn.fetchval(
                "SELECT reference.fx_convert($1::numeric,$2,'USD')", deposit, ccy)

        print(f"  {len(accounts)} traders funded in "
              f"{len({t[4] for t in TRADERS})} currencies")

        # ---------------- 6. market-maker inventory ----------------
        # The MM needs cash and shares to quote both sides of every book.
        await conn.execute("""
            SELECT ledger.post_entry('deposit','Market maker capitalisation',
                ARRAY[ ROW($1::bigint,'cash',NULL,-50000000::money_amt,NULL)::ledger.leg,
                       ROW($2::bigint,'cash',NULL, 50000000::money_amt,NULL)::ledger.leg ],
                NULL, NULL, $3::timestamptz);
        """, bank, mm_acct, setup_at)
        for sym, iid in inst.items():
            await conn.execute("""
                SELECT ledger.post_entry('adjustment',$1,
                    ARRAY[ ROW($2::bigint,'security',$3::int,-200000::money_amt,NULL)::ledger.leg,
                           ROW($4::bigint,'security',$3::int, 200000::money_amt,NULL)::ledger.leg ],
                    NULL, NULL, $5::timestamptz);
            """, f"Share issuance {sym}", float_acct, iid, mm_acct, setup_at)
            await conn.execute("SELECT trading.set_cost_basis($1,$2,$3)",
                               mm_acct, iid, money(last_close.get(sym, 100.0)))
        print("  market maker capitalised with inventory in every name")

        # ---------------- 7. historical trade history ----------------
        # Written through ops.backfill_execution so the ledger, positions
        # and point-in-time queries all see a genuine past.
        trader_emails = [e for e, *_ in TRADERS if e not in
                         ("compliance@apex.io", "admin@apex.io")]
        fills = 0
        for d in days:
            open_utc = await conn.fetchval(
                "SELECT open_ts FROM reference.trading_session "
                "WHERE exchange_id=$1 AND session_date=$2", ex_id, d)
            if open_utc is None:
                continue
            for _ in range(RNG.randint(6, 14)):
                email = RNG.choice(trader_emails)
                sym = RNG.choice(list(inst.keys()))
                iid = inst[sym]
                minute = RNG.randint(0, SESSION_MINUTES - 1)
                at = open_utc + timedelta(minutes=minute, seconds=RNG.randint(0, 59))
                px = await conn.fetchval("""
                    SELECT close FROM market.candle_1m
                     WHERE instrument_id=$1 AND bucket_start <= $2
                     ORDER BY bucket_start DESC LIMIT 1;""", iid, at)
                if not px:
                    continue
                # Size by notional, not by share count. 50 units is a
                # sensible equity clip and an absurd one in BTC-USD: at
                # $67,000 it is a $3.3m order that no demo account can
                # pay for, so every crypto fill failed its pre-trade
                # check and crypto never appeared in anyone's portfolio.
                tick, lot = micro[sym]
                px_d = (Decimal(str(px)) / tick).quantize(Decimal(1)) * tick
                if px_d <= 0:
                    continue
                target = Decimal(RNG.choice([2_000, 5_000, 8_000, 12_000, 20_000]))
                qty = max(((target / px_d) / lot).quantize(Decimal(1)) * lot, lot)
                px = px_d
                acct = accounts[email]
                # Buy from the market maker, or sell back to it.
                buying = RNG.random() < 0.58
                held = await conn.fetchval("SELECT ledger.position_qty($1,$2)", acct, iid)
                if not buying and (held or 0) < qty:
                    buying = True
                # Prices are USD, but an account may hold no USD at all --
                # measure its total spending power across every currency.
                cash = await conn.fetchval(
                    "SELECT ledger.cash_total_in($1,'USD')", acct)
                # Keep a cash reserve. Without a floor, 45 sessions of
                # random buying leaves every demo account ~100% invested
                # with no buying power, so the dashboard opens on accounts
                # that cannot place a single order. Real portfolios hold
                # cash; so should the demo.
                deposit = next(deposits_usd[e] for e in deposits_usd if accounts[e] == acct)
                cash_floor = Decimal(deposit) * Decimal("0.35")
                cost = px * qty * Decimal("1.01")
                if buying and ((cash or 0) - cost) < cash_floor:
                    continue
                try:
                    await conn.execute("""
                        SELECT ops.backfill_execution($1,$2,$3,$4,$5,$6,$7);
                    """, iid,
                        acct if buying else mm_acct,
                        mm_acct if buying else acct,
                        px, qty, at, 'buy' if buying else 'sell')
                    fills += 1
                except asyncpg.PostgresError:
                    continue
        print(f"  {fills} historical fills written through the ledger")

        # ---------------- 8. NAV snapshot reconstruction ----------------
        n = await conn.fetchval("SELECT ops.backfill_snapshots($1,$2)", days[0], days[-1])
        print(f"  {n} days of NAV history reconstructed from the journal")

        # ---------------- 9. live order book ----------------
        # Market maker quotes a two-sided book so the depth ladder and
        # the matching engine have something real to work against.
        quoted = 0
        for sym, iid in inst.items():
            mid = last_close.get(sym)
            if not mid:
                continue
            tick, lot = micro[sym]
            # Snap the mid onto the tick grid first: engine.validate_order
            # rejects a price that is not a whole number of ticks, and a
            # mid taken straight from a candle close rarely is.
            mid_d = (Decimal(str(mid)) / tick).quantize(Decimal(1)) * tick
            if mid_d <= 0:
                continue
            for level in range(1, 6):
                # Four basis points per level, but never less than one
                # tick. The old floor was a hard 0.01, which on DOGE-USD
                # (tick 0.00001, price ~0.13) is an 8% spread -- wide
                # enough that the book looked broken and every quote sat
                # outside anything a taker would cross.
                spread = max((mid_d * Decimal("0.0004") * level / tick)
                             .quantize(Decimal(1)) * tick, tick)
                # Size in notional terms. A flat 100-800 "shares" is
                # meaningless across a $0.13 coin and a $67,000 one.
                notional = Decimal(RNG.choice([40_000, 80_000, 120_000])) * level
                raw = notional / mid_d
                size = max((raw / lot).quantize(Decimal(1)) * lot, lot)
                for side, price in (("buy", mid_d - spread),
                                    ("sell", mid_d + spread)):
                    try:
                        await conn.execute("""
                            SELECT order_id FROM engine.submit_order(
                                   $1,$2,$3::trading.order_side,'limit',
                                   $4::qty_amt,$5::numeric,NULL,'gtc');
                        """, mm_acct, iid, side, size, price)
                        quoted += 1
                    except asyncpg.PostgresError as exc:
                        print(f"    ! {sym} {side} {price}: {str(exc).splitlines()[0][:70]}")
        print(f"  {quoted} resting market-maker orders across {len(inst)} books")

        # ---------------- 10. copy-trading ----------------
        strategies = [
            ("samrender@apex.io", "Momentum Alpha", "momentum-alpha",
             "Trend-following on high-beta technology names.", "public", 150),
            ("vartika@apex.io", "Mean Reversion Core", "mean-reversion-core",
             "Fades intraday dislocations in large-cap liquidity.", "public", 100),
            ("paritosh@apex.io", "Index Rotation", "index-rotation",
             "Rotates between broad-market ETFs on relative strength.", "followers", 75),
        ]
        strat_ids = {}
        for email, name, slug, desc, vis, fee in strategies:
            uid = await conn.fetchval("SELECT user_id FROM identity.app_user WHERE email=$1", email)
            sid = await conn.fetchval("""
                INSERT INTO social.strategy
                    (owner_user_id,source_account_id,name,slug,description,visibility,fee_bps)
                VALUES ($1,$2,$3,$4,$5,$6::social.visibility,$7)
                ON CONFLICT (slug) DO UPDATE SET description=EXCLUDED.description
                RETURNING strategy_id;
            """, uid, accounts[email], name, slug, desc, vis, fee)
            strat_ids[slug] = sid

        for slug, followers in (
            ("momentum-alpha", ["sam@apex.io", "ginni@apex.io", "pari@apex.io"]),
            ("mean-reversion-core", ["pari@apex.io", "sam@apex.io"]),
            ("index-rotation", ["ginni@apex.io"]),
        ):
            for email in followers:
                await conn.execute("""
                    INSERT INTO social.copy_subscription
                        (strategy_id,account_id,allocation_pct,max_trade_notional)
                    VALUES ($1,$2,$3,$4)
                    ON CONFLICT (strategy_id,account_id) DO NOTHING;
                """, strat_ids[slug], accounts[email], RNG.choice([25, 50, 75]),
                     RNG.choice([5000, 10000, 20000]))
                uid = await conn.fetchval(
                    "SELECT user_id FROM identity.app_user WHERE email=$1", email)
                await conn.execute("""
                    INSERT INTO social.follow (follower_user_id,strategy_id)
                    VALUES ($1,$2) ON CONFLICT DO NOTHING;""", uid, strat_ids[slug])
        print(f"  {len(strat_ids)} strategies published with copy subscriptions")

        # ---------------- 11. plant abuse patterns ----------------
        # Deliberate, so the surveillance report is not empty on a fresh
        # install. Each pattern maps to one rule in surveil.rule.
        ginni = accounts["ginni@apex.io"]
        iid = inst["INTC"]
        px = last_close.get("INTC", 31.0)
        # (a) wash trades: same user on both sides.
        # Top up first: a self-match nets cash to zero EXCEPT the fees,
        # which the account pays on BOTH legs -- a nice illustration of
        # why wash trading is expensive as well as illegal.
        await conn.execute("""
            SELECT ledger.post_entry('deposit','Top-up for surveillance demo',
                ARRAY[ ROW($1::bigint,'cash',NULL,-100000::money_amt,NULL)::ledger.leg,
                       ROW($2::bigint,'cash',NULL, 100000::money_amt,NULL)::ledger.leg ]);
        """, bank, ginni)
        await conn.execute("""
            SELECT ledger.post_entry('adjustment','Wash-trade setup inventory',
                ARRAY[ ROW($1::bigint,'security',$2::int,-4000::money_amt,NULL)::ledger.leg,
                       ROW($3::bigint,'security',$2::int, 4000::money_amt,NULL)::ledger.leg ]);
        """, float_acct, iid, ginni)
        await conn.execute("SELECT trading.set_cost_basis($1,$2,$3)", ginni, iid, money(px))
        for k in range(6):
            await conn.execute("""
                SELECT ops.backfill_execution($1,$2,$2,$3,$4,$5,'buy');
            """, iid, ginni, money(px), 200,
                 datetime.now(timezone.utc) - timedelta(hours=3, minutes=10 * k))
        # (b) spoofing: many quickly-cancelled orders on one side
        pari_a = accounts["pari@apex.io"]
        spoof_iid = inst["DIS"]
        spoof_px = money(money(last_close.get("DIS", 95.0)) * Decimal("0.97"))
        await conn.execute("""
            SELECT ledger.post_entry('deposit','Top-up for surveillance demo',
                ARRAY[ ROW($1::bigint,'cash',NULL,-60000::money_amt,NULL)::ledger.leg,
                       ROW($2::bigint,'cash',NULL, 60000::money_amt,NULL)::ledger.leg ]);
        """, bank, pari_a)
        for _ in range(12):
            row = await conn.fetchrow("""
                SELECT order_id, status::text AS status
                  FROM engine.submit_order($1,$2,'buy','limit',
                       $3::qty_amt,$4::numeric,NULL,'gtc');""",
                pari_a, spoof_iid, 100, spoof_px)
            # Only a live order can be cancelled; a risk rejection is
            # already terminal.
            if row and row["status"] in ("working", "partially_filled"):
                await conn.execute("SELECT engine.cancel_order($1)", row["order_id"])
        print("  surveillance test patterns planted (wash trades + layering)")

        # ---------------- 12. aggregates + scans ----------------
        await conn.execute("SELECT analytics.take_snapshots(CURRENT_DATE)")
        scans = await conn.fetch("SELECT * FROM surveil.run_all_scans()")
        await conn.execute("SELECT analytics.refresh_all(FALSE)")
        print("  surveillance scan:", ", ".join(
            f"{r['rule_code']}={r['alerts_raised']}" for r in scans))

        # ---------------- summary ----------------
        print("\n" + "=" * 62)
        for label, q in [
            ("instruments",        "SELECT count(*) FROM reference.instrument"),
            ("1m candles",         "SELECT count(*) FROM market.candle_1m"),
            ("users",              "SELECT count(*) FROM identity.app_user"),
            ("accounts",           "SELECT count(*) FROM trading.account"),
            ("orders",             "SELECT count(*) FROM trading.trade_order"),
            ("executions",         "SELECT count(*) FROM trading.execution"),
            ("ledger postings",    "SELECT count(*) FROM ledger.posting"),
            ("NAV snapshots",      "SELECT count(*) FROM analytics.account_snapshot"),
            ("resting orders",     "SELECT count(*) FROM trading.trade_order WHERE status IN ('working','partially_filled')"),
            ("surveillance alerts","SELECT count(*) FROM surveil.alert"),
        ]:
            print(f"  {label:<22} {await conn.fetchval(q):>9,}")
        print("=" * 62)
        print(f"\n  demo login password for every account: {DEMO_PASSWORD}")

    finally:
        await feed.aclose()
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
