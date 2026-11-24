-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — ACCESS CONTROL / ROLES & PERMISSIONS
-- V89: REAL-TIME ROLE SYNC + MEMBERSHIP / GENERAL SECRETARY ATTENDANCE REPAIR
-- ============================================================================
-- RUN IN: Supabase Dashboard -> SQL Editor -> New query -> Run
-- SAFE TO RE-RUN: yes. Idempotent; accounts, members, attendance, duty hours,
--   monthly reports, activity logs, and recovery points are never deleted.
--
-- WHAT THIS PATCH FIXES
--   1. Supabase is the single source of truth for the Role & Permission Center:
--      native v82/v89 permission payloads are installed even on older databases.
--   2. Membership keeps all three Attendance calendars (including Official
--      Members) and every write column required to save attendance/events.
--   3. General Secretary is guaranteed the baseline Attendance actions needed
--      to create an activity and record attendance in a NEW month
--      (manageEvents + saveDraftAttendance + events/attendance write columns).
--   4. Column grants are recalculated from the role's saved actions for EVERY
--      role, so a custom grant to Secretary/Staff/Trainee still writes correctly.
--   5. lso_get_permission_center now returns the signed-in account identity and
--      a single updatedAt fingerprint. The website polls that fingerprint and
--      applies role/permission changes to open sessions within seconds.
--   6. Carries forward the V88 non-admin writer fix: no forced Administrator
--      session in lso_update_state(), and dynamic calendar validation instead
--      of the obsolete Membership "Trainee/Probationary only" guard.
--   7. Adds ownAttendanceView to the native permission model (identity-bound to
--      Trainee/Probationary) so it cannot be lost by an old save function.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-- ----------------------------------------------------------------------------
do $v89_preflight$
begin
  if to_regclass('public.system_state') is null
     or to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null then
    raise exception 'LSO database tables not found. Run the base database installer first.' using errcode = 'P0002';
  end if;
  if to_regprocedure('public.lso_session_account_id(text,boolean)') is null then
    raise exception 'public.lso_session_account_id(text,boolean) is missing.' using errcode = 'P0002';
  end if;
end;
$v89_preflight$;

create table if not exists public.lso_schema_migrations (
  migration_key text primary key,
  version_number integer not null,
  title text not null,
  checksum text not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default 'master-installer',
  notes text not null default ''
);

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
  updated_by text not null default 'migration-009'
);

-- ----------------------------------------------------------------------------
-- 1. SERVER MANIFEST — one answer for every role and every write column
-- ----------------------------------------------------------------------------
create or replace function public.lso_role_can(
  p_role text,
  p_permission_key text,
  p_resource text default ''
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- Operational action -> required shared-state columns. This is the single
-- source of truth used by the server writer and by the browser manifest.
create or replace function public.lso_v89_columns_for_actions(p_actions text[])
returns text[]
language plpgsql
immutable
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- Keep the older helper name working for installations still calling V82 code.
create or replace function public.lso_v82_columns_for_actions(p_actions text[])
returns text[]
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select public.lso_v89_columns_for_actions(p_actions);
$$;

-- ----------------------------------------------------------------------------
-- 2. OFFICIAL DEFAULTS (used for Administrator, Reset, and first-time seeds)
-- ----------------------------------------------------------------------------
create or replace function public.lso_default_role_configuration(p_role text)
returns jsonb
language plpgsql
immutable
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- ----------------------------------------------------------------------------
-- 3. SHARED CONFIGURATION WRITER (Save / Reset / seed)
-- ----------------------------------------------------------------------------
create or replace function public.lso_v89_write_role_configuration(
  p_role text,
  p_landing_view text,
  p_views text[],
  p_actions text[],
  p_attendance_groups text[],
  p_updated_by text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_v82_write_role_configuration(
  p_role text,
  p_landing_view text,
  p_views text[],
  p_actions text[],
  p_attendance_groups text[],
  p_updated_by text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform public.lso_v89_write_role_configuration(p_role,p_landing_view,p_views,p_actions,p_attendance_groups,p_updated_by);
end;
$$;

create or replace function public.lso_apply_default_role_configuration(
  p_role text,
  p_updated_by text default 'migration-009'
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- ----------------------------------------------------------------------------
-- 4. NATIVE PERMISSION CENTER READ (identity + change fingerprint)
-- ----------------------------------------------------------------------------
create or replace function public.lso_get_permission_center(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- Lightweight polling endpoint: detects role/permission changes without
-- downloading the full manifest. The website uses the full read above.
create or replace function public.lso_get_permission_revision(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- ----------------------------------------------------------------------------
-- 5. ADMIN SAVE / RESET — validation stays on the server
-- ----------------------------------------------------------------------------
create or replace function public.lso_save_role_permissions(
  p_token text,
  p_role text,
  p_landing_view text,
  p_views jsonb,
  p_actions jsonb,
  p_attendance_groups jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_reset_role_permissions(p_token text, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- ----------------------------------------------------------------------------
-- 6. REPAIR EXISTING ROLES WITHOUT RESETTING ADMINISTRATOR'S CUSTOM GRANTS
-- ----------------------------------------------------------------------------
create or replace function public.lso_v89_repair_role(p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

do $v89_repair_roles$
declare
  v_role text;
begin
  foreach v_role in array array['Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    perform public.lso_v89_repair_role(v_role);
  end loop;
end;
$v89_repair_roles$;

-- ----------------------------------------------------------------------------
-- 7. SHARED STATE WRITER — V88 repair carried forward (non-admin + dynamic)
-- ----------------------------------------------------------------------------
create or replace function public.lso_update_state_core(
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
$$;

-- ----------------------------------------------------------------------------
-- 3. WRAPPER — NO-OP OPTIMIZATION WITH NON-ADMIN SESSION VALIDATION
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
$lso$;

-- ----------------------------------------------------------------------------
-- 4. lso_update_state_v69 — CANONICAL, CONFLICT-FREE OPTIMISTIC CONCURRENCY WRITER
--    Drops all competing overloads so PostgREST schema cache has exactly ONE
--    unique function signature (preventing PGRST202 ambiguity errors).
-- ----------------------------------------------------------------------------
drop function if exists public.lso_update_state_v69(text, text, jsonb, integer) cascade;
drop function if exists public.lso_update_state_v69(text, text, jsonb, bigint) cascade;

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
$lso$;


-- ----------------------------------------------------------------------------
-- 8. MIGRATION MARKER + SECURITY
-- ----------------------------------------------------------------------------
insert into public.lso_schema_migrations(migration_key,version_number,title,checksum,notes)
values(
  '014_access_control_realtime_sync_v89',
  14,
  'Access Control real-time role sync and attendance permission repair',
  'access-control-realtime-sync-v89-014',
  'Native V89 permission center with identity/change fingerprint, baseline Membership and General Secretary attendance grants, all-role column reconciliation, non-admin state writer, and identity-bound My Attendance support.'
)
on conflict(migration_key) do update
set version_number=excluded.version_number,
    title=excluded.title,
    checksum=excluded.checksum,
    notes=excluded.notes;

revoke all on function public.lso_v89_columns_for_actions(text[]) from public, anon, authenticated;
revoke all on function public.lso_v82_columns_for_actions(text[]) from public, anon, authenticated;
revoke all on function public.lso_v89_write_role_configuration(text,text,text[],text[],text[],text) from public, anon, authenticated;
revoke all on function public.lso_v82_write_role_configuration(text,text,text[],text[],text[],text) from public, anon, authenticated;
revoke all on function public.lso_apply_default_role_configuration(text,text) from public, anon, authenticated;
revoke all on function public.lso_v89_repair_role(text) from public, anon, authenticated;

revoke all on function public.lso_role_can(text,text,text) from public;
revoke all on function public.lso_get_permission_center(text) from public;
revoke all on function public.lso_get_permission_revision(text) from public;
revoke all on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) from public;
revoke all on function public.lso_reset_role_permissions(text,text) from public;
revoke all on function public.lso_update_state_core(text,text,jsonb) from public;
revoke all on function public.lso_update_state(text,text,jsonb) from public;
revoke all on function public.lso_update_state_v69(text,text,jsonb,bigint) from public;

grant execute on function public.lso_role_can(text,text,text) to anon, authenticated;
grant execute on function public.lso_get_permission_center(text) to anon, authenticated;
grant execute on function public.lso_get_permission_revision(text) to anon, authenticated;
grant execute on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) to anon, authenticated;
grant execute on function public.lso_reset_role_permissions(text,text) to anon, authenticated;
grant execute on function public.lso_update_state_core(text,text,jsonb) to anon, authenticated;
grant execute on function public.lso_update_state(text,text,jsonb) to anon, authenticated;
grant execute on function public.lso_update_state_v69(text,text,jsonb,bigint) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- 9. VERIFICATION (read-only result)
-- ----------------------------------------------------------------------------
select jsonb_build_object(
  'permission_schema', 14,
  'membership_official_attendance_allowed', public.lso_role_can('Membership','attendance_group','Official Members'),
  'membership_trainee_attendance_allowed', public.lso_role_can('Membership','attendance_group','Trainee Members'),
  'membership_probationary_attendance_allowed', public.lso_role_can('Membership','attendance_group','Probationary Members'),
  'membership_events_write_allowed', public.lso_role_can('Membership','write_column','events'),
  'membership_attendance_write_allowed', public.lso_role_can('Membership','write_column','attendance'),
  'membership_members_write_allowed', public.lso_role_can('Membership','write_column','members'),
  'gensec_manage_events_allowed', public.lso_role_can('General Secretary','action','manageEvents'),
  'gensec_record_attendance_allowed', public.lso_role_can('General Secretary','action','saveDraftAttendance'),
  'gensec_official_attendance_allowed', public.lso_role_can('General Secretary','attendance_group','Official Members'),
  'gensec_events_write_allowed', public.lso_role_can('General Secretary','write_column','events'),
  'gensec_attendance_write_allowed', public.lso_role_can('General Secretary','write_column','attendance'),
  'admin_always_allowed', public.lso_role_can('Administrator','write_column','settings'),
  'get_permission_center_installed', to_regprocedure('public.lso_get_permission_center(text)') is not null,
  'permission_revision_installed', to_regprocedure('public.lso_get_permission_revision(text)') is not null,
  'lso_update_state_installed', to_regprocedure('public.lso_update_state(text,text,jsonb)') is not null,
  'lso_update_state_core_installed', to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is not null,
  'lso_update_state_v69_installed', to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null
) as verification_results;
