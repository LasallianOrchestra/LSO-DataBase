-- ============================================================================
-- ⚠️ OBSOLETE — DO NOT RUN THIS FILE AGAIN. ⚠️
-- This repair added a SECOND lso_update_state_v69 overload (bigint) that still
-- contains a conflict check. It was superseded by LSO_FINAL_FIX_EVERYTHING.sql,
-- which drops every overload and installs one conflict-free last-write-wins
-- writer. Run LSO_FINAL_FIX_EVERYTHING.sql instead.
-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — SUPABASE ERROR-FLOOD REPAIR (SUPERSEDED)
-- ----------------------------------------------------------------------------
-- WHY THE SUPABASE LOGS ARE FULL OF ERRORS
--
-- The deployed website (cloud-staff-v8.js and older cached cloud clients) calls
-- the following database functions on a regular basis:
--
--   1. lso_update_state_v69            (called on EVERY save)
--   2. lso_get_state_meta_v69          (called on every load and every poll)
--   3. lso_get_collection_page_v69     (server-side paging for large lists)
--   4. lso_v69_capabilities            (feature/version probe)
--   5. lso_get_notification_preferences_v69
--   6. lso_save_notification_preferences_v69
--   7. lso_save_role_notification_preferences_v69
--   8. lso_sync_health_v82             (only exists in the separate V82 patch;
--                                       missing if that patch was never run)
--
-- None of the "…_v69" functions were ever shipped in ANY SQL file in this
-- package. When the browser calls a function that does not exist, PostgREST
-- answers with error PGRST202:
--
--   "Could not find the function public.lso_update_state_v69(...) in the schema cache"
--
-- and Supabase logs that error every single time. The website still works only
-- because the client silently falls back to the older functions, but the
-- Supabase API/Postgres logs keep filling up with these missing-function errors.
--
-- THIS QUERY
--   * Creates the missing V69 functions so those calls succeed and stop logging
--     PGRST202 errors.
--   * Adds an optimistic-concurrency "column version" layer the V69 client was
--     already expecting (it is optional and backwards-compatible).
--   * Re-asserts lso_sync_health_v82 so health checks stop 404ing when the V82
--     patch was not applied.
--   * Is idempotent: safe to run again. It does NOT delete or alter any
--     existing member, event, attendance, duty, report, account, or session data.
--
-- RUN IN: Supabase Dashboard > SQL Editor > New query
-- ============================================================================

-- Pre-flight: the existing LSO base database must be present.
do $lso_v69_preflight$
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
$lso_v69_preflight$;

begin;

-- ----------------------------------------------------------------------------
-- 1. STORAGE FOR COLUMN VERSIONS (optimistic concurrency)
-- ----------------------------------------------------------------------------
alter table public.system_state
  add column if not exists column_versions jsonb not null default '{}'::jsonb;

-- ----------------------------------------------------------------------------
-- 2. lso_get_state_meta_v69  — lightweight state/version heartbeat
--    Used on every load and poll. Returns column versions + last update time.
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
-- 3. lso_update_state_v69 — version-aware save
--    Reuses ALL of the existing role/attendance/duty write guards inside
--    lso_update_state, then bumps the column version. Raises LSO_CONFLICT only
--    when the client actually tracks a version and it is stale (never when the
--    version is unknown/0), so current users are not interrupted.
-- ----------------------------------------------------------------------------
create or replace function public.lso_update_state_v69(
  p_token text,
  p_column text,
  p_value jsonb,
  p_expected_version bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_current bigint;
  v_result jsonb;
  v_versions jsonb;
begin
  perform public.lso_session_account_id(p_token, false);

  if p_column not in ('members','events','attendance','duty_hours','monthly_reports',
                      'instruments','settings','activity_log') then
    raise exception 'Unknown shared-state column.' using errcode = '22023';
  end if;

  select coalesce((column_versions ->> p_column)::bigint, 0)
    into v_current
    from public.system_state
   where id = 1
   for update;

  if coalesce(p_expected_version, 0) > 0
     and v_current > 0
     and p_expected_version <> v_current then
    raise exception 'LSO_CONFLICT: The shared % data changed on the server since this edit. Refresh and retry.', p_column
      using errcode = 'P0001';
  end if;

  -- All existing permission/attendance/duty validations run here.
  v_result := public.lso_update_state(p_token, p_column, p_value);

  update public.system_state
     set column_versions = jsonb_set(
           coalesce(column_versions, '{}'::jsonb),
           array[p_column],
           to_jsonb((coalesce((coalesce(column_versions, '{}'::jsonb) ->> p_column)::bigint, 0) + 1)),
           true
         )
   where id = 1
   returning column_versions into v_versions;

  return v_result || jsonb_build_object('column_versions', coalesce(v_versions, '{}'::jsonb));
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 4. lso_v69_capabilities — feature probe for the V69 database-optimization panel
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
    'conflictProtection', true,
    'serverPagination', true,
    'notificationPreferences', true,
    'schemaVersion', v_version,
    'serverTime', now()
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 5. lso_get_collection_page_v69 — server-side paging + text filter for lists
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

  -- Case-insensitive text filter (matches the browser fallback behavior).
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
-- 6. NOTIFICATION PREFERENCES (account + per-role defaults)
--    Kept in a dedicated table so it never touches the protected
--    "Only the Administrator can change system settings" column.
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
-- 7. lso_sync_health_v82 — re-assert the session-aware health RPC (idempotent)
--    Already shipped in LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql; included here so
--    databases that never ran that patch stop 404ing on every health check.
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
-- 8. SECURITY: RPC-only access, no direct table access
-- ----------------------------------------------------------------------------
revoke all on function public.lso_get_state_meta_v69(text) from public, anon, authenticated;
revoke all on function public.lso_update_state_v69(text, text, jsonb, bigint) from public, anon, authenticated;
revoke all on function public.lso_v69_capabilities(text) from public, anon, authenticated;
revoke all on function public.lso_get_collection_page_v69(text, text, integer, integer, text) from public, anon, authenticated;
revoke all on function public.lso_get_notification_preferences_v69(text) from public, anon, authenticated;
revoke all on function public.lso_save_notification_preferences_v69(text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_sync_health_v82(text) from public, anon, authenticated;

grant execute on function public.lso_get_state_meta_v69(text) to anon, authenticated;
grant execute on function public.lso_update_state_v69(text, text, jsonb, bigint) to anon, authenticated;
grant execute on function public.lso_v69_capabilities(text) to anon, authenticated;
grant execute on function public.lso_get_collection_page_v69(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.lso_get_notification_preferences_v69(text) to anon, authenticated;
grant execute on function public.lso_save_notification_preferences_v69(text, jsonb) to anon, authenticated;
grant execute on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_sync_health_v82(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 9. MIGRATION MARKER (guarded for older databases without the table)
-- ----------------------------------------------------------------------------
do $lso_marker$
begin
  if to_regclass('public.lso_schema_migrations') is not null then
    insert into public.lso_schema_migrations (migration_key, version_number, title, checksum, notes)
    values (
      '014_missing_v69_rpc_repair',
      14,
      'Repair missing V69 RPC functions',
      'missing-v69-rpc-014',
      'Creates lso_update_state_v69, lso_get_state_meta_v69, lso_v69_capabilities, lso_get_collection_page_v69, notification-preference RPCs, and re-asserts lso_sync_health_v82 so the deployed client stops logging PGRST202 missing-function errors.'
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
-- 10. VERIFICATION (read-only). Expected result:
--     missingRpcFixed = true, columnVersionsColumn = true
-- ----------------------------------------------------------------------------
select jsonb_build_object(
  'missingRpcFixed',
    to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null
    and to_regprocedure('public.lso_get_state_meta_v69(text)') is not null
    and to_regprocedure('public.lso_v69_capabilities(text)') is not null
    and to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is not null
    and to_regprocedure('public.lso_get_notification_preferences_v69(text)') is not null
    and to_regprocedure('public.lso_save_notification_preferences_v69(text,jsonb)') is not null
    and to_regprocedure('public.lso_save_role_notification_preferences_v69(text,text,jsonb)') is not null
    and to_regprocedure('public.lso_sync_health_v82(text)') is not null,
  'columnVersionsColumn',
    exists (select 1 from information_schema.columns
             where table_schema = 'public'
               and table_name = 'system_state'
               and column_name = 'column_versions')
) as lso_v69_repair_verification;
