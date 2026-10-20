# The matching engine

## Model

A **continuous-auction limit order book** with price-time priority — the model used by
most modern equity venues.

1. Better-priced orders execute first.
2. Among equal prices, the order that arrived first executes first.

Rule 2 is ordered by `engine.order_seq`, a monotonic sequence, not by a wall clock.
Timestamps can tie at the same microsecond, and can even run backwards under an NTP
adjustment; a sequence cannot do either.

## The resting order sets the price

When an aggressor crosses the spread, the fill happens at the **resting** (maker) order's
price, not the aggressor's limit. So an order to buy at 182.50 that meets a resting offer
at 182.40 trades at **182.40** — the buyer receives price improvement.

Demonstrated by the test suite:

```
book:    SELL 200 @ 182.40  (Carol, seq 2)
         SELL 150 @ 182.40  (Bob,   seq 3)
         SELL 100 @ 182.50  (Bob,   seq 1)

incoming: BUY 400 @ 182.50

fills:   200 @ 182.40  → Carol   (best price, earliest at that price)
         150 @ 182.40  → Bob     (same price, later sequence)
          50 @ 182.50  → Bob     (next price level)

average fill 182.4125 against a 182.50 limit — 8.75¢/share of improvement
```

Note that Bob's 182.50 order carries sequence 1 — it arrived *first overall* — and still
fills last, because price beats time.

## Order types

| Type | Behaviour |
|---|---|
| `market` | Takes whatever is available; never rests |
| `limit` | Fills at the limit or better, remainder rests |
| `stop` | Dormant until the stop price trades, then behaves as a market order |
| `stop_limit` | Dormant until the stop price trades, then behaves as a limit order |
| `trailing_stop` | Stop ratchets with favourable price moves, then behaves as a market order |
| `iceberg` | Limit order that shows only `display_qty` in the public book |

### Why `kind` is never mutated on election

An elected stop *behaves* as a market order, but changing `kind` to `'market'` would
violate the `order_shape_matches_kind` CHECK, because `stop_price` is still populated.
Instead the engine derives behaviour from `kind` + `stop_armed` via
`engine.effective_limit()`. The order's identity stays truthful about what the user
submitted; only its current behaviour changes.

## Time in force

| TIF | Behaviour |
|---|---|
| `day` | Expires at session close (`engine.expire_orders`) |
| `gtc` | Rests until filled or cancelled |
| `ioc` | Fill what is available immediately, cancel the rest |
| `fok` | All at once or nothing |

`fok` is the interesting one: the engine measures available liquidity at acceptable prices
**before** touching the book, because a partially-executed fill-or-kill would be a
contradiction that cannot be undone within the same statement.

## Concurrency

```sql
PERFORM pg_advisory_xact_lock(hashtext('apex_book'), p_instrument_id);
```

- **Transaction-scoped**, so it is released automatically at COMMIT or ROLLBACK — a
  crashed session cannot wedge the book.
- **Keyed per instrument**, so AAPL and MSFT match in parallel; only same-symbol flow
  serialises.
- Contra rows are additionally taken `FOR UPDATE`.

### Why not `SKIP LOCKED`

`SKIP LOCKED` is the right tool for a work queue (and is used for exactly that in
`social.process_copy_queue`). It is the **wrong** tool here: skipping a locked resting
order would let a later-arriving order jump the queue, silently violating time priority.
Fairness is the product. The engine blocks instead.

### Proof

`db/test/concurrency.sh` fires 480 orders from 16 simultaneous sessions across three
accounts at a single resting order of 3,000 shares — 4,800 shares of demand:

```
resting_quantity            | 3000.00000000
resting_filled              | 3000.00000000
resting_status              | filled
total_fills                 | 300
overfilled_orders           | 0
shares_created_or_destroyed | 0.00000000
cash_created_or_destroyed   | 0.00000000
```

Filled exactly 3,000 — not 3,001. Nothing created, nothing destroyed, ledger exact.

## Settlement

Every fill produces one balanced journal entry:

```
buyer  cash      -(notional + buy_fee)
seller cash      +(notional - sell_fee)
house  cash      +(buy_fee + sell_fee)      → cash legs sum to 0
buyer  security  +qty
seller security  -qty                       → security legs sum to 0
```

Cash and each security must balance **independently** within one entry — you cannot settle
a share deficit with dollars. Fees are asymmetric: the aggressor pays the taker rate, the
resting side pays the lower maker rate, both configurable in `ops.config`.

## Stop cascade

A print may touch resting stops; electing them produces fills that may touch further
stops. `engine.submit_order` loops over `engine.elect_stops` with a bound from
`ops.config.max_stop_cascade`, so a feedback loop terminates instead of running away.

## What it does not do

Stated plainly, because knowing the boundary matters:

- **No opening/closing auction.** Real venues run a call auction at the open and close;
  this is continuous trading only.
- **No pro-rata matching.** Some futures markets allocate pro-rata at a price level rather
  than strictly by time. Only price-time is implemented.
- **No hidden/reserve replenishment.** Iceberg orders expose `display_qty` in the depth
  view, but the hidden remainder does not re-queue at the back on each refill the way some
  venues require.
- **No cross/block facility**, no market-on-close orders, no self-trade-prevention by
  default (it exists as `surveil.block_self_match` but ships disabled, so the demo can
  generate wash trades for the surveillance module to find).
