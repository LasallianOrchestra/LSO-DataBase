-- ============================================================================
-- ⚠️ OBSOLETE — DO NOT RUN THIS FILE AGAIN. ⚠️
-- This file was never applied to your database (migration 015 is missing from
-- your migration list). It has been superseded by LSO_FINAL_FIX_EVERYTHING.sql,
-- which performs the identical drop-and-reinstall but also re-asserts every
-- other RPC. Run LSO_FINAL_FIX_EVERYTHING.sql instead.
-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — CONFLICT + REAL-TIME SYNC REPAIR (V2, SUPERSEDED)
-- ----------------------------------------------------------------------------
-- THIS FILE REPLACES / SUPERSEDES LSO_MISSING_V69_RPC_REPAIR.sql.
--
-- ROOT CAUSE OF THE ERRORS YOU ARE STILL SEEING
-- ---------------------------------------------
-- Your Supabase database already contains an OLDER version of
-- lso_update_state_v69 whose 4th argument is INTEGER. (You can see it in the
-- error you pasted: PostgREST generated  "p_expected_version" integer.) That
-- older function raises  LSO_CONFLICT:<column>:<version>  whenever the version
-- the browser sends does not match the version the server has reached.
--
-- activity_log is the shared audit trail: EVERY device adds an entry to it on
-- EVERY save. So its version climbs constantly (you saw 587), and any device
-- whose local version is a moment behind gets its write REJECTED with
-- LSO_CONFLICT:activity_log:587. That rejection:
--
--   * stops the Membership role's changes from ever reaching the server, which
--     is why other roles do not see Membership updates in real time;
--   * fills the Supabase logs with the LSO_CONFLICT error + the long
--     "WITH pgrst_source AS ..." PostgREST query text you pasted.
--
-- The previous repair created a NEW bigint overload, but PostgREST kept calling
-- the OLD integer overload, so nothing changed.
--
-- WHAT THIS QUERY DOES
-- --------------------
-- 1. Drops EVERY overload of lso_update_state_v69 (integer, bigint, any other)
--    so PostgREST has exactly one unambiguous function to call.
-- 2. Recreates lso_update_state_v69 as a LAST-WRITE-WINS writer: it performs
--    the exact same permission / attendance / duty validations as the base
--    lso_update_state, but NEVER rejects a write because of a version number.
--    It only keeps a per-column version counter for diagnostics.
-- 3. Re-asserts lso_get_state_meta_v69 and lso_sync_health_v82 so the browser
--    fast-path and health checks work.
-- 4. Re-asserts the remaining V69 RPCs so this file is a complete standalone
--    repair no matter which pieces are missing.
-- 5. Does NOT delete or alter any member, event, attendance, duty, report,
--    account, or session data. Idempotent — safe to run again.
--
-- RUN IN: Supabase Dashboard > SQL Editor > New query
-- ============================================================================

-- Pre-flight: the LSO base database must be present.
do $lso_preflight$
begin
  if to_regclass('public.system_state') is null
     or to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null
     or to_regprocedure('public.lso_session_account_id(text,boolean)') is null
     or to_regprocedure('public.lso_update_state(text,text,jsonb)') is null
     or to_regprocedure('public.lso_get_state(text)') is null then
    raise exception 'LSO base database is not installed. Run supabase-setup.sql (or LSO_MASTER_MIGRATION_INSTALLER.sql) first, then run this repair.';
  end if;
end;
$lso_preflight$;

begin;

-- ----------------------------------------------------------------------------
-- 1. REMOVE EVERY EXISTING lso_update_state_v69 OVERLOAD
--    This kills the old conflict-raising function and any duplicate signatures
--    so PostgREST can no longer pick the wrong one.
-- ----------------------------------------------------------------------------
do $lso_drop_v69$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'lso_update_state_v69'
  loop
    execute 'drop function public.' || r.sig || ' cascade';
  end loop;
end;
$lso_drop_v69$;

-- ----------------------------------------------------------------------------
-- 2. PER-COLUMN VERSION STORAGE (kept only for bookkeeping/diagnostics)
-- ----------------------------------------------------------------------------
alter table public.system_state
  add column if not exists column_versions jsonb not null default '{}'::jsonb;

-- ----------------------------------------------------------------------------
-- 3. lso_update_state_v69 — SINGLE CANONICAL, CONFLICT-FREE WRITER
--    Last-write-wins, identical to the pre-V69 behavior that worked. It never
--    raises LSO_CONFLICT, so cross-device / cross-role edits always land and
--    propagate on the browser's next poll.
-- ----------------------------------------------------------------------------
create or replace function public.lso_update_state_v69(
  p_token text,
  p_column text,
  p_value jsonb,
  p_expected_version integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_result jsonb;
  v_versions jsonb;
  v_next bigint;
begin
  perform public.lso_session_account_id(p_token, false);

  if p_column not in ('members','events','attendance','duty_hours','monthly_reports',
                      'instruments','settings','activity_log') then
    raise exception 'Unknown shared-state column.' using errcode = '22023';
  end if;

  -- The 4th argument (p_expected_version) is intentionally accepted but ignored.
  -- Version checks were rejecting the shared audit log (activity_log) on almost
  -- every save and breaking real-time sync between roles. The base writer
  -- lso_update_state already performs all real permission/attendance/duty checks.
  v_result := public.lso_update_state(p_token, p_column, p_value);

  -- Bookkeeping only: advance the column version so the client's optional
  -- conflict UI has accurate numbers. It is never used to reject a write.
  select coalesce((coalesce(column_versions, '{}'::jsonb) ->> p_column)::bigint, 0) + 1
    into v_next
    from public.system_state
   where id = 1;

  update public.system_state
     set column_versions = jsonb_set(
           coalesce(column_versions, '{}'::jsonb),
           array[p_column],
           to_jsonb(v_next),
           true
         )
   where id = 1
   returning column_versions into v_versions;

  return v_result || jsonb_build_object('column_versions', coalesce(v_versions, '{}'::jsonb));
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 4. lso_get_state_meta_v69 — lightweight heartbeat for fast polls
-- ----------------------------------------------------------------------------
create or replace function public.lso_get_state_meta_v69(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_versions jsonb;
  v_updated timestamptz;
begin
  perform public.lso_session_account_id(p_token, false);

  select column_versions, updated_at
    into v_versions, v_updated
    from public.system_state
   where id = 1;

  return jsonb_build_object(
    'ok', true,
    'columnVersions', coalesce(v_versions, '{}'::jsonb),
    'updatedAt', v_updated,
    'serverTime', now()
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 5. lso_sync_health_v82 — session-aware health check
-- ----------------------------------------------------------------------------
create or replace function public.lso_sync_health_v82(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_account_id uuid;
  v_role text;
  v_state_updated timestamptz;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select role into v_role from public.lso_accounts where id = v_account_id;
  select updated_at into v_state_updated from public.system_state where id = 1;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'serverTime', now(),
    'stateUpdatedAt', v_state_updated,
    'schemaVersion', 13,
    'permissionModel', 'v82'
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 6. lso_v69_capabilities — feature probe for the database-optimization panel
-- ----------------------------------------------------------------------------
create or replace function public.lso_v69_capabilities(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_version integer := 0;
begin
  perform public.lso_session_account_id(p_token, false);

  if to_regclass('public.lso_schema_migrations') is not null then
    select coalesce(max(version_number), 0) into v_version
      from public.lso_schema_migrations;
  end if;

  return jsonb_build_object(
    'installed', true,
    'conflictProtection', false,
    'serverPagination', true,
    'notificationPreferences', true,
    'schemaVersion', v_version,
    'serverTime', now()
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 7. lso_get_collection_page_v69 — server-side paging + text filter
-- ----------------------------------------------------------------------------
create or replace function public.lso_get_collection_page_v69(
  p_token text,
  p_collection text,
  p_offset integer default 0,
  p_limit integer default 25,
  p_search text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_account_id uuid;
  v_role text;
  v_member_id text;
  v_source jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_limit integer := greatest(1, least(100, coalesce(p_limit, 25)));
  v_search text := lower(btrim(coalesce(p_search, '')));
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select role, member_id into v_role, v_member_id
    from public.lso_accounts
   where id = v_account_id;

  select case p_collection
    when 'members'      then coalesce(state.members, '[]'::jsonb)
    when 'events'       then coalesce(state.events, '[]'::jsonb)
    when 'attendance'   then coalesce(state.attendance, '[]'::jsonb)
    when 'instruments'  then coalesce(state.instruments, '[]'::jsonb)
    when 'activity_log' then coalesce(state.activity_log, '[]'::jsonb)
    when 'duty_entries' then coalesce(state.duty_hours -> 'entries', '[]'::jsonb)
    else null
  end
    into v_source
    from public.system_state as state
   where state.id = 1;

  if v_source is null then
    raise exception 'Unknown or unsupported collection.' using errcode = '22023';
  end if;
  if jsonb_typeof(v_source) <> 'array' then
    v_source := '[]'::jsonb;
  end if;

  -- Trainee/Probationary accounts may page only their own duty entries.
  if v_role = 'Trainee/Probationary'
     and p_collection = 'duty_entries'
     and nullif(btrim(coalesce(v_member_id, '')), '') is not null then
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_source
      from jsonb_array_elements(v_source) with ordinality as t(item, idx)
     where item ->> 'memberId' = v_member_id;
  end if;

  if v_search <> '' then
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_source
      from jsonb_array_elements(v_source) with ordinality as t(item, idx)
     where position(v_search in lower(coalesce(item::text, ''))) > 0;
  end if;

  v_total := jsonb_array_length(v_source);

  select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(v_source) with ordinality as t(item, idx)
   where idx > v_offset
   order by idx
   limit v_limit;

  return jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'offset', v_offset,
    'limit', v_limit
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 8. NOTIFICATION PREFERENCES (kept out of the protected System Settings)
-- ----------------------------------------------------------------------------
create table if not exists public.lso_v69_notification_preferences (
  scope text not null check (scope in ('account', 'role')),
  pref_key text not null,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (scope, pref_key)
);

alter table public.lso_v69_notification_preferences enable row level security;
revoke all on table public.lso_v69_notification_preferences from anon, authenticated;

create or replace function public.lso_get_notification_preferences_v69(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_account_prefs jsonb := '{}'::jsonb;
  v_role_prefs jsonb := '{}'::jsonb;
  v_role_defaults jsonb := '{}'::jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;
  if not found then
    raise exception 'Account not found.' using errcode = '42501';
  end if;

  select preferences into v_account_prefs
    from public.lso_v69_notification_preferences
   where scope = 'account' and pref_key = v_account.username;

  select preferences into v_role_prefs
    from public.lso_v69_notification_preferences
   where scope = 'role' and pref_key = v_account.role;

  select coalesce(jsonb_object_agg(pref_key, preferences), '{}'::jsonb)
    into v_role_defaults
    from public.lso_v69_notification_preferences
   where scope = 'role';

  return jsonb_build_object(
    'ok', true,
    'accountPreferences', coalesce(v_account_prefs, '{}'::jsonb),
    'rolePreferences', coalesce(v_role_prefs, '{}'::jsonb),
    'roleDefaults', v_role_defaults,
    'serverTime', now()
  );
end;
$lso$;

create or replace function public.lso_save_notification_preferences_v69(
  p_token text,
  p_preferences jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_account_id uuid;
  v_username text;
  v_prefs jsonb := coalesce(p_preferences, '{}'::jsonb);
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select username into v_username from public.lso_accounts where id = v_account_id;

  insert into public.lso_v69_notification_preferences (scope, pref_key, preferences, updated_at)
  values ('account', v_username, v_prefs, now())
  on conflict (scope, pref_key) do update
    set preferences = excluded.preferences,
        updated_at = now();

  return jsonb_build_object('ok', true, 'accountPreferences', v_prefs);
end;
$lso$;

create or replace function public.lso_save_role_notification_preferences_v69(
  p_token text,
  p_role text,
  p_preferences jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_admin public.lso_accounts%rowtype;
  v_role text := btrim(coalesce(p_role, ''));
  v_prefs jsonb := coalesce(p_preferences, '{}'::jsonb);
begin
  v_admin := public.lso_admin_account(p_token);

  if v_role not in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary') then
    raise exception 'Unknown account role.' using errcode = '22023';
  end if;

  insert into public.lso_v69_notification_preferences (scope, pref_key, preferences, updated_at)
  values ('role', v_role, v_prefs, now())
  on conflict (scope, pref_key) do update
    set preferences = excluded.preferences,
        updated_at = now();

  return jsonb_build_object('ok', true, 'rolePreferences', v_prefs);
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 9. SECURITY: RPC-only access, no direct table access
-- ----------------------------------------------------------------------------
revoke all on function public.lso_get_state_meta_v69(text) from public, anon, authenticated;
revoke all on function public.lso_update_state_v69(text, text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.lso_v69_capabilities(text) from public, anon, authenticated;
revoke all on function public.lso_get_collection_page_v69(text, text, integer, integer, text) from public, anon, authenticated;
revoke all on function public.lso_get_notification_preferences_v69(text) from public, anon, authenticated;
revoke all on function public.lso_save_notification_preferences_v69(text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_sync_health_v82(text) from public, anon, authenticated;

grant execute on function public.lso_get_state_meta_v69(text) to anon, authenticated;
grant execute on function public.lso_update_state_v69(text, text, jsonb, integer) to anon, authenticated;
grant execute on function public.lso_v69_capabilities(text) to anon, authenticated;
grant execute on function public.lso_get_collection_page_v69(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.lso_get_notification_preferences_v69(text) to anon, authenticated;
grant execute on function public.lso_save_notification_preferences_v69(text, jsonb) to anon, authenticated;
grant execute on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_sync_health_v82(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 10. MIGRATION MARKER (guarded for older databases without the table)
-- ----------------------------------------------------------------------------
do $lso_marker$
begin
  if to_regclass('public.lso_schema_migrations') is not null then
    insert into public.lso_schema_migrations (migration_key, version_number, title, checksum, notes)
    values (
      '015_conflict_free_v69_writer',
      15,
      'Conflict-free V69 writer and real-time sync repair',
      'conflict-free-v69-015',
      'Drops all lso_update_state_v69 overloads and installs a single last-write-wins writer that never raises LSO_CONFLICT, restoring cross-role real-time synchronization and clearing the PostgREST error flood.'
    )
    on conflict (migration_key) do update
      set version_number = excluded.version_number,
          title = excluded.title,
          checksum = excluded.checksum,
          notes = excluded.notes;
  end if;
end;
$lso_marker$;

commit;

notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- 11. VERIFICATION (read-only). Expected result: every value true.
-- ----------------------------------------------------------------------------
select jsonb_build_object(
  'singleV69Writer',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'lso_update_state_v69') = 1,
  'integerSignature',
    exists (select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'lso_update_state_v69'
        and pg_get_function_arguments(p.oid) like '%p_expected_version integer%'),
  'conflictCheckRemoved',
    position('LSO_CONFLICT' in pg_get_functiondef('public.lso_update_state_v69(text,text,jsonb,integer)'::regprocedure)) = 0,
  'metaRpc',
    to_regprocedure('public.lso_get_state_meta_v69(text)') is not null,
  'healthRpc',
    to_regprocedure('public.lso_sync_health_v82(text)') is not null,
  'collectionPageRpc',
    to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is not null,
  'capabilitiesRpc',
    to_regprocedure('public.lso_v69_capabilities(text)') is not null,
  'notificationRpc',
    to_regprocedure('public.lso_get_notification_preferences_v69(text)') is not null
    and to_regprocedure('public.lso_save_notification_preferences_v69(text,jsonb)') is not null
    and to_regprocedure('public.lso_save_role_notification_preferences_v69(text,text,jsonb)') is not null,
  'columnVersionsColumn',
    exists (select 1 from information_schema.columns
             where table_schema = 'public'
               and table_name = 'system_state'
               and column_name = 'column_versions')
) as lso_v69_conflict_fix_verification;
