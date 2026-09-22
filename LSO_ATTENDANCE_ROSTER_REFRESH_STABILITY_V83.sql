-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — LSO V83
-- ATTENDANCE ROSTER REFRESH STABILITY (OPTIONAL SHARED-DATABASE PATCH)
-- Date: 2026-09-16
-- Companion to: ATTENDANCE_INPUT_STABILITY_V83_GUIDE.txt
-- ============================================================================
--
-- IS THIS REQUIRED FOR THE V83 ATTENDANCE FIX?
--   No. The repair for "attendance keeps refreshing and cannot be saved" is
--   entirely client-side (management-attendance-member-info-v4.js V83). Deploy
--   that first — it works with or without this SQL.
--
-- WHAT THIS PATCH DOES
--   Every device polls the shared database (every 9s while active, every 22s
--   when quiet). A poll re-downloads and re-applies the whole shared state when
--   the row's updated_at changed. Because lso_update_state always rewrites the
--   column and always bumps updated_at — even when the payload it receives is
--   byte-for-byte identical to what is already stored — one device's harmless
--   re-save makes EVERY other device re-download, re-apply and re-render. With
--   several officers recording attendance at the same time, that ping-pong is
--   what makes the attendance workspace appear to refresh continuously.
--
--   This patch adds a no-op guard: when the incoming payload is already exactly
--   what is stored, the write (and the updated_at bump, and the column-version
--   bump) is skipped and the current state is returned instead. Nothing about
--   the data changes — only pointless writes disappear.
--
-- SAFETY
--   - The existing functions are RENAMED to *_core, never rewritten, so every
--     installed permission, role, attendance, and duty validation is preserved.
--   - The new wrapper only short-circuits when the payload is identical. Any
--     real change goes straight to the original implementation.
--   - The script is idempotent: run it as many times as you like.
--   - It is a thin wrapper; if you prefer not to use it, see the rollback at
--     the bottom of this file.
--
-- HOW TO RUN
--   Supabase Dashboard -> SQL Editor -> New query -> paste this file -> Run.
--   Maintenance window recommended (two DDL statements, sub-second).
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. PRE-FLIGHT — make sure the expected schema is present
-- ----------------------------------------------------------------------------
do $lso_v83_preflight$
begin
  if to_regclass('public.system_state') is null then
    raise exception 'LSO_V83: public.system_state is missing. Install the base LSO Supabase schema first.';
  end if;
  if to_regprocedure('public.lso_update_state(text,text,jsonb)') is null then
    raise exception 'LSO_V83: public.lso_update_state(text,text,jsonb) is missing. Install the base LSO Supabase schema first.';
  end if;
  if to_regprocedure('public.lso_get_state(text)') is null then
    raise exception 'LSO_V83: public.lso_get_state(text) is missing. Install the base LSO Supabase schema first.';
  end if;
end;
$lso_v83_preflight$;

-- ----------------------------------------------------------------------------
-- 1. Move the current implementations aside (only the first time).
--    All existing grants, ownership and validation logic travel with them.
-- ----------------------------------------------------------------------------
do $lso_v83_rename$
begin
  if to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is null then
    alter function public.lso_update_state(text, text, jsonb) rename to lso_update_state_core;
  end if;

  if to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null
     and to_regprocedure('public.lso_update_state_v69_core(text,text,jsonb,bigint)') is null then
    alter function public.lso_update_state_v69(text, text, jsonb, bigint) rename to lso_update_state_v69_core;
  end if;
end;
$lso_v83_rename$;

-- ----------------------------------------------------------------------------
-- 2. lso_update_state — skip writes that would not change anything.
--    Validation and permissions are untouched: any difference at all is still
--    handed to the original implementation, which performs every check.
-- ----------------------------------------------------------------------------
create or replace function public.lso_update_state(
  p_token text,
  p_column text,
  p_value jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_existing jsonb;
begin
  -- The session is validated here too, so an invalid token is still rejected
  -- instead of silently succeeding on an identical payload.
  perform public.lso_session_account_id(p_token, false);

  -- Read the stored column through the row image so this wrapper never depends
  -- on a hard-coded column list. An unknown column simply yields null, which
  -- skips the guard and lets the original implementation raise its own error.
  select to_jsonb(state_row) -> p_column
    into v_existing
    from public.system_state as state_row
   where id = 1;

  -- No-op guard: identical payload -> no write, no updated_at bump, no
  -- forced re-download for every other signed-in device.
  if v_existing is not null and v_existing = p_value then
    return public.lso_get_state(p_token);
  end if;

  return public.lso_update_state_core(p_token, p_column, p_value);
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 3. lso_update_state_v69 — same guard, plus no wasted version bump.
--    The optimistic-concurrency check still runs first, so a genuine conflict
--    is still reported exactly as before.
-- ----------------------------------------------------------------------------
do $lso_v83_v69$
begin
  if to_regprocedure('public.lso_update_state_v69_core(text,text,jsonb,bigint)') is null then
    return; -- V69 RPC not installed on this database: nothing to wrap.
  end if;

  execute $ddl$
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
  v_existing jsonb;
  v_versions jsonb;
begin
  perform public.lso_session_account_id(p_token, false);

  select to_jsonb(state_row) -> p_column
    into v_existing
    from public.system_state as state_row
   where id = 1;

  if v_existing is not null and v_existing = p_value then
    select coalesce(column_versions, '{}'::jsonb) into v_versions from public.system_state where id = 1;
    return public.lso_get_state(p_token) || jsonb_build_object('column_versions', v_versions, 'noop', true);
  end if;

  return public.lso_update_state_v69_core(p_token, p_column, p_value, p_expected_version);
end;
$lso$;
$ddl$;
end;
$lso_v83_v69$;

-- ----------------------------------------------------------------------------
-- 4. Permissions — the renamed functions keep their grants; the new wrappers
--    need theirs.
-- ----------------------------------------------------------------------------
revoke all on function public.lso_update_state(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;

do $lso_v83_grants$
begin
  if to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null then
    revoke all on function public.lso_update_state_v69(text, text, jsonb, bigint) from public, anon, authenticated;
    grant execute on function public.lso_update_state_v69(text, text, jsonb, bigint) to anon, authenticated;
  end if;
end;
$lso_v83_grants$;

commit;

-- ============================================================================
-- VERIFICATION — run this after the patch. Every row must read true/ok.
-- ============================================================================
-- select
--   to_regprocedure('public.lso_update_state(text,text,jsonb)')      is not null as wrapper_installed,
--   to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is not null as core_preserved,
--   (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('lso_update_state','lso_update_state_v69')
--       and p.proacl is not null)                                              as granted_wrappers;
--
-- Functional check (no data change expected):
--   select public.lso_update_state('<token>', 'attendance',
--          (select attendance from public.system_state where id = 1));
--   -- before the patch: updated_at moves
--   -- after the patch:  updated_at does NOT move
-- select id, updated_at from public.system_state where id = 1;
--
-- ============================================================================
-- ROLLBACK — restores the original functions exactly as they were.
-- ============================================================================
-- begin;
-- do $$
-- begin
--   if to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null then
--     drop function public.lso_update_state_v69(text, text, jsonb, bigint);
--   end if;
--   if to_regprocedure('public.lso_update_state_v69_core(text,text,jsonb,bigint)') is not null then
--     alter function public.lso_update_state_v69_core(text, text, jsonb, bigint) rename to lso_update_state_v69;
--   end if;
--   drop function if exists public.lso_update_state(text, text, jsonb);
--   if to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is not null then
--     alter function public.lso_update_state_core(text, text, jsonb) rename to lso_update_state;
--   end if;
-- end $$;
-- commit;
-- ============================================================================
