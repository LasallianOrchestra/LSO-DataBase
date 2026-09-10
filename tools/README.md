# LSO database tooling

Offline helpers for applying the LSO Supabase installers through the dashboard, and for
proving afterwards that they actually applied.

Nothing here connects to a database, sends a query, or mutates anything. The splitter reads
a `.sql` file from this repository and writes text files; the two audit queries are things
**you** run in the Supabase dashboard.

## Why these exist

Two failure modes in this project look identical from the dashboard but have opposite fixes:

1. **`LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql` "is rejected by the SQL editor".**
   The patch is not being rejected for syntax. It opens with a `$v82_preflight$` block
   (lines 24–39) that `raise exception`s unless six tables and two function signatures
   already exist, and the whole patch is wrapped in `begin;` … `commit;` — so the abort also
   rolls back everything, leaving the editor looking as if nothing happened.

   Those prerequisites (`public.lso_accounts`, `lso_sessions`, `lso_role_permissions`,
   `lso_role_profiles`, `system_state`, `lso_schema_migrations`, plus
   `lso_session_account_id(text,boolean)` and `lso_admin_account(text)`) are created by
   **`supabase-setup.sql`** — which also defines `lso_login`, `lso_get_state`,
   `lso_update_state`, `lso_replace_state`, `lso_list_accounts` and `lso_resume_session`.
   That single missing base install is simultaneously why the patch aborts **and** why the
   site renders with no data: `cloud-staff-v8.js` treats an unreachable shared-state RPC as
   "offline" rather than raising a page-level error, so no error screen ever appears.

   **The V82 patch is a later step, never the first one.**

2. **"Run submitted" with no result, so there is no way to tell whether it worked.**
   Both installers end with a bare `select jsonb_build_object(...) as …;`. One jsonb cell in
   the dashboard's result panel reads as "no data", especially after an abort where the
   `select` never ran. The two queries here return **one row of plain text** instead, and
   that row states a verdict.

## Run this order

```
0. node tools/split-sql-chunks.mjs supabase-setup.sql
   node tools/split-sql-chunks.mjs LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql

1. tools/check-v82-prerequisites.sql        (read-only audit — run this FIRST, in the dashboard)
2. tools/sql-chunks/supabase-setup/         chunks 001 → 00N, one at a time, in order
3. tools/sql-chunks/LSO_V82_ROLE_SYNC_SUPABASE_PATCH/   single chunk
4. tools/verify-v82-migration.sql           must end with "FULLY APPLIED AND REACHABLE"
```

Step 1 decides everything. If it reports missing base tables, do not touch the patch again —
run the base installer. If it says all prerequisites are present, the patch's pre-flight is
not your blocker and the red error text names the real cause.

If intermediate patches are also unapplied, the master installer
(`LSO_MASTER_MIGRATION_INSTALLER.sql`, same splitter usage) goes between steps 2 and 3.

## Files

| File | What it does |
| --- | --- |
| `split-sql-chunks.mjs` | Cuts an installer into paste-ready chunks on top-level statement boundaries only, keeping every `begin;`/`commit;` section whole. Asserts byte-exact rejoin before writing. |
| `check-v82-prerequisites.sql` | Read-only, catalog-only. One row of text: which pre-flight tables/functions/shared-state RPCs exist, RLS state, and whether role `anon` can execute them. Runs on an empty database. |
| `verify-v82-migration.sql` | Read-only. One row of text: marker row `013_role_sync_interview_v82` present, the seven V82 functions created, `anon`-executable, and their bodies carrying the V82 logic. |
| `sql-chunks/<installer>/index.md` | Generated run order per installer, with sizes. Regenerate rather than hand-edit; chunks are derived files. |

## Splitter guarantees

A chunk boundary is legal only when all of these hold, and the tool aborts instead of
writing if any fail:

- the cut is at a top-level `;` — determined by a lexer that treats `$$`/`$tag$` bodies,
  `'…'` literals (with `''` escapes), `--` comments and nestable `/* */` comments as opaque,
  and parenthesized lists as one statement;
- top-level transaction depth is `0` at the cut, so no section is split mid-transaction;
- no chunk starts with a stray `commit;`/`rollback;`;
- the files, read back from disk and concatenated, reproduce the source byte-for-byte
  (the check runs on what is actually written, not on the in-memory buffer).

Sections larger than `--max-bytes` (default 90 000) are kept whole and reported with a
`NOTE:` rather than cut — a 117 KB transaction in `supabase-setup.sql` is the current
largest. The dashboard accepts that size; if yours does not, there is no safe smaller cut for
that section, so run it as its own query.

## Notes

- Both audit queries reference `public.lso_role_permissions` / `lso_schema_migrations`
  directly and therefore *error* if the base schema is absent. That error is itself the
  answer (base not installed), which is why step 1 is catalog-only by design.
- `check-v82-prerequisites.sql` lists eight RPCs the current build calls that no installer in
  this repository defines (`lso_get_collection_page_v69`, `lso_update_state_v69`,
  `lso_get_state_meta_v69`, `lso_v69_capabilities`, the three notification-preference
  functions, `lso_bootstrap_default_admin`). All are optional: each is wrapped in
  `try/catch` with a documented fallback in `cloud-staff-v8.js`, or is only called by the
  legacy `cloud-staff-v2/v3.js` connectors. They are **not** a cause of "no data" and must
  not be invented into a patch.
- Row counts come from `pg_stat_user_tables.n_live_tup`, so they are estimates and lag until
  autovacuum/analyze.
