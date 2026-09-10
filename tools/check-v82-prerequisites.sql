-- =============================================================================
-- LSO BASE-SCHEMA AUDIT  (read-only, catalog-only, always returns one row)
-- =============================================================================
-- WHY THIS EXISTS
--   LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql opens with a $v82_preflight$ block
--   that RAISEs an exception unless six tables and two session/auth functions
--   already exist, and it is wrapped in begin;/commit; -- so the abort also
--   rolls the whole paste back. In the Supabase dashboard that looks exactly
--   like "the editor rejected the patch", and the message that names the real
--   cause scrolls away. This audit answers the only question that matters
--   before re-running the patch: is the base LSO schema installed, and is it
--   complete enough for the website to load data?
--
-- WHY IT CANNOT FAIL ON AN EMPTY DATABASE
--   * It references no LSO table by name. Every fact comes from the
--     PostgreSQL catalogs, so it parses and plans even on a project where
--     nothing has been installed yet.
--   * It SELECTs exactly one row of plain text -- never zero rows -- so there
--     is no "no data" to interpret and no result grid dependency.
--   * It creates nothing and changes nothing.
--
-- RUN IN:  Supabase Dashboard > SQL Editor > New query
-- EXPECT:  one row, column "lso_base_audit", ending in a VERDICT.
-- =============================================================================

with
-- Objects demanded by to_regclass() inside the patch's $v82_preflight$.
required_tables(name) as (
  values
    ('public.lso_accounts'),
    ('public.lso_sessions'),
    ('public.lso_role_permissions'),
    ('public.lso_role_profiles'),
    ('public.system_state'),
    ('public.lso_schema_migrations')
),
-- Objects demanded by to_regprocedure() inside the same pre-flight. Signatures
-- are exact: an overload with different argument types does not satisfy it.
required_signatures(name, sig) as (
  values
    ('lso_session_account_id', 'public.lso_session_account_id(text,boolean)'),
    ('lso_admin_account',      'public.lso_admin_account(text)')
),
-- RPCs the website must reach just to sign in, load, or save shared state.
-- Every one is created by supabase-setup.sql only, so these are the first
-- casualties of a missing base install -- and the direct cause of "the app
-- renders but no data loads".
required_rpc(name) as (
  values
    ('lso_login'),
    ('lso_logout'),
    ('lso_resume_session'),
    ('lso_ping'),
    ('lso_get_state'),
    ('lso_update_state'),
    ('lso_replace_state'),
    ('lso_list_accounts'),
    ('lso_register_account'),
    ('lso_delete_account'),
    ('lso_save_accounts'),
    ('lso_get_permission_center'),
    ('lso_save_role_permissions'),
    ('lso_sync_health_v82')
),
tbl as (
  select
    t.name,
    c.oid is not null                                              as present,
    coalesce(s.n_live_tup, 0)                                      as est_rows,
    case
      when c.oid is null                              then 'ABSENT'
      when c.relrowsecurity and c.relforcerowsecurity  then 'RLS enforced'
      when c.relrowsecurity                              then 'RLS on, not forced'
      else 'RLS OFF'
    end                                                            as rls
  from required_tables t
  left join pg_class c on c.oid = to_regclass(t.name) and c.relkind in ('r', 'p')
  left join pg_stat_user_tables s
    on s.schemaname = 'public' and s.relname = replace(t.name, 'public.', '')
),
sig as (
  select
    q.sig,
    to_regprocedure(q.sig) is not null                             as present,
    coalesce(
      (select string_agg(pg_get_function_arguments(p.oid), '  or  ')
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
        where p.proname = q.name),
      'no function with this name'
    )                                                              as found_overloads
  from required_signatures q
),
-- anon is the role the browser key actually connects as, so a function that
-- exists but is not executable by anon is just as invisible to the website.
anon as (
  select
    p.proname                                   as name,
    bool_or(has_function_privilege('anon', p.oid, 'execute')) as any_executable,
    count(*)                                     as overloads
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where exists (select 1 from pg_roles where rolname = 'anon')
  group by p.proname
),
rpc as (
  select
    r.name,
    x.oid is not null                              as present,
    coalesce(x.overloads, 0)                       as overloads,
    case
      when x.oid is null                          then 'no function'
      when a.name is null                          then 'NOT executable by anon'
      when a.any_executable                        then 'anon can execute'
      else 'NOT executable by anon'
    end                                            as access
  from required_rpc r
  left join lateral (
    select min(p.oid) as oid, count(*) as overloads
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
     where p.proname = r.name
  ) x on true
  left join anon a on a.name = r.name
)
select concat_ws(
  chr(10),
  'LSO BASE-SCHEMA AUDIT',
  '  database : ' || current_database() || '    postgres : ' || split_part(version(), ' ', 2),
  '  note     : catalog-only reads; nothing created or changed',
  '',
  '1. TABLES THE V82 PRE-FLIGHT REQUIRES',
  (
    select coalesce(string_agg(
             '     ' || case when present then '[present]' else '[ ABSENT ]' end
               || '  ' || rpad(name, 31, ' ')
               || 'rows~' || lpad(est_rows::text, 7, ' ')
               || '  ' || rls,
             chr(10) order by name), '     none')
    from tbl
  ),
  '',
  '2. SESSION/AUTH FUNCTIONS THE V82 PRE-FLIGHT REQUIRES (exact signatures)',
  (
    select coalesce(string_agg(
             '     ' || case when present then '[present]' else '[ ABSENT ]' end
               || '  ' || rpad(sig, 47, ' ')
               || chr(10) || '                found: ' || found_overloads,
             chr(10) order by sig), '     none')
    from sig
  ),
  '',
  '3. RPCs THE WEBSITE NEEDS IN ORDER TO LOAD OR SAVE DATA',
  '     created only by supabase-setup.sql; the browser runs as role anon',
  (
    select coalesce(string_agg(
             '     ' || case when present then '[present]' else '[ ABSENT ]' end
               || '  ' || rpad(name, 32, ' ')
               || rpad(access, 24, ' ')
               || 'overloads: ' || overloads::text,
             chr(10) order by name), '     none')
    from rpc
  ),
  '',
  '4. VERDICT',
  case
    when (select count(*) from tbl where not present) > 0 then
         '     ' || (select count(*) from tbl where not present)::text
      || ' of the 6 pre-flight tables are ABSENT, so the base LSO database is not'
      || chr(10) ||
      '     installed (or is only partly installed). Re-running the V82 patch will'
      || chr(10) ||
      '     abort at its pre-flight again -- that is what "the editor rejected it"'
      || chr(10) ||
      '     means here. Install supabase-setup.sql first; if the editor will not'
      || chr(10) ||
      '     accept all 5,693 lines, use: node tools/split-sql-chunks.mjs supabase-setup.sql'
    when (select count(*) from sig where not present) > 0 then
         '     All six tables exist but a pre-flight function signature does NOT,'
      || chr(10) ||
      '     i.e. the base installer is half-applied. Re-run supabase-setup.sql'
      || chr(10) ||
      '     (idempotent, create or replace + if not exists) before the V82 patch.'
    when (select count(*) from rpc where not present) > 0 then
         '     Base tables and session functions look right, but '
      || (select count(*) from rpc where not present)::text
      || ' shared-data RPC(s) are missing (section 3). That alone is enough for'
      || chr(10) ||
      '     "app renders, no data loads": the connector catches the lookup failure'
      || chr(10) ||
      '     and marks the session offline, so no error page appears.'
    when (select count(*) from rpc where present and access <> 'anon can execute') > 0 then
         '     Functions exist but are not executable by role anon'
      || chr(10) ||
      '     (see the "NOT executable" lines). The browser key can never reach them,'
      || chr(10) ||
      '     so the symptoms match a missing install even though it is a grant gap.'
    else '     Every pre-flight prerequisite is present and anon-reachable. The V82'
      || chr(10) ||
      '     patch should run. If it still failed, the cause is NOT this pre-flight:'
      || chr(10) ||
      '     copy the exact red error text from the editor -- it names the real one.'
  end
) as lso_base_audit;
