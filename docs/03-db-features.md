# Advanced database features — where each one lives and why

This is the viva cheat sheet. Every feature below is used because the problem
genuinely needed it, not to tick a box — the "why" column is the part that matters.

Line numbers are approximate; search the quoted identifier to jump straight there.

---

## Constraints and data integrity

| Feature | Location | Why it is there |
|---|---|---|
| **Deferred constraint trigger** | `005_accounts_ledger.sql` → `trg_posting_balanced` | The legs of a journal entry are inserted one row at a time, so the entry is legitimately unbalanced *during* the transaction. The zero-sum check must run at `COMMIT`, which only a `DEFERRABLE INITIALLY DEFERRED` constraint trigger can do. |
| **GiST exclusion constraint** | `007_risk.sql` → `no_overlapping_halts` | "No two halts on one instrument may overlap in time" is a range-overlap rule. `UNIQUE` cannot express it; an exclusion constraint over `tstzrange` with `btree_gist` can. |
| **Domains** | `001_foundation.sql` → `money_amt`, `price_amt`, `qty_amt`, `symbol_code` | One definition of what money is (`NUMERIC(28,8)`, never float) with validation attached, reused across every table. |
| **Cross-column CHECK** | `002_identity.sql` → `kyc_timestamp_consistent` | A verified KYC state must carry its timestamp. The contradiction becomes unrepresentable rather than something to audit for later. |
| **Discriminated-union CHECK** | `006_orders.sql` → `order_shape_matches_kind` | Encodes the whole order-type grammar: a market order with a limit price, or a stop order with no stop price, cannot be stored at all. |
| **Payload-per-kind CHECK** | `003_reference.sql` → `ca_payload_matches_kind` | A dividend cannot be stored carrying a split ratio, and vice versa. |
| **Generated column** | `006_orders.sql` → `leaves_qty` | Remaining size is arithmetic, not state, so it can never drift from `quantity - filled_qty`. |
| **Expression unique index** | `002_identity.sql` → `uq_app_user_email_ci` | Case-insensitive email uniqueness while still storing the address as the user typed it. |
| **Partial unique via `NULLS NOT DISTINCT`** | `005_accounts_ledger.sql` → `uq_balance_slot` | One index covers both the cash row (`instrument_id IS NULL`) and per-security rows. Before PostgreSQL 15 this needed a sentinel value or two indexes. |

## Procedural code

| Feature | Location | Why |
|---|---|---|
| **The matching engine** | `008_engine.sql` → `engine.match_order` | Price-time priority walk of the contra side, with partial fills and price improvement. |
| **Transaction-scoped advisory lock** | `008_engine.sql` → `pg_advisory_xact_lock(hashtext('apex_book'), instrument_id)` | Serialises matching per instrument so two concurrent aggressors cannot double-fill one resting order, while different symbols still match in parallel. Released automatically at COMMIT, so a crashed session cannot wedge the book. |
| **`FOR UPDATE` without `SKIP LOCKED`** | `008_engine.sql` → match loop | Deliberate. Skipping a locked order would let a later order jump the queue and break *time* priority, so the engine blocks and stays fair. |
| **`FOR UPDATE SKIP LOCKED`** | `010_social.sql` → `social.process_copy_queue` | The opposite case: a work queue, where N workers should each claim a disjoint batch with no coordination. |
| **Stored procedure (not function)** | `015_maintenance.sql` → `ops.end_of_day` | Declared `PROCEDURE` specifically so it can `COMMIT` mid-body; a function runs inside the caller's transaction and cannot. |
| **`SECURITY DEFINER`** | `005`, `014` | Required in two places: the deferred ledger check (fires at COMMIT, outside any definer context, and must see *both* sides of a trade past RLS) and the RLS predicate helper (reads a table whose own policy calls it — otherwise infinite recursion). Every such function has a pinned `search_path`. |
| **Composite type + array parameter** | `005_accounts_ledger.sql` → `ledger.leg[]` | Lets an entire balanced entry be posted in one call instead of a loop of inserts the caller could get wrong. |
| **Exception handling in subtransactions** | `010_social.sql` → copy fan-out | One follower's risk rejection must not roll back the whole batch. |

## Physical design

| Feature | Location | Why |
|---|---|---|
| **Declarative range partitioning** | `004_market.sql` (`tick`, `candle_1m`), `006_orders.sql` (`execution`) | These are the tables that grow without bound. Partitioning gives planner pruning, O(1) archival by `DETACH`, and index sizes that stay cache-resident. |
| **Automated partition management** | `004_market.sql` → `ops.ensure_time_partitions` | Idempotent DDL generation, called by both the seeder and the nightly job. |
| **Partition detach for archival** | `015_maintenance.sql` → `ops.detach_old_partitions` | Dropping a month is a catalog operation, not a mass `DELETE`. |
| **BRIN index** | `004_market.sql` → `ix_tick_ts_brin` | Tick data arrives in timestamp order, so BRIN prunes blocks at ~1/177th the size of the B-tree (24 kB vs 4,248 kB measured in `db/bench`). |
| **Partial index** | `006_orders.sql` → `ix_book_bids`, `ix_book_asks` | The order-book index covers only *live* orders, so it is sized by the book, not by order history, which grows forever. Measured: 21% of rows indexed. |
| **Index as the sort order** | `006_orders.sql` → `(instrument_id, limit_price DESC, seq_no ASC)` | Price-time priority *is* the index definition, so the engine reads top-of-book with an index scan and **no Sort node**. Proven in `db/bench/explain.sql §2`. |
| **Covering index (`INCLUDE`)** | `003_reference.sql` → `ix_instrument_tradable` | Index-only scan with `Heap Fetches: 0` for the hot instrument listing. |
| **GIN trigram** | `003_reference.sql` → `ix_instrument_symbol_trgm` | Fuzzy symbol/name search without a separate search service. |
| **GIN on JSONB** | `009_surveillance.sql` → `ix_alert_evidence` | Each surveillance rule produces a different shape of evidence; querying it needs no schema change. |

## Multi-currency

| Feature | Location | Why |
|---|---|---|
| **Per-currency zero-sum invariant** | `019_currency.sql` → `assert_entry_balanced` | The deferred trigger now groups by `(asset_class, currency, instrument_id)`. Dollars cannot settle a rupee deficit any more than cash can settle a share deficit. |
| **Four-legged FX entry** | `019_currency.sql` → `ledger.convert_currency` | A conversion is a trade, so it is booked like one: the source currency balances between trader and FX desk, the destination balances the other way. Multiplying by a rate and storing one number would make the books stop saying what happened. |
| **Rate time series** | `019_currency.sql` → `reference.fx_rate` | Rates are stored with `as_of`, so a trade settled three weeks ago converts at *that day's* rate. A single "current rate" column makes historical valuation a look-ahead error. |
| **Derived cross rates** | `019_currency.sql` → `reference.fx_rate_at` | Only USD-base pairs are stored; inverse and cross rates are computed. USD/INR and INR/USD therefore cannot drift apart. |
| **Settlement auto-conversion** | `020`, `021` → `ledger.ensure_currency` | A rupee-funded account buying a USD stock gets the shortfall converted first, as a separate FX entry, then the trade settles single-currency. Exactly what a real broker does. |
| **Currency-aware valuation** | `020_currency_trading.sql` → `risk.account_nav`, `buying_power`, `order_value_in_base` | Every aggregate states which currency it is in and converts rather than adds. |
| **Minor units as data** | `019_currency.sql` → `reference.currency.minor_units` | JPY has no minor unit, most currencies have two. Rounding money correctly requires knowing this, so it is a column rather than an assumption. |

## Analytics

| Feature | Location | Why |
|---|---|---|
| **Window functions** | `012_views.sql` → `v_book_depth` | Cumulative depth per price level — the number a trader actually needs. |
| **Chained window functions** | `013_analytics.sql` → `analytics.equity_curve` | `LAG` for returns, `MAX ... ROWS UNBOUNDED PRECEDING` for the running high-water mark, drawdown as the gap between them. |
| **Statistical window aggregates** | `009_surveillance.sql` → `scan_volume_anomaly` | `stddev_samp` over each instrument's *own* history, so a thin name is not compared against a mega-cap. |
| **`date_bin` rollup** | `013_analytics.sql` → `market.candles` | One function serves 1m/5m/1h/1d/1w from a single base table, so a 1h bar can never disagree with the 60 minutes inside it. |
| **Recursive CTE** | `013_analytics.sql` → `analytics.order_lineage` | Bracket orders, OCO pairs and copy-trade mirrors form a tree of arbitrary depth, with a cycle guard. |
| **Materialized views + `REFRESH CONCURRENTLY`** | `013_analytics.sql` → `mv_strategy_leaderboard`, `mv_instrument_daily` | Expensive aggregates read on every page load. Each carries a `UNIQUE` index, which is what makes concurrent refresh possible — without it the refresh takes an exclusive lock and the dashboard stalls. |
| **`LATERAL` joins** | `012_views.sql` → `v_account_summary` | Per-account subaggregates without a correlated scalar subquery per column. |
| **Ordered-set aggregation** | `004_market.sql` → `build_candles_1m` | `array_agg(... ORDER BY ...)` to take the first open and last close within a bucket. |

## Security

| Feature | Location | Why |
|---|---|---|
| **Row Level Security** | `014_security.sql` + `022_...sql` — 24 policies | Tenant isolation enforced by the database, not by remembering a `WHERE` clause. A forgotten predicate returns an empty set instead of a data breach. |
| **Session-variable identity** | `014_security.sql` → `identity.current_user_id()` + `backend/app/core/db.py` | The API sets `apex.current_user_id` per request and clears it on release, so a pooled connection cannot leak one user's identity into the next request. |
| **Role separation** | `014_security.sql` | The API connects as `apex_app`, deliberately **not** the owner or a superuser — both bypass RLS, which would defeat the whole design. |
| **`pgcrypto` bcrypt** | `002_identity.sql` → `identity.hash_password` | Hashing lives in the database so no application path can persist a plaintext password. |
| **Atomic auth + lockout** | `002_identity.sql` → `identity.authenticate` | Credential check, failed-attempt lockout and forensic log in one transaction, so no API path can skip the lockout. |
| **Short selling as an explicit privilege** | `018_short_selling.sql` → `allow_short_selling` | Defaults to FALSE with a CHECK forbidding it on cash accounts. Enforced in the risk gate *and* independently in the ledger, so the two layers cannot disagree about what is permitted. |
| **Append-only enforcement** | `005_accounts_ledger.sql`, `011_audit.sql` | `UPDATE`/`DELETE` on the ledger and the audit log raise. Corrections are made by posting a reversing entry. |
| **Generic audit trigger** | `011_audit.sql` → `audit.track` | One trigger function for every table via `to_jsonb(NEW/OLD)`, with a JSONB diff so wide-table updates do not bloat the log. |
| **`security_invoker` views** | `024_view_security_invoker.sql` | A view runs as its *owner* by default, and a table owner is exempt from its own RLS — so every view over an RLS-protected table read straight past the policies. `security_invoker = true` makes the view run as the caller. `trading.v_book_depth` is the deliberate exception: depth is public market data and must show every participant's size. |
| **Append-only tables** | `005_accounts_ledger.sql`, `011_audit.sql`, `022_...sql` → `forbid_mutation()` | A `BEFORE UPDATE OR DELETE` trigger that always raises. History that can be rewritten is not history. It also forces a real decision when something references it — see design decision 19. |

---

## Asset classes and market microstructure

| Feature | Location | Why it is there |
|---|---|---|
| **Per-instrument microstructure as data** | `003_reference.sql` → `tick_size`, `lot_size`, `price_band_pct`; `022_crypto_watchlist_alerts.sql` → `trades_24x7` | Equities and crypto run on the *same* matching engine. Everything that differs between them — a satoshi lot against a whole share, a 0.00001 tick against a cent, a 40% band against 20%, a 24×7 session against 390 minutes — is a column, not a branch in the engine. |
| **Session rule as a function** | `022_...sql` → `reference.is_instrument_open()` | "Is this market open" has two different answers depending on the asset class. One function answers it for both, so no caller has to know which kind of instrument it is holding. |
| **Tick-grid rounding** | `023_candle_provenance.sql` → `reference.align_price()` | `ROUND(x, 2)` is an equity assumption. Every caller that *computes* a price — a market-maker spread, a percentage offset — has to land on the instrument's grid or `engine.validate_order()` rejects it, which empties a book with no error anywhere. One function, so the rule is not reimplemented per caller. |
| **Row provenance** | `023_...sql` → `market.candle_1m.source` | A bar loaded as history and a bar derived from ticks are different kinds of fact. The tick roller may only overwrite its own. Without the distinction it ate the tail of every 24×7 instrument's history — see design decision 16. |
| **Generated-column-style flag** | `026_tick_trade_flag.sql` → `market.tick.is_trade` | A fill carries a quantity; an external price mark does not. OHLC wants every print, volume and VWAP want only trades. Encoding that in a boolean beats encoding it in a `source` string the aggregator has to know the vocabulary of. |

---

## Real-time

| Feature | Location | Why |
|---|---|---|
| **`LISTEN`/`NOTIFY`** | `008_engine.sql` → `pg_notify` in `settle_fill`; `backend/app/api/ws.py` | The API never polls for fills. The notify happens in the same transaction that writes the execution, so a client is told about a trade only if that trade actually committed. |
| **Single listener, fan-out** | `backend/app/api/ws.py` → `EventHub` | One database connection listens; connection count stays independent of how many browsers are open. |

---

## Self-checking invariants

| Feature | Location | Why it is there |
|---|---|---|
| **`ops.health_check()`** | `027_health_checks.sql` | 17 structural invariants reported rather than assumed — ledger conservation, position/journal agreement, uncrossed books, partition runway, RLS integrity, candle provenance, tick-grid pricing, quoted books. Every check corresponds to a defect that produced *no error* until something downstream was already wrong. |
| **`ops.assert_rls_intact()`** | `024_view_security_invoker.sql` | Lists any view over user data still running as its owner, which silently disables the RLS underneath it. Makes the condition checkable instead of remembered. |
| **`ledger.verify_integrity()`** | `005_accounts_ledger.sql` | Proves the derived balance cache still matches the append-only journal. Correctness by construction, performance by cache, with a proof that they agree. |
| **`ops.v_index_usage`** | `015_maintenance.sql` | Indexes that are never scanned are pure write cost. This is how the unused GIN indexes in design decision 6 were found. |

---

## Running the evidence

```bash
./scripts/db.sh bench
```

`db/bench/explain.sql` proves each physical-design claim with `EXPLAIN ANALYZE`, including
partition pruning (`Subplans Removed: 9`), the sort-free order-book scan, BRIN vs B-tree
sizes, and index-only scans. Where the demo dataset is too small for the planner to choose
an index, the file says so explicitly and demonstrates the index separately rather than
overclaiming.
