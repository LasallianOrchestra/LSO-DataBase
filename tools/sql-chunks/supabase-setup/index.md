# supabase-setup — paste-ready chunks

Source: `supabase-setup.sql` — 231,674 bytes, 259 top-level statements, 2 chunks.

Guarantees checked by the splitter before these files were written:

- every boundary sits on a top-level statement end (quotes, `$$` bodies and comments are opaque);
- no chunk splits a `begin;`/`commit;` pair, so each chunk is a complete script;
- concatenating the chunks reproduces the source byte-for-byte.

## Run order

1. `001-of-002-supabase-setup.sql` — 113,825 bytes, ~3162 lines, 5 transaction block(s)
2. `002-of-002-supabase-setup.sql` — 117,849 bytes, ~2533 lines, 4 transaction block(s)

## In the dashboard

1. Supabase → project → **SQL Editor** → New query. Paste chunk 001, press Run, wait for success.
2. Repeat per chunk in order. A chunk that succeeds is durable; you never re-run earlier ones.
3. If a chunk fails, **stop and read the red error text** — later chunks assume it applied.
4. Close with the verification query (`tools/check-v82-prerequisites.sql` for the base schema,
   `tools/verify-v82-migration.sql` after the V82 patch) so the result proves the schema state
   instead of relying on an empty-looking "Run submitted".
