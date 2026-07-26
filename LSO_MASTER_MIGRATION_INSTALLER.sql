-- Lasallian Symphony Orchestra
-- Master Database Migration Installer
-- Target schema: 008_duty_mobile_required_approver
-- Safe to run repeatedly. Existing system records are preserved.

begin;

create extension if not exists pgcrypto;

-- Required compatibility columns. These statements are intentionally
-- idempotent so this one installer can repair older LSO projects.
alter table if exists public.lso_accounts
  add column if not exists member_id text;

alter table if exists public.system_state
  add column if not exists members jsonb not null default '[]'::jsonb,
  add column if not exists events jsonb not null default '[]'::jsonb,
  add column if not exists attendance jsonb not null default '[]'::jsonb,
  add column if not exists duty_hours jsonb not null default '{"version":7,"commitments":{},"entries":[]}'::jsonb,
  add column if not exists monthly_reports jsonb not null default '{}'::jsonb,
  add column if not exists instruments jsonb not null default '[]'::jsonb,
  add column if not exists settings jsonb not null default '{}'::jsonb,
  add column if not exists activity_log jsonb not null default '[]'::jsonb,
  add column if not exists updated_at timestamptz not null default now();

insert into public.system_state (id) values (1) on conflict (id) do nothing;

-- Every future database change must be represented by one immutable row here.
create table if not exists public.lso_schema_migrations (
  migration_key text primary key,
  version_number integer not null,
  title text not null,
  checksum text not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default 'master-installer',
  notes text not null default ''
);

create unique index if not exists lso_schema_migrations_version_unique
  on public.lso_schema_migrations (version_number);

insert into public.lso_schema_migrations
  (migration_key, version_number, title, checksum, notes)
values
  ('001_initial_shared_database', 1, 'Initial shared database', 'baseline-001', 'Accounts, sessions, and shared state.'),
  ('002_member_account_linkage', 2, 'Member account linkage', 'baseline-002', 'Member ID linkage and expanded account roles.'),
  ('003_separate_duty_punch_approval', 3, 'Separate Duty Hours punch approval', 'baseline-003', 'Independent Time In and Time Out review.'),
  ('004_attendance_governance', 4, 'Attendance governance', 'baseline-004', 'Draft, finalization, unlock, and audit workflow.'),
  ('005_monthly_report_workspace', 5, 'Monthly report workspace', 'baseline-005', 'Shared monthly reports and editable filing tables.'),
  ('006_enterprise_operations', 6, 'Enterprise operations controls', 'enterprise-006-v2', 'Health center, recovery points, error log, permissions manifest, and version tracking.'),
  ('007_staff_operations', 7, 'Staff monitoring and Duty review', 'staff-007-v1', 'Staff access is limited to Dashboard, Members, Attendance monitoring, and separate Duty punch review.')
on conflict (migration_key) do update
set title = excluded.title,
    checksum = excluded.checksum,
    notes = excluded.notes;

-- Versioned server permission manifest. Website and database permissions use
-- the same role/action vocabulary, while the specialized workflow guards below
-- continue to protect finalized attendance and current-stage Duty Hours records.
create table if not exists public.lso_role_permissions (
  role_name text not null,
  permission_key text not null,
  resource text not null default '',
  allowed boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (role_name, permission_key, resource)
);

delete from public.lso_role_permissions
where role_name in ('Administrator','Staff Account','Membership','General Secretary','Trainee/Probationary')
  and permission_key in ('write_column','view','manage','self');

insert into public.lso_role_permissions(role_name, permission_key, resource, allowed)
values
  ('Administrator','write_column','members',true),
  ('Administrator','write_column','events',true),
  ('Administrator','write_column','attendance',true),
  ('Administrator','write_column','duty_hours',true),
  ('Administrator','write_column','monthly_reports',true),
  ('Administrator','write_column','instruments',true),
  ('Administrator','write_column','settings',true),
  ('Administrator','write_column','activity_log',true),
  ('Membership','write_column','members',true),
  ('Membership','write_column','events',true),
  ('Membership','write_column','attendance',true),
  ('Membership','write_column','duty_hours',true),
  ('Membership','write_column','monthly_reports',true),
  ('Membership','write_column','settings',true),
  ('Membership','write_column','activity_log',true),
  ('General Secretary','write_column','events',true),
  ('General Secretary','write_column','attendance',true),
  ('General Secretary','write_column','activity_log',true),
  ('Staff Account','view','dashboardView',true),
  ('Staff Account','view','membersView',true),
  ('Staff Account','view','attendanceView',true),
  ('Staff Account','view','dutyHoursView',true),
  ('Administrator','view','systemHealthView',true),
  ('Administrator','manage','recovery',true),
  ('Administrator','manage','systemErrors',true),
  ('Administrator','manage','monthlyFinalization',true),
  ('Administrator','manage','attendanceFinalization',true),
  ('Membership','manage','dutyReview',true),
  ('Staff Account','manage','dutyReview',true),
  ('Administrator','manage','dutyReview',true),
  ('Trainee/Probationary','self','dutyPunch',true)
on conflict (role_name, permission_key, resource) do update
set allowed=excluded.allowed, updated_at=now();

create or replace function public.lso_role_can(p_role text, p_permission_key text, p_resource text default '')
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select allowed from public.lso_role_permissions
    where role_name=p_role and permission_key=p_permission_key and resource=coalesce(p_resource,'')), false);
$$;

-- Server-side recovery points preserve complete system_state snapshots before
-- risky operations. A maximum of 20 points is retained automatically.
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

-- Friendly error records. Technical details are stored for Administrators,
-- while the normal interface displays the public message and stable code.
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
  on public.lso_system_errors (resolved_at) where resolved_at is null;

create or replace function public.lso_admin_account(p_token text)
returns public.lso_accounts
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_system_health(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
    jsonb_build_object('id','permission-manifest','label','Server permission manifest','ok',to_regclass('public.lso_role_permissions') is not null and to_regprocedure('public.lso_role_can(text,text,text)') is not null)
  );

  return jsonb_build_object(
    'ok', true,
    'databaseVersion', '007_staff_operations',
    'targetMigration', 7,
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
$$;

create or replace function public.lso_create_recovery_point(
  p_token text,
  p_label text,
  p_reason text default '',
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_list_recovery_points(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_restore_recovery_point(p_token text, p_recovery_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_delete_recovery_point(p_token text, p_recovery_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform public.lso_admin_account(p_token);
  delete from public.lso_recovery_points where id=p_recovery_id;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.lso_log_system_error(p_token text, p_error jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_list_system_errors(p_token text, p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform public.lso_admin_account(p_token);
  return coalesce((select jsonb_agg(to_jsonb(errors) order by errors.created_at desc) from (
    select id,error_code,severity,module,public_message,technical_message,context,app_version,browser_info,created_at,created_by_username,resolved_at,resolved_by_username,resolution_note
    from public.lso_system_errors order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
  ) errors),'[]'::jsonb);
end;
$$;

create or replace function public.lso_resolve_system_error(p_token text, p_error_id uuid, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_account public.lso_accounts%rowtype;
begin
  v_account := public.lso_admin_account(p_token);
  update public.lso_system_errors set resolved_at=now(),resolved_by_username=v_account.username,resolution_note=left(coalesce(p_note,''),500) where id=p_error_id;
  return jsonb_build_object('ok',true);
end;
$$;

-- Rebuild the shared-state writer so its broad column permissions come from
-- the centralized server manifest. Detailed attendance and Duty Hours guards
-- remain in place inside this function.
create or replace function public.lso_update_state(
  p_token text,
  p_column text,
  p_value jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

  -- Non-administrator attendance roles may create and edit activities, but may
  -- not delete them or alter an already finalized/unlocked attendance workflow.
  if v_role in ('Membership', 'General Secretary') and p_column = 'events' then
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
    -- Existing protected workflow objects must remain byte-for-byte unchanged.
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

  -- Draft editors cannot silently change attendance rows whose matching roster
  -- is currently Finalized. An Administrator must unlock the roster first.
  if v_role in ('Membership', 'General Secretary') and p_column = 'attendance' then
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

  -- Membership attendance editing is limited to Trainee and Probationary rows.
  if v_role = 'Membership' and p_column = 'attendance' then
    for v_old in
      select value from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb))
      where coalesce(value ->> 'attendanceGroup', '') not in ('Trainee Members', 'Probationary Members')
    loop
      if not exists (select 1 from jsonb_array_elements(p_value) as item where item = v_old) then
        raise exception 'Membership attendance access is limited to Trainee and Probationary rosters.' using errcode = '42501';
      end if;
    end loop;
    for v_new in
      select value from jsonb_array_elements(p_value)
      where coalesce(value ->> 'attendanceGroup', '') not in ('Trainee Members', 'Probationary Members')
    loop
      if not exists (select 1 from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) as item where item = v_new) then
        raise exception 'Membership attendance access is limited to Trainee and Probationary rosters.' using errcode = '42501';
      end if;
    end loop;
  end if;

  -- Membership may update the report payload stored in settings, but cannot
  -- change system-wide automation settings.
  if v_role = 'Membership' and p_column = 'settings' then
    if (p_value - '__lso_monthly_reports_v1') is distinct from (coalesce(v_existing, '{}'::jsonb) - '__lso_monthly_reports_v1') then
      raise exception 'Only the Administrator can change system settings.' using errcode = '42501';
    end if;
  end if;

  -- Membership Duty Hours changes are restricted to people who are currently
  -- in the Trainee or Probationary Period. Historical/official records are kept exact.
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
$$;

alter table public.lso_role_permissions enable row level security;
alter table public.lso_schema_migrations enable row level security;
alter table public.lso_recovery_points enable row level security;
alter table public.lso_system_errors enable row level security;

revoke all on table public.lso_role_permissions from anon, authenticated;
revoke all on table public.lso_schema_migrations from anon, authenticated;
revoke all on table public.lso_recovery_points from anon, authenticated;
revoke all on table public.lso_system_errors from anon, authenticated;

revoke all on function public.lso_role_can(text,text,text) from public;
revoke all on function public.lso_admin_account(text) from public;
revoke all on function public.lso_system_health(text) from public;
revoke all on function public.lso_create_recovery_point(text,text,text,jsonb) from public;
revoke all on function public.lso_list_recovery_points(text) from public;
revoke all on function public.lso_restore_recovery_point(text,uuid) from public;
revoke all on function public.lso_delete_recovery_point(text,uuid) from public;
revoke all on function public.lso_log_system_error(text,jsonb) from public;
revoke all on function public.lso_list_system_errors(text,integer) from public;
revoke all on function public.lso_resolve_system_error(text,uuid,text) from public;

grant execute on function public.lso_system_health(text) to anon, authenticated;
grant execute on function public.lso_create_recovery_point(text,text,text,jsonb) to anon, authenticated;
grant execute on function public.lso_list_recovery_points(text) to anon, authenticated;
grant execute on function public.lso_restore_recovery_point(text,uuid) to anon, authenticated;
grant execute on function public.lso_delete_recovery_point(text,uuid) to anon, authenticated;
grant execute on function public.lso_log_system_error(text,jsonb) to anon, authenticated;
grant execute on function public.lso_list_system_errors(text,integer) to anon, authenticated;
grant execute on function public.lso_resolve_system_error(text,uuid,text) to anon, authenticated;

notify pgrst, 'reload schema';
commit;

-- Verification after running:
-- select migration_key, version_number, applied_at from public.lso_schema_migrations order by version_number;


-- ============================================================================
-- STAFF OPERATIONS MIGRATION 007
-- ============================================================================
-- Lasallian Symphony Orchestra
-- Staff Account Monitoring and Duty Punch Review Upgrade
-- Target schema: 007_staff_operations
-- Safe to run repeatedly. Existing records are preserved.

begin;

create table if not exists public.lso_schema_migrations (
  migration_key text primary key,
  version_number integer not null,
  title text not null,
  checksum text not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default 'master-installer',
  notes text not null default ''
);

insert into public.lso_schema_migrations
  (migration_key, version_number, title, checksum, notes)
values
  ('007_staff_operations', 7, 'Staff monitoring and Duty review', 'staff-007-v1',
   'Staff access is limited to Dashboard, Members, Attendance monitoring, and separate Duty punch review.')
on conflict (migration_key) do update
set title=excluded.title, checksum=excluded.checksum, notes=excluded.notes;

create table if not exists public.lso_role_permissions (
  role_name text not null,
  permission_key text not null,
  resource text not null default '',
  allowed boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (role_name, permission_key, resource)
);

-- Remove older Staff permissions, then grant only the requested operational right.
delete from public.lso_role_permissions
where role_name='Staff Account'
  and permission_key in ('write_column','view','manage','self');

insert into public.lso_role_permissions(role_name, permission_key, resource, allowed)
values
  ('Staff Account','view','dashboardView',true),
  ('Staff Account','view','membersView',true),
  ('Staff Account','view','attendanceView',true),
  ('Staff Account','view','dutyHoursView',true),
  ('Staff Account','manage','dutyReview',true)
on conflict (role_name, permission_key, resource) do update
set allowed=excluded.allowed, updated_at=now();

create or replace function public.lso_review_duty_punch(
  p_token text,
  p_entry_id text,
  p_punch_type text,
  p_decision text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_admin_id uuid;
  v_admin_username text;
  v_admin_display_name text;
  v_reviewer_role text;
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
  v_admin_id := public.lso_session_account_id(p_token, false);
  select username, display_name, role
  into v_admin_username, v_admin_display_name, v_reviewer_role
  from public.lso_accounts
  where id = v_admin_id;

  if v_reviewer_role not in ('Administrator', 'Membership', 'Staff Account') then
    raise exception 'Administrator, Membership, or Staff access is required to review Duty Hours punches.' using errcode = '42501';
  end if;

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
$$;

revoke all on function public.lso_review_duty_punch(text, text, text, text) from public;
grant execute on function public.lso_review_duty_punch(text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- Migration 008: Duty Hours mobile input and required Member/s Approved.
-- Lasallian Symphony Orchestra
-- Duty Hours mobile input and required Member/s Approved update
-- Migration: 008_duty_mobile_required_approver
-- Safe to run repeatedly. Existing records are preserved.

begin;

create table if not exists public.lso_schema_migrations (
  migration_key text primary key,
  version_number integer not null,
  title text not null,
  checksum text not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default 'migration-installer',
  notes text not null default ''
);

create or replace function public.lso_duty_time_in(
  p_token text,
  p_semester text,
  p_description text default '',
  p_member_approvers text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
  if v_member_approvers = '' then
    raise exception 'Member/s Approved is required before submitting Time In.' using errcode = '22023';
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
$$;

create or replace function public.lso_duty_time_out(
  p_token text,
  p_description text default '',
  p_member_approvers text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
  if nullif(btrim(coalesce(v_final_member_approvers, '')), '') is null then
    raise exception 'Member/s Approved is required before submitting Time Out.' using errcode = '22023';
  end if;
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
$$;

revoke all on function public.lso_duty_time_in(text, text, text, text) from public;
grant execute on function public.lso_duty_time_in(text, text, text, text) to anon, authenticated;
revoke all on function public.lso_duty_time_out(text, text, text) from public;
grant execute on function public.lso_duty_time_out(text, text, text) to anon, authenticated;

insert into public.lso_schema_migrations
  (migration_key, version_number, title, checksum, notes)
values
  ('008_duty_mobile_required_approver', 8, 'Duty mobile input and required approver', 'duty-mobile-008-v1',
   'Prevents keyboard resize from resetting the Duty Hours form and requires Member/s Approved for Time In and Time Out.')
on conflict (migration_key) do update
set title = excluded.title,
    checksum = excluded.checksum,
    notes = excluded.notes;

commit;
notify pgrst, 'reload schema';
