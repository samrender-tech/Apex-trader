#!/usr/bin/env python3
"""
Generate the ER diagram from the LIVE database catalog.

Hand-drawn ER diagrams drift from the schema the moment someone adds a
column. This reads pg_catalog, so the diagram in docs/ is always what the
database actually contains.

    python scripts/gen_erd.py > docs/er-diagram.mmd
"""
import asyncio, os, sys
import asyncpg

DSN = os.environ.get("APEX_ADMIN_DSN",
                     "postgresql://apex:apex_dev_pw@127.0.0.1:5432/apex_trader")

SCHEMAS = ['identity', 'reference', 'market', 'trading', 'ledger',
           'risk', 'surveil', 'social', 'analytics', 'audit', 'ops']

# Keep the diagram readable: these are the columns that carry meaning.
SKIP_COLS = {'created_at', 'updated_at', 'taken_at', 'refreshed_at'}


async def main():
    conn = await asyncpg.connect(DSN)

    tables = await conn.fetch("""
        SELECT n.nspname AS schema, c.relname AS table
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r','p')
           AND NOT c.relispartition
           AND n.nspname = ANY($1)
         ORDER BY n.nspname, c.relname;""", SCHEMAS)

    cols = await conn.fetch("""
        SELECT n.nspname AS schema, c.relname AS table, a.attname AS column,
               format_type(a.atttypid, a.atttypmod) AS type,
               a.attnotnull AS notnull,
               COALESCE(ix.is_pk, false) AS is_pk,
               COALESCE(fk.is_fk, false) AS is_fk
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN LATERAL (
              SELECT true AS is_pk FROM pg_index i
               WHERE i.indrelid = c.oid AND i.indisprimary
                 AND a.attnum = ANY(i.indkey) LIMIT 1) ix ON true
          LEFT JOIN LATERAL (
              SELECT true AS is_fk FROM pg_constraint k
               WHERE k.conrelid = c.oid AND k.contype = 'f'
                 AND a.attnum = ANY(k.conkey) LIMIT 1) fk ON true
         WHERE a.attnum > 0 AND NOT a.attisdropped
           AND c.relkind IN ('r','p') AND NOT c.relispartition
           AND n.nspname = ANY($1)
         ORDER BY n.nspname, c.relname, a.attnum;""", SCHEMAS)

    fks = await conn.fetch("""
        SELECT sn.nspname AS src_schema, sc.relname AS src_table,
               tn.nspname AS tgt_schema, tc.relname AS tgt_table,
               k.conname AS name,
               -- A NOT NULL FK column means the child REQUIRES a parent.
               (SELECT bool_and(a.attnotnull) FROM pg_attribute a
                 WHERE a.attrelid = sc.oid AND a.attnum = ANY(k.conkey)) AS required
          FROM pg_constraint k
          JOIN pg_class sc ON sc.oid = k.conrelid
          JOIN pg_namespace sn ON sn.oid = sc.relnamespace
          JOIN pg_class tc ON tc.oid = k.confrelid
          JOIN pg_namespace tn ON tn.oid = tc.relnamespace
         WHERE k.contype = 'f'
           AND sn.nspname = ANY($1) AND tn.nspname = ANY($1)
           AND NOT sc.relispartition
         ORDER BY 1,2;""", SCHEMAS)

    await conn.close()

    def ent(schema, table):
        return f"{schema}__{table}"

    def mermaid_type(t):
        t = t.split('(')[0].strip()
        return (t.replace(' ', '_').replace('"', '')
                 .replace('[]', '_arr').replace('.', '_'))

    out = ["erDiagram"]
    by_table = {}
    for c in cols:
        by_table.setdefault((c['schema'], c['table']), []).append(c)

    for t in tables:
        key = (t['schema'], t['table'])
        out.append(f"    {ent(*key)} {{")
        for c in by_table.get(key, []):
            if c['column'] in SKIP_COLS and not c['is_pk']:
                continue
            marks = []
            if c['is_pk']: marks.append("PK")
            if c['is_fk']: marks.append("FK")
            suffix = f' "{",".join(marks)}"' if marks else ""
            out.append(f"        {mermaid_type(c['type'])} {c['column']}{suffix}")
        out.append("    }")

    seen = set()
    for f in fks:
        a = ent(f['src_schema'], f['src_table'])
        b = ent(f['tgt_schema'], f['tgt_table'])
        if (a, b) in seen:
            continue
        seen.add((a, b))
        # one-to-many; the child side is optional unless the FK is NOT NULL
        card = "||--o{" if f['required'] else "|o--o{"
        out.append(f"    {b} {card} {a} : \"\"")

    print("\n".join(out))
    print(f"\n%% {len(tables)} tables, {len(seen)} relationships, "
          f"generated from pg_catalog", file=sys.stderr)


asyncio.run(main())
