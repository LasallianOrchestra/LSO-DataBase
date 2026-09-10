-- Lasallian Symphony Orchestra
-- V82 ALL-ROLES PERMISSION + SHARED DATABASE SYNCHRONIZATION PATCH
-- Generated for the V82 website package.
--
-- PURPOSE
--   1) Make Interview a native Supabase permission (no client-only persistence required).
--   2) Make write-column permissions derive from the Administrator-selected ACTIONS for
--      every configurable role, not from hard-coded role names.
--   3) Repair existing Membership / General Secretary / Staff / Trainee write-column rows
--      without resetting their current module/action/calendar selections.
--   4) Add a session-aware shared-database health RPC used by V82 to stabilize status.
--   5) Preserve existing accounts, members, attendance, duty records, reports, settings,
--      audit history, recovery points, and role selections.
--
-- RUN IN: Supabase Dashboard > SQL Editor
-- PREREQUISITE: the existing LSO management database through V69 / migration 012.
-- SAFE TO RE-RUN: yes. The migration is idempotent and does not delete operational data.

begin;

-- -----------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-- -----------------------------------------------------------------------------
do $v82_preflight$
begin
  if to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null
     or to_regclass('public.lso_role_permissions') is null
     or to_regclass('public.lso_role_profiles') is null
     or to_regclass('public.system_state') is null
     or to_regclass('public.lso_schema_migrations') is null then
    raise exception 'LSO V82 requires the existing LSO management database. Install/repair the base LSO database through V69 before running this patch.';
  end if;
  if to_regprocedure('public.lso_session_account_id(text,boolean)') is null
     or to_regprocedure('public.lso_admin_account(text)') is null then
    raise exception 'LSO V82 requires the existing authentication/session functions. Install/repair the base LSO database before running this patch.';
  end if;
end;
$v82_preflight$;

-- -----------------------------------------------------------------------------
-- 1. SINGLE SOURCE OF TRUTH: operational ACTION -> required shared-state columns
-- -----------------------------------------------------------------------------
create or replace function public.lso_v82_columns_for_actions(p_actions text[])
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
  -- Member editing and contract history both persist inside the members document.
  if 'manageMembers' = any(v_actions) or 'generateContract' = any(v_actions) then
    v_columns := array_append(v_columns, 'members');
  end if;

  -- Attendance activity management persists event definitions.
  if 'manageEvents' = any(v_actions) or 'deleteEvents' = any(v_actions) then
    v_columns := array_append(v_columns, 'events');
  end if;

  -- Attendance roster/lifecycle operations persist attendance rows.
  if 'saveDraftAttendance' = any(v_actions)
     or 'finalizeAttendance' = any(v_actions)
     or 'unlockAttendance' = any(v_actions)
     or 'deleteEvents' = any(v_actions) then
    v_columns := array_append(v_columns, 'attendance');
  end if;

  -- Attendance review/finalize/reopen/archive governance is persisted in settings.
  if 'finalizeAttendance' = any(v_actions) or 'unlockAttendance' = any(v_actions) then
    v_columns := array_append(v_columns, 'settings');
  end if;

  -- Manual Duty Hours management and requirement configuration persist duty_hours.
  if 'manageDutyHours' = any(v_actions) or 'manageDutyRequirements' = any(v_actions) then
    v_columns := array_append(v_columns, 'duty_hours');
  end if;

  -- Monthly Report uses the current state plus the compatibility copy inside settings.
  if 'editMonthlyReport' = any(v_actions)
     or 'finalizeMonthlyReport' = any(v_actions)
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

-- -----------------------------------------------------------------------------
-- 2. V82 CURRENT DEFAULTS (used only for Administrator and explicit Reset)
--    Existing configurable-role selections are NOT reset by this migration.
-- -----------------------------------------------------------------------------
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
      'views',jsonb_build_array(
        'dashboardView','membersView','contractView','interviewView','monthlyReportView',
        'attendanceView','dutyHoursView','accountsView','systemHealthView','dataView'
      ),
      'actions',jsonb_build_array(
        'manageAccounts','manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
        'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
        'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
        'manageSettings','manageInventory','manageData','manageRecovery','viewSystemHealth',
        'writeActivityLog','manageAccessibility'
      ),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','instruments','settings','activity_log')
    )
    when 'Membership' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','contractView','monthlyReportView','attendanceView','dutyHoursView'),
      'actions',jsonb_build_array(
        'manageMembers','generateContract','editMonthlyReport','manageEvents','saveDraftAttendance',
        'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
        'writeActivityLog','manageAccessibility'
      ),
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
      'views',jsonb_build_array('dutyHoursView'),
      'actions',jsonb_build_array('selfDutyPunch','manageAccessibility'),
      'attendanceGroups',jsonb_build_array(),
      'columns',jsonb_build_array()
    )
    else null
  end;
end;
$$;

-- Internal writer used by Save and Reset. Browser roles never receive EXECUTE on it.
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
declare
  v_value text;
  v_columns text[];
begin
  v_columns := public.lso_v82_columns_for_actions(p_actions);

  delete from public.lso_role_permissions
  where role_name = p_role
    and permission_key in ('view','action','attendance_group','write_column');

  foreach v_value in array coalesce(p_views, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'view',v_value,true,now())
    on conflict(role_name,permission_key,resource)
    do update set allowed=true,updated_at=excluded.updated_at;
  end loop;

  foreach v_value in array coalesce(p_actions, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'action',v_value,true,now())
    on conflict(role_name,permission_key,resource)
    do update set allowed=true,updated_at=excluded.updated_at;
  end loop;

  foreach v_value in array coalesce(p_attendance_groups, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'attendance_group',v_value,true,now())
    on conflict(role_name,permission_key,resource)
    do update set allowed=true,updated_at=excluded.updated_at;
  end loop;

  foreach v_value in array coalesce(v_columns, array[]::text[]) loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'write_column',v_value,true,now())
    on conflict(role_name,permission_key,resource)
    do update set allowed=true,updated_at=excluded.updated_at;
  end loop;

  insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
  values(p_role,p_landing_view,now(),coalesce(nullif(p_updated_by,''),'V82'))
  on conflict(role_name) do update
  set landing_view=excluded.landing_view,
      updated_at=excluded.updated_at,
      updated_by=excluded.updated_by;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. NATIVE PERMISSION CENTER READ -- ALWAYS RETURNS columns + schemaVersion
-- -----------------------------------------------------------------------------
create or replace function public.lso_get_permission_center(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_role text;
  v_roles jsonb := '[]'::jsonb;
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

  select greatest(
    coalesce((select max(updated_at) from public.lso_role_permissions), '-infinity'::timestamptz),
    coalesce((select max(updated_at) from public.lso_role_profiles), '-infinity'::timestamptz)
  ) into v_updated_at;
  if v_updated_at = '-infinity'::timestamptz then v_updated_at := now(); end if;

  foreach v_role in array array['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    v_default := public.lso_default_role_configuration(v_role);

    if v_role = 'Administrator' then
      v_landing := v_default->>'landingView';
      v_views := v_default->'views';
      v_actions := v_default->'actions';
      v_groups := v_default->'attendanceGroups';
      v_columns := v_default->'columns';
    else
      select (
        exists(select 1 from public.lso_role_profiles where role_name=v_role)
        or exists(select 1 from public.lso_role_permissions where role_name=v_role)
      ) into v_has_configuration;

      if not v_has_configuration then
        v_landing := v_default->>'landingView';
        v_views := v_default->'views';
        v_actions := v_default->'actions';
        v_groups := v_default->'attendanceGroups';
        v_columns := v_default->'columns';
      else
        select coalesce(landing_view, v_default->>'landingView') into v_landing
        from public.lso_role_profiles where role_name=v_role;
        v_landing := coalesce(v_landing, v_default->>'landingView');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_views
        from public.lso_role_permissions
        where role_name=v_role and permission_key='view' and allowed=true
          and resource in ('dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_actions
        from public.lso_role_permissions
        where role_name=v_role and permission_key='action' and allowed=true
          and resource in (
            'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
            'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
            'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
            'writeActivityLog','manageAccessibility','selfDutyPunch'
          )
          and (resource <> 'selfDutyPunch' or v_role='Trainee/Probationary');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_groups
        from public.lso_role_permissions
        where role_name=v_role and permission_key='attendance_group' and allowed=true
          and resource in ('Official Members','Trainee Members','Probationary Members');

        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_columns
        from public.lso_role_permissions
        where role_name=v_role and permission_key='write_column' and allowed=true
          and resource in ('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','settings','activity_log');
      end if;
    end if;

    v_roles := v_roles || jsonb_build_array(jsonb_build_object(
      'roleName',v_role,
      'landingView',v_landing,
      'views',coalesce(v_views,'[]'::jsonb),
      'actions',coalesce(v_actions,'[]'::jsonb),
      'attendanceGroups',coalesce(v_groups,'[]'::jsonb),
      'columns',coalesce(v_columns,'[]'::jsonb)
    ));
  end loop;

  return jsonb_build_object(
    'roles',v_roles,
    'updatedAt',v_updated_at,
    'schemaVersion',13,
    'permissionModel','v82'
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. ADMIN SAVE -- Interview is a native module and columns derive from actions
-- -----------------------------------------------------------------------------
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
  v_views text[];
  v_actions text[];
  v_groups text[];
begin
  v_admin := public.lso_admin_account(p_token);

  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode='22023';
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_views
  from jsonb_array_elements_text(coalesce(p_views,'[]'::jsonb)) as value
  where value in (
    'dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView'
  );

  if coalesce(array_length(v_views,1),0)=0 then
    raise exception 'Assign at least one visible module.' using errcode='22023';
  end if;
  if not (coalesce(p_landing_view,'')=any(v_views)) then
    raise exception 'The landing page must be one of the assigned modules.' using errcode='22023';
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_actions
  from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb)) as value
  where value in (
    'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
    'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
    'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
    'writeActivityLog','manageAccessibility','selfDutyPunch'
  )
  and (value <> 'selfDutyPunch' or p_role='Trainee/Probationary');

  if p_role <> 'Trainee/Probationary' then
    v_actions := array_remove(v_actions,'selfDutyPunch');
  end if;

  select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_groups
  from jsonb_array_elements_text(coalesce(p_attendance_groups,'[]'::jsonb)) as value
  where value in ('Official Members','Trainee Members','Probationary Members');

  if 'attendanceView'=any(v_views) and coalesce(array_length(v_groups,1),0)=0 then
    raise exception 'Attendance access requires at least one assigned attendance calendar.' using errcode='22023';
  end if;

  -- Server-side dependency validation prevents a role from being assigned an action whose UI
  -- module it cannot open.
  if 'manageMembers'=any(v_actions) and not ('membersView'=any(v_views)) then raise exception 'Manage member records requires Members.' using errcode='22023'; end if;
  if 'generateContract'=any(v_actions) and not ('contractView'=any(v_views)) then raise exception 'Generate contracts requires Contract.' using errcode='22023'; end if;
  if (('editMonthlyReport'=any(v_actions)) or ('finalizeMonthlyReport'=any(v_actions)) or ('reopenMonthlyReport'=any(v_actions))) and not ('monthlyReportView'=any(v_views)) then raise exception 'Monthly Report actions require Monthly Report.' using errcode='22023'; end if;
  if (('manageEvents'=any(v_actions)) or ('deleteEvents'=any(v_actions)) or ('saveDraftAttendance'=any(v_actions)) or ('finalizeAttendance'=any(v_actions)) or ('unlockAttendance'=any(v_actions))) and not ('attendanceView'=any(v_views)) then raise exception 'Attendance actions require Attendance.' using errcode='22023'; end if;
  if (('reviewDutyPunches'=any(v_actions)) or ('manageDutyHours'=any(v_actions)) or ('manageDutyRequirements'=any(v_actions)) or ('certifyDutyHours'=any(v_actions)) or ('selfDutyPunch'=any(v_actions))) and not ('dutyHoursView'=any(v_views)) then raise exception 'Duty Hours actions require Duty Hours.' using errcode='22023'; end if;

  perform public.lso_v82_write_role_configuration(
    p_role,p_landing_view,v_views,v_actions,v_groups,v_admin.username
  );

  return public.lso_get_permission_center(p_token);
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. RESET ONE ROLE TO CURRENT OFFICIAL DEFAULTS
-- -----------------------------------------------------------------------------
create or replace function public.lso_reset_role_permissions(p_token text,p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_admin public.lso_accounts%rowtype;
  v_default jsonb;
  v_views text[];
  v_actions text[];
  v_groups text[];
begin
  v_admin := public.lso_admin_account(p_token);
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode='22023';
  end if;

  v_default := public.lso_default_role_configuration(p_role);
  select coalesce(array_agg(value),array[]::text[]) into v_views from jsonb_array_elements_text(v_default->'views') value;
  select coalesce(array_agg(value),array[]::text[]) into v_actions from jsonb_array_elements_text(v_default->'actions') value;
  select coalesce(array_agg(value),array[]::text[]) into v_groups from jsonb_array_elements_text(v_default->'attendanceGroups') value;

  perform public.lso_v82_write_role_configuration(
    p_role,v_default->>'landingView',v_views,v_actions,v_groups,v_admin.username
  );

  return public.lso_get_permission_center(p_token);
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. SESSION-AWARE HEALTH CHECK FOR THE SYNCHRONIZATION STATUS
-- -----------------------------------------------------------------------------
create or replace function public.lso_sync_health_v82(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- 7. MIGRATE THE V79 INTERVIEW COMPATIBILITY OVERLAY, IF PRESENT
--    This preserves Interview grants already made before the native server patch.
-- -----------------------------------------------------------------------------
do $v82_migrate_overlay$
declare
  v_role text;
  v_overlay jsonb;
  v_views text[];
  v_landing text;
  v_value text;
begin
  foreach v_role in array array['Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    select settings->'__lso_role_permission_overlay_v79'->'roles'->v_role
      into v_overlay
    from public.system_state where id=1;

    if v_overlay is not null and jsonb_typeof(v_overlay)='object' and jsonb_typeof(v_overlay->'views')='array' then
      select coalesce(array_agg(distinct value order by value),array[]::text[]) into v_views
      from jsonb_array_elements_text(v_overlay->'views') value
      where value in ('dashboardView','membersView','contractView','interviewView','monthlyReportView','attendanceView','dutyHoursView');

      if coalesce(array_length(v_views,1),0)>0 then
        delete from public.lso_role_permissions where role_name=v_role and permission_key='view';
        foreach v_value in array v_views loop
          insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
          values(v_role,'view',v_value,true,now())
          on conflict(role_name,permission_key,resource)
          do update set allowed=true,updated_at=excluded.updated_at;
        end loop;

        v_landing := nullif(v_overlay->>'landingView','');
        if v_landing is null or not (v_landing=any(v_views)) then v_landing := v_views[1]; end if;
        insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
        values(v_role,v_landing,now(),'V82 overlay migration')
        on conflict(role_name) do update
        set landing_view=excluded.landing_view,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
      end if;
    end if;
  end loop;
end;
$v82_migrate_overlay$;

-- -----------------------------------------------------------------------------
-- 8. PRESERVE CONFIGURATIONS, SEED ONLY MISSING ROLES, THEN REPAIR WRITE COLUMNS
-- -----------------------------------------------------------------------------
do $v82_repair_roles$
declare
  v_role text;
  v_default jsonb;
  v_views text[];
  v_actions text[];
  v_groups text[];
  v_columns text[];
  v_landing text;
  v_value text;
  v_has_any boolean;
begin
  foreach v_role in array array['Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    select exists(select 1 from public.lso_role_profiles where role_name=v_role)
        or exists(select 1 from public.lso_role_permissions where role_name=v_role)
      into v_has_any;

    v_default := public.lso_default_role_configuration(v_role);

    if not v_has_any then
      select coalesce(array_agg(value),array[]::text[]) into v_views from jsonb_array_elements_text(v_default->'views') value;
      select coalesce(array_agg(value),array[]::text[]) into v_actions from jsonb_array_elements_text(v_default->'actions') value;
      select coalesce(array_agg(value),array[]::text[]) into v_groups from jsonb_array_elements_text(v_default->'attendanceGroups') value;
      perform public.lso_v82_write_role_configuration(v_role,v_default->>'landingView',v_views,v_actions,v_groups,'V82 default seed');
    else
      -- If a legacy role has permissions but no profile, preserve its grants and create only
      -- a valid landing profile.
      if not exists(select 1 from public.lso_role_profiles where role_name=v_role) then
        select coalesce(array_agg(resource order by resource),array[]::text[]) into v_views
        from public.lso_role_permissions where role_name=v_role and permission_key='view' and allowed=true;
        v_landing := v_default->>'landingView';
        if not (v_landing=any(v_views)) then v_landing := v_views[1]; end if;
        if v_landing is not null then
          insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
          values(v_role,v_landing,now(),'V82 profile repair') on conflict(role_name) do nothing;
        end if;
      end if;

      -- Recalculate write-column rows from the role's CURRENT saved actions. This is the
      -- all-role persistence repair: it works for custom grants to Secretary, Staff, or
      -- Trainee exactly the same way it works for Membership.
      select coalesce(array_agg(resource order by resource),array[]::text[]) into v_actions
      from public.lso_role_permissions
      where role_name=v_role and permission_key='action' and allowed=true
        and resource in (
          'manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport',
          'manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance',
          'reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours',
          'writeActivityLog','manageAccessibility','selfDutyPunch'
        )
        and (resource <> 'selfDutyPunch' or v_role='Trainee/Probationary');
      v_columns := public.lso_v82_columns_for_actions(v_actions);

      delete from public.lso_role_permissions where role_name=v_role and permission_key='write_column';
      foreach v_value in array coalesce(v_columns,array[]::text[]) loop
        insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
        values(v_role,'write_column',v_value,true,now())
        on conflict(role_name,permission_key,resource)
        do update set allowed=true,updated_at=excluded.updated_at;
      end loop;
    end if;
  end loop;
end;
$v82_repair_roles$;

-- -----------------------------------------------------------------------------
-- 9. MIGRATION MARKER + SECURITY
-- -----------------------------------------------------------------------------
insert into public.lso_schema_migrations(migration_key,version_number,title,checksum,notes)
values(
  '013_role_sync_interview_v82',
  13,
  'All-role permission persistence and native Interview access',
  'role-sync-interview-v82-013',
  'Adds native interviewView permission support, returns write columns in permission payloads, derives write columns from selected operational actions for every configurable role, migrates the V79 Interview overlay, repairs existing role write-column grants, and adds a session-aware synchronization health RPC.'
)
on conflict(migration_key) do update
set version_number=excluded.version_number,
    title=excluded.title,
    checksum=excluded.checksum,
    notes=excluded.notes;

-- Internal helpers: no browser execution.
revoke all on function public.lso_v82_columns_for_actions(text[]) from public;
revoke all on function public.lso_v82_write_role_configuration(text,text,text[],text[],text[],text) from public;

-- Browser-facing RPCs remain RPC-only and session-validated.
revoke all on function public.lso_get_permission_center(text) from public;
revoke all on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) from public;
revoke all on function public.lso_reset_role_permissions(text,text) from public;
revoke all on function public.lso_sync_health_v82(text) from public;

grant execute on function public.lso_get_permission_center(text) to anon,authenticated;
grant execute on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) to anon,authenticated;
grant execute on function public.lso_reset_role_permissions(text,text) to anon,authenticated;
grant execute on function public.lso_sync_health_v82(text) to anon,authenticated;

commit;
notify pgrst, 'reload schema';

-- -----------------------------------------------------------------------------
-- 10. SQL EDITOR VERIFICATION (read-only result)
--     Expected: migrationInstalled=true, nativeInterview=true, healthRpc=true,
--     mismatchedRoles=[]
-- -----------------------------------------------------------------------------
with configurable_roles(role_name) as (
  values ('Membership'),('General Secretary'),('Staff Account'),('Trainee/Probationary')
), role_checks as (
  select r.role_name,
         public.lso_v82_columns_for_actions(coalesce((
           select array_agg(resource order by resource)
           from public.lso_role_permissions p
           where p.role_name=r.role_name and p.permission_key='action' and p.allowed=true
         ),array[]::text[])) as expected_columns,
         coalesce((
           select array_agg(resource order by resource)
           from public.lso_role_permissions p
           where p.role_name=r.role_name and p.permission_key='write_column' and p.allowed=true
         ),array[]::text[]) as actual_columns
  from configurable_roles r
)
select jsonb_build_object(
  'migrationInstalled',exists(select 1 from public.lso_schema_migrations where migration_key='013_role_sync_interview_v82'),
  'nativeInterview',position('interviewView' in pg_get_functiondef('public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb)'::regprocedure))>0,
  'permissionPayloadIncludesColumns',position('''columns''' in pg_get_functiondef('public.lso_get_permission_center(text)'::regprocedure))>0,
  'healthRpc',to_regprocedure('public.lso_sync_health_v82(text)') is not null,
  'roleColumns',(
    select jsonb_object_agg(role_name,jsonb_build_object('expected',expected_columns,'actual',actual_columns,'ok',expected_columns=actual_columns))
    from role_checks
  ),
  'mismatchedRoles',coalesce((select jsonb_agg(role_name) from role_checks where expected_columns<>actual_columns),'[]'::jsonb)
) as v82_role_sync_status;
