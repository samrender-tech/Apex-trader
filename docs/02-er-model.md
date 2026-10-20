# Entity model

The machine-generated diagram is [`er-diagram.mmd`](er-diagram.mmd), produced from
`pg_catalog` by `scripts/gen_erd.py` so it cannot drift from the schema. Paste it into
any Mermaid renderer. This document explains the *reasoning*.

## Core chain

```
app_user ──< account ──< trade_order ──< execution >── trade_order
                │                            │
                └──< position                └──> journal_entry ──< posting
```

Read that right-hand branch carefully: an execution does not *update* balances, it points
at the journal entry that moved them.

## The entities that were missing before

| Entity | What it solves |
|---|---|
| `reference.instrument` | The original design had no stock entity at all. Tick size, lot size and price bands now live here and are read by the matching engine on every order, so microstructure rules are **data, not code**. |
| `trading.execution` | The trade history table. Immutable, partitioned monthly, and each row carries `settlement_entry_id` so a fill can be traced to the exact ledger entry that moved the money. |
| `ledger.journal_entry` / `ledger.posting` | The book of record. Replaces the mutable `balance` column entirely. |
| `reference.trading_session` | Which dates are sessions and when they open — needed for a calendar-aware engine and for building daily bars correctly. |
| `reference.corporate_action` | Splits and dividends retroactively change what historical prices mean. |
| `analytics.account_snapshot` | End-of-session NAV. Performance metrics need a *value* time series; daily cash flow is not one. |

## Three modelling decisions worth defending

### 1. `trading.account` has no balance column

Balances are derived from `ledger.posting`. `ledger.balance` exists only as a
trigger-maintained **cache**, and `ledger.verify_integrity()` proves at any moment that
the cache still equals the sum of the journal.

This is the whole design. A mutable balance is its own only record; derived balances can
always be recomputed and reconciled.

### 2. Position quantity is derived; cost basis is not

`trading.position.quantity` is maintained by a trigger on `ledger.posting`, so *any*
movement of shares — a trade, an issuance, a corporate action, a transfer — updates it.
The two models cannot drift, by construction.

`avg_cost` and `realized_pnl` are **not** derivable from the ledger, because they depend
on the order fills arrived in. Those are written by the trade path, and
`trading.verify_positions_match_ledger()` asserts the quantity halves still agree.

(The first version of this schema updated `position` only from fills, and desynchronised
the instant shares moved for any other reason. See
[05-design-decisions.md](05-design-decisions.md).)

### 3. System accounts make the ledger a closed system

| `system_code` | Role |
|---|---|
| `EXTERNAL_CASH` | The bank / outside world |
| `HOUSE_FEES` | Commission revenue |
| `SECURITY_FLOAT` | The pool instruments are issued from |
| `MARKET_MAKER` | Synthetic liquidity provider |

Without these, a deposit could not balance — the money has to come *from* somewhere
nameable. With them, summing every posting across every account yields exactly zero for
every asset, which is check #3 in `ledger.verify_integrity()`.

## Cardinality notes

- `account → trade_order` is one-to-many and **mandatory on the child**: an order cannot
  exist without an account (`NOT NULL` FK).
- `trade_order → execution` is many-to-many *through the execution itself*: one execution
  references both a buy order and a sell order. A partial fill means one order has many
  executions.
- `journal_entry → posting` is one-to-many with a floor of **two**, enforced by the
  deferred trigger rather than by cardinality notation — SQL has no way to say "at least
  two children" declaratively.
- `trade_order → trade_order` is a self-reference (`parent_order_id`) forming the bracket
  / OCO / copy-mirror tree, walked by a recursive CTE.
- `strategy → copy_subscription → account` is many-to-many between strategies and
  accounts, with the subscription carrying its own attributes (allocation, notional cap).
