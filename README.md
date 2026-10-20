# Apex Trader

**An exchange implemented inside PostgreSQL.**

Not a trading app that forwards orders to somebody else's API — the limit order book
lives in the database and orders are crossed there, in PL/pgSQL, under price-time
priority, settling into a double-entry ledger that cannot be made to disagree with
itself.

**Author:** Samrender Singh Saini (24BCE2865)  
**Course:** BCSE302P – Database Systems Lab, Vellore Institute of Technology, Vellore  
**Faculty:** Prof. Nithya N S

A rebuild of the original three-table *Apex Trader* design.

---

## Why this is different from every other trading project

Almost every student trading system — and almost every tutorial — is the same thing:

```sql
UPDATE account SET balance = balance - 1000 WHERE account_id = 7;
UPDATE holding SET quantity = quantity + 10 WHERE ...;
```

That design has one fatal property: **the current balance is the only record of itself.**
If a bug, a race, or a partial failure writes the wrong number, the correct number is gone
and there is nothing to reconcile against.

Apex Trader inverts it:

| | Typical project | Apex Trader |
|---|---|---|
| Order handling | `INSERT` a row, mark it "complete" | Real limit order book, price-time priority, partial fills |
| Prices | Fetched from an API and displayed | API is a *reference mark*; prices are **discovered by matching** |
| Balances | `UPDATE balance` | **Derived** from an append-only double-entry journal |
| Correctness | Hope the app is right | Deferred constraint trigger: every entry must sum to **zero** at COMMIT |
| History | Overwritten | Append-only — portfolio at *any past instant* is a query |
| Multi-tenancy | `WHERE user_id = ?` everywhere | **Row Level Security** — the database refuses to leak |
| Concurrency | Untested | 480 concurrent orders proven not to overfill by one share |
| Abuse | Not considered | Wash-trade / layering / momentum-ignition detection in SQL |

---

## What it does

- **Matching engine** — continuous-auction limit order book, price-time priority, partial
  fills, price improvement for the aggressor, per-instrument advisory locking
- **Order types** — market, limit, stop, stop-limit, trailing stop, iceberg;
  DAY / GTC / IOC / FOK time-in-force; idempotent order entry via client order id
- **Double-entry ledger** — signed postings, deferred zero-sum invariant per asset,
  append-only, point-in-time reconstruction, cache-vs-journal integrity proof
- **Pre-trade risk** — buying power net of committed orders, share availability net of
  open sells, concentration, order rate, tick/lot size, price bands, daily loss,
  margin and margin calls, volatility circuit breakers
- **Market surveillance** — wash trading, layering/spoofing, momentum ignition and
  statistical volume anomalies, each a single analytical query, with evidence as JSONB
- **Copy trading** — published strategies, Sharpe/drawdown leaderboard from real NAV
  history, fan-out queue drained with `FOR UPDATE SKIP LOCKED`
- **Multi-currency** — USD, INR, EUR, GBP, JPY, AED, SGD, AUD, CAD, CHF. A conversion
  is a four-legged journal entry through an FX desk, and the zero-sum invariant applies
  **independently per currency**. A rupee-funded account buying a dollar-priced stock is
  auto-converted at settlement, at that date's rate
- **Two asset classes, one engine** — equities, ETFs and eight crypto pairs on the same
  order book. What differs is *data, not code*: each instrument carries its own tick size,
  lot size, price band and session rule, so BTC-USD trades 24×7 in satoshi lots at a
  0.01 tick while DOGE-USD quotes to 0.00001 and AAPL stays on the cent grid
- **Instrument search and on-demand listing** — trigram similarity over the listed
  universe (so "aple" finds AAPL) plus a parallel provider lookup; anything the provider
  knows and this venue does not can be listed on the spot, with microstructure chosen
  from its asset class and minute history backfilled
- **Watchlists and price alerts** — above / below / percentage-move-from-a-fixed-reference,
  evaluated in SQL on every ingestion cycle and pushed to the browser on the same
  `LISTEN/NOTIFY` channel as fills. A fired alert is archived rather than deleted,
  because its fire rows are append-only
- **Market data** — Yahoo Finance and Finnhub adapters plus a deterministic GBM simulator,
  so the whole system runs with no API key and no network. If the live provider stops
  responding the worker falls back to the simulator *and says so in the UI* rather than
  showing a frozen price behind a green "live" badge
- **Live UI** — candlestick charts with SMA / Bollinger / RSI / volume toggles, a
  depth-of-market ladder, order ticket, equity curve with drawdown, asset-class
  allocation, CSV export on every table, keyboard shortcuts (`?` for the list) and a
  compliance console; real-time via `LISTEN/NOTIFY` → WebSocket

---

## Scale of the thing

| | |
|---|---|
| Migrations | 28 |
| Tables / partitions | 35 / 30 |
| Stored functions & procedures | 82 |
| Triggers | 40 |
| Views / materialized views | 14 / 2 |
| Indexes | 336 |
| Constraints | 347 |
| RLS policies | 24 |
| Enum types / domains | 19 / 9 |
| Currencies supported | 10 |
| Instruments seeded | 16 equities/ETFs + 8 crypto pairs |
| SQL | ~8,500 lines |
| Python (API, feed, tooling) | ~4,800 lines |
| Frontend | ~2,900 lines |
| Test assertions | **150 SQL + 118 API + 51 browser** |

---

## Quick start

Requires PostgreSQL 15+ (uses `NULLS NOT DISTINCT`) and Python 3.11+.

```bash
createuser -s apex
createdb -O apex apex_trader
psql -d apex_trader -c "ALTER ROLE apex WITH PASSWORD 'apex_dev_pw';"

./scripts/setup.sh
```

That is the whole install. `setup.sh` builds the virtualenv (the archive ships none —
it is platform-specific binaries), installs the dependencies, applies the migrations,
seeds the demo data and starts the API, stopping at the first step that fails with a
message saying what to do about it.

`setup.sh` runs the four steps in the order they have to happen — migrate, verify, seed,
start — and stops at the first one that fails with a message saying what to do. Add
`--fresh` to drop and rebuild the database first.

Then open <http://127.0.0.1:8000>.

Sign in as any of the demo accounts — they are listed on the login screen and the chip is
the username: **samrender**, **vartika**, **paritosh**, **sam**, **ginni**, **pari**, plus
**compliance** and **admin**. The password for all of them is `Apex@2026`. Each is funded
in a different base currency (USD, GBP, INR, EUR, AED) so the multi-currency ledger is
visible without setting anything up.

Press `?` in the app for the keyboard shortcuts.

### If `.venv/bin/python` is not found

The archive ships no virtualenv — it is platform-specific binaries, and a macOS one would
not run on Linux. `./scripts/setup.sh` builds it for you. By hand:

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
```

### If the page says "The API server is out of date"

```bash
./scripts/api.sh restart
```

An API server from an earlier session was still holding port 8000, so a newer dashboard
was talking to older code. The dashboard checks for this before it renders and says so,
rather than letting you discover it as six unrelated-looking faults — search returning
"Not Found", an empty Markets page, "Watchlist failed: Method Not Allowed", blank currency
dropdowns. `api.sh start` now replaces a server whose version disagrees with the source on
disk instead of reporting "already running".

If it survives a restart, something outside this project holds the port:

```bash
lsof -ti:8000 | xargs kill
```

### If an order is rejected as "outside the band"

```
price 334.85 outside 20.0000% band [567.4640, 851.1960]
```

The price band is anchored on the external feed's mark, and the book is priced from this
venue's own tape. If you seeded from the simulator and then ran the API against a live
feed, those are different price levels — simulator META is ~$335, the real one is ~$709 —
and the band stops containing the book.

Reseed. The seeder now anchors its synthetic history to whichever provider the API will
run on, so the two start out continuous:

```bash
.venv/bin/python scripts/seed.py --reset
```

The condition is checkable at any time:

```sql
SELECT * FROM market.mark_divergence();
SELECT * FROM ops.health_check() WHERE check_name = 'bands_contain_their_books';
```

Until you reseed, the ingestion worker refuses any mark more than 50% from the venue's own
last trade, so the books stay tradable and `/api/health` lists the instruments affected.

### Short selling

Every demo account seeds with short selling **off**, so selling more than you hold is
refused by name rather than quietly opening a short position:

```
cannot sell 9.00000000 MSFT: you hold 4.00000000.
Short selling is not enabled on this account.
```

To demonstrate the other half, grant it to one margin account:

```bash
./scripts/db.sh psql -c "UPDATE trading.account SET allow_short_selling = TRUE WHERE account_no = 'APX-000001';"
```

A *cash* account cannot be granted it at all — `short_requires_margin` refuses at the
constraint level, not in application code.

### Upgrading an existing database

Run `./scripts/setup.sh` again. Migrations are incremental: each file is recorded in
`ops.schema_migration` once it succeeds, and only unrecorded files are applied.

On a database built before tracking existed, the first run detects which migrations are
already present (by probing for a known object from each) and marks them **baselined**
rather than replaying them. Nothing is re-run, nothing is lost.

```bash
./scripts/db.sh status     # per-migration: applied, baselined, or PENDING
./scripts/db.sh migrate    # apply only what is pending
```

The seeder refuses to run against an out-of-date schema, so a skipped migration produces
one clear line rather than a traceback about a missing table.

### Market data: which provider, and why

`APEX_FEED_PROVIDER` in `.env` takes `auto` (the default), `yahoo`, `finnhub` or
`simulator`. **`auto` needs no signup**: it uses Finnhub if `APEX_FINNHUB_API_KEY` is set
and Yahoo Finance otherwise.

| | Yahoo | Finnhub | Simulator |
|---|---|---|---|
| API key | none | free tier, required | none |
| Symbol search | yes | yes | no |
| Minute history | ~7 days | ~30 days (free tier) | unlimited, generated |
| Crypto | yes (`BTC-USD`) | yes | yes |
| Works offline / in CI | no | no | **yes** |

Yahoo is the default because it needs no key and because it is the one that answers
*"what symbols match 'bitcoin'"* — which is what the search box and on-demand listing need.
Finnhub is better if you have a key: documented rate limits and longer minute history.

```bash
echo "APEX_FINNHUB_API_KEY=your_key" >> .env    # optional
echo "APEX_FEED_PROVIDER=simulator" >> .env     # force offline mode
```

With no key and no network the system uses the built-in simulator — geometric Brownian
motion with per-symbol drift and volatility, regime switching and jump events, seeded
deterministically so every run reproduces the same history. The whole project therefore
demos offline, outside market hours.

If a live provider stops responding mid-session (rate limit, expired key, blocked egress),
the worker falls back to the simulator after a minute of empty polls **and the UI badge
changes from `live · yahoo` to `simulated`**. A frozen price behind a green "live" light
is the failure mode worth avoiding.

---

## Verify it

```bash
./scripts/test.sh              # 150 SQL assertions: ledger, engine, risk, currency, crypto
./db/test/concurrency.sh       # parallel sessions against one book
.venv/bin/python scripts/api_smoke.py   # 118 end-to-end API checks
.venv/bin/python scripts/ui_check.py    # 51 checks driving the real UI in Chromium
./scripts/db.sh bench          # EXPLAIN ANALYZE evidence for the physical design
```

`scripts/test.sh` fails on an assertion that is *false* and also on an assertion that
never ran: a statement that errors writes no result row at all, so a suite can go green
while quietly checking less than it claims. That happened — see design decision 16.

The database can also check itself at any time:

```sql
SELECT * FROM ops.health_check();      -- 18 structural invariants
SELECT * FROM ops.assert_rls_intact(); -- any view that bypasses RLS
SELECT * FROM ledger.verify_integrity();
```

The concurrency test is the one to run first. It fires **300 orders from 12 simultaneous
sessions** at a single resting order of 3,000 shares — demand exactly equal to supply,
so any double-fill shows up immediately as an overfill:

```
resting_quantity            | 3000.00000000
resting_filled              | 3000.00000000   <- exactly, not 3001
overfilled_orders           | 0
shares_created_or_destroyed | 0.00000000
cash_created_or_destroyed   | 0.00000000
```

---

## Documentation

| Document | Contents |
|---|---|
| [docs/01-architecture.md](docs/01-architecture.md) | Layers, schemas, request lifecycle |
| [docs/02-er-model.md](docs/02-er-model.md) | Entity model and relationship reasoning |
| [docs/03-db-features.md](docs/03-db-features.md) | **Every advanced DB feature → exact file and why** |
| [docs/04-matching-engine.md](docs/04-matching-engine.md) | Matching algorithm, settlement, concurrency |
| [docs/05-design-decisions.md](docs/05-design-decisions.md) | Decisions taken, and **the real bugs this design caught** |
| [docs/06-normalization.md](docs/06-normalization.md) | **1NF → BCNF analysis** with the functional dependencies, and the 3 deliberate exceptions |
| [docs/er-diagram.mmd](docs/er-diagram.mmd) | Mermaid ERD, generated from `pg_catalog` |

---

## Layout

```
db/migrations/     28 ordered migrations — the actual project
db/test/           SQL test suite + concurrency harness
db/demo/           COMMIT / ROLLBACK / SAVEPOINT demonstration
db/bench/          EXPLAIN ANALYZE performance evidence
backend/app/       FastAPI: thin routers over database procedures
  core/            asyncpg pool with per-request RLS identity, JWT
  api/             auth, market, orders, portfolio, social, admin, websocket
  feed/            Yahoo + Finnhub adapters, GBM simulator, ingestion worker
frontend/          Dashboard (vanilla JS, no build step)
scripts/           setup.sh, db.sh, api.sh, test.sh, seed.py, gen_erd.py,
                   api_smoke.py, ui_check.py
```

---

## Against the original design

The original deck listed five limitations. All five are addressed:

| Original limitation | Now |
|---|---|
| Only 3 entities (USER, ACCOUNT, HOLDING) | 38 tables (plus 30 partitions) across 12 bounded-context schemas |
| No separate trade-history table | `trading.execution` — partitioned, immutable, each row linked to its settlement entry |
| Stock data not separately modelled | `reference.instrument` with tick size, lot size, price bands driving the engine |
| No views, triggers or stored procedures | 12 views, 2 matviews, 40 triggers, 83 functions, 1 procedure |
| Limited scalability features | Range partitioning with automated management, BRIN on time-series, partial/covering/GIN/trigram indexes, materialized views with concurrent refresh |

> **Note on the test suite:** `./scripts/test.sh` loads a fixture that replaces the demo
> users with a minimal set. Re-run `scripts/seed.py --days 45 --reset` before demoing.

---

## Author

**Samrender Singh Saini**  
Registration number 24BCE2865  
B.Tech Computer Science and Engineering, Vellore Institute of Technology, Vellore
