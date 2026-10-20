# Submission — BCSE302P Database Systems Lab

| File | Contents |
|---|---|
| `Apex_Trader_Project_Report_BCSE302P.docx` | The project report, 68 pages, all 11 required sections |
| `Apex_Trader_Presentation_BCSE302P.pptx` | The final presentation, 46 slides |
| `*.pdf` | PDF renders of both, for printing or if Word reflows anything |

The report text is black, Times New Roman, 1.5 line spacing, with bold headings,
and code in Courier New. Each chapter opens on a new page. There is no table of
contents.

The drawn figures are black ink, redrawn to be legible at the width of an A4 text
column. The application screenshots are real captures of the running application
in its own dark theme, reproduced in full colour. The ER diagram and the six wide
screenshots are on landscape pages.

Faculty: Prof. Nithya N S
Team: 24BCE2863 Kumar Paritosh · 24BCE2865 Samrender Singh Saini · 24BCE2886 Vartika Chaudhary

## Mapping to the guidelines

### Report — the eleven required sections
1. Project title, team, course code, faculty — page 1
2. Introduction: description and purpose — page 5
3. Objectives and problems addressed — page 6
4. Software requirements, and the system architecture — page 7
5. Database design: ER diagram, schema, normalization — page 11
6. Database creation and sample data: CREATE TABLE, constraints, INSERT — page 17
7. Database operations and outputs: SELECT, JOIN, aggregates, subqueries, DML — page 23
8. Advanced features: procedures, triggers, views, transaction control, RLS — page 30
9. Project output screenshots: structure, records, queries, application — page 39
10. Conclusion — page 51
11. References — page 53

### Presentation — 46 slides, in the guideline order
Title · Agenda · Abstract and problem statement · Objectives · Scope and delimitations ·
System architecture · Workflow · Database management system · ER diagram · Relational
schema · Normalization · CREATE TABLE (×3) · Constraint inventory · Sample data ·
SQL queries and outputs (×3) · INSERT/UPDATE/DELETE · The order round trip ·
Settlement · Operations the database refuses · Transaction control (×2) · Procedures
and functions · The matching loop · Triggers · Views · Row Level Security ·
Partitioning and indexing · Surveillance · Market data · Application screenshots (×6) ·
Testing and results (×2) · What was learnt · Conclusion · Future enhancement ·
References · Closing

## Where the numbers come from

Every SQL listing in Section 7 and Section 8 of the report, and every output shown
in the deck, is a captured psql transcript from the seeded demonstration database.
Statements that modify data are wrapped in a transaction and rolled back, so running
them leaves the database as it was found.

## Supporting material in the project itself

- `docs/06-normalization.md` — full 1NF→BCNF analysis with functional dependencies
- `db/demo/10_transactions.sql` — runnable COMMIT / ROLLBACK / SAVEPOINT demonstration
- `docs/assets/` — colour figures and screenshots used in the deck
- `docs/assets/print/` — the monochrome figures used in the report
- `docs/assets/colour/` — the full-colour application screenshots used in the report
- `ops.health_check()` — 18 structural invariants the database checks on itself
- `db/test/` — 150 SQL assertions; `db/test/concurrency.sh` — the 12-session proof
