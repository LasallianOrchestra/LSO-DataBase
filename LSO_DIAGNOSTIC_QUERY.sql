-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — READ-ONLY DIAGNOSTIC (NO CHANGES ARE MADE)
-- ----------------------------------------------------------------------------
-- Run this in Supabase > SQL Editor > New query, then COPY THE FULL RESULT
-- (all sections) back to me. It reveals the TRUE source of every error without
-- altering anything in the database.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SECTION A — The app's own error log (what the website recorded as errors)
-- ----------------------------------------------------------------------------
select 'A. RECENT SYSTEM ERRORS (app error log)' as section;
select
  created_at,
  error_code,
  severity,
  module,
  public_message,
  left(technical_message, 600) as technical_message,
  created_by_username,
  resolved_at is not null as resolved
from public.lso_system_errors
order by created_at desc
limit 200;

-- ----------------------------------------------------------------------------
-- SECTION B — Every lso_update_state_v69 function version on the server
--             (this is where the LSO_CONFLICT / overload problem lives)
-- ----------------------------------------------------------------------------
select 'B. lso_update_state_v69 OVERLOADS' as section;
select
  p.oid::regprocedure as signature,
  pg_get_function_arguments(p.oid) as arguments,
  position('LSO_CONFLICT' in pg_get_functiondef(p.oid)) > 0 as contains_conflict_check,
  position('p_expected_version' in pg_get_functiondef(p.oid)) > 0 as reads_expected_version
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'lso_update_state_v69';

-- ----------------------------------------------------------------------------
-- SECTION C — Does each function the website calls actually exist?
-- ----------------------------------------------------------------------------
select 'C. FUNCTION PRESENCE' as section;
select
  fname,
  to_regprocedure(sig) is not null as exists
from (values
  ('lso_update_state_v69','public.lso_update_state_v69(text,text,jsonb,integer)'),
  ('lso_update_state_v69_bigint','public.lso_update_state_v69(text,text,jsonb,bigint)'),
  ('lso_update_state','public.lso_update_state(text,text,jsonb)'),
  ('lso_get_state','public.lso_get_state(text)'),
  ('lso_get_state_meta_v69','public.lso_get_state_meta_v69(text)'),
  ('lso_sync_health_v82','public.lso_sync_health_v82(text)'),
  ('lso_ping','public.lso_ping()'),
  ('lso_v69_capabilities','public.lso_v69_capabilities(text)'),
  ('lso_get_collection_page_v69','public.lso_get_collection_page_v69(text,text,integer,integer,text)'),
  ('lso_get_notification_preferences_v69','public.lso_get_notification_preferences_v69(text)'),
  ('lso_save_notification_preferences_v69','public.lso_save_notification_preferences_v69(text,jsonb)'),
  ('lso_save_role_notification_preferences_v69','public.lso_save_role_notification_preferences_v69(text,text,jsonb)'),
  ('lso_log_system_error','public.lso_log_system_error(text,jsonb)'),
  ('lso_list_system_errors','public.lso_list_system_errors(text,integer)'),
  ('lso_resolve_system_error','public.lso_resolve_system_error(text,uuid,text)'),
  ('lso_session_account_id','public.lso_session_account_id(text,boolean)'),
  ('lso_admin_account','public.lso_admin_account(text)')
) as t(fname, sig);

-- ----------------------------------------------------------------------------
-- SECTION D — Column / table inventory
-- ----------------------------------------------------------------------------
select 'D. SCHEMA STATE' as section;
select jsonb_build_object(
  'column_versions_exists',
    exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='system_state'
               and column_name='column_versions'),
  'system_state_exists', to_regclass('public.system_state') is not null,
  'lso_system_errors_exists', to_regclass('public.lso_system_errors') is not null,
  'lso_schema_migrations_exists', to_regclass('public.lso_schema_migrations') is not null,
  'migrations_applied',
    (select coalesce(jsonb_agg(jsonb_build_object('key',migration_key,'version',version_number)),'[]'::jsonb)
       from public.lso_schema_migrations)
) as state;
