# Relational schema and normalization

The schema is in **Boyce-Codd Normal Form**, with three deliberate, documented
exceptions. This page states the functional dependencies that justify that claim and
defends each exception, because "it is normalized" is an assertion and the dependencies
are the evidence.

---

## Why normalization matters here specifically

This is a ledger. The cost of an update anomaly is not an inconvenient report — it is
money that exists in one place and not another. Every redundancy below was either removed
or given a trigger that keeps it provably equal to its source, and
`ledger.verify_integrity()` re-checks that equality on demand.

---

## First Normal Form

**1NF: every attribute is atomic; no repeating groups; every row is uniquely
identifiable.**

Each of the 35 base tables has a declared `PRIMARY KEY` — 130 `PRIMARY KEY` constraints in
total once partitions are counted. There are no comma-separated lists, no `phone1 /
phone2 / phone3` columns, and no array columns used as a substitute for a child table.

Two cases are worth defending, because both *look* like 1NF violations:

**`reference.instrument.metadata jsonb`.** JSONB is not a repeating group here. It holds
provenance that is genuinely schemaless and never joined on — which provider supplied the
listing, which user imported it, the exchange string the provider returned. Nothing in the
engine, the risk gate or any view reads a key out of it to make a decision. The moment an
attribute *does* drive behaviour it gets a column: `trades_24x7` began as a metadata key
and became a `BOOLEAN` the day `reference.is_instrument_open()` needed it.

**`surveil.alert.evidence jsonb`.** An alert's evidence differs in shape by rule — a wash
trade cites two order ids, a volume anomaly cites a z-score and a mean. Forcing one table
to hold the union of every rule's evidence columns would produce a wide table that is
mostly NULL, which is the anomaly 1NF is trying to prevent, not the cure for it.

**Atomic money.** `money_amt` is `NUMERIC(28,8)`, never `FLOAT`. A binary float is not an
atomic decimal value — 174.73 is not representable — and the project has a documented bug
(design decision 1) where that non-atomicity rejected 153 of 160 orders.

---

## Second Normal Form

**2NF: 1NF, and no non-key attribute depends on only part of a composite key.**

Most tables have a single-column surrogate key, for which 2NF is automatic. The tables
with composite keys are where the work is:

| Table | Key | Non-key attributes | Depends on the whole key? |
|---|---|---|---|
| `trading.position` | (`account_id`, `instrument_id`) | `quantity`, `avg_cost`, `realized_pnl`, `opened_at` | Yes — a quantity belongs to one account *in* one instrument |
| `ledger.balance` | (`account_id`, `asset_class`, `currency`, `instrument_id`) † | `balance`, `updated_at` | Yes |
| `reference.fx_rate` | (`base_ccy`, `quote_ccy`, `as_of`) | `rate`, `source` | Yes — a rate is meaningless without all three |
| `reference.trading_session` | (`exchange_id`, `session_date`) | `is_trading_day`, `open_ts`, `close_ts` | Yes — hours are per exchange per day |
| `social.watchlist_item` | (`watchlist_id`, `instrument_id`) | `position`, `note`, `added_at` | Yes |

† `ledger.balance` is keyed by a unique index rather than a `PRIMARY KEY`, and the reason
is instructive. `instrument_id` is **NULL for cash** — cash is not an instrument — and
under standard SQL semantics two NULLs are distinct, so a plain unique key would happily
allow an account two separate USD cash balances. PostgreSQL 15's `NULLS NOT DISTINCT` is
what makes the key actually unique:

```sql
CREATE UNIQUE INDEX uq_balance_slot ON ledger.balance
    (account_id, asset_class, currency, instrument_id) NULLS NOT DISTINCT;
```

This is the single feature that sets the project's minimum version at PostgreSQL 15. It is
also a nice illustration that "declare a key" and "the key is enforced" are not the same
statement when nullable attributes are involved.

The violation to watch for would be putting `instrument.symbol` or `account.account_no` on
`trading.position` "for convenience". The symbol depends on `instrument_id` alone — half
the key — so it is a partial dependency and it is not there. Every view that displays a
symbol joins `reference.instrument` for it.

`reference.fx_rate` is worth dwelling on. Storing `rate` keyed only on the currency pair
would be 2NF-clean but factually wrong: a rate is a *time series*, and a trade settled
three weeks ago must convert at that day's rate. Dropping `as_of` from the key would apply
a look-ahead rate to history. Correct normalization and correct finance agree here.

---

## Third Normal Form

**3NF: 2NF, and no non-key attribute depends transitively on the key through another
non-key attribute.**

The transitive dependencies that a trading schema invites, and where each one lives
instead:

| Tempting column | Transitive chain | Where it actually lives |
|---|---|---|
| `trade_order.symbol` | order → instrument → symbol | `reference.instrument` |
| `trade_order.tick_size` | order → instrument → tick_size | `reference.instrument`, read by `engine.validate_order()` |
| `execution.notional` | = `quantity × price`, both already present | computed in `analytics.v_blotter` |
| `position.market_value` | position → instrument → quote → last_price | computed in `analytics.v_portfolio` |
| `account.nav` | account → every position → every quote | `risk.account_nav()`, a function |
| `app_user.account_count` | user → accounts → count | an aggregate, never stored |

The rule applied throughout: **if it can be derived, it is a view or a function, not a
column.** 14 views and 84 functions exist largely to hold values that would otherwise have
become stale columns.

One real 3NF decision: `trading.account.base_currency` is a column, and
`reference.currency` holds that currency's `symbol` and `minor_units`. Those two attributes
depend on the currency code, not on the account, so they are *not* duplicated onto the
account. `analytics.v_account_summary` joins for them.

---

## Boyce-Codd Normal Form

**BCNF: for every non-trivial functional dependency X → Y, X is a superkey.**

The tables with more than one candidate key are the only places BCNF can bite:

- **`reference.instrument`** has two: `instrument_id` (surrogate) and
  (`exchange_id`, `symbol`) (natural, enforced by `symbol_unique_per_exchange`). Every
  other attribute depends on the full instrument identity, not on part of either. The same
  symbol may legitimately list on two exchanges with different tick sizes, which is why
  the natural key is the *pair* and not the symbol alone.
  `isin` is **not** a candidate key here — it is nullable and carries no unique constraint,
  because not every instrument this venue lists has one (no crypto pair does).
- **`identity.app_user`** has three: `user_id`, `public_id`, and `lower(email)` — the last
  enforced by a unique *expression* index, `uq_app_user_email_ci`, so that
  `Sam@apex.io` and `sam@apex.io` cannot both exist. Each determines the whole row.
- **`trading.account`** has three: `account_id`, `account_no`, and `system_code`
  (unique, nullable — only the system accounts carry one).
- **`reference.currency`** has exactly one, `code`. `name` and `symbol` are not unique and
  determine nothing; two currencies may share the symbol `$`.

No table has an attribute determined by a non-superkey, so the schema is in BCNF. Nothing
required decomposition beyond 3NF — the usual BCNF counterexamples need two *overlapping*
composite candidate keys, and no table here has even one composite candidate key beyond
its primary key, except `reference.instrument`, whose two candidate keys share no
attribute.

Worth noting what BCNF costs if you ignore it: had `symbol` alone been made unique, a
venue could never list the same ticker on two exchanges, and the fix later would be a
table decomposition rather than a constraint change.

---

## The three deliberate exceptions

Each is a cache of something derivable, kept because deriving it on every read gets slower
for ever. Each is maintained by trigger, not by application code, and each is provable
against its source.

### 1. `ledger.balance` — a materialized aggregate of `ledger.posting`

Pure derivation (`SUM` the journal every time) is correct and unboundedly slow. The cache
is maintained by `trg_posting_updates_balance` and proved by
`ledger.verify_integrity()`:

```sql
SELECT check_name, passed, detail FROM ledger.verify_integrity();
-- balance_cache_matches_journal | t | 0 drifted slot(s)
```

The invariant is *checkable*, which is the price of keeping the redundancy. A denormalized
value with no proof is a bug waiting to be discovered by an auditor.

### 2. `trading.position` — a per-instrument roll-up of the same journal

`quantity` duplicates what `ledger.balance` holds for `asset_class = 'security'`, and
`avg_cost` / `realized_pnl` carry lot accounting that the journal does not express
directly. `trg_posting_syncs_position` keeps it in step, and `positions_match_ledger` in
`ops.health_check()` fails if it drifts. This redundancy was the cause of a real bug: the
position was originally updated only from fills, so any movement posted directly to the
ledger left the two disagreeing (design decision 2).

### 3. `market.quote` — the latest row of `market.tick`, plus session statistics

`last_price` is the most recent print and could be a `MAX(ts)` subquery over a partitioned
tick table on every page load. It is a column because the dashboard reads it constantly.
`day_open/high/low/volume` are session aggregates maintained by `engine.settle_fill()`.

A fourth, smaller case: `market.candle_1m` is an aggregate of `market.tick`, and higher
intervals (5m, 1h, 1D) are *not* stored at all — `market.candles()` derives them from the
minute table, so a 1h bar cannot contradict the 60 minute bars inside it. The line between
"cache this" and "derive this" is drawn at the base resolution.

---

## What normalization alone does not give you

Normal forms remove redundancy within a row. They say nothing about **conservation across
rows**, which is the property that actually matters for a ledger: the legs of a journal
entry must sum to zero, independently for cash and for every security and every currency.

No normal form expresses that. It needs a `DEFERRABLE INITIALLY DEFERRED` constraint
trigger that fires at `COMMIT`, when the entry is whole — see
`db/demo/10_transactions.sql`, section 4. Normalization and integrity are different jobs,
and a schema can be in BCNF while cheerfully creating money.

---

## Summary

| Normal form | Status | Evidence |
|---|---|---|
| 1NF | Met | 130 PK constraints; atomic `NUMERIC` money; JSONB only for non-determining provenance |
| | | `uq_app_user_email_ci` shows a candidate key can be an *expression*, not just a column |
| 2NF | Met | Composite keys audited above; no symbol or account_no denormalized onto child tables |
| 3NF | Met | Derived values live in 14 views and 84 functions, not columns |
| BCNF | Met | Multi-candidate-key tables audited; no non-superkey determinant |
| Exceptions | 3, documented | Each trigger-maintained and proved by `ledger.verify_integrity()` / `ops.health_check()` |
