-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — SUPABASE REPAIR V90
-- TARGETED FIX FOR: "Administrator cannot create anything"
-- ============================================================================
-- Run this entire file once in Supabase Dashboard -> SQL Editor -> New query.
-- Safe to re-run. It preserves all accounts and shared records.
--
-- ROOT CAUSES FIXED
--   1. public.lso_update_state_v69 reads/writes system_state.column_versions,
--      but the base installer (supabase-setup.sql) and the master migration
--      installer never created that column. Every shared-data write failed with
--      PostgreSQL 42703: column "column_versions" does not exist.
--   2. The merged Duty Hours installer reset lso_accounts_role_check to only
--      Administrator / Staff Account / Trainee-Probationary, so Membership and
--      General Secretary accounts could not be created or approved (23514).
--   3. Older installers defined public.lso_role_can without an Administrator
--      bypass. Administrator has no lso_role_permissions rows, so its writes
--      were rejected with 42501.
--
-- USE LSO_SUPABASE_REWRITE_V90.sql INSTEAD IF
--   * this is a brand-new project, or
--   * the database is missing base tables/functions.
-- This repair is for an existing project whose website can already sign in.
-- ============================================================================

begin;

-- 0. PRE-FLIGHT — the base tables must already exist.
do $v90_preflight$
begin
  if to_regclass('public.system_state') is null
     or to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null then
    raise exception 'LSO base tables are missing. Run LSO_SUPABASE_REWRITE_V90.sql first.' using errcode = 'P0002';
  end if;
end;
$v90_preflight$;

-- 1. MISSING V69 CONCURRENCY COLUMN — the direct cause of every failed save.
alter table public.system_state
  add column if not exists column_versions jsonb not null default '{}'::jsonb;

-- 2. RESTORE ALL FIVE ACCOUNT ROLES.
do $v90_roles$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table public.lso_accounts drop constraint %I', v_constraint.conname);
  end loop;
end;
$v90_roles$;

alter table public.lso_accounts
  add constraint lso_accounts_role_check
  check (role in ('Administrator','Staff Account','Membership','General Secretary','Trainee/Probationary'));

-- 3. PERMISSION TABLES.
create table if not exists public.lso_role_permissions (
  role_name text not null,
  permission_key text not null,
  resource text not null default '',
  allowed boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (role_name, permission_key, resource)
);

create table if not exists public.lso_role_profiles (
  role_name text primary key,
  landing_view text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'v90-repair'
);

create table if not exists public.lso_schema_migrations (
  migration_key text primary key,
  version_number integer not null,
  title text not null,
  checksum text not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default 'v90-repair',
  notes text not null default ''
);

-- 4. ADMINISTRATOR WRITE COLUMNS — explicit rows for older code paths that
--    read lso_role_permissions directly instead of using lso_role_can().
insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
values
  ('Administrator','write_column','members',true,now()),
  ('Administrator','write_column','events',true,now()),
  ('Administrator','write_column','attendance',true,now()),
  ('Administrator','write_column','duty_hours',true,now()),
  ('Administrator','write_column','monthly_reports',true,now()),
  ('Administrator','write_column','monthly_reports_compat',true,now()),
  ('Administrator','write_column','instruments',true,now()),
  ('Administrator','write_column','settings',true,now()),
  ('Administrator','write_column','activity_log',true,now())
on conflict(role_name,permission_key,resource)
do update set allowed = true, updated_at = excluded.updated_at;

-- 5. SUPPORTING TABLES.
create table if not exists public.lso_recovery_points (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  reason text not null default '',
  snapshot jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by_account_id uuid references public.lso_accounts(id) on delete set null,
  created_by_username text not null default '',
  restored_at timestamptz,
  restored_by_username text
);

create index if not exists lso_recovery_points_created_at_index
  on public.lso_recovery_points (created_at desc);

create table if not exists public.lso_system_errors (
  id uuid primary key default gen_random_uuid(),
  error_code text not null,
  severity text not null default 'error',
  module text not null default 'System',
  public_message text not null,
  technical_message text not null default '',
  context jsonb not null default '{}'::jsonb,
  app_version text not null default '',
  browser_info text not null default '',
  created_at timestamptz not null default now(),
  created_by_account_id uuid references public.lso_accounts(id) on delete set null,
  created_by_username text not null default '',
  resolved_at timestamptz,
  resolved_by_username text,
  resolution_note text not null default ''
);

create index if not exists lso_system_errors_created_at_index
  on public.lso_system_errors (created_at desc);
create index if not exists lso_system_errors_unresolved_index
  on public.lso_system_errors (created_at desc)
  where resolved_at is null;

create table if not exists public.lso_v69_notification_preferences (
  scope text not null check (scope in ('account', 'role')),
  pref_key text not null,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (scope, pref_key)
);

alter table public.lso_v69_notification_preferences enable row level security;
revoke all on table public.lso_v69_notification_preferences from anon, authenticated;

-- 6. FUNCTION REWRITE — current V89/V90 definitions.
--    Each definition is CREATE OR REPLACE and self-contained.
--
--    ORDER MATTERS: the definitions below are emitted in dependency order, so a
--    function is created only after every function it calls already exists.
--    PostgreSQL validates SQL-language function bodies at CREATE time; creating
--    lso_v82_columns_for_actions (a SQL wrapper) before the V89 helper it calls
--    fails with 42883 on a project that does not already have that helper.
--    Keep this section dependency-ordered when regenerating it.

CREATE OR REPLACE FUNCTION public.lso_account_json(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'id', account.id,
    'username', account.username,
    'email', coalesce(account.contact_email, ''),
    'displayName', account.display_name,
    'role', account.role,
    'memberId', coalesce(account.member_id, ''),
    'approvalStatus', account.approval_status,
    'disabled', account.disabled,
    'isDefault', account.is_default,
    'requestedAt', account.requested_at,
    'approvedAt', account.approved_at,
    'approvedBy', coalesce(account.approved_by, ''),
    'rejectedAt', account.rejected_at,
    'rejectedBy', coalesce(account.rejected_by, ''),
    'createdAt', account.created_at,
    'updatedAt', account.updated_at
  )
  from public.lso_accounts as account
  where account.id = p_account_id;
$function$;

CREATE OR REPLACE FUNCTION public.lso_default_role_configuration(p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  return case p_role
    when 'Administrator' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView','accountsView','systemHealthView','dataView'),
      'actions',jsonb_build_array('manageAccounts','manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport','manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','manageSettings','manageInventory','manageData','manageRecovery','viewSystemHealth','writeActivityLog','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','instruments','settings','activity_log')
    )
    when 'Membership' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','contractView','monthlyReportView','attendanceView','dutyHoursView'),
      'actions',jsonb_build_array('manageMembers','generateContract','editMonthlyReport','manageEvents','saveDraftAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','settings','activity_log')
    )
    when 'General Secretary' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','attendanceView','dutyHoursView'),
      'actions',jsonb_build_array('manageEvents','saveDraftAttendance','reviewDutyPunches','writeActivityLog','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('events','attendance','activity_log')
    )
    when 'Staff Account' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','attendanceView','dutyHoursView'),
      'actions',jsonb_build_array('reviewDutyPunches','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array()
    )
    when 'Trainee/Probationary' then jsonb_build_object(
      'landingView','dutyHoursView',
      'views',jsonb_build_array('dutyHoursView','ownAttendanceView'),
      'actions',jsonb_build_array('selfDutyPunch','manageAccessibility'),
      'attendanceGroups',jsonb_build_array(),
      'columns',jsonb_build_array()
    )
    else null
  end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_local_date()
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select (now() at time zone 'Asia/Manila')::date;
$function$;

CREATE OR REPLACE FUNCTION public.lso_login(p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account public.lso_accounts%rowtype;
  v_token text;
  v_expires_at timestamptz;
begin
  delete from public.lso_sessions where expires_at <= now();

  select * into v_account
  from public.lso_accounts
  where lower(username) = lower(btrim(coalesce(p_username, '')))
  limit 1;

  if v_account.id is null
     or v_account.password_hash <> crypt(coalesce(p_password, ''), v_account.password_hash) then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials');
  end if;

  if v_account.approval_status = 'Pending' then
    return jsonb_build_object('ok', false, 'code', 'pending');
  end if;

  if v_account.approval_status = 'Rejected' then
    return jsonb_build_object('ok', false, 'code', 'rejected');
  end if;

  if v_account.disabled then
    return jsonb_build_object('ok', false, 'code', 'disabled');
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_expires_at := now() + interval '30 days';

  -- Keep a reasonable number of active devices per account.
  delete from public.lso_sessions
  where id in (
    select id
    from public.lso_sessions
    where account_id = v_account.id
    order by last_seen_at desc
    offset 10
  );

  insert into public.lso_sessions (account_id, token_hash, expires_at)
  values (v_account.id, encode(digest(v_token, 'sha256'), 'hex'), v_expires_at);

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'expiresAt', v_expires_at,
    'account', public.lso_account_json(v_account.id)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_logout(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  delete from public.lso_sessions
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return true;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_member_period_on_date(p_member jsonb, p_on_date date DEFAULT lso_local_date())
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_trainee_start date;
  v_probationary_start date;
  v_membership_start date;
  v_skipped boolean := false;
  v_period text;
  v_stage text;
begin
  if p_member is null or jsonb_typeof(p_member) <> 'object' then
    return '';
  end if;

  begin
    v_trainee_start := nullif(coalesce(p_member ->> 'traineeStartDate', p_member ->> 'dateRegistered'), '')::date;
  exception when others then
    v_trainee_start := null;
  end;

  begin
    v_probationary_start := nullif(p_member ->> 'probationaryStartDate', '')::date;
  exception when others then
    v_probationary_start := null;
  end;

  begin
    v_membership_start := nullif(coalesce(p_member ->> 'regularMemberDate', p_member ->> 'membershipStartDate'), '')::date;
  exception when others then
    v_membership_start := null;
  end;

  v_skipped := lower(coalesce(p_member ->> 'probationarySkipped', 'false')) in ('true', '1', 'yes');
  v_period := coalesce(p_member ->> 'periodGroup', '');
  v_stage := coalesce(p_member ->> 'membershipStage', '');

  if v_membership_start is not null and p_on_date >= v_membership_start then
    return 'Membership Period';
  end if;

  if not v_skipped
     and v_probationary_start is not null
     and p_on_date >= v_probationary_start then
    return 'Probationary Period';
  end if;

  if v_trainee_start is not null and p_on_date >= v_trainee_start then
    return 'Trainee Period';
  end if;

  -- Fallback for older member records that do not yet have complete timeline dates.
  if v_period in ('Trainee Period', 'Probationary Period', 'Membership Period') then
    return v_period;
  end if;

  if v_stage = 'Trainee' then return 'Trainee Period'; end if;
  if v_stage = 'Probationary' then return 'Probationary Period'; end if;
  if v_stage in ('Regular Member', 'Member', 'Official Member') then return 'Membership Period'; end if;

  return '';
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_ping()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('ok', true, 'serverTime', now());
$function$;

CREATE OR REPLACE FUNCTION public.lso_register_account(p_username text, p_password text, p_display_name text, p_contact_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_username text := btrim(coalesce(p_username, ''));
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_contact_email text := nullif(lower(btrim(coalesce(p_contact_email, ''))), '');
  v_id uuid;
begin
  if v_username !~ '^[A-Za-z0-9._-]{4,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_username');
  end if;


  if char_length(v_display_name) < 2 or char_length(v_display_name) > 60 then
    return jsonb_build_object('ok', false, 'code', 'invalid_display_name');
  end if;

  if char_length(coalesce(p_password, '')) < 6 then
    return jsonb_build_object('ok', false, 'code', 'weak_password');
  end if;

  if v_contact_email is not null
     and v_contact_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_email');
  end if;

  if exists (
    select 1 from public.lso_accounts where lower(username) = lower(v_username)
  ) then
    return jsonb_build_object('ok', false, 'code', 'username_taken');
  end if;

  insert into public.lso_accounts (
    username,
    contact_email,
    display_name,
    password_hash,
    role,
    approval_status,
    disabled,
    is_default,
    requested_at
  ) values (
    v_username,
    v_contact_email,
    v_display_name,
    crypt(p_password, gen_salt('bf', 12)),
    'Staff Account',
    'Pending',
    false,
    false,
    now()
  ) returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'code', 'pending',
    'account', public.lso_account_json(v_id)
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'username_taken');
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_resume_session(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
begin
  select account.*
  into v_account
  from public.lso_sessions as session
  join public.lso_accounts as account on account.id = session.account_id
  where session.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
    and session.expires_at > now()
  limit 1;

  v_account_id := v_account.id;

  if v_account_id is null then
    return jsonb_build_object('ok', false, 'code', 'session_expired');
  end if;

  if v_account.approval_status <> 'Approved' then
    delete from public.lso_sessions
    where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
    return jsonb_build_object('ok', false, 'code', lower(v_account.approval_status));
  end if;

  if v_account.disabled then
    delete from public.lso_sessions
    where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
    return jsonb_build_object('ok', false, 'code', 'disabled');
  end if;

  update public.lso_sessions
  set last_seen_at = now()
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');

  return jsonb_build_object(
    'ok', true,
    'account', public.lso_account_json(v_account_id)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_role_can(p_role text, p_permission_key text, p_resource text DEFAULT ''::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select case
    when p_role = 'Administrator' then true
    else coalesce((
      select allowed
      from public.lso_role_permissions
      where role_name = p_role
        and permission_key = p_permission_key
        and resource = coalesce(p_resource, '')
    ), false)
  end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_session_account_id(p_token text, p_require_admin boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
begin
  if p_token is null or char_length(p_token) < 32 then
    raise exception 'Invalid or expired session.' using errcode = '42501';
  end if;

  select account.id
  into v_account_id
  from public.lso_sessions as session
  join public.lso_accounts as account on account.id = session.account_id
  where session.token_hash = encode(digest(p_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.approval_status = 'Approved'
    and account.disabled = false
    and (not p_require_admin or account.role = 'Administrator')
  limit 1;

  if v_account_id is null then
    raise exception 'Invalid or expired session.' using errcode = '42501';
  end if;

  update public.lso_sessions
  set last_seen_at = now()
  where token_hash = encode(digest(p_token, 'sha256'), 'hex');

  return v_account_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_admin_account(p_token text)
 RETURNS lso_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;
  if not found or v_account.role <> 'Administrator' then
    raise exception 'Administrator access is required.' using errcode = '42501';
  end if;
  return v_account;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_create_recovery_point(p_token text, p_label text, p_reason text DEFAULT ''::text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account public.lso_accounts%rowtype;
  v_snapshot jsonb;
  v_point public.lso_recovery_points%rowtype;
begin
  v_account := public.lso_admin_account(p_token);
  select to_jsonb(state) into v_snapshot from public.system_state as state where id = 1 for share;
  if v_snapshot is null then raise exception 'The shared system state is missing.' using errcode='P0002'; end if;

  insert into public.lso_recovery_points(label, reason, snapshot, metadata, created_by_account_id, created_by_username)
  values(left(coalesce(nullif(btrim(p_label),''),'Recovery point'),120), left(coalesce(p_reason,''),500), v_snapshot, coalesce(p_metadata,'{}'::jsonb), v_account.id, v_account.username)
  returning * into v_point;

  delete from public.lso_recovery_points
  where id in (
    select id from public.lso_recovery_points order by created_at desc offset 20
  );

  return jsonb_build_object('ok',true,'recoveryPoint',jsonb_build_object(
    'id',v_point.id,'label',v_point.label,'reason',v_point.reason,'createdAt',v_point.created_at,'createdBy',v_point.created_by_username,'metadata',v_point.metadata
  ));
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_delete_account(p_token text, p_account_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id uuid;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);

  if p_account_id = v_admin_id then
    raise exception 'You cannot delete your own active account.' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.lso_accounts
    where id = p_account_id and is_default = true
  ) then
    raise exception 'The default administrator cannot be deleted.' using errcode = '42501';
  end if;

  delete from public.lso_accounts where id = p_account_id;
  return found;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_delete_recovery_point(p_token text, p_recovery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform public.lso_admin_account(p_token);
  delete from public.lso_recovery_points where id=p_recovery_id;
  return jsonb_build_object('ok',true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_notification_preferences_v69(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_permission_center(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_roles jsonb := '[]'::jsonb;
  v_role text;
  v_default jsonb;
  v_landing text;
  v_views jsonb;
  v_actions jsonb;
  v_groups jsonb;
  v_columns jsonb;
  v_has_configuration boolean;
  v_updated_at timestamptz;
begin
  v_account_id := public.lso_session_account_id(p_token,false);
  select * into v_account from public.lso_accounts where id = v_account_id;
  if not found then
    raise exception 'Account not found.' using errcode = '42501';
  end if;

  select greatest(
    coalesce((select max(updated_at) from public.lso_role_permissions), '-infinity'::timestamptz),
    coalesce((select max(updated_at) from public.lso_role_profiles), '-infinity'::timestamptz),
    coalesce(v_account.updated_at, '-infinity'::timestamptz)
  ) into v_updated_at;
  if v_updated_at = '-infinity'::timestamptz then v_updated_at := now(); end if;

  foreach v_role in array array['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    -- Non-administrators only receive their own configuration row.
    if v_account.role <> 'Administrator' and v_role <> v_account.role then
      continue;
    end if;

    v_default := public.lso_default_role_configuration(v_role);

    if v_role = 'Administrator' then
      v_landing := v_default ->> 'landingView';
      v_views := v_default -> 'views';
      v_actions := v_default -> 'actions';
      v_groups := v_default -> 'attendanceGroups';
      v_columns := v_default -> 'columns';
    else
      select exists(
        select 1 from public.lso_role_profiles where role_name = v_role
        union all
        select 1 from public.lso_role_permissions where role_name = v_role
      ) into v_has_configuration;

      if not v_has_configuration then
        v_landing := v_default ->> 'landingView';
        v_views := v_default -> 'views';
        v_actions := v_default -> 'actions';
        v_groups := v_default -> 'attendanceGroups';
        v_columns := v_default -> 'columns';
      else
        select coalesce(p.landing_view, v_default ->> 'landingView')
          into v_landing
        from public.lso_role_profiles p
        where p.role_name = v_role;
        v_landing := coalesce(v_landing, v_default ->> 'landingView');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_views
        from public.lso_role_permissions
        where role_name = v_role and permission_key = 'view' and allowed = true
          and resource in ('dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView','ownAttendanceView')
          and (resource <> 'ownAttendanceView' or v_role = 'Trainee/Probationary');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_actions
        from public.lso_role_permissions
        where role_name = v_role and permission_key = 'action' and allowed = true
          and resource in (
            'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
            'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
            'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
            'writeActivityLog','manageAccessibility','selfDutyPunch'
          )
          and (resource <> 'selfDutyPunch' or v_role = 'Trainee/Probationary');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_groups
        from public.lso_role_permissions
        where role_name = v_role and permission_key = 'attendance_group' and allowed = true
          and resource in ('Official Members','Trainee Members','Probationary Members');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_columns
        from public.lso_role_permissions
        where role_name = v_role and permission_key = 'write_column' and allowed = true
          and resource in ('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','settings','activity_log');
      end if;
    end if;

    v_roles := v_roles || jsonb_build_array(jsonb_build_object(
      'roleName', v_role,
      'landingView', v_landing,
      'views', coalesce(v_views,'[]'::jsonb),
      'actions', coalesce(v_actions,'[]'::jsonb),
      'attendanceGroups', coalesce(v_groups,'[]'::jsonb),
      'columns', coalesce(v_columns,'[]'::jsonb),
      'updatedAt', v_updated_at
    ));
  end loop;

  return jsonb_build_object(
    'roles', v_roles,
    'updatedAt', v_updated_at,
    'schemaVersion', 14,
    'permissionModel', 'v89',
    'editable', v_account.role = 'Administrator',
    'requestedRole', v_account.role,
    'account', public.lso_account_json(v_account.id),
    'accountRole', v_account.role,
    'accountRoleUpdatedAt', v_account.updated_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_permission_revision(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_role text;
  v_updated_at timestamptz;
begin
  v_account_id := public.lso_session_account_id(p_token,false);
  select role into v_role from public.lso_accounts where id = v_account_id;
  select greatest(
    coalesce((select max(updated_at) from public.lso_role_permissions), '-infinity'::timestamptz),
    coalesce((select max(updated_at) from public.lso_role_profiles), '-infinity'::timestamptz),
    coalesce((select updated_at from public.lso_accounts where id = v_account_id), '-infinity'::timestamptz)
  ) into v_updated_at;
  if v_updated_at = '-infinity'::timestamptz then v_updated_at := now(); end if;
  return jsonb_build_object(
    'updatedAt', v_updated_at,
    'schemaVersion', 14,
    'accountRole', v_role
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_state_meta_v69(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_list_accounts(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id uuid;
  v_result jsonb;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);

  select coalesce(jsonb_agg(public.lso_account_json(account.id) order by account.created_at desc), '[]'::jsonb)
  into v_result
  from public.lso_accounts as account;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_list_recovery_points(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform public.lso_admin_account(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',id,'label',label,'reason',reason,'metadata',metadata,'createdAt',created_at,'createdBy',created_by_username,
    'restoredAt',restored_at,'restoredBy',restored_by_username,
    'summary',jsonb_build_object(
      'members',case when jsonb_typeof(snapshot->'members')='array' then jsonb_array_length(snapshot->'members') else 0 end,
      'events',case when jsonb_typeof(snapshot->'events')='array' then jsonb_array_length(snapshot->'events') else 0 end,
      'attendance',case when jsonb_typeof(snapshot->'attendance')='array' then jsonb_array_length(snapshot->'attendance') else 0 end,
      'dutyEntries',case when jsonb_typeof(snapshot->'duty_hours'->'entries')='array' then jsonb_array_length(snapshot->'duty_hours'->'entries') else 0 end
    )
  ) order by created_at desc) from public.lso_recovery_points), '[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_list_system_errors(p_token text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform public.lso_admin_account(p_token);
  return coalesce((select jsonb_agg(to_jsonb(errors) order by errors.created_at desc) from (
    select id,error_code,severity,module,public_message,technical_message,context,app_version,browser_info,created_at,created_by_username,resolved_at,resolved_by_username,resolution_note
    from public.lso_system_errors order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
  ) errors),'[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_log_system_error(p_token text, p_error jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_id uuid;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id=v_account_id;
  insert into public.lso_system_errors(
    error_code,severity,module,public_message,technical_message,context,app_version,browser_info,created_by_account_id,created_by_username
  ) values(
    left(coalesce(nullif(p_error->>'errorCode',''),'SYS-UNEXPECTED-999'),60),
    left(coalesce(nullif(p_error->>'severity',''),'error'),20),
    left(coalesce(nullif(p_error->>'module',''),'System'),80),
    left(coalesce(nullif(p_error->>'publicMessage',''),'An unexpected system error occurred.'),500),
    left(coalesce(p_error->>'technicalMessage',''),4000),
    case when jsonb_typeof(p_error->'context')='object' then p_error->'context' else '{}'::jsonb end,
    left(coalesce(p_error->>'appVersion',''),80),
    left(coalesce(p_error->>'browserInfo',''),500),
    v_account.id,v_account.username
  ) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_resolve_system_error(p_token text, p_error_id uuid, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_account public.lso_accounts%rowtype;
begin
  v_account := public.lso_admin_account(p_token);
  update public.lso_system_errors set resolved_at=now(),resolved_by_username=v_account.username,resolution_note=left(coalesce(p_note,''),500) where id=p_error_id;
  return jsonb_build_object('ok',true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_save_accounts(p_token text, p_accounts jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id uuid;
  v_admin_username text;
  v_item jsonb;
  v_target_id uuid;
  v_status text;
  v_role text;
  v_member_id text;
  v_disabled boolean;
  v_old_role text;
  v_old_member_id text;
  v_old_status text;
  v_member jsonb;
  v_current_period text;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username into v_admin_username
  from public.lso_accounts
  where id = v_admin_id;

  if jsonb_typeof(p_accounts) <> 'array' then
    raise exception 'Accounts payload must be a JSON array.' using errcode = '22023';
  end if;

  for v_item in select value from jsonb_array_elements(p_accounts)
  loop
    begin
      v_target_id := (v_item ->> 'id')::uuid;
    exception when others then
      continue;
    end;

    if not exists (select 1 from public.lso_accounts where id = v_target_id)
       or exists (select 1 from public.lso_accounts where id = v_target_id and is_default = true) then
      continue;
    end if;

    select role, member_id, approval_status
    into v_old_role, v_old_member_id, v_old_status
    from public.lso_accounts
    where id = v_target_id;

    v_status := case
      when v_item ->> 'approvalStatus' in ('Pending', 'Approved', 'Rejected')
        then v_item ->> 'approvalStatus'
      else 'Pending'
    end;

    v_role := case
      when v_item ->> 'role' = 'Administrator' then 'Administrator'
      when v_item ->> 'role' = 'Membership' then 'Membership'
      when v_item ->> 'role' = 'General Secretary' then 'General Secretary'
      when v_item ->> 'role' = 'Trainee/Probationary' then 'Trainee/Probationary'
      else 'Staff Account'
    end;

    v_member_id := case
      when v_role = 'Trainee/Probationary'
        then nullif(btrim(coalesce(v_item ->> 'memberId', '')), '')
      else null
    end;

    -- Changing an approved role or member link always requires fresh approval.
    if v_old_status = 'Approved'
       and (
         v_old_role is distinct from v_role
         or coalesce(v_old_member_id, '') <> coalesce(v_member_id, '')
       ) then
      v_status := 'Pending';
    end if;

    begin
      v_disabled := coalesce((v_item ->> 'disabled')::boolean, false);
    exception when others then
      v_disabled := false;
    end;

    -- A link that is unchanged from the stored row is not re-validated: a
    -- stale or period-expired link on ONE account must never abort saves of
    -- unrelated accounts ("The selected linked member record could not be
    -- found." while changing another account's role). New or changed links
    -- are still fully validated below.
    if v_role = 'Trainee/Probationary' and v_member_id is not null
       and (v_old_role is distinct from v_role
            or coalesce(v_old_member_id, '') <> coalesce(v_member_id, '')) then
      select member
      into v_member
      from public.system_state as state,
           jsonb_array_elements(coalesce(state.members, '[]'::jsonb)) as member
      where state.id = 1
        and member ->> 'id' = v_member_id
      limit 1;

      if v_member is null then
        raise exception 'The selected linked member record could not be found.' using errcode = '22023';
      end if;

      v_current_period := public.lso_member_period_on_date(v_member, public.lso_local_date());
      if v_current_period not in ('Trainee Period', 'Probationary Period') then
        raise exception 'The selected member is not currently in the Trainee or Probationary Period.' using errcode = '22023';
      end if;
    end if;

    if v_role = 'Trainee/Probationary'
       and v_status = 'Approved'
       and v_member_id is null then
      raise exception 'Select a Trainee or Probationary member before approving this account.' using errcode = '22023';
    end if;

    -- One active approved account per member prevents entries from being
    -- submitted under two different usernames.
    if v_role = 'Trainee/Probationary'
       and v_status = 'Approved'
       and not v_disabled
       and exists (
         select 1
         from public.lso_accounts as other_account
         where other_account.id <> v_target_id
           and other_account.role = 'Trainee/Probationary'
           and other_account.approval_status = 'Approved'
           and other_account.disabled = false
           and other_account.member_id = v_member_id
       ) then
      raise exception 'This member is already linked to another active approved Trainee/Probationary account.' using errcode = '23505';
    end if;

    update public.lso_accounts
    set role = v_role,
        member_id = v_member_id,
        approval_status = v_status,
        disabled = v_disabled,
        approved_at = case
          when v_status = 'Approved'
            then coalesce(nullif(v_item ->> 'approvedAt', '')::timestamptz, approved_at, now())
          else null
        end,
        approved_by = case
          when v_status = 'Approved'
            then coalesce(nullif(v_item ->> 'approvedBy', ''), v_admin_username)
          else null
        end,
        rejected_at = case
          when v_status = 'Rejected'
            then coalesce(nullif(v_item ->> 'rejectedAt', '')::timestamptz, rejected_at, now())
          else null
        end,
        rejected_by = case
          when v_status = 'Rejected'
            then coalesce(nullif(v_item ->> 'rejectedBy', ''), v_admin_username)
          else null
        end
    where id = v_target_id;

    if v_status <> 'Approved'
       or v_disabled
       or v_old_role is distinct from v_role
       or coalesce(v_old_member_id, '') <> coalesce(v_member_id, '') then
      delete from public.lso_sessions where account_id = v_target_id;
    end if;
  end loop;

  return public.lso_list_accounts(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_save_notification_preferences_v69(p_token text, p_preferences jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_save_role_notification_preferences_v69(p_token text, p_role text, p_preferences jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_sync_health_v82(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_role text;
  v_state_updated timestamptz;
begin
  v_account_id := public.lso_session_account_id(p_token,false);
  select role into v_role from public.lso_accounts where id=v_account_id;
  select updated_at into v_state_updated from public.system_state where id=1;

  return jsonb_build_object(
    'ok',true,
    'role',v_role,
    'serverTime',now(),
    'stateUpdatedAt',v_state_updated,
    'schemaVersion',13,
    'permissionModel','v82'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_trainee_scoped_state_v85(p_state jsonb, p_member_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_member_id text := nullif(btrim(coalesce(p_member_id, '')), '');
  v_members jsonb := '[]'::jsonb;
  v_attendance jsonb := '[]'::jsonb;
  v_events jsonb := '[]'::jsonb;
  v_entries jsonb := '[]'::jsonb;
  v_commitments jsonb := '{}'::jsonb;
  v_duty_hours jsonb;
  v_all_members jsonb;
  v_all_attendance jsonb;
  v_all_events jsonb;
begin
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'The shared system state is missing.' using errcode = 'P0002';
  end if;

  v_all_members := case when jsonb_typeof(p_state -> 'members') = 'array' then p_state -> 'members' else '[]'::jsonb end;
  v_all_attendance := case when jsonb_typeof(p_state -> 'attendance') = 'array' then p_state -> 'attendance' else '[]'::jsonb end;
  v_all_events := case when jsonb_typeof(p_state -> 'events') = 'array' then p_state -> 'events' else '[]'::jsonb end;
  v_duty_hours := case
    when jsonb_typeof(p_state -> 'duty_hours') = 'object' then p_state -> 'duty_hours'
    else '{"version":6,"commitments":{},"entries":[]}'::jsonb
  end;

  -- An account that is not linked to a member receives nothing but the shell.
  if v_member_id is not null then
    -- Own member record (unchanged behaviour).
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_members
      from jsonb_array_elements(v_all_members) with ordinality as t(item, idx)
     where btrim(coalesce(item ->> 'id', '')) = v_member_id;

    -- V85: own attendance rows only (every roster mode and attendance calendar).
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_attendance
      from jsonb_array_elements(v_all_attendance) with ordinality as t(item, idx)
     where btrim(coalesce(item ->> 'memberId', '')) = v_member_id;

    -- V85: only the activities referenced by those rows (date/title/type/venue
    -- for the table). Activities without an own record are not disclosed.
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_events
      from jsonb_array_elements(v_all_events) with ordinality as t(item, idx)
     where btrim(coalesce(item ->> 'id', '')) <> ''
       and exists (
         select 1
           from jsonb_array_elements(v_attendance) as own_record
          where btrim(coalesce(own_record ->> 'eventId', '')) = btrim(coalesce(item ->> 'id', ''))
       );

    -- Own Duty Hours entries and commitment (unchanged behaviour).
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_entries
      from jsonb_array_elements(
        case when jsonb_typeof(v_duty_hours -> 'entries') = 'array' then v_duty_hours -> 'entries' else '[]'::jsonb end
      ) with ordinality as t(item, idx)
     where btrim(coalesce(item ->> 'memberId', '')) = v_member_id;

    if jsonb_typeof(v_duty_hours -> 'commitments' -> v_member_id) = 'object' then
      v_commitments := jsonb_build_object(v_member_id, v_duty_hours -> 'commitments' -> v_member_id);
    end if;
  end if;

  return jsonb_build_object(
    'id', coalesce(p_state -> 'id', '1'::jsonb),
    'members', v_members,
    'events', v_events,
    'attendance', v_attendance,
    'duty_hours', jsonb_build_object(
      'version', coalesce(v_duty_hours -> 'version', '6'::jsonb),
      'commitments', v_commitments,
      'entries', v_entries
    ),
    'monthly_reports', '{}'::jsonb,
    'instruments', '[]'::jsonb,
    'settings', '{}'::jsonb,
    'activity_log', '[]'::jsonb,
    'updated_at', coalesce(p_state -> 'updated_at', to_jsonb(now())),
    'scope', jsonb_build_object('role', 'Trainee/Probationary', 'memberId', coalesce(v_member_id, ''), 'model', 'v85-own-record')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_collection_page_v69(p_token text, p_collection text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
  v_scoped jsonb;
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

  -- V85: Trainee/Probationary accounts page only their own records. The same
  -- helper that scopes lso_get_state decides what belongs to the member.
  if v_role = 'Trainee/Probationary' then
    select public.lso_trainee_scoped_state_v85(to_jsonb(state), v_member_id)
      into v_scoped
      from public.system_state as state
     where state.id = 1;
    v_source := case p_collection
      when 'members'      then coalesce(v_scoped -> 'members', '[]'::jsonb)
      when 'events'       then coalesce(v_scoped -> 'events', '[]'::jsonb)
      when 'attendance'   then coalesce(v_scoped -> 'attendance', '[]'::jsonb)
      when 'duty_entries' then coalesce(v_scoped -> 'duty_hours' -> 'entries', '[]'::jsonb)
      else '[]'::jsonb
    end;
  end if;

  -- Case-insensitive text filter (matches the browser fallback behaviour).
  if v_search <> '' then
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_source
      from jsonb_array_elements(v_source) with ordinality as t(item, idx)
     where position(v_search in lower(coalesce(item::text, ''))) > 0;
  end if;

  v_total := jsonb_array_length(v_source);

  -- V85 repair: the previous body ordered/limited an aggregate directly, which
  -- PostgreSQL rejects ("column t.idx must appear in the GROUP BY clause"), so
  -- every call failed. The page is now selected first and aggregated after.
  select coalesce(jsonb_agg(page.item order by page.idx), '[]'::jsonb)
    into v_items
    from (
      select t.item, t.idx
        from jsonb_array_elements(v_source) with ordinality as t(item, idx)
       where t.idx > v_offset
       order by t.idx
       limit v_limit
    ) as page;

  return jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'offset', v_offset,
    'limit', v_limit
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_get_state(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_role text;
  v_member_id text;
  v_state jsonb;
  v_duty_hours jsonb;
  v_monthly_reports jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);

  select role, member_id
    into v_role, v_member_id
    from public.lso_accounts
   where id = v_account_id;

  select to_jsonb(state)
    into v_state
    from public.system_state as state
   where state.id = 1;

  if v_state is null then
    raise exception 'The shared system state is missing.' using errcode = 'P0002';
  end if;

  -- V85: identity-bound payload for the self-service role. Only the linked
  -- member's own records leave the database; nothing in the request can widen it.
  if v_role = 'Trainee/Probationary' then
    return public.lso_trainee_scoped_state_v85(v_state, v_member_id);
  end if;

  v_duty_hours := case
    when jsonb_typeof(v_state -> 'duty_hours') = 'object' then v_state -> 'duty_hours'
    else '{"version":6,"commitments":{},"entries":[]}'::jsonb
  end;

  v_monthly_reports := case
    when jsonb_typeof(v_state -> 'monthly_reports') = 'object' then v_state -> 'monthly_reports'
    when jsonb_typeof(v_state -> 'settings' -> '__lso_monthly_reports_v1') = 'object' then v_state -> 'settings' -> '__lso_monthly_reports_v1'
    else '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb
  end;

  return jsonb_build_object(
    'id', coalesce(v_state -> 'id', '1'::jsonb),
    'members', case when jsonb_typeof(v_state -> 'members') = 'array' then v_state -> 'members' else '[]'::jsonb end,
    'events', case when jsonb_typeof(v_state -> 'events') = 'array' then v_state -> 'events' else '[]'::jsonb end,
    'attendance', case when jsonb_typeof(v_state -> 'attendance') = 'array' then v_state -> 'attendance' else '[]'::jsonb end,
    'duty_hours', v_duty_hours,
    'monthly_reports', v_monthly_reports,
    'instruments', case when jsonb_typeof(v_state -> 'instruments') = 'array' then v_state -> 'instruments' else '[]'::jsonb end,
    'settings', case when jsonb_typeof(v_state -> 'settings') = 'object' then v_state -> 'settings' else '{}'::jsonb end,
    'activity_log', case when jsonb_typeof(v_state -> 'activity_log') = 'array' then v_state -> 'activity_log' else '[]'::jsonb end,
    'updated_at', coalesce(v_state -> 'updated_at', to_jsonb(now()))
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_duty_time_in(p_token text, p_semester text, p_description text DEFAULT ''::text, p_member_approvers text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_now timestamptz := clock_timestamp();
  v_local_timestamp timestamp;
  v_duty_date date;
  v_time_in text;
  v_member jsonb;
  v_period text;
  v_members jsonb;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_activity_log jsonb;
  v_entry_id text := gen_random_uuid()::text;
  v_entry jsonb;
  v_activity jsonb;
  v_description text := left(btrim(coalesce(p_description, '')), 160);
  v_member_approvers text := left(btrim(coalesce(p_member_approvers, '')), 200);
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may submit Duty Hours.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;
  if p_semester not in ('First Semester', 'Second Semester') then
    raise exception 'Select a valid duty semester.' using errcode = '22023';
  end if;

  v_local_timestamp := v_now at time zone 'Asia/Manila';
  v_duty_date := v_local_timestamp::date;
  v_time_in := to_char(v_local_timestamp, 'HH24:MI');

  select members, duty_hours, activity_log
  into v_members, v_duty_hours, v_activity_log
  from public.system_state
  where id = 1
  for update;

  if not found then
    raise exception 'The shared system state is missing.' using errcode = 'P0002';
  end if;
  if v_members is null or jsonb_typeof(v_members) <> 'array' then v_members := '[]'::jsonb; end if;
  if v_duty_hours is null or jsonb_typeof(v_duty_hours) <> 'object' then
    v_duty_hours := '{"version":7,"commitments":{},"entries":[]}'::jsonb;
  end if;
  v_entries := case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
    then v_duty_hours -> 'entries' else '[]'::jsonb end;

  select item into v_member
  from jsonb_array_elements(v_members) as item
  where item ->> 'id' = v_account.member_id
  limit 1;

  if v_member is null then
    raise exception 'The linked member record could not be found.' using errcode = '42501';
  end if;

  v_period := public.lso_member_period_on_date(v_member, v_duty_date);
  if v_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'The linked member is not currently in the Trainee or Probationary Period.' using errcode = '42501';
  end if;

  -- Only one punch may remain open without a Time Out request.
  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where (entry ->> 'memberId') = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and nullif(entry ->> 'timeOut', '') is null
      and coalesce(
        nullif(entry ->> 'timeInApprovalStatus', ''),
        case when coalesce(entry ->> 'approvalStatus', 'Approved') in ('Pending', 'Active') then 'Pending' else 'Approved' end
      ) in ('Pending', 'Approved')
  ) then
    raise exception 'You already have an open Time In request. Submit Time Out before starting another session.' using errcode = '23505';
  end if;

  -- A new request may follow a prior Time Out request on the same day, but its
  -- server time cannot fall inside another non-rejected interval.
  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where (entry ->> 'memberId') = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and entry ->> 'date' = to_char(v_duty_date, 'YYYY-MM-DD')
      and coalesce(nullif(entry ->> 'timeInApprovalStatus', ''), 'Approved') <> 'Rejected'
      and coalesce(nullif(entry ->> 'timeOutApprovalStatus', ''), 'Approved') not in ('Rejected', 'Cancelled')
      and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and (entry ->> 'timeIn')::time <= v_time_in::time
      and (entry ->> 'timeOut')::time > v_time_in::time
  ) then
    raise exception 'The current time overlaps an existing duty session.' using errcode = '23505';
  end if;

  v_entry := jsonb_build_object(
    'id', v_entry_id,
    'memberId', v_account.member_id,
    'semester', p_semester,
    'period', v_period,
    'entryType', 'Duty',
    'date', to_char(v_duty_date, 'YYYY-MM-DD'),
    'minutes', 0,
    'timeIn', v_time_in,
    'timeOut', '',
    'clockInAt', v_now,
    'clockOutAt', '',
    'timeSource', 'Supabase server / Asia/Manila',
    'description', v_description,
    'memberApprovers', v_member_approvers,
    'approvalStatus', 'Pending',
    'timeInApprovalStatus', 'Pending',
    'timeOutApprovalStatus', 'Not Submitted',
    'timeInRequestedAt', v_now,
    'timeInReviewedAt', '',
    'timeInReviewedBy', '',
    'timeOutRequestedAt', '',
    'timeOutReviewedAt', '',
    'timeOutReviewedBy', '',
    'punchAudit', jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'timestamp', v_now,
      'punchType', 'TimeIn',
      'action', 'Submitted',
      'by', v_account.username
    )),
    'submittedByAccountId', v_account.id,
    'submittedByUsername', v_account.username,
    'submittedByRole', v_account.role,
    'createdAt', v_now,
    'createdBy', v_account.display_name,
    'createdByUsername', v_account.username
  );

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '7'::jsonb, true),
    '{entries}', v_entries || jsonb_build_array(v_entry), true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', v_now,
    'action', 'Submitted Duty Time In',
    'category', 'Duty Hours',
    'details', to_char(v_duty_date, 'YYYY-MM-DD') || ' • ' || v_time_in || ' • Pending Administrator approval',
    'account', v_account.display_name,
    'username', v_account.username
  );
  v_activity_log := jsonb_build_array(v_activity) ||
    case when jsonb_typeof(v_activity_log) = 'array' then v_activity_log else '[]'::jsonb end;

  update public.system_state
  set duty_hours = v_duty_hours,
      activity_log = v_activity_log,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_duty_time_out(p_token text, p_description text DEFAULT ''::text, p_member_approvers text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_now timestamptz := clock_timestamp();
  v_local_timestamp timestamp;
  v_today date;
  v_time_out text;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_next_entries jsonb;
  v_activity_log jsonb;
  v_target jsonb;
  v_target_count integer;
  v_start_at timestamptz;
  v_start_date date;
  v_start_time text;
  v_minutes integer;
  v_description text := left(btrim(coalesce(p_description, '')), 160);
  v_member_approvers text := left(btrim(coalesce(p_member_approvers, '')), 200);
  v_final_description text;
  v_final_member_approvers text;
  v_in_status text;
  v_next_overall text;
  v_activity jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may submit Duty Hours.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  v_local_timestamp := v_now at time zone 'Asia/Manila';
  v_today := v_local_timestamp::date;
  v_time_out := to_char(v_local_timestamp, 'HH24:MI');

  select duty_hours, activity_log
  into v_duty_hours, v_activity_log
  from public.system_state
  where id = 1
  for update;

  if not found then
    raise exception 'The shared system state is missing.' using errcode = 'P0002';
  end if;
  if v_duty_hours is null or jsonb_typeof(v_duty_hours) <> 'object' then
    raise exception 'The Duty Hours database is unavailable.' using errcode = 'P0002';
  end if;
  v_entries := case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
    then v_duty_hours -> 'entries' else '[]'::jsonb end;

  select count(*)::integer
  into v_target_count
  from jsonb_array_elements(v_entries) as entry
  where (entry ->> 'memberId') = v_account.member_id
    and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
    and nullif(entry ->> 'timeOut', '') is null
    and coalesce(
      nullif(entry ->> 'timeInApprovalStatus', ''),
      case when coalesce(entry ->> 'approvalStatus', 'Approved') in ('Pending', 'Active') then 'Pending' else 'Approved' end
    ) in ('Pending', 'Approved');

  if v_target_count = 0 then
    raise exception 'There is no open Time In request to close.' using errcode = '22023';
  elsif v_target_count > 1 then
    raise exception 'More than one open Time In request was found. Ask the Administrator to correct the duty ledger.' using errcode = 'P0001';
  end if;

  select entry into v_target
  from jsonb_array_elements(v_entries) as entry
  where (entry ->> 'memberId') = v_account.member_id
    and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
    and nullif(entry ->> 'timeOut', '') is null
    and coalesce(
      nullif(entry ->> 'timeInApprovalStatus', ''),
      case when coalesce(entry ->> 'approvalStatus', 'Approved') in ('Pending', 'Active') then 'Pending' else 'Approved' end
    ) in ('Pending', 'Approved')
  order by coalesce(entry ->> 'createdAt', '') desc
  limit 1;

  begin
    v_start_date := (v_target ->> 'date')::date;
  exception when others then
    raise exception 'The open duty session has an invalid start date.' using errcode = '22023';
  end;
  v_start_time := coalesce(v_target ->> 'timeIn', '');
  if v_start_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'The open duty session has an invalid Time In.' using errcode = '22023';
  end if;
  begin
    v_start_at := nullif(v_target ->> 'clockInAt', '')::timestamptz;
  exception when others then
    v_start_at := null;
  end;
  if v_start_at is null then
    v_start_at := ((v_start_date::text || ' ' || v_start_time)::timestamp at time zone 'Asia/Manila');
  end if;
  if v_today <> v_start_date then
    raise exception 'This duty request crossed midnight. Ask the Administrator to correct the record.' using errcode = '22023';
  end if;

  v_minutes := floor(extract(epoch from (v_now - v_start_at)) / 60)::integer;
  if v_minutes <= 0 then
    raise exception 'Time Out must be later than Time In.' using errcode = '22023';
  end if;
  if v_minutes > 960 then
    raise exception 'A single duty session cannot exceed 16 hours.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where (entry ->> 'id') <> (v_target ->> 'id')
      and (entry ->> 'memberId') = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and (entry ->> 'date') = (v_target ->> 'date')
      and coalesce(nullif(entry ->> 'timeInApprovalStatus', ''), 'Approved') <> 'Rejected'
      and coalesce(nullif(entry ->> 'timeOutApprovalStatus', ''), 'Approved') not in ('Rejected', 'Cancelled')
      and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and (entry ->> 'timeIn')::time < v_time_out::time
      and (entry ->> 'timeOut')::time > v_start_time::time
  ) then
    raise exception 'This Time Out would overlap another duty session.' using errcode = '23505';
  end if;

  v_final_description := case when v_description <> '' then v_description else coalesce(v_target ->> 'description', '') end;
  v_final_member_approvers := case when v_member_approvers <> '' then v_member_approvers else coalesce(v_target ->> 'memberApprovers', '') end;
  v_in_status := coalesce(nullif(v_target ->> 'timeInApprovalStatus', ''), 'Pending');
  v_next_overall := case when v_in_status = 'Approved' then 'Active' else 'Pending' end;

  select coalesce(jsonb_agg(
    case
      when (entry ->> 'id') = (v_target ->> 'id') then
        entry || jsonb_build_object(
          'timeOut', v_time_out,
          'clockOutAt', v_now,
          'minutes', v_minutes,
          'description', v_final_description,
          'memberApprovers', v_final_member_approvers,
          'timeOutApprovalStatus', 'Pending',
          'timeOutRequestedAt', v_now,
          'timeOutReviewedAt', '',
          'timeOutReviewedBy', '',
          'approvalStatus', v_next_overall,
          'submittedAt', v_now,
          'punchAudit', (case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end) ||
            jsonb_build_array(jsonb_build_object(
              'id', gen_random_uuid()::text,
              'timestamp', v_now,
              'punchType', 'TimeOut',
              'action', 'Submitted',
              'by', v_account.username
            ))
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_next_entries
  from jsonb_array_elements(v_entries) with ordinality as records(entry, ordinal_position);

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '7'::jsonb, true),
    '{entries}', v_next_entries, true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', v_now,
    'action', 'Submitted Duty Time Out',
    'category', 'Duty Hours',
    'details', (v_target ->> 'date') || ' • ' || v_start_time || '–' || v_time_out || ' • Pending separate approval',
    'account', v_account.display_name,
    'username', v_account.username
  );
  v_activity_log := jsonb_build_array(v_activity) ||
    case when jsonb_typeof(v_activity_log) = 'array' then v_activity_log else '[]'::jsonb end;

  update public.system_state
  set duty_hours = v_duty_hours,
      activity_log = v_activity_log,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_replace_state(p_token text, p_state jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
begin
  v_account_id := public.lso_session_account_id(p_token, true);

  update public.system_state
  set members = case when jsonb_typeof(p_state -> 'members') = 'array' then p_state -> 'members' else members end,
      events = case when jsonb_typeof(p_state -> 'events') = 'array' then p_state -> 'events' else events end,
      attendance = case when jsonb_typeof(p_state -> 'attendance') = 'array' then p_state -> 'attendance' else attendance end,
      duty_hours = case when jsonb_typeof(p_state -> 'duty_hours') = 'object' then p_state -> 'duty_hours' else duty_hours end,
      monthly_reports = case when jsonb_typeof(p_state -> 'monthly_reports') = 'object' then p_state -> 'monthly_reports' else monthly_reports end,
      instruments = case when jsonb_typeof(p_state -> 'instruments') = 'array' then p_state -> 'instruments' else instruments end,
      settings = case when jsonb_typeof(p_state -> 'settings') = 'object' then p_state -> 'settings' else settings end,
      activity_log = case when jsonb_typeof(p_state -> 'activity_log') = 'array' then p_state -> 'activity_log' else activity_log end,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_restore_recovery_point(p_token text, p_recovery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account public.lso_accounts%rowtype;
  v_point public.lso_recovery_points%rowtype;
  v_current jsonb;
begin
  v_account := public.lso_admin_account(p_token);
  select * into v_point from public.lso_recovery_points where id = p_recovery_id for update;
  if not found then raise exception 'The selected recovery point was not found.' using errcode='P0002'; end if;

  select to_jsonb(state) into v_current from public.system_state as state where id=1 for update;
  insert into public.lso_recovery_points(label,reason,snapshot,metadata,created_by_account_id,created_by_username)
  values('Automatic point before restore','Created immediately before restoring '||v_point.label,v_current,jsonb_build_object('type','pre-restore','sourceRecoveryId',v_point.id),v_account.id,v_account.username);

  update public.system_state set
    members = case when jsonb_typeof(v_point.snapshot->'members')='array' then v_point.snapshot->'members' else members end,
    events = case when jsonb_typeof(v_point.snapshot->'events')='array' then v_point.snapshot->'events' else events end,
    attendance = case when jsonb_typeof(v_point.snapshot->'attendance')='array' then v_point.snapshot->'attendance' else attendance end,
    duty_hours = case when jsonb_typeof(v_point.snapshot->'duty_hours')='object' then v_point.snapshot->'duty_hours' else duty_hours end,
    monthly_reports = case when jsonb_typeof(v_point.snapshot->'monthly_reports')='object' then v_point.snapshot->'monthly_reports' else monthly_reports end,
    instruments = case when jsonb_typeof(v_point.snapshot->'instruments')='array' then v_point.snapshot->'instruments' else instruments end,
    settings = case when jsonb_typeof(v_point.snapshot->'settings')='object' then v_point.snapshot->'settings' else settings end,
    activity_log = case when jsonb_typeof(v_point.snapshot->'activity_log')='array' then v_point.snapshot->'activity_log' else activity_log end,
    updated_at = now()
  where id=1;

  update public.lso_recovery_points set restored_at=now(), restored_by_username=v_account.username where id=v_point.id;
  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_review_duty_entry(p_token text, p_entry_id text, p_decision text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id uuid;
  v_admin_username text;
  v_admin_display_name text;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_next_entries jsonb;
  v_target jsonb;
  v_activity_log jsonb;
  v_activity jsonb;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username, display_name
  into v_admin_username, v_admin_display_name
  from public.lso_accounts
  where id = v_admin_id;

  if p_decision not in ('Approved', 'Rejected') then
    raise exception 'Decision must be Approved or Rejected.' using errcode = '22023';
  end if;

  if nullif(btrim(coalesce(p_entry_id, '')), '') is null then
    raise exception 'The duty entry identifier is missing.' using errcode = '22023';
  end if;

  select duty_hours, activity_log
  into v_duty_hours, v_activity_log
  from public.system_state
  where id = 1
  for update;

  if v_duty_hours is null or jsonb_typeof(v_duty_hours) <> 'object' then
    raise exception 'The Duty Hours database is unavailable.' using errcode = 'P0002';
  end if;

  v_entries := case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
    then v_duty_hours -> 'entries' else '[]'::jsonb end;

  select entry
  into v_target
  from jsonb_array_elements(v_entries) as entry
  where entry ->> 'id' = p_entry_id
  limit 1;

  if v_target is null then
    raise exception 'The duty entry could not be found.' using errcode = '22023';
  end if;

  if coalesce(v_target ->> 'approvalStatus', 'Approved') <> 'Pending' then
    raise exception 'This duty entry has already been reviewed.' using errcode = '22023';
  end if;

  if coalesce(v_target ->> 'entryType', 'Duty') <> 'Duty' then
    raise exception 'Only a pending duty entry can be reviewed here.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(
    case
      when entry ->> 'id' = p_entry_id and p_decision = 'Approved' then
        (entry - 'rejectedAt' - 'rejectedBy') || jsonb_build_object(
          'approvalStatus', 'Approved',
          'approvedAt', now(),
          'approvedBy', v_admin_username,
          'reviewedAt', now(),
          'reviewedBy', v_admin_username
        )
      when entry ->> 'id' = p_entry_id and p_decision = 'Rejected' then
        (entry - 'approvedAt' - 'approvedBy') || jsonb_build_object(
          'approvalStatus', 'Rejected',
          'rejectedAt', now(),
          'rejectedBy', v_admin_username,
          'reviewedAt', now(),
          'reviewedBy', v_admin_username
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_next_entries
  from jsonb_array_elements(v_entries)
    with ordinality as records(entry, ordinal_position);

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '5'::jsonb, true),
    '{entries}', v_next_entries, true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', now(),
    'action', p_decision || ' duty entry',
    'category', 'Duty Hours',
    'details', coalesce(v_target ->> 'submittedByUsername', 'member') || ' • ' ||
               coalesce(v_target ->> 'date', '') || ' • ' ||
               coalesce(v_target ->> 'timeIn', '') || '–' || coalesce(v_target ->> 'timeOut', ''),
    'account', v_admin_display_name,
    'username', v_admin_username
  );

  v_activity_log := jsonb_build_array(v_activity) ||
    case when jsonb_typeof(v_activity_log) = 'array' then v_activity_log else '[]'::jsonb end;

  if jsonb_array_length(v_activity_log) > 500 then
    select coalesce(jsonb_agg(item order by ordinal_position), '[]'::jsonb)
    into v_activity_log
    from jsonb_array_elements(v_activity_log) with ordinality as records(item, ordinal_position)
    where ordinal_position <= 500;
  end if;

  update public.system_state
  set duty_hours = v_duty_hours,
      activity_log = v_activity_log,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_review_duty_punch(p_token text, p_entry_id text, p_punch_type text, p_decision text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin_id uuid;
  v_admin_username text;
  v_admin_display_name text;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_next_entries jsonb;
  v_target jsonb;
  v_activity_log jsonb;
  v_activity jsonb;
  v_in_status text;
  v_out_status text;
  v_current_status text;
  v_next_overall text;
  v_now timestamptz := clock_timestamp();
  v_punch_label text;
  v_punch_time text;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username, display_name
  into v_admin_username, v_admin_display_name
  from public.lso_accounts
  where id = v_admin_id;

  if p_punch_type not in ('TimeIn', 'TimeOut') then
    raise exception 'Punch type must be TimeIn or TimeOut.' using errcode = '22023';
  end if;
  if p_decision not in ('Approved', 'Rejected') then
    raise exception 'Decision must be Approved or Rejected.' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_entry_id, '')), '') is null then
    raise exception 'The duty entry identifier is missing.' using errcode = '22023';
  end if;

  select duty_hours, activity_log
  into v_duty_hours, v_activity_log
  from public.system_state
  where id = 1
  for update;

  if v_duty_hours is null or jsonb_typeof(v_duty_hours) <> 'object' then
    raise exception 'The Duty Hours database is unavailable.' using errcode = 'P0002';
  end if;
  v_entries := case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
    then v_duty_hours -> 'entries' else '[]'::jsonb end;

  select entry into v_target
  from jsonb_array_elements(v_entries) as entry
  where (entry ->> 'id') = p_entry_id
  limit 1;

  if v_target is null then
    raise exception 'The duty entry could not be found.' using errcode = '22023';
  end if;
  if coalesce(v_target ->> 'entryType', 'Duty') <> 'Duty' then
    raise exception 'Only Duty Hours punches can be reviewed here.' using errcode = '22023';
  end if;

  v_in_status := coalesce(nullif(v_target ->> 'timeInApprovalStatus', ''),
    case
      when coalesce(v_target ->> 'approvalStatus', 'Approved') = 'Pending' and nullif(v_target ->> 'timeOut', '') is null then 'Pending'
      when coalesce(v_target ->> 'approvalStatus', 'Approved') = 'Rejected' and nullif(v_target ->> 'timeOut', '') is null then 'Rejected'
      else 'Approved'
    end);
  v_out_status := coalesce(nullif(v_target ->> 'timeOutApprovalStatus', ''),
    case
      when nullif(v_target ->> 'timeOut', '') is null then 'Not Submitted'
      when coalesce(v_target ->> 'approvalStatus', 'Approved') = 'Approved' then 'Approved'
      when coalesce(v_target ->> 'approvalStatus', 'Approved') = 'Rejected' then 'Rejected'
      else 'Pending'
    end);
  v_current_status := case when p_punch_type = 'TimeIn' then v_in_status else v_out_status end;

  if v_current_status <> 'Pending' then
    raise exception 'This punch request is no longer pending.' using errcode = '22023';
  end if;
  if p_punch_type = 'TimeOut' and p_decision = 'Approved' and v_in_status <> 'Approved' then
    raise exception 'Approve the linked Time In request before approving Time Out.' using errcode = '22023';
  end if;

  if p_punch_type = 'TimeIn' and p_decision = 'Approved' then
    -- Approval order is chronological. A later Time In cannot become official
    -- while an earlier approved Time In is still missing an approved Time Out.
    if exists (
      select 1
      from jsonb_array_elements(v_entries) as entry
      where (entry ->> 'id') <> p_entry_id
        and (entry ->> 'memberId') = (v_target ->> 'memberId')
        and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
        and coalesce(nullif(entry ->> 'timeInApprovalStatus', ''),
          case when coalesce(entry ->> 'approvalStatus', '') in ('Active', 'Approved') then 'Approved' else 'Pending' end) = 'Approved'
        and coalesce(nullif(entry ->> 'timeOutApprovalStatus', ''),
          case when coalesce(entry ->> 'approvalStatus', '') = 'Approved' then 'Approved' else 'Not Submitted' end) not in ('Approved', 'Rejected', 'Cancelled')
        and coalesce(nullif(entry ->> 'timeInApprovalStatus', ''), 'Approved') <> 'Rejected'
        and coalesce(nullif(entry ->> 'clockInAt', ''), nullif(entry ->> 'createdAt', '')) <
            coalesce(nullif(v_target ->> 'clockInAt', ''), nullif(v_target ->> 'createdAt', ''))
    ) then
      raise exception 'Approve or resolve the earlier session Time Out before approving this Time In.' using errcode = '22023';
    end if;
  end if;

  if p_punch_type = 'TimeOut' and p_decision = 'Approved' then
    -- Prevent an approved session from overlapping another approved session.
    if exists (
      select 1
      from jsonb_array_elements(v_entries) as entry
      where (entry ->> 'id') <> p_entry_id
        and (entry ->> 'memberId') = (v_target ->> 'memberId')
        and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
        and (entry ->> 'date') = (v_target ->> 'date')
        and coalesce(nullif(entry ->> 'timeInApprovalStatus', ''), 'Approved') = 'Approved'
        and coalesce(nullif(entry ->> 'timeOutApprovalStatus', ''),
          case when coalesce(entry ->> 'approvalStatus', '') = 'Approved' then 'Approved' else 'Not Submitted' end) = 'Approved'
        and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        and (v_target ->> 'timeIn') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        and (v_target ->> 'timeOut') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        and (entry ->> 'timeIn')::time < (v_target ->> 'timeOut')::time
        and (entry ->> 'timeOut')::time > (v_target ->> 'timeIn')::time
    ) then
      raise exception 'This approved Time Out would create an overlapping duty session.' using errcode = '23505';
    end if;
  end if;

  v_punch_label := case when p_punch_type = 'TimeOut' then 'Time Out' else 'Time In' end;
  v_punch_time := case when p_punch_type = 'TimeOut' then v_target ->> 'timeOut' else v_target ->> 'timeIn' end;

  select coalesce(jsonb_agg(
    case
      when (entry ->> 'id') <> p_entry_id then entry
      when p_punch_type = 'TimeIn' and p_decision = 'Approved' then
        entry || jsonb_build_object(
          'timeInApprovalStatus', 'Approved',
          'timeInReviewedAt', v_now,
          'timeInReviewedBy', v_admin_username,
          'approvalStatus', case when v_out_status = 'Approved' then 'Approved' else 'Active' end,
          'approvedAt', case when v_out_status = 'Approved' then v_now::text else coalesce(nullif(entry ->> 'approvedAt', ''), '') end,
          'approvedBy', case when v_out_status = 'Approved' then v_admin_username else coalesce(entry ->> 'approvedBy', '') end,
          'reviewedAt', v_now,
          'reviewedBy', v_admin_username,
          'punchAudit', (case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end) ||
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'timestamp', v_now, 'punchType', 'TimeIn', 'action', 'Approved', 'by', v_admin_username))
        )
      when p_punch_type = 'TimeIn' and p_decision = 'Rejected' then
        entry || jsonb_build_object(
          'timeInApprovalStatus', 'Rejected',
          'timeInReviewedAt', v_now,
          'timeInReviewedBy', v_admin_username,
          'approvalStatus', 'Rejected',
          'rejectedAt', v_now,
          'rejectedBy', v_admin_username,
          'reviewedAt', v_now,
          'reviewedBy', v_admin_username,
          'punchAudit', (case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end) ||
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'timestamp', v_now, 'punchType', 'TimeIn', 'action', 'Rejected', 'by', v_admin_username))
        )
      when p_punch_type = 'TimeOut' and p_decision = 'Approved' then
        entry || jsonb_build_object(
          'timeOutApprovalStatus', 'Approved',
          'timeOutReviewedAt', v_now,
          'timeOutReviewedBy', v_admin_username,
          'approvalStatus', 'Approved',
          'approvedAt', v_now,
          'approvedBy', v_admin_username,
          'reviewedAt', v_now,
          'reviewedBy', v_admin_username,
          'punchAudit', (case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end) ||
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'timestamp', v_now, 'punchType', 'TimeOut', 'action', 'Approved', 'by', v_admin_username))
        )
      when p_punch_type = 'TimeOut' and p_decision = 'Rejected' then
        entry || jsonb_build_object(
          'timeOutApprovalStatus', 'Rejected',
          'timeOutReviewedAt', v_now,
          'timeOutReviewedBy', v_admin_username,
          'approvalStatus', 'Rejected',
          'rejectedAt', v_now,
          'rejectedBy', v_admin_username,
          'reviewedAt', v_now,
          'reviewedBy', v_admin_username,
          'punchAudit', (case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end) ||
            jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'timestamp', v_now, 'punchType', 'TimeOut', 'action', 'Rejected', 'by', v_admin_username))
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_next_entries
  from jsonb_array_elements(v_entries) with ordinality as records(entry, ordinal_position);

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '7'::jsonb, true),
    '{entries}', v_next_entries, true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', v_now,
    'action', p_decision || ' Duty ' || v_punch_label,
    'category', 'Duty Hours',
    'details', coalesce(v_target ->> 'submittedByUsername', 'member') || ' • ' ||
               coalesce(v_target ->> 'date', '') || ' • ' || coalesce(v_punch_time, ''),
    'account', v_admin_display_name,
    'username', v_admin_username
  );
  v_activity_log := jsonb_build_array(v_activity) ||
    case when jsonb_typeof(v_activity_log) = 'array' then v_activity_log else '[]'::jsonb end;

  update public.system_state
  set duty_hours = v_duty_hours,
      activity_log = v_activity_log,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_submit_duty_entry(p_token text, p_semester text, p_period text, p_date text, p_time_in text, p_time_out text, p_description text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_member jsonb;
  v_current_period text;
  v_entry_period text;
  v_duty_date date;
  v_minutes integer;
  v_description text;
  v_entry jsonb;
  v_entry_id text := gen_random_uuid()::text;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_activity_log jsonb;
  v_activity jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account
  from public.lso_accounts
  where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may submit a self-service duty entry.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  if p_semester not in ('First Semester', 'Second Semester') then
    raise exception 'Select a valid duty semester.' using errcode = '22023';
  end if;

  if p_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end if;

  begin
    v_duty_date := p_date::date;
  exception when others then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end;

  if v_duty_date > public.lso_local_date() then
    raise exception 'A future duty date cannot be submitted.' using errcode = '22023';
  end if;

  if p_time_in !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or p_time_out !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Enter valid Time In and Time Out values.' using errcode = '22023';
  end if;

  if p_time_out::time <= p_time_in::time then
    raise exception 'Time Out must be later than Time In for a same-day duty entry.' using errcode = '22023';
  end if;

  v_minutes := floor(extract(epoch from (p_time_out::time - p_time_in::time)) / 60)::integer;
  if v_minutes <= 0 or v_minutes > 960 then
    raise exception 'A duty entry must be longer than 0 minutes and no longer than 16 hours.' using errcode = '22023';
  end if;

  v_description := left(btrim(coalesce(p_description, '')), 160);
  if char_length(v_description) < 3 then
    raise exception 'Enter a duty assignment or description with at least 3 characters.' using errcode = '22023';
  end if;

  -- Lock the shared row. This prevents two simultaneous submissions from
  -- passing duplicate/overlap validation and overwriting each other.
  select duty_hours, activity_log
  into v_duty_hours, v_activity_log
  from public.system_state
  where id = 1
  for update;

  if v_duty_hours is null or jsonb_typeof(v_duty_hours) <> 'object' then
    v_duty_hours := '{"version":5,"commitments":{},"entries":[]}'::jsonb;
  end if;
  v_entries := case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
    then v_duty_hours -> 'entries' else '[]'::jsonb end;

  select member
  into v_member
  from public.system_state as state,
       jsonb_array_elements(coalesce(state.members, '[]'::jsonb)) as member
  where state.id = 1
    and member ->> 'id' = v_account.member_id
  limit 1;

  if v_member is null then
    raise exception 'The linked member record could not be found.' using errcode = '42501';
  end if;

  v_current_period := public.lso_member_period_on_date(v_member, public.lso_local_date());
  if v_current_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'The linked member is no longer in the Trainee or Probationary Period.' using errcode = '42501';
  end if;

  v_entry_period := public.lso_member_period_on_date(v_member, v_duty_date);
  if v_entry_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'The selected date is outside this member''s Trainee or Probationary period.' using errcode = '22023';
  end if;

  -- Reject exact duplicates and any overlapping non-rejected duty interval.
  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where entry ->> 'memberId' = v_account.member_id
      and entry ->> 'entryType' = 'Duty'
      and entry ->> 'date' = p_date
      and coalesce(entry ->> 'approvalStatus', 'Approved') <> 'Rejected'
      and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and (entry ->> 'timeIn')::time < p_time_out::time
      and (entry ->> 'timeOut')::time > p_time_in::time
  ) then
    raise exception 'This duty time overlaps an existing pending or approved entry for the same date.' using errcode = '23505';
  end if;

  v_entry := jsonb_build_object(
    'id', v_entry_id,
    'memberId', v_account.member_id,
    'semester', p_semester,
    'period', v_entry_period,
    'entryType', 'Duty',
    'date', p_date,
    'minutes', v_minutes,
    'timeIn', p_time_in,
    'timeOut', p_time_out,
    'description', v_description,
    'approvalStatus', 'Pending',
    'submittedByAccountId', v_account.id,
    'submittedByUsername', v_account.username,
    'submittedByRole', v_account.role,
    'submittedAt', now(),
    'createdAt', now(),
    'createdBy', v_account.display_name,
    'createdByUsername', v_account.username
  );

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '5'::jsonb, true),
    '{entries}',
    v_entries || jsonb_build_array(v_entry),
    true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', now(),
    'action', 'Submitted duty entry',
    'category', 'Duty Hours',
    'details', p_date || ' • ' || p_time_in || '–' || p_time_out || ' • Pending approval',
    'account', v_account.display_name,
    'username', v_account.username
  );

  v_activity_log := jsonb_build_array(v_activity) ||
    case when jsonb_typeof(v_activity_log) = 'array' then v_activity_log else '[]'::jsonb end;

  if jsonb_array_length(v_activity_log) > 500 then
    select coalesce(jsonb_agg(item order by ordinal_position), '[]'::jsonb)
    into v_activity_log
    from jsonb_array_elements(v_activity_log) with ordinality as records(item, ordinal_position)
    where ordinal_position <= 500;
  end if;

  update public.system_state
  set duty_hours = v_duty_hours,
      activity_log = v_activity_log,
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_update_state_core(p_token text, p_column text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account_id uuid;
  v_role text;
  v_existing jsonb;
  v_old jsonb;
  v_new jsonb;
  v_key text;
  v_value jsonb;
  v_event jsonb;
  v_allowed boolean;
begin
  -- Validate session for all authenticated accounts (false = non-admin allowed)
  v_account_id := public.lso_session_account_id(p_token, false);
  select role into v_role from public.lso_accounts where id = v_account_id;

  if p_column in ('members', 'events', 'attendance', 'instruments', 'activity_log')
     and jsonb_typeof(p_value) <> 'array' then
    raise exception 'The selected data collection must be a JSON array.' using errcode = '22023';
  end if;
  if p_column in ('settings', 'duty_hours', 'monthly_reports')
     and jsonb_typeof(p_value) <> 'object' then
    raise exception 'The selected data collection must be a JSON object.' using errcode = '22023';
  end if;

  v_allowed := public.lso_role_can(v_role, 'write_column', p_column);
  if not v_allowed then
    raise exception 'This account role cannot update the selected system area.' using errcode = '42501';
  end if;

  select case p_column
    when 'members' then members
    when 'events' then events
    when 'attendance' then attendance
    when 'duty_hours' then duty_hours
    when 'monthly_reports' then monthly_reports
    when 'instruments' then instruments
    when 'settings' then settings
    when 'activity_log' then activity_log
  end
  into v_existing
  from public.system_state
  where id = 1
  for update;

  -- Events protection: Non-administrator roles may create and edit activities,
  -- but cannot delete them or alter finalized/unlocked attendance workflows.
  if v_role <> 'Administrator' and p_column = 'events' then
    for v_old in select value from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) loop
      select value into v_new
      from jsonb_array_elements(p_value)
      where value ->> 'id' = v_old ->> 'id'
      limit 1;
      if v_new is null then
        raise exception 'Only the Administrator can delete activities.' using errcode = '42501';
      end if;
      for v_key, v_value in
        select key, value from jsonb_each(coalesce(v_old -> 'attendanceWorkflows', '{}'::jsonb))
        where value ->> 'state' = 'Finalized'
           or nullif(value ->> 'unlockedAt', '') is not null
           or nullif(value ->> 'finalizedAt', '') is not null
      loop
        if coalesce(v_new -> 'attendanceWorkflows' -> v_key, 'null'::jsonb) is distinct from v_value then
          raise exception 'Only the Administrator can finalize, unlock, or modify a protected attendance workflow.' using errcode = '42501';
        end if;
      end loop;
      for v_key, v_value in
        select key, value from jsonb_each(coalesce(v_new -> 'attendanceWorkflows', '{}'::jsonb))
        where value ->> 'state' = 'Finalized'
           or nullif(value ->> 'unlockedAt', '') is not null
           or nullif(value ->> 'finalizedAt', '') is not null
      loop
        if coalesce(v_old -> 'attendanceWorkflows' -> v_key, 'null'::jsonb) is distinct from v_value then
          raise exception 'Only the Administrator can finalize, unlock, or modify a protected attendance workflow.' using errcode = '42501';
        end if;
      end loop;
    end loop;

    -- A newly created activity must begin with Draft attendance workflows.
    for v_new in select value from jsonb_array_elements(p_value) loop
      select value into v_old
      from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb))
      where value ->> 'id' = v_new ->> 'id'
      limit 1;
      for v_key, v_value in
        select key, value from jsonb_each(coalesce(v_new -> 'attendanceWorkflows', '{}'::jsonb))
        where value ->> 'state' = 'Finalized'
           or nullif(value ->> 'unlockedAt', '') is not null
           or nullif(value ->> 'finalizedAt', '') is not null
      loop
        if v_old is null
           or coalesce(v_old -> 'attendanceWorkflows' -> v_key, 'null'::jsonb) is distinct from v_value then
          raise exception 'Only the Administrator can create, finalize, unlock, or modify a protected attendance workflow.' using errcode = '42501';
        end if;
      end loop;
    end loop;
  end if;

  -- Attendance protection: Draft editors cannot change attendance rows whose
  -- matching roster is currently Finalized.
  if v_role <> 'Administrator' and p_column = 'attendance' then
    for v_old in select value from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) loop
      select value into v_event
      from public.system_state as state,
           jsonb_array_elements(coalesce(state.events, '[]'::jsonb)) as event
      where state.id = 1 and event ->> 'id' = v_old ->> 'eventId'
      limit 1;
      v_key := coalesce(nullif(v_old ->> 'attendanceGroup', ''), 'Official Members') || '::' ||
               coalesce(nullif(v_old ->> 'rosterModeAtEdit', ''), 'Current');
      if coalesce(v_event -> 'attendanceWorkflows' -> v_key ->> 'state', 'Draft') = 'Finalized'
         and not exists (select 1 from jsonb_array_elements(p_value) as item where item = v_old) then
        raise exception 'Finalized attendance is locked. The Administrator must unlock it before corrections.' using errcode = '42501';
      end if;
    end loop;
    for v_new in select value from jsonb_array_elements(p_value) loop
      select value into v_event
      from public.system_state as state,
           jsonb_array_elements(coalesce(state.events, '[]'::jsonb)) as event
      where state.id = 1 and event ->> 'id' = v_new ->> 'eventId'
      limit 1;
      v_key := coalesce(nullif(v_new ->> 'attendanceGroup', ''), 'Official Members') || '::' ||
               coalesce(nullif(v_new ->> 'rosterModeAtEdit', ''), 'Current');
      if coalesce(v_event -> 'attendanceWorkflows' -> v_key ->> 'state', 'Draft') = 'Finalized'
         and not exists (select 1 from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) as item where item = v_new) then
        raise exception 'Finalized attendance is locked. The Administrator must unlock it before corrections.' using errcode = '42501';
      end if;
    end loop;
  end if;

  -- Attendance calendar permission: Non-administrator roles may only modify rows
  -- belonging to attendance calendars assigned to their role in Role & Permission Center
  -- (e.g. Official Members, Trainee Members, Probationary Members).
  -- This replaces the obsolete hardcoded "limited to Trainee and Probationary" restriction.
  if v_role <> 'Administrator' and p_column = 'attendance' then
    for v_old in select value from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) loop
      if not exists (select 1 from jsonb_array_elements(p_value) as item where item = v_old) then
        if not public.lso_role_can(v_role, 'attendance_group', coalesce(nullif(v_old ->> 'attendanceGroup', ''), 'Official Members')) then
          raise exception 'This account role is not assigned to the selected Attendance calendar.' using errcode = '42501';
        end if;
      end if;
    end loop;
    for v_new in select value from jsonb_array_elements(p_value) loop
      if not exists (select 1 from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) as item where item = v_new) then
        if not public.lso_role_can(v_role, 'attendance_group', coalesce(nullif(v_new ->> 'attendanceGroup', ''), 'Official Members')) then
          raise exception 'This account role is not assigned to the selected Attendance calendar.' using errcode = '42501';
        end if;
      end if;
    end loop;
  end if;

  -- Settings protection: Membership may update monthly reports in settings,
  -- but cannot change system-wide automation settings.
  if v_role = 'Membership' and p_column = 'settings' then
    if (p_value - '__lso_monthly_reports_v1') is distinct from (coalesce(v_existing, '{}'::jsonb) - '__lso_monthly_reports_v1') then
      raise exception 'Only the Administrator can change system settings.' using errcode = '42501';
    end if;
  end if;

  -- Duty Hours protection: Membership Duty Hours changes are restricted to
  -- members currently in Trainee or Probationary Period.
  if v_role = 'Membership' and p_column = 'duty_hours' then
    for v_old in select value from jsonb_array_elements(coalesce(v_existing -> 'entries', '[]'::jsonb)) loop
      select exists (
        select 1 from public.system_state as st,
          jsonb_array_elements(coalesce(st.members, '[]'::jsonb)) as member
        where st.id = 1 and member ->> 'id' = v_old ->> 'memberId'
          and public.lso_member_period_on_date(member, public.lso_local_date()) in ('Trainee Period', 'Probationary Period')
      ) into v_allowed;
      if not v_allowed and not exists (select 1 from jsonb_array_elements(coalesce(p_value -> 'entries', '[]'::jsonb)) as item where item = v_old) then
        raise exception 'Membership Duty Hours access is limited to current Trainee and Probationary members.' using errcode = '42501';
      end if;
    end loop;
    for v_new in select value from jsonb_array_elements(coalesce(p_value -> 'entries', '[]'::jsonb)) loop
      select exists (
        select 1 from public.system_state as st,
          jsonb_array_elements(coalesce(st.members, '[]'::jsonb)) as member
        where st.id = 1 and member ->> 'id' = v_new ->> 'memberId'
          and public.lso_member_period_on_date(member, public.lso_local_date()) in ('Trainee Period', 'Probationary Period')
      ) into v_allowed;
      if not v_allowed and not exists (select 1 from jsonb_array_elements(coalesce(v_existing -> 'entries', '[]'::jsonb)) as item where item = v_new) then
        raise exception 'Membership Duty Hours access is limited to current Trainee and Probationary members.' using errcode = '42501';
      end if;
    end loop;
    for v_key, v_value in select key, value from jsonb_each(coalesce(v_existing -> 'commitments', '{}'::jsonb)) loop
      select exists (
        select 1 from public.system_state as st,
          jsonb_array_elements(coalesce(st.members, '[]'::jsonb)) as member
        where st.id = 1 and member ->> 'id' = v_key
          and public.lso_member_period_on_date(member, public.lso_local_date()) in ('Trainee Period', 'Probationary Period')
      ) into v_allowed;
      if not v_allowed and coalesce(p_value -> 'commitments' -> v_key, 'null'::jsonb) is distinct from v_value then
        raise exception 'Membership Duty Hours access is limited to current Trainee and Probationary members.' using errcode = '42501';
      end if;
    end loop;
    for v_key, v_value in select key, value from jsonb_each(coalesce(p_value -> 'commitments', '{}'::jsonb)) loop
      select exists (
        select 1 from public.system_state as st,
          jsonb_array_elements(coalesce(st.members, '[]'::jsonb)) as member
        where st.id = 1 and member ->> 'id' = v_key
          and public.lso_member_period_on_date(member, public.lso_local_date()) in ('Trainee Period', 'Probationary Period')
      ) into v_allowed;
      if not v_allowed and coalesce(v_existing -> 'commitments' -> v_key, 'null'::jsonb) is distinct from v_value then
        raise exception 'Membership Duty Hours access is limited to current Trainee and Probationary members.' using errcode = '42501';
      end if;
    end loop;
  end if;

  case p_column
    when 'members' then update public.system_state set members = p_value, updated_at = now() where id = 1;
    when 'events' then update public.system_state set events = p_value, updated_at = now() where id = 1;
    when 'attendance' then update public.system_state set attendance = p_value, updated_at = now() where id = 1;
    when 'duty_hours' then update public.system_state set duty_hours = p_value, updated_at = now() where id = 1;
    when 'monthly_reports' then update public.system_state set monthly_reports = p_value, updated_at = now() where id = 1;
    when 'instruments' then update public.system_state set instruments = p_value, updated_at = now() where id = 1;
    when 'settings' then update public.system_state set settings = p_value, updated_at = now() where id = 1;
    when 'activity_log' then update public.system_state set activity_log = p_value, updated_at = now() where id = 1;
    else raise exception 'Unsupported shared-data column.' using errcode = '22023';
  end case;

  return public.lso_get_state(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_update_state(p_token text, p_column text, p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_existing jsonb;
begin
  -- Validate session for all authenticated accounts (false = non-admin allowed)
  perform public.lso_session_account_id(p_token, false);

  -- Read the stored column through the row image
  select to_jsonb(state_row) -> p_column
    into v_existing
    from public.system_state as state_row
   where id = 1;

  -- No-op guard: identical payload -> skip redundant write and return current state
  if v_existing is not null and v_existing = p_value then
    return public.lso_get_state(p_token);
  end if;

  return public.lso_update_state_core(p_token, p_column, p_value);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_update_state_v69(p_token text, p_column text, p_value jsonb, p_expected_version bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_existing jsonb;
  v_versions jsonb;
  v_result jsonb;
  v_next bigint;
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

  v_result := public.lso_update_state(p_token, p_column, p_value);

  -- Advance the column version for diagnostics
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_v69_capabilities(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.lso_v89_columns_for_actions(p_actions text[])
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actions text[] := coalesce(p_actions, array[]::text[]);
  v_columns text[] := array[]::text[];
begin
  if 'manageMembers' = any(v_actions) or 'generateContract' = any(v_actions) then
    v_columns := array_append(v_columns, 'members');
  end if;
  if 'manageEvents' = any(v_actions) or 'deleteEvents' = any(v_actions) then
    v_columns := array_append(v_columns, 'events');
  end if;
  if 'saveDraftAttendance' = any(v_actions) or 'finalizeAttendance' = any(v_actions)
     or 'unlockAttendance' = any(v_actions) or 'deleteEvents' = any(v_actions) then
    v_columns := array_append(v_columns, 'attendance');
  end if;
  if 'finalizeAttendance' = any(v_actions) or 'unlockAttendance' = any(v_actions) then
    v_columns := array_append(v_columns, 'settings');
  end if;
  if 'manageDutyHours' = any(v_actions) or 'manageDutyRequirements' = any(v_actions) then
    v_columns := array_append(v_columns, 'duty_hours');
  end if;
  if 'editMonthlyReport' = any(v_actions) or 'finalizeMonthlyReport' = any(v_actions)
     or 'reopenMonthlyReport' = any(v_actions) then
    v_columns := array_cat(v_columns, array['monthly_reports','monthly_reports_compat','settings']);
  end if;
  if 'writeActivityLog' = any(v_actions) then
    v_columns := array_append(v_columns, 'activity_log');
  end if;
  select coalesce(array_agg(distinct item order by item), array[]::text[])
    into v_columns
  from unnest(v_columns) as item;
  return coalesce(v_columns, array[]::text[]);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_v82_columns_for_actions(p_actions text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select public.lso_v89_columns_for_actions(p_actions);
$function$;

CREATE OR REPLACE FUNCTION public.lso_v89_write_role_configuration(p_role text, p_landing_view text, p_views text[], p_actions text[], p_attendance_groups text[], p_updated_by text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_value text;
  v_columns text[];
begin
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode = '22023';
  end if;
  v_columns := public.lso_v89_columns_for_actions(p_actions);

  delete from public.lso_role_permissions
  where role_name = p_role
    and permission_key in ('view','action','attendance_group','write_column');

  foreach v_value in array coalesce(p_views, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'view',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;
  foreach v_value in array coalesce(p_actions, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'action',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;
  foreach v_value in array coalesce(p_attendance_groups, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'attendance_group',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;
  foreach v_value in array coalesce(v_columns, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'write_column',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;

  insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
  values(p_role,p_landing_view,now(),coalesce(nullif(p_updated_by,''),'V89'))
  on conflict(role_name) do update
  set landing_view=excluded.landing_view,
      updated_at=excluded.updated_at,
      updated_by=excluded.updated_by;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_apply_default_role_configuration(p_role text, p_updated_by text DEFAULT 'migration-009'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_config jsonb;
begin
  v_config := public.lso_default_role_configuration(p_role);
  if v_config is null then
    raise exception 'Unknown LSO account role.' using errcode = '22023';
  end if;
  perform public.lso_v89_write_role_configuration(
    p_role,
    v_config ->> 'landingView',
    array(select jsonb_array_elements_text(v_config -> 'views')),
    array(select jsonb_array_elements_text(v_config -> 'actions')),
    array(select jsonb_array_elements_text(v_config -> 'attendanceGroups')),
    coalesce(nullif(p_updated_by,''),'migration-009')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_reset_role_permissions(p_token text, p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin public.lso_accounts%rowtype;
  v_admin_id uuid;
begin
  v_admin_id := public.lso_session_account_id(p_token,true);
  select * into v_admin from public.lso_accounts where id = v_admin_id;
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode = '22023';
  end if;
  perform public.lso_apply_default_role_configuration(p_role, v_admin.username);
  return public.lso_get_permission_center(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_save_role_permissions(p_token text, p_role text, p_landing_view text, p_views jsonb, p_actions jsonb, p_attendance_groups jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_admin public.lso_accounts%rowtype;
  v_admin_id uuid;
  v_views text[];
  v_actions text[];
  v_groups text[];
begin
  v_admin_id := public.lso_session_account_id(p_token,true);
  select * into v_admin from public.lso_accounts where id = v_admin_id;

  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_views
  from jsonb_array_elements_text(coalesce(p_views,'[]'::jsonb)) as value
  where value in ('dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView','ownAttendanceView');
  if coalesce(array_length(v_views,1),0) = 0 then
    raise exception 'Assign at least one visible module.' using errcode = '22023';
  end if;
  if not (coalesce(p_landing_view,'') = any(v_views)) then
    raise exception 'The landing page must be one of the assigned modules.' using errcode = '22023';
  end if;
  if 'ownAttendanceView' = any(v_views) and p_role <> 'Trainee/Probationary' then
    raise exception 'My Attendance is identity-bound to Trainee/Probationary accounts only.' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_actions
  from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb)) as value
  where value in (
    'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
    'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
    'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
    'writeActivityLog','manageAccessibility','selfDutyPunch'
  );
  if 'selfDutyPunch' = any(v_actions) and p_role <> 'Trainee/Probationary' then
    raise exception 'Personal Duty punches are identity-bound to Trainee/Probationary accounts only.' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_groups
  from jsonb_array_elements_text(coalesce(p_attendance_groups,'[]'::jsonb)) as value
  where value in ('Official Members','Trainee Members','Probationary Members');

  if 'attendanceView' = any(v_views) and coalesce(array_length(v_groups,1),0) = 0 then
    raise exception 'Attendance access requires at least one assigned Attendance calendar.' using errcode = '22023';
  end if;

  if 'manageMembers' = any(v_actions) and not ('membersView' = any(v_views)) then
    raise exception 'Manage member records requires the Members module.' using errcode = '22023';
  end if;
  if 'generateContract' = any(v_actions) and not ('contractView' = any(v_views)) then
    raise exception 'Generate contracts requires the Contract module.' using errcode = '22023';
  end if;
  if ('editMonthlyReport' = any(v_actions) or 'finalizeMonthlyReport' = any(v_actions) or 'reopenMonthlyReport' = any(v_actions))
     and not ('monthlyReportView' = any(v_views)) then
    raise exception 'Monthly Report actions require the Monthly Report module.' using errcode = '22023';
  end if;
  if ('manageEvents' = any(v_actions) or 'deleteEvents' = any(v_actions) or 'saveDraftAttendance' = any(v_actions)
      or 'finalizeAttendance' = any(v_actions) or 'unlockAttendance' = any(v_actions))
     and not ('attendanceView' = any(v_views)) then
    raise exception 'Attendance actions require the Attendance module.' using errcode = '22023';
  end if;
  if ('reviewDutyPunches' = any(v_actions) or 'manageDutyHours' = any(v_actions)
      or 'manageDutyRequirements' = any(v_actions) or 'certifyDutyHours' = any(v_actions)
      or 'selfDutyPunch' = any(v_actions)) and not ('dutyHoursView' = any(v_views)) then
    raise exception 'Duty Hours actions require the Duty Hours module.' using errcode = '22023';
  end if;

  perform public.lso_v89_write_role_configuration(
    p_role, p_landing_view, v_views, v_actions, v_groups, v_admin.username
  );
  return public.lso_get_permission_center(p_token);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_system_health(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_account public.lso_accounts%rowtype;
  v_state public.system_state%rowtype;
  v_latest_recovery timestamptz;
  v_unresolved_errors integer := 0;
  v_recovery_count integer := 0;
  v_migrations jsonb;
  v_checks jsonb;
begin
  v_account := public.lso_admin_account(p_token);
  select * into v_state from public.system_state where id = 1;
  select max(created_at), count(*)::integer into v_latest_recovery, v_recovery_count from public.lso_recovery_points;
  select count(*)::integer into v_unresolved_errors from public.lso_system_errors where resolved_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'key', migration_key,
    'version', version_number,
    'title', title,
    'checksum', checksum,
    'appliedAt', applied_at,
    'appliedBy', applied_by,
    'notes', notes
  ) order by version_number), '[]'::jsonb)
  into v_migrations
  from public.lso_schema_migrations;

  v_checks := jsonb_build_array(
    jsonb_build_object('id','accounts-table','label','Accounts table','ok',to_regclass('public.lso_accounts') is not null),
    jsonb_build_object('id','sessions-table','label','Sessions table','ok',to_regclass('public.lso_sessions') is not null),
    jsonb_build_object('id','state-table','label','Shared system state','ok',to_regclass('public.system_state') is not null),
    jsonb_build_object('id','member-link','label','Account member linkage','ok',exists(select 1 from information_schema.columns where table_schema='public' and table_name='lso_accounts' and column_name='member_id')),
    jsonb_build_object('id','monthly-reports','label','Monthly Reports storage','ok',exists(select 1 from information_schema.columns where table_schema='public' and table_name='system_state' and column_name='monthly_reports')),
    jsonb_build_object('id','duty-time-in','label','Duty Time In function','ok',to_regprocedure('public.lso_duty_time_in(text,text,text,text)') is not null),
    jsonb_build_object('id','duty-time-out','label','Duty Time Out function','ok',to_regprocedure('public.lso_duty_time_out(text,text,text)') is not null),
    jsonb_build_object('id','duty-review','label','Separate punch review','ok',to_regprocedure('public.lso_review_duty_punch(text,text,text,text)') is not null),
    jsonb_build_object('id','recovery','label','Recovery Center','ok',to_regclass('public.lso_recovery_points') is not null),
    jsonb_build_object('id','error-log','label','System error log','ok',to_regclass('public.lso_system_errors') is not null),
    jsonb_build_object('id','permission-manifest','label','Server permission manifest','ok',to_regclass('public.lso_role_permissions') is not null and to_regprocedure('public.lso_role_can(text,text,text)') is not null),
    jsonb_build_object('id','permission-center','label','Dynamic Role & Permission Center','ok',to_regclass('public.lso_role_profiles') is not null and to_regprocedure('public.lso_get_permission_center(text)') is not null and to_regprocedure('public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb)') is not null)
  );

  return jsonb_build_object(
    'ok', true,
    'databaseVersion', '009_dynamic_role_permissions',
    'targetMigration', 9,
    'serverTime', clock_timestamp(),
    'philippinesDate', to_char(clock_timestamp() at time zone 'Asia/Manila', 'YYYY-MM-DD'),
    'stateUpdatedAt', v_state.updated_at,
    'counts', jsonb_build_object(
      'members', case when jsonb_typeof(v_state.members)='array' then jsonb_array_length(v_state.members) else 0 end,
      'events', case when jsonb_typeof(v_state.events)='array' then jsonb_array_length(v_state.events) else 0 end,
      'attendance', case when jsonb_typeof(v_state.attendance)='array' then jsonb_array_length(v_state.attendance) else 0 end,
      'dutyEntries', case when jsonb_typeof(v_state.duty_hours->'entries')='array' then jsonb_array_length(v_state.duty_hours->'entries') else 0 end,
      'accounts', (select count(*) from public.lso_accounts),
      'recoveryPoints', v_recovery_count,
      'unresolvedErrors', v_unresolved_errors
    ),
    'latestRecoveryAt', v_latest_recovery,
    'migrations', v_migrations,
    'checks', v_checks,
    'requestedBy', v_account.username
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_v82_write_role_configuration(p_role text, p_landing_view text, p_views text[], p_actions text[], p_attendance_groups text[], p_updated_by text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform public.lso_v89_write_role_configuration(p_role,p_landing_view,p_views,p_actions,p_attendance_groups,p_updated_by);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lso_v89_repair_role(p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_default jsonb;
  v_baseline_views text[];
  v_baseline_actions text[];
  v_baseline_groups text[];
  v_has_configuration boolean;
  v_landing text;
  v_actions text[];
  v_columns text[];
  v_value text;
begin
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'Unknown configurable LSO role.' using errcode = '22023';
  end if;
  v_default := public.lso_default_role_configuration(p_role);

  select exists(
    select 1 from public.lso_role_profiles where role_name = p_role
    union all
    select 1 from public.lso_role_permissions where role_name = p_role
  ) into v_has_configuration;

  if not v_has_configuration then
    perform public.lso_apply_default_role_configuration(p_role,'V89 default seed');
    return jsonb_build_object('role',p_role,'seeded',true,'repaired',true);
  end if;

  -- Guarantee the minimum operational grants for every configured role.
  v_baseline_views := case p_role
    when 'Membership' then array['dashboardView','membersView','contractView','monthlyReportView','attendanceView','dutyHoursView']
    when 'General Secretary' then array['dashboardView','membersView','attendanceView','dutyHoursView']
    when 'Staff Account' then array['dashboardView','membersView','attendanceView','dutyHoursView']
    else array['dutyHoursView','ownAttendanceView']
  end;
  v_baseline_actions := case p_role
    when 'Membership' then array['manageMembers','generateContract','editMonthlyReport','manageEvents','saveDraftAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility']
    when 'General Secretary' then array['manageEvents','saveDraftAttendance','reviewDutyPunches','writeActivityLog','manageAccessibility']
    when 'Staff Account' then array['reviewDutyPunches','manageAccessibility']
    else array['selfDutyPunch','manageAccessibility']
  end;
  v_baseline_groups := case p_role
    when 'Trainee/Probationary' then array[]::text[]
    else array['Official Members','Trainee Members','Probationary Members']
  end;

  foreach v_value in array v_baseline_views loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'view',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;
  foreach v_value in array v_baseline_actions loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'action',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;
  foreach v_value in array v_baseline_groups loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'attendance_group',v_value,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true, updated_at=excluded.updated_at;
  end loop;

  select landing_view into v_landing from public.lso_role_profiles where role_name = p_role;
  if v_landing is null or not exists (
    select 1 from jsonb_array_elements_text(v_default -> 'views') as allowed_view where allowed_view = v_landing
  ) then
    v_landing := v_default ->> 'landingView';
  end if;
  insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
  values(p_role,v_landing,now(),'V89 repair')
  on conflict(role_name) do update
  set landing_view=excluded.landing_view, updated_at=excluded.updated_at, updated_by=excluded.updated_by;

  -- Derive write columns from the CURRENT saved actions for this role. This is
  -- what reconnects custom grants to the shared database writer.
  select coalesce(array_agg(resource order by resource),array[]::text[]) into v_actions
  from public.lso_role_permissions
  where role_name = p_role and permission_key = 'action' and allowed = true
    and resource in (
      'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
      'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
      'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
      'writeActivityLog','manageAccessibility','selfDutyPunch'
    );
  v_columns := public.lso_v89_columns_for_actions(v_actions);
  delete from public.lso_role_permissions where role_name = p_role and permission_key = 'write_column';
  foreach v_value in array coalesce(v_columns,array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'write_column',v_value,true,now());
  end loop;

  return jsonb_build_object('role',p_role,'seeded',false,'repaired',true);
end;
$function$;

-- 7. SECURITY — match the installer grants. CREATE OR REPLACE preserves the
--    privileges of an existing function, but a function that was missing gets
--    the default PUBLIC grant. Normalize every LSO function explicitly.
-- The complete installer deliberately keeps ten helper functions internal:
-- they are called only by other SECURITY DEFINER functions and must never be
-- executable by browser roles. Reproduce that exact matrix instead of granting
-- every lso_% function to anon/authenticated.
do $v90_grants$
declare
  v_func record;
  c_internal constant text[] := array[
    'lso_admin_account',
    'lso_apply_default_role_configuration',
    'lso_default_role_configuration',
    'lso_session_account_id',
    'lso_trainee_scoped_state_v85',
    'lso_v82_columns_for_actions',
    'lso_v82_write_role_configuration',
    'lso_v89_columns_for_actions',
    'lso_v89_repair_role',
    'lso_v89_write_role_configuration'
  ];
begin
  for v_func in
    select p.oid, p.proname
    from pg_proc as p
    join pg_namespace as n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'lso_%'
  loop
    execute format('revoke all on function public.%I(%s) from public',
                   v_func.proname, pg_get_function_identity_arguments(v_func.oid));
    if v_func.proname = any(c_internal) then
      execute format('revoke all on function public.%I(%s) from anon, authenticated',
                     v_func.proname, pg_get_function_identity_arguments(v_func.oid));
    else
      execute format('grant execute on function public.%I(%s) to anon, authenticated',
                     v_func.proname, pg_get_function_identity_arguments(v_func.oid));
    end if;
  end loop;
end;
$v90_grants$;

-- 8. MIGRATION MARKER.
insert into public.lso_schema_migrations (migration_key, version_number, title, checksum, notes)
select '900_supabase_repair_v90',
       greatest(coalesce((select max(version_number) from public.lso_schema_migrations), 0) + 1, 90),
       'Supabase repair V90 - Administrator writes, column_versions, five roles',
       'supabase-repair-v90',
       'Adds system_state.column_versions, restores the five-role account constraint, adds an Administrator bypass to lso_role_can, and rewrites the shared-state writers.'
where not exists (
  select 1 from public.lso_schema_migrations where migration_key = '900_supabase_repair_v90'
);

notify pgrst, 'reload schema';

-- 9. VERIFICATION — every check must be true.
select jsonb_build_object(
  'column_versions_present', exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'system_state' and column_name = 'column_versions'
  ),
  'all_five_roles_allowed', exists (
    select 1 from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and conname = 'lso_accounts_role_check'
      and pg_get_constraintdef(oid) like '%Membership%'
      and pg_get_constraintdef(oid) like '%General Secretary%'
  ),
  'administrator_write_members', public.lso_role_can('Administrator','write_column','members'),
  'administrator_write_events', public.lso_role_can('Administrator','write_column','events'),
  'administrator_write_attendance', public.lso_role_can('Administrator','write_column','attendance'),
  'administrator_write_settings', public.lso_role_can('Administrator','write_column','settings'),
  'writer_v69_present', to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null,
  'writer_core_present', to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is not null,
  'save_accounts_present', to_regprocedure('public.lso_save_accounts(text,jsonb)') is not null,
  'permission_center_present', to_regprocedure('public.lso_get_permission_center(text)') is not null,
  'account_count', (select count(*) from public.lso_accounts),
  'accounts_by_role', (
    select coalesce(jsonb_object_agg(role, n), '{}'::jsonb)
    from (select role, count(*) n from public.lso_accounts group by role) as counts
  )
) as v90_repair_verification;

commit;
