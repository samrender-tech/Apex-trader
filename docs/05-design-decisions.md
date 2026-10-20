# Design decisions, and the bugs this design caught

The interesting part of this project is not the feature list — it is which invariants were
pushed into the database, and what they caught. Each bug below was found by a constraint
or a test, not by a user.

---

## Twenty-six real bugs

Most of them produced no error, no exception and no visible symptom. That is the pattern
worth noticing: the dangerous failures here were not crashes, they were invariants that
quietly stopped being enforced while everything carried on looking right.

### 1. Float money — caught by a tick-size CHECK

The seeder sent prices as Python `float`. asyncpg encodes a float as `float8`, and 174.73
is not representable in binary, so the server received:

```
python 174.73  →  numeric 174.729999999999989768184605054557323455810546875
                  mod 0.01 = 0.00999999999998976...   (not zero)
```

153 of 160 market-maker orders were rejected as "price must be a multiple of tick size
0.01" — for prices that *are* multiples of 0.01.

**The strict constraint was right.** Fixed in two places: the client now sends `Decimal`
(exact under `NUMERIC`), and the engine normalises to the stored scale before validating,
so the check agrees with what the column will hold. This is the exact failure mode the
`money_amt` domain comment warns about, and it validated the decision to use `NUMERIC`
everywhere rather than `float8`.

### 2. Position quantity desynchronised from the ledger

`trading.position` was updated only from trade fills. The moment shares moved for any
other reason — issuance, a corporate action, a transfer — the position table and the
ledger disagreed. `trading.verify_positions_match_ledger()` surfaced it immediately.

**Fixed structurally, not with a patch:** share quantity is now maintained by a trigger on
`ledger.posting`, so every security movement updates it regardless of cause. Cost basis
and realised P&L, which genuinely are not derivable from the ledger, stayed on the trade
path.

### 3. Daily loss limit measured cash flow, not P&L

`risk.pretrade_check` compared net cash movement against `max_daily_loss`. Buying 400
shares for 73,038 is a 73,038 cash *outflow* but not a loss — you hold 73,038 of stock.
The effect: any trader who bought more than their daily loss limit was frozen out of their
own account for the rest of the session.

**Fixed** by separating three genuinely different quantities:

| Function | Meaning |
|---|---|
| `risk.cash_flow_today` | Net cash movement (for the blotter) |
| `risk.realized_pnl_today` | P&L from closing trades |
| `risk.pnl_today` | Realised + mark-to-market — what the limit measures |

This is the same conceptual error that motivated `analytics.account_snapshot` in the first
place: a return series needs *values*, not cash flows.

### 4. RLS policy recursion

`identity.current_user_is_privileged()` reads `identity.app_user`, and `app_user`'s RLS
policy calls that function. Reading your own profile aborted with *"stack depth limit
exceeded"*.

Invisible during development, because everything was being tested as a superuser and
superusers bypass RLS entirely.

**Fixed** by making the helper `SECURITY DEFINER` — the standard way to write an RLS
predicate helper.

### 5. ...which immediately caused a privilege escalation

The fix for #4 introduced a worse bug. The function ended with:

```sql
OR pg_has_role(current_user, 'apex_compliance', 'MEMBER')
```

Inside a `SECURITY DEFINER` function, `current_user` is the function's **owner**. The
owner is a superuser, and `pg_has_role()` reports a superuser as a member of every role —
so this returned `TRUE` for every caller and **silently disabled Row Level Security across
the entire database**. Every trader could read every other trader's orders, positions and
ledger.

Caught by the API test asserting that two traders see disjoint order sets.

**Fixed** by testing `session_user` (the role that actually connected) instead of
`current_user`. Both the static check and the behavioural check are now regression tests.

### Bonus: the deferred trigger met RLS

Once the API ran as a non-superuser, every trade between two different users was rejected
as unbalanced. The deferred constraint trigger fires at `COMMIT` — *after*
`ledger.post_entry` (which is `SECURITY DEFINER`) has returned — so it ran as the ordinary
application role and RLS hid the counterparty's legs. It saw the buyer's cash without the
seller's and concluded the entry did not balance.

The invariant is a property of the whole entry, so the check must see the whole entry.
`ledger.assert_entry_balanced` is now `SECURITY DEFINER`, with a comment explaining why
it is load-bearing.

### 6. The audit log was 70% of order latency

Orders felt slow in the UI. Profiling, not guessing:

```
full submit_order            35.7 ms
  with audit trigger off     11.0 ms   <- the trigger was ~70% of it
pre-trade risk gate           3.0 ms
top-of-book refresh           1.2 ms
```

Two causes, both surfaced by the project's own `ops.v_index_usage` view:

- `ix_audit_newrow`, a 744 kB GIN index over the whole `new_row` JSONB
  document, had been scanned **zero** times. GIN tokenises every key and value
  on insert, so it was pure write amplification for no read benefit.
- Every order wrote **four** audit rows — the insert plus three updates as the
  engine advanced `filled_qty` and `status`. 205 of 210 recorded updates changed
  nothing but `status`.

Fixed in `017_audit_tuning.sql`: the unused GIN indexes are dropped (replaced by
a BRIN on `acted_at`, which suits an append-only log), and order updates are
audited only on a **terminal state or an amendment of economic terms**, via a
trigger `WHEN` clause — evaluated before the function is called, so a skipped
row costs nothing.

That is a judgement about what an audit log is *for*: it records decisions, not
the engine's internal progress. Fill-by-fill detail already lives in
`trading.execution`, immutably and in more detail. Six regression assertions pin
down exactly what must still be captured.

**Result: 35.7 ms → 6.5 ms in the database, ~40 ms → ~12 ms end-to-end over HTTP.**

The ingestion worker was batched in the same pass: it had been doing four
sequential round trips per instrument (64 per cycle for a 16-name universe) on
the same event loop that serves API requests, so a poll cycle landing on top of
an order delayed it. It is now three `UNNEST`-based statements, with the circuit
breaker evaluated only for instruments whose price actually moved.

### 7. The order ticket pre-filled a price that could never fill

Reported as "I click buy and it just says buying". The engine was correct and
the ticket was wrong.

With the book at bid 174.73 / ask 174.87, the ticket defaulted the limit price
to `last_price` (174.80). A buy limit at 174.80 does not cross a 174.87 offer,
so it correctly rested on the bid — and the user's own order then appeared as
the best bid, which made it look even stranger.

Two fixes, both about making correct behaviour legible:

- A buy now defaults to the **ask** and a sell to the **bid** — the marketable
  side — and re-prices when the side is flipped. This is what every real trading
  ticket does.
- The ticket shows, before you commit, whether the order will cross or rest:
  *"crosses the spread — fills now at 174.87 or better"* versus *"rests on the
  book at 169.62 — 3.00% away from the offer; fills only if the market comes to
  it"*.

Worth noting for a demo: the second message is the one that teaches someone what
a limit order actually is.

### 8. A half-applied migration that no test could see

Migration 019 adds a currency dimension to the ledger. It aborted partway, because
`analytics.v_account_summary` depended on the one-argument `ledger.cash_balance` it was
trying to drop. PostgreSQL refused, the migration stopped, and `convert_currency`,
`v_fx_board` and the two-argument `cash_balance` were never created.

**The whole test suite still passed.** Nothing exercised the currency path, so a feature
that did not exist at all looked healthy.

Two fixes. The migration now drops the dependent view first (migration 020 rebuilds it,
currency-aware). And there is a `db/test/40_currency.sql` suite whose first five
assertions check that the migration actually completed — that `convert_currency` exists,
that `cash_balance` takes a currency, that the FX board has rows, and that no function in
the database has ambiguous overloads.

A feature with no test is a feature that can vanish silently.

### 9. Default parameters do not replace older signatures

Four functions gained a parameter with a default — `post_entry` (currency),
`cash_balance` (currency), `convert_currency` and `ensure_currency` (timestamp). In each
case the older, narrower signature remained callable, and every existing call then failed
with *"function is not unique"*.

`CREATE OR REPLACE FUNCTION` replaces a function with the **same** argument list. A
different arity is a new function, not a replacement. Each migration now explicitly
`DROP FUNCTION`s the old signature, and a test asserts no schema in the database has an
ambiguous overload.

### 10. Everything that aggregated cash had to be told which cash

Adding a currency dimension is not finished when the ledger compiles. `account_nav`,
`buying_power`, `cash_flow_today`, `open_buy_exposure`, both snapshot builders and two
views all summed a `balance` column. With one currency that was right; with several it
would add rupees to dollars and report a portfolio 83x too large.

`ledger.verify_integrity()` caught it within seconds of the first conversion — it reported
six drifted slots, because it was comparing a per-currency cache against a currency-blind
journal sum. The pre-trade gate needed the same treatment: an order's value is in the
*instrument's* currency while buying power is in the *account's*, and comparing them
unconverted would let a rupee account buy roughly 83 times what it can afford.

### 11. Short selling should never be something you fall into

A trader sold 10 QQQ they did not own and ended up with a **-10 position**. The engine was
behaving as designed: the account was a margin account and QQQ was flagged shortable,
which was exactly the condition that permitted a short.

That is the wrong default. Short selling carries unlimited downside and at a real broker
needs a separate agreement and a locate on borrowable stock. `kind = margin` should not
silently imply it.

It is now a third, explicit condition — `trading.account.allow_short_selling`, default
`FALSE`, with a CHECK forbidding it on a cash account. Overselling a long position is an
error with a message that says what you actually hold. The ledger enforces it
independently, so the risk gate and the book of record cannot disagree.

### 12. The migration runner was itself the bug

Reported as "it's not working properly" after an upgrade. Nothing in the application was
wrong — the new migrations had simply never run.

`scripts/db.sh migrate` replayed **every** file on every invocation. That works exactly
once, on an empty database. On an existing one it died on the 43rd line of migration 001:

```
psql:001_foundation.sql:43: ERROR:  type "money_amt" already exists
```

`set -e` aborted the run, so migrations 018–021 were never reached. The upgrade silently
did nothing, and the instruction to run `./scripts/db.sh migrate` to upgrade was wrong.

There were 132 non-idempotent statements across the 21 files — 28 `CREATE TYPE`/`DOMAIN`,
29 `CREATE TABLE`, 56 `CREATE INDEX`, 19 `CREATE TRIGGER`. Guarding each one by hand was
the wrong fix: a migration is not supposed to be idempotent, it is supposed to run
**exactly once**. What was missing was the thing that remembers.

`ops.schema_migration` now records every applied file with its checksum, duration and
timestamp, and `migrate` applies only what is unrecorded. Files are applied inside a
single transaction so a failure rolls back rather than half-applying — except files
containing `ALTER TYPE ... ADD VALUE`, which PostgreSQL will not allow to be used in the
transaction that creates them.

For a database built before tracking existed, the first `migrate` **baselines** it: each
migration has a sentinel object (migration 019 → `reference.currency`, 018 →
`trading.account.allow_short_selling`), and any migration whose sentinel is already there
is recorded without being re-run. Verified by building a v2.0-era database, running the
new `migrate`, and confirming it baselined 001–017 and applied exactly 018–021.

The lesson is the one that keeps recurring in this project: **the thing that verifies is
as important as the thing that works.** The feature was correct; the mechanism that was
supposed to deliver it had no check that it had.

### 13. The login screen hardcoded a list that had moved on

The seeder was changed to create the project team's accounts, and it did. But the login
screen carried its own copy of the demo logins as a JavaScript constant, so it went on
offering `priya.sharma@apex.io` and `wei.zhang@apex.io` — accounts that no longer
existed. The data was right and the thing showing it was stale.

Swapping the strings would have fixed the symptom and left the cause: two places
claiming to know who can log in. The login screen now fetches
`GET /api/auth/demo-accounts`, which reads `identity.app_user` and reports each account's
base currency, type, whether it publishes a strategy and whether surveillance has flagged
it. Reseeding with different accounts updates the screen with no code change.

The endpoint is gated behind `APEX_DEMO_MODE` (default on) because it lists real account
emails — fine for a seeded demo, not for anything else.

### 14. A seeder that failed on the symptom, not the cause

Running the seeder against a database that had not been migrated produced this:

```
asyncpg.exceptions.UndefinedTableError: relation "reference.fx_rate" does not exist
```

...under twenty lines of asyncio traceback. Accurate, and useless: the real problem was
that `db.sh migrate` had not been run, and nothing in that message says so.

The seeder now checks `ops.schema_migration` against the migration files on disk before
touching anything, and names the gap:

```
ERROR: 4 migration(s) have not been applied:
    - 018_short_selling.sql
    - 019_currency.sql
    - 020_currency_trading.sql
    - 021_currency_backfill.sql

Seeding now would fail on a missing table. Run:
    ./scripts/db.sh migrate
```

There is also `scripts/setup.sh`, which runs migrate → verify → seed → start in order and
stops at the first failure. The steps have a required ordering, and the previous failure
mode for getting it wrong was an error that pointed at a missing table rather than at the
skipped step.

A related footgun, worth recording because it cost a round trip: instructions written as a
pasteable block with `# inline comments` do not survive a paste into zsh, where
`interactive_comments` is off by default at the prompt. The apostrophe in *"what's
applied"* opened a quote and left the terminal sitting at `quote>`.

### 15. Crypto broke four equity assumptions that had never been wrong before

Listing eight crypto pairs did not need a new engine. It needed the existing one to stop
assuming things that happen to be true of every US equity.

**A lot size of 1.** The seeder sized historical fills as `RNG.choice([5, 10, 20, ... 150])`
"shares". At $67,000 a coin that is a $3.3m clip, so every crypto fill failed its
pre-trade check and no account ever held a coin. Quantities are now sized by *notional*
and snapped to `lot_size`, which for crypto is `0.00000001` — a satoshi.

**A tick size of 0.01.** The market maker computed its spread as
`max(mid * 0.0004 * level, 0.01)`. On DOGE-USD, whose tick is `0.00001` and whose price is
about $0.13, that floor is an 8% spread — and the resulting prices were not whole numbers
of ticks, so `engine.validate_order()` rejected them. The symptom was not an error
anywhere: it was **70 resting orders where there should have been 160**, and crypto books
that looked empty. The spread is now computed in ticks, and `reference.align_price()`
exists so that no caller has to rediscover this.

**`round(x, 2)` everywhere a price is handled.** The simulator rounded every step of its
random walk to two decimals, which quantises a $0.13 coin into about thirteen
distinguishable price levels — DOGE's whole price path came out as a staircase with
`high == low` on most bars. The ingestion worker did the same to its marks, so a 4% move
rounded to nothing and the live chart was flat. Rounding now happens at the point of
emission, scaled to the magnitude of the price, and the frontend reads the instrument's
own `tick_size` rather than assuming cents.

**That history has a gap between "yesterday" and "now".** This one was the real bug, and
it gets its own entry below.

### 16. The candle roller ate the history it was supposed to extend

After a clean seed, the last two bars of every crypto series looked like this:

```
ADA-USD  20:32  close 57.54   volume 10
ADA-USD  20:31  close 57.70   volume 7
ADA-USD  20:30  close  0.39   volume 1110
ADA-USD  20:29  close  0.40   volume 1276
```

ADA is a $0.39 coin. The last two bars said $57.

Two faults compounded. The first: `IngestionWorker` primed the simulator from stored
prices **once, at start-up**. The worker starts with the API, and instruments arrive
later — a reseed, or `/market/import` listing a symbol on demand. Anything created after
start was never primed, so the feed fell back to its profile's opening price, and for a
symbol with no profile it *invented one from a hash of the name* — which is exactly where
$57.66 came from. Priming is now lazy and per-symbol, so the window cannot reopen.

The second fault is the structural one. `market.build_candles_1m()` rolls recent ticks
into bars every 50 seconds with an unconditional `ON CONFLICT DO UPDATE`. For an equity
that is harmless: the loaded history stops at the previous session close, so the roller's
window and the backfill never overlap. **Crypto trades 24×7**, so its history runs right
up to the current minute and the roller landed straight on top of real bars, replacing a
1,110-volume bar with one synthesised from two unit ticks.

That then propagated: `market.quote.reference_price` is marked off the last bar, so the
corrupted bar became the price band's anchor, and the band `[34.70, 80.98]` rejected every
honest order on the book.

The fix is provenance. `market.candle_1m.source` records whether a bar came from loaded
history or from ticks, and the roller is only allowed to overwrite bars it owns
(migration 023). A backfilled bar is authoritative and immutable to it.

The lesson worth keeping: *the overlap had always been possible; equities just never
exercised it.* A new asset class is a good way to find out which of your invariants were
only coincidences.

### 17. Volume was counting things that are not trades

`market.tick` holds two different kinds of row: a fill, whose `volume` is a quantity that
changed hands, and a *mark* — one row per ingestion poll recording the external reference
price. A mark has no quantity, so the worker wrote `volume = 1` as a placeholder, with a
comment saying so.

The candle builder summed both. A live minute bar therefore reported "volume 12" — twelve
polls — next to a backfilled bar at 2,500. The volume histogram flatlined at the right
edge of every chart, VWAP was dragged toward a price nothing traded at, and the
volume-anomaly surveillance rule was comparing bars whose volumes meant different things.

A placeholder had quietly become data. `market.tick.is_trade` now says which is which:
OHLC uses every print, because a mark is still the best evidence of where the instrument
is between fills; volume, trade count and VWAP use trades only. A minute with marks and no
fills reports volume 0 and a NULL VWAP, which is the honest answer.

### 18. Row Level Security was switched off by every view that used it

`14_security.sql` enables RLS on twelve tenant tables and has regression tests proving the
policies hold. They do hold — when you query the **table**.

A view runs with the privileges of its *owner*, and RLS on the underlying tables is
evaluated against that owner too. Every view here is owned by `apex`, which owns the
tables, and a table owner is exempt from its own RLS unless `FORCE ROW LEVEL SECURITY` is
set. So reading the same rows through `analytics.v_portfolio` or `social.v_watchlist`
consulted no policy at all.

Nothing caught it because almost every endpoint *also* passes an explicit `account_id`
predicate — the leak was masked by application code doing the filtering the database was
supposed to be doing. The RLS layer was decoration.

`GET /api/watchlist` was the endpoint with no predicate of its own. Its docstring said, in
as many words:

```python
"""
The caller's watchlists with live quotes.

No user_id predicate: Row Level Security scopes this to the caller.
"""
```

It returned all eight demo users' watchlists.

PostgreSQL 15's `security_invoker` makes a view run as the caller, and migration 024 sets
it on every view over user data. `trading.v_book_depth` is deliberately excluded and the
exclusion is asserted: depth is public market data and must show every participant's
resting size, so running it as the invoker would filter the ladder down to the viewer's
own orders — not a security improvement but a functional break.

The durable part of the fix is `ops.assert_rls_intact()`, which lists any view in a
user-data schema still running as its owner. It is in `ops.health_check()` and in the test
suite, so the next view someone adds has to make the decision explicitly instead of
inheriting the unsafe default.

### 19. Two rules that contradicted each other, so one of them never ran

`risk.alert_fire` was given both of these:

```sql
alert_id BIGINT NOT NULL REFERENCES risk.price_alert(alert_id) ON DELETE CASCADE
CREATE TRIGGER ... BEFORE UPDATE OR DELETE ON risk.alert_fire
    EXECUTE FUNCTION ledger.forbid_mutation();
```

"When the alert goes, its history goes with it" and "nothing in this table is ever
deleted". Each is defensible alone. Together they mean an alert that has ever fired can
**never** be deleted: the cascade tries to remove the fire rows, the append-only trigger
refuses, and the whole `DELETE` aborts. `DELETE /api/alerts/{id}` returned a 500 for
exactly the alerts a user is most likely to want to clear.

`ON DELETE SET NULL` fails the same way one level down — `SET NULL` is an `UPDATE`, which
the trigger also forbids.

The resolution is to decide which rule wins rather than to weaken both. A fire is history;
an alert is configuration; history wins. The FK is `RESTRICT`, and `risk.remove_alert()`
deletes an alert that never fired and **archives** one that did. The user's list stops
showing it either way; the difference is only whether a notification that really was sent
can be erased, and it should not be.

A smaller bug fell out of the same investigation: `ledger.forbid_mutation()` hardcoded
`'ledger.%'` into its error message, so a violation on `risk.alert_fire` reported
`ledger.alert_fire is append-only` — a table that does not exist.

### 20. A test suite that reported green while checking less than it claimed

`db/test/10_ledger.sql` contained this:

```sql
v_before := ledger.cash_balance(v_alice);   -- v_before is money_amt
...
PERFORM t.eq('ledger', '...', ledger.cash_balance(v_alice) - v_before, 2500::money_amt);
```

`money_amt` is a DOMAIN over `NUMERIC`, and subtracting two domain values yields plain
`numeric`. `t.eq` takes `ANYELEMENT` for both sides, so `numeric` vs `money_amt` resolved
to no function at all.

The suite runs with `ON_ERROR_STOP` deliberately **off**, because `t.raises()` tests expect
failures. So the statement simply errored, the assertion was never recorded, and the DO
block it was inside stopped early — taking three more assertions with it. The report said
`ledger | 13 passed | 0 failed` and everyone believed it.

A failed assertion is loud. An assertion that never ran is silent, because it writes no
result row at all. `scripts/test.sh` now collects anything that reaches psql's error
channel and fails the run on it, with the message *"the suite checked less than it
reports"*. The ledger suite went from 13 assertions to 16 the moment it was fixed.

This is the same failure shape as decision 8 — a half-applied migration that no test could
see — which is why both are worth writing down.

### 21. A wide child stretched the entire application

Wrapping the instrument tape in a flex bar to hold the new asset-class chips pushed the
whole page to **5,384px wide** on a 1,600px viewport: the header, the trade grid and
everything else went with it.

`#app` is a single-column grid, and a grid column sized `auto` resolves to the *max-content*
of its widest row. The tape used to be the grid item itself and got away with being 5,000px
of scrollable chips because `overflow-x: auto` gives a grid item an automatic minimum size
of zero. Wrapping it moved that overflow one level down, and the protection went with it.

`grid-template-columns: minmax(0, 1fr)` pins the column regardless of what is inside it.
The layout is now swept at seven viewport widths from 1920 down to 430 across four views,
asserting `document.body.scrollWidth <= innerWidth` — because "it looked fine on my screen"
is how this class of bug survives.

### 22. One stale process, six unrelated-looking faults

A report came back with six symptoms at once: search said *Not Found*,
History said *Not Found*, every card on the Markets page was empty, the watchlist said
*Watchlist failed: Method Not Allowed*, the currency dropdowns were blank, and the
allocation panel showed no Crypto despite the account holding 1.35 ETH.

They were one fault. The dashboard files on disk were current; the **process serving them
was not**. Unregistered `/api` routes fall through to the `StaticFiles` mount at `/`,
which answers `404 {"detail":"Not Found"}` to a GET and `405 {"detail":"Method Not
Allowed"}` to a POST. So every endpoint added after that server started reported a
plausible-looking failure of its own, and none of them named the cause. The allocation
panel was the giveaway: `classOf()` reads `instrument.kind`, the old
`/market/instruments` did not return it, so ETH-USD was silently bucketed as a stock.

`scripts/api.sh start` was complicit. Its liveness check was:

```bash
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running (pid ...)"; return 0
fi
```

`kill -0` is true for *any* process holding that number — a recycled PID after a reboot,
or a uvicorn from an earlier session. "Already running" is only good news if what is
running is this code, and nothing checked that.

Three changes, because the failure needs catching at three different moments:

1. **The server states its contract.** `API_CONTRACT` in `backend/app/main.py`, reported by
   `/api/health`, bumped whenever a route the dashboard depends on changes.
2. **The dashboard refuses to pretend.** It compares that number against the one it was
   built for *before the login screen renders*, and on a mismatch replaces the page with
   what is wrong and the command that fixes it. A missing field is treated as a mismatch,
   which is what catches a build predating the check.
3. **`api.sh` will not leave a stale server up.** It compares the contract in the source
   on disk against the live one, replaces a server that disagrees — falling back to
   `lsof -ti:PORT | xargs kill` when the process is not the one in its PID file — and
   fails loudly if the server that comes up still disagrees.

The general lesson is about catch-alls. A static mount under the same prefix as an API is
a convenience that converts "this route does not exist" into "this resource was not
found", and those are not the same sentence. Any router that swallows unmatched paths
should be assumed to be hiding a deployment fault until something proves otherwise.

### 23. Short selling was the wrong default for the account you land on

Selling more shares than held produced a position of **−6 MSFT** rather than an error.

The engine was right: `samrender` was seeded as a margin account with
`allow_short_selling = true`, and the risk gate let the sale through because that account
was permitted to be short. But it is the account the demo opens on, so the first thing
anyone does — sell a holding, slightly over — silently opens a short, and a holdings table
showing a negative quantity reads as a bug no matter what the schema intended.

Every demo trader now seeds with the privilege **off**, so over-selling is refused by name:

```
cannot sell 9.00000000 MSFT: you hold 4.00000000.
Short selling is not enabled on this account.
```

The feature is untouched — still enforced independently by `risk.pretrade_check` and by the
ledger, still refused outright on a cash account by the `short_requires_margin` CHECK. It
is just no longer the default on the account a first-time user signs in to. `api_smoke.py`
now proves both halves: the refusal when the privilege is absent, and a genuine short with
a balanced ledger once an account is granted it — then buys it back, so the suite can run
twice in a row against the same database.

### 24. The fix for 22 had the same bug it was fixing

The version check shipped in decision 22 did not fire against the server it was written
for. The user ran it and got:

```
WARNING: started, but the server reports contract none
         while this source tree is 3. Something else is on port 8000.
```

`live_contract()` greps the version out of `/api/health` and returns an empty string when
it is not there. But it returns an empty string just as readily when **nothing is
listening at all**, and `start()` gated the whole replacement branch on that string being
non-empty:

```bash
HAVE="$(live_contract)"
if [ -n "$HAVE" ]; then        # false for a pre-versioning server
    ... replace it ...
```

So against the one server that most needed replacing — an old one with no version field —
the branch was skipped entirely. uvicorn then failed to bind the busy port, the old server
kept answering the health check, and the only output was a warning telling the user to run
`lsof` themselves. The guard detected the condition and then declined to act on it.

The mistake is conflating *absence of an answer* with *an answer that says nothing*.
`live_responding()` now asks whether anything is there at all, separately from what it
claims to be, and `free_port()` evicts the holder by port when it is not a process this
script started. Four paths are tested: nothing running, a current server, a stale PID
file, and a pre-versioning server squatting on the port.

### 25. Two prerequisites that reported the wrong cause

Both surfaced in the same session, and both failed in the same style: a true-sounding
message about the wrong thing.

**The virtualenv.** `scripts/setup.sh` checked for `.venv` and died with "Python
environment missing. Run: python3 -m venv .venv && ...". The archive deliberately ships no
`.venv` — it is tens of megabytes of platform-specific binaries, and a macOS one is
useless on Linux — so *every* fresh extract hits this. A check whose remedy is two
commands the script could run itself is homework, not a diagnostic. It now builds the
virtualenv and installs the requirements. `api.sh` keeps a check, because it must not
`nohup` a binary that is not there, but it names the cause and points at `setup.sh`.

**The PostgreSQL version probe.** This ran without credentials:

```bash
PGVER="$(psql -h "$PGHOST" -U "$PGUSER" -d postgres -tAc 'SHOW server_version_num' \
         2>/dev/null || echo 0)"
if [ "$PGVER" -lt 150000 ]; then
    die "PostgreSQL 15 or newer is required (found $PGVER)"
fi
```

`db.sh` exports `PGPASSWORD`; `setup.sh` did not. So on any server with password auth the
probe failed, `|| echo 0` swallowed the reason, and the script announced that **PostgreSQL
needed upgrading** — sending the reader to reinstall a database whose version was never in
question. `pg_isready` had already passed two lines earlier, which should have made the
contradiction obvious and did not.

An empty result and a failed connection are different facts, and `|| echo 0` erases the
difference. The probe now distinguishes them and, when the connection is the problem,
prints the `createuser` / `createdb` / `ALTER ROLE` lines that fix it.

Three bugs in a row — 22, 24 and this one — all the same shape: **a diagnostic that
reported something other than what went wrong.** A check that misreports is worse than no
check, because it is believed.

### 26. The venue and its feed became two different price universes

A user could not sell. The rejection read:

```
Order rejected by pre-trade risk
price 334.85000000 outside 20.0000% band [567.4640, 851.1960]
```

META's book was at 334.85 and the band was centred on 709. Both numbers were correct; they
were simply from different worlds. The demo had been seeded from the **simulator**, whose
META walks around $335, and the API was then started against a **live feed**, where META
really is $709.

`market.quote` deliberately keeps two prices apart — `last_price` is what traded *here*,
`reference_price` is the external mark — precisely so a feed can never claim a trade
happened at a price nobody traded (see [01-architecture.md](01-architecture.md)). But
`engine.validate_order()` anchors the price band on `reference_price`:

```sql
v_ref := COALESCE(v_q.reference_price, v_q.last_price, v_q.prev_close);
v_band_low  := v_ref * (1 - v_i.price_band_pct/100.0);
```

So the two are not independent in practice. When the mark walks away from the venue's own
tape, the band walks with it, stops containing the order book, and **every order in that
instrument is rejected** — no error, no corruption, no log line. The venue silently stops
accepting trades, and the only evidence is a rejection quoting a band that looks arbitrary.
The chart showed it too: a cliff at the right-hand edge where simulated history at 335 met
live ticks at 709.

Three defences, at three different layers.

**The seed and the feed now agree by construction.** `scripts/seed.py` works out which
provider the API will run on — reading `.env` the same way the app does — and fetches one
live quote per symbol, two dozen calls rather than the ~440,000 bars that make bulk live
history impossible. It then **scales each simulated walk so its final close lands exactly
on the live price**. The history stays synthetic and reproducible; only its level changes.
The book, the positions, the candles and the feed all start out continuous.

**The worker refuses an impossible mark.** A feed price more than 50% from this venue's own
last trade is not a market move, it is a different price universe. Those marks are dropped,
the instruments are listed in `/api/health`, and the log says what to do about it. Dropping
a mark keeps the books tradable; adopting it breaks all of them.

**The database can check it.** `market.mark_divergence()` reports every instrument whose
mark has left its tape behind, and — the question that actually matters —
`band_contains_book`. `ops.health_check()` fails on it by name:

```
bands_contain_their_books | FAIL | 1 instrument(s) untradable -- the external mark
                                   has left the venue's own price behind: META.
                                   Reseed to re-anchor: scripts/seed.py --reset
```

The general shape is worth naming. Two values were kept separate for a good reason, and a
third thing quietly coupled them. The separation was real; the *independence* was assumed.
It is worth asking, of any two fields deliberately kept distinct, what reads both — and
what happens when they disagree by more than anyone imagined they could.

A footnote on how this was nearly made worse: the first attempt to fix the test pointed a
string replacement at `WHERE symbol='AAPL'`, which matched an **earlier** block — silently
repointing an equity tick-grid assertion at a crypto instrument. It still passed, because
BTC-USD's tick is also 0.01. A test that passes for the wrong reason is worse than one
that fails, and a blind single-occurrence replace in a file with repeated idioms is a good
way to create one.

---

## Decisions

### Raw SQL, no ORM

The database *is* the product here. An ORM's purpose is to hide SQL, which would hide the
matching engine, the double-entry invariant and the risk gate. Raw SQL with `asyncpg` also
keeps money as `Decimal` end-to-end.

### Balances derived, with a cache

Pure derivation (always `SUM` the journal) is correct but gets slower forever.
`ledger.balance` is a trigger-maintained cache, and `ledger.verify_integrity()` proves it
still matches the journal. Correctness by construction, performance by cache, with a proof
that they agree.

### Rejections are 200, not 4xx

A risk rejection is a normal business outcome and the client needs the reason text, so
`POST /api/orders` returns 201 with `status: "rejected"` and `reject_reason`. HTTP errors
are reserved for malformed requests and genuine faults.

### The simulator is a first-class component

Not a stub. Geometric Brownian motion with per-symbol drift and volatility, regime
switching and jump events, seeded deterministically so the same run reproduces the same
history. This means the project demos with no API key, no network and outside market
hours — which matters for a graded demo and for CI.

---

## Honest limitations

- **Single database instance.** No replication, no sharding. The partitioning and index
  work is what makes vertical scale credible; horizontal scale is not implemented.
- **Matching is serialised per instrument.** Correct, and parallel across symbols, but a
  real venue's engine is an in-memory process doing microseconds per order. This is
  milliseconds.
- **The simulator is not a market.** It has no order flow feedback: simulated prices do
  not react to trades on our own book.
- **Corporate actions are modelled, not applied.** `reference.corporate_action` stores
  splits and dividends with an `is_applied` flag, but the routine that adjusts historical
  candles and open orders on an ex-date is not written.
- **Copy-trading has no fee settlement.** `strategy.fee_bps` is stored and displayed;
  charging it on profitable copied notional is not implemented.
- **No opening/closing auction, no pro-rata matching** — see
  [04-matching-engine.md](04-matching-engine.md).
- **Frontend has no unit tests.** It is verified end-to-end by `scripts/ui_check.py`, a
  Playwright run that drives the real UI and asserts 51 behaviours — sub-cent precision
  through the order ticket, fractional quantities not rounding to zero, watchlist and
  alert round-trips, asset-class filters, the health panel, no console output — plus a
  layout sweep at seven viewport widths. That is end-to-end coverage, not unit coverage.
- **No session rollover for day statistics.** `market.quote.day_open/high/low/volume`
  accumulate from fills and are seeded on first sight, but nothing resets them at an
  exchange's daily open. `015_maintenance.sql` owns the end-of-day batch and is where
  that belongs.
- **Imported instruments get a week of history.** `POST /market/import` backfills at
  *minute* resolution because `market.candle_1m` is the single base table every other
  interval is aggregated from. Providers serve roughly a week of minute data, so that is
  the cap — writing coarser bars into minute buckets would silently corrupt every
  aggregate above them.
