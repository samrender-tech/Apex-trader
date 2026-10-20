# Architecture

## The central decision

**Business invariants live in the database, not in the application.**

The alternative — check risk in Python, then match in Python, then write balances — cannot
be made atomic across concurrent orders without either a global lock (which destroys
throughput) or a distributed transaction (which is worse). Pushing matching, settlement
and risk into one database transaction is what makes the system correct under concurrency.

That decision explains everything else, including why there is no ORM: the SQL *is* the
system, and an ORM exists to hide exactly that.

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Browser dashboard — charts, depth ladder, ticket, console   │
│ vanilla JS, no build step                                   │
└────────────┬──────────────────────────────┬─────────────────┘
             │ REST (JSON)                  │ WebSocket
┌────────────▼──────────────────────────────▼─────────────────┐
│ FastAPI                                                     │
│  • deliberately THIN: order entry is ONE database call      │
│  • sets apex.current_user_id per request  → activates RLS   │
│  • Decimal end-to-end; a float never touches a NUMERIC      │
│  • EventHub: one LISTEN connection fans out to all sockets  │
└────────────┬────────────────────────────────────────────────┘
             │ asyncpg, raw SQL
┌────────────▼────────────────────────────────────────────────┐
│ PostgreSQL — the actual product                             │
│                                                             │
│  engine    matching, settlement, stop election              │
│  ledger    double-entry journal (book of record)            │
│  risk      pre-trade gate, margin, halts                    │
│  trading   accounts, orders, executions, positions          │
│  market    ticks, quotes, OHLCV candles (partitioned)       │
│  reference instruments, exchanges, calendar, corp actions   │
│  surveil   market-abuse detection                           │
│  social    strategies, copy-trading fan-out queue           │
│  analytics views, matviews, NAV history, performance        │
│  audit     immutable change log                             │
│  identity  users, credentials, sessions                     │
│  ops       partitions, maintenance, observability           │
└─────────────────────────────────────────────────────────────┘
             ▲
             │ reference prices only
┌────────────┴────────────────────────────────────────────────┐
│ Market data feed — Yahoo │ Finnhub │ GBM simulator          │
│   auto-selects; falls back to the simulator (and says so)   │
│   in the UI if the live provider stops responding           │
└─────────────────────────────────────────────────────────────┘
```

## Why the feed is pluggable, and what "auto" picks

`APEX_FEED_PROVIDER` takes `auto` (the default), `yahoo`, `finnhub` or `simulator`.
`auto` uses Finnhub when `APEX_FINNHUB_API_KEY` is set and Yahoo otherwise, so the system
works with no key and no signup. Search and on-demand instrument listing always go through
Yahoo, because it is the one that will answer "what symbols match *bitcoin*" without a
contract.

| | Yahoo | Finnhub | Simulator |
|---|---|---|---|
| API key | none | free tier, required | none |
| Symbol search | yes | yes | no |
| Minute history | ~7 days | ~30 days on the free tier | unlimited, generated |
| Crypto | yes, `BTC-USD` style | yes, exchange-prefixed | yes |
| Rate limits | undocumented and real | 60/min on the free tier | none |
| Offline / CI | no | no | **yes** |

The simulator is not a stub — see [05-design-decisions.md](05-design-decisions.md). It is
what makes the project demonstrable outside market hours, on a plane, and in CI.

A live feed that stops answering used to be invisible: the worker returned quietly,
retried in five seconds, and the dashboard showed a frozen price behind a green "live"
badge. After a minute of empty polls the worker now switches to the simulator and the UI
badge changes to **simulated**. A demo running on clearly-labelled synthetic prices is
more honest than one that has silently stopped.

## Why bounded-context schemas

The system is split into twelve PostgreSQL schemas rather than one flat `public`. This
gives readable qualified names (`ledger.posting` says what it is), a per-context `GRANT`
surface, and a natural place to attach RLS policies. It also makes the dependency
direction visible: `engine` depends on `ledger` and `risk`, never the reverse.

## The feed is a reference, not a source of truth

A subtle but important point. The external market-data feed sets
`market.quote.reference_price` — the mark that anchors price bands and the circuit
breaker. It deliberately does **not** overwrite `last_price`, because `last_price` is the
last price *traded on this venue*, discovered by our own matching engine. Conflating them
would mean the exchange reported trades at prices nobody traded at.

## Request lifecycle: placing an order

1. **API** validates the payload shape with Pydantic (`Decimal`, never `float`) and
   mirrors the database's order-type grammar so obvious mistakes return a clear 422.
2. **Connection checkout** sets `apex.current_user_id`, activating Row Level Security for
   this tenant.
3. **`engine.submit_order`** — a single call, therefore a single transaction:
   - idempotency check on `client_order_id` (a retried POST cannot double-order)
   - `pg_advisory_xact_lock` on the instrument
   - `engine.validate_order` — tradability, lot size, tick size, price band, halts
   - `risk.pretrade_check` — buying power net of committed orders, share availability net
     of open sells, concentration, order rate, daily loss
   - FOK liquidity probe, if applicable
   - `engine.match_order` — walk the contra side in price-time priority
   - for each fill, `engine.settle_fill` → execution row + balanced journal entry +
     position update + tick + quote update + `pg_notify`
   - residual handling per time-in-force; bounded stop-order cascade
4. **COMMIT** — the deferred double-entry invariant is verified here. If any entry does
   not sum to zero, the *entire* order is rolled back.
5. **`NOTIFY`** payloads reach the `EventHub`, which pushes to every open WebSocket.

Either all of that happened, or none of it did. There is no intermediate state in which an
order is half-processed.

## Failing closed

Several defaults are chosen so that a mistake produces nothing rather than something wrong:

- A connection with no `apex.current_user_id` set sees **no rows**, not all rows.
- A cash posting that would overdraw an account raises, even though pre-trade risk should
  already have prevented it — the ledger refuses to represent the impossible state.
- The matching engine blocks rather than using `SKIP LOCKED`, because skipping would
  silently violate time priority, which is worse than waiting.
- `ops.health_check()` separates `FAIL` (structurally broken) from `ATTENTION` (an open
  critical alert — which a correctly-working venue *will* have).
