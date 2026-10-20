# Apex Trader – Canva slide content (13 slides)

Follows the BCSE302P Final PPT guidelines, one guideline item per slide; Database Implementation takes two.
Images to upload are in this folder; the number in each file name is its slide.

---

## Slide 1 – Title

**APEX TRADER**
A Stock and Cryptocurrency Trading Database Management System
with an In-Database Matching Engine and a Double-Entry Ledger

BCSE302P – Database Systems Lab
Submitted by: 24BCE2863 Kumar Paritosh · 24BCE2865 Samrender Singh Saini · 24BCE2886 Vartika Chaudhary
Under the guidance of: Prof. Nithya N S
School of Computer Science and Engineering, VIT Vellore

---

## Slide 2 – Abstract and Problem Statement

**Abstract**
- A trading venue where the database *is* the exchange: the order book lives in PostgreSQL and orders are matched in PL/pgSQL under price-time priority.
- Every trade settles into a double-entry ledger; balances are derived, never typed in.
- Multi-user isolation is enforced by Row Level Security, not by application code.

**Problem statement**
- The original design had only 3 entities (USER, ACCOUNT, HOLDING).
- Balances stored as plain numbers can be silently wrong, with nothing to reconcile against.
- Concurrent orders can double-fill, and one user can read another's data.

---

## Slide 3 – Objectives and Scope

**Objectives**
1. Model a complete trading venue in a normalised relational schema (BCNF).
2. Implement order matching inside the database: limit, market, stop, iceberg orders.
3. Guarantee accounting integrity: every journal entry sums to zero at COMMIT.
4. Run pre-trade risk checks before an order reaches the book.
5. Detect market abuse with analytical SQL.
6. Isolate users at the database layer (24 RLS policies on 16 tables).

**Scope**
- In scope: equities, ETFs and crypto; continuous auction; 10 currencies; surveillance.
- Out of scope: opening/closing auctions, corporate actions, real clearing.

---

## Slide 4 – System Architecture / Workflow

Image: `04-architecture.png`

Workflow of one order:
Browser → REST API (FastAPI) → `engine.submit_order()` → risk check → match against book → settle fill into ledger → COMMIT → WebSocket push to browser

Key point: the API holds no business logic; every write is one database function call.

---

## Slide 5 – ER Diagram

Image: `05-er-diagram.png`

- 12 core entities shown; 38 tables in total across 12 schemas.
- Key relationships: user 1:N account · account 1:N order · order 1:N execution · journal_entry 1:N posting.
- Each execution is linked 1:1 to the ledger entry that settled it.

---

## Slide 6 – Relational Schema and Normalization

**Schema: 12 PostgreSQL schemas**
identity · reference · market · trading · ledger · engine · risk · surveil · social · analytics · audit · ops

**Normalization**
- **1NF:** atomic columns; no repeating groups (order legs are rows, not columns).
- **2NF:** no partial dependency; composite keys such as position (account_id, instrument_id) fully determine their attributes.
- **3NF:** no transitive dependency; order symbol is fetched by joining instrument, not stored.
- **BCNF:** every determinant is a candidate key.
- **Deliberate denormalization:** ledger.balance is a trigger-maintained cache of the journal, checked by `ledger.verify_integrity()`.

---

## Slide 7 – Database Implementation (1): DBMS, CREATE TABLE, Constraints

**DBMS:** PostgreSQL 16 (extensions: pgcrypto, pg_trgm, btree_gist)

```sql
CREATE TABLE ledger.posting (
    posting_id    BIGINT GENERATED ALWAYS AS IDENTITY,
    entry_id      BIGINT NOT NULL,
    account_id    BIGINT NOT NULL,
    asset_class   ledger.asset_class NOT NULL,
    instrument_id INTEGER,
    amount        money_amt NOT NULL,
    currency      CHAR(3),
    PRIMARY KEY (posting_id),
    FOREIGN KEY (entry_id) REFERENCES ledger.journal_entry(entry_id),
    FOREIGN KEY (account_id) REFERENCES trading.account(account_id),
    CHECK (amount <> 0)
);
```

**Constraints in the database**
| PRIMARY KEY | FOREIGN KEY | UNIQUE | NOT NULL | CHECK |
|---|---|---|---|---|
| 37 | 57 | 11 | 540 | 71 |

---

## Slide 8 – Database Implementation (2): INSERT and Queries with Output

**Sample INSERT**
```sql
INSERT INTO reference.exchange (code, name, country_code, timezone, currency)
VALUES ('XBOM', 'BSE Limited', 'IN', 'Asia/Kolkata', 'INR');
```

**Query: aggregates with GROUP BY, HAVING and FILTER**
```sql
SELECT i.symbol, count(*) AS orders,
       count(*) FILTER (WHERE o.side = 'buy')  AS buys,
       count(*) FILTER (WHERE o.side = 'sell') AS sells
FROM trading.trade_order o JOIN reference.instrument i USING (instrument_id)
GROUP BY i.symbol HAVING count(*) >= 30
ORDER BY orders DESC, i.symbol;
```

**Output** (first 5 of 9 rows)
| symbol | orders | buys | sells |
|---|---|---|---|
| DIS | 54 | 33 | 21 |
| INTC | 48 | 24 | 24 |
| NVDA | 36 | 18 | 18 |
| AAPL | 35 | 20 | 15 |
| AMZN | 35 | 18 | 17 |

---

## Slide 9 – Advanced Database Concepts

Image: `09-double-entry.png`

| Concept | In Apex Trader |
|---|---|
| Procedures and functions | 83 functions + 1 procedure, e.g. `engine.submit_order()`, `engine.match_order()`, `risk.pretrade_check()` |
| Triggers | 40 triggers; a deferred constraint trigger rejects any unbalanced journal entry at COMMIT |
| Views | 12 views + 2 materialized views, e.g. `analytics.v_portfolio` |
| Transaction control | Order, fills, ledger and position change in one transaction; any failure is a ROLLBACK; SAVEPOINT shown in demo |

---

## Slide 10 – Application Screenshots / Demonstration

Images: `10-trading-terminal.png` (main), `10-login.png`, `10-positions.png`, `10-portfolio.png`

- Trading terminal: live candlestick chart, depth of market, order ticket.
- Positions: unrealised profit and loss against the live price.
- Portfolio: net asset value curve and performance statistics.
- Every number on screen is computed by the database.

---

## Slide 11 – Testing and Results

Image: `11-compliance.png`

| Test suite | Result |
|---|---|
| SQL assertion suite (5 files) | 150 assertions passed |
| API checks (every REST path) | 118 checks passed |
| Browser checks (all screens) | 51 checks passed |
| Structural invariants (`ops.health_check`) | 18 of 18 PASS |

**Concurrency test:** 12 parallel sessions sent 300 buy orders against one 3,000-share sell order.
Result: exactly 3,000 shares filled, 0 overfilled orders, 0 shares or cash created or destroyed.

---

## Slide 12 – Conclusion and Future Enhancement

**Conclusion**
- The database itself enforces correctness: matching, settlement, risk and access control all run inside PostgreSQL.
- Balances can always be rebuilt from the journal, so the books cannot silently drift.
- Concurrent trading is safe, as shown by the 12-session test.

**Future enhancement**
- Logical replication to a read replica for analytics.
- Continuous aggregates for candle data.
- Options and futures (a third asset class in the ledger).
- T+1 settlement cycles.
- Order-book depth beyond the top of book.
- Detaching old partitions to cold storage.

---

## Slide 13 – References

1. Elmasri, R. and Navathe, S. B., *Fundamentals of Database Systems*, 7th ed., Pearson, 2016.
2. Silberschatz, A., Korth, H. F. and Sudarshan, S., *Database System Concepts*, 7th ed., McGraw-Hill, 2019.
3. Codd, E. F., "A Relational Model of Data for Large Shared Data Banks", *Communications of the ACM*, 1970.
4. Kleppmann, M., *Designing Data-Intensive Applications*, O'Reilly, 2017.
5. PostgreSQL Global Development Group, *PostgreSQL 16 Documentation*, 2024.
6. Harris, L., *Trading and Exchanges: Market Microstructure for Practitioners*, Oxford University Press, 2003.
7. FastAPI Documentation, https://fastapi.tiangolo.com/
