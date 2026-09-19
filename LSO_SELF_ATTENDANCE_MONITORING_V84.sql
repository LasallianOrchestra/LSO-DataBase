-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — LSO V84
-- MY ATTENDANCE (TRAINEE / PROBATIONARY SELF-MONITORING) SUPABASE PATCH
-- Date: 2026-09-19
-- Companion to: SELF_ATTENDANCE_MONITORING_V84_GUIDE.txt
-- ============================================================================
--
-- WHAT THIS PATCH DOES
--   Adds ONE native permission module: `ownAttendanceView` ("My Attendance").
--   It is the only module that lets a signed-in Trainee/Probationary account
--   see and monitor its OWN attendance record. The module is view-only:
--
--     * The resource is a MODULE (permission_key = 'view'), never an action.
--     * `lso_v82_columns_for_actions()` is untouched, and the new module is not
--       mapped to any shared-state column — so holding it grants ZERO write
--       columns and cannot write members, events, attendance, settings, duty
--       hours, reports, or the activity log.
--     * No edit/delete/save RPC exists for it, and no client surface for it
--       renders an editing control.
--
--   The permission is identity-bound: only 'Trainee/Probationary' may ever hold
--   it. The read RPC and the save RPC both enforce that guard server-side, so an
--   Administrator cannot grant it to a different role and no other role can
--   return it.
--
-- WHAT THIS PATCH DOES NOT CHANGE
--   No operational data is deleted or rewritten. Accounts, members, attendance
--   records, duty hours, monthly reports, settings, audit history, recovery
--   points, and every existing role selection are preserved. Existing roles keep
--   their saved modules/actions/calendars; the one-time step (section 5) adds the
--   new module to the saved Trainee/Probationary configuration, and only if that
--   role already has a saved module configuration.
--
-- PREREQUISITE
--   The existing LSO management database as required by the V82 role-sync patch
--   (accounts, sessions, role permissions/profiles, shared system state, and the
--   session helper functions). See: LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql.
--
-- SCHEMA VERSION
--   The permission MODEL is unchanged: it is still the V82 model
--   (schemaVersion 13 / permissionModel 'v82'). This patch only extends the
--   supported resource lists, which is why the V82 synchronization health RPC
--   and the website's schema target are intentionally left untouched.
--
-- HOW TO RUN
--   Supabase Dashboard -> SQL Editor -> New query -> paste this file -> Run.
--   SAFE TO RE-RUN: yes. The migration marker makes the one-time grant apply
--   exactly once; every other statement is idempotent.
--
-- AFTER RUNNING
--   System Administration -> Access Control -> Role & Permission Center ->
--   select "Trainee/Probationary" -> the module "My Attendance" is listed with
--   Duty Hours. Save is only required if you want to change that selection.
-- ============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. PRE-FLIGHT — refuse to run against a database that is not the LSO schema.
-- -----------------------------------------------------------------------------
do $v84_preflight$
begin
  if to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null
     or to_regclass('public.lso_role_permissions') is null
     or to_regclass('public.lso_role_profiles') is null
     or to_regclass('public.system_state') is null
     or to_regclass('public.lso_schema_migrations') is null then
    raise exception 'LSO V84 requires the existing LSO management database. Install/repair the base LSO database (and LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql) before running this patch.';
  end if;
  if to_regprocedure('public.lso_session_account_id(text,boolean)') is null
     or to_regprocedure('public.lso_admin_account(text)') is null then
    raise exception 'LSO V84 requires the existing authentication/session functions. Install/repair the base LSO database before running this patch.';
  end if;
end;
$v84_preflight$;

-- -----------------------------------------------------------------------------
-- 1. OFFICIAL DEFAULTS — Trainee/Probationary gains the read-only module.
--    Every other role default is byte-for-byte the V82 definition.
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
      -- V84: Duty Hours (self-service punches) plus My Attendance (read-only own
      -- record). No additional ACTION is packaged: viewing is not an editable
      -- permission, so the Trainee still receives zero write columns.
      'views',jsonb_build_array('dutyHoursView','ownAttendanceView'),
      'actions',jsonb_build_array('selfDutyPunch','manageAccessibility'),
      'attendanceGroups',jsonb_build_array(),
      'columns',jsonb_build_array()
    )
    else null
  end;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. PERMISSION CENTER READ — supports the new module, always returns columns
--    and the schema model marker. Identical to V82 plus `ownAttendanceView`.
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

        -- V84: the module whitelist now includes ownAttendanceView, and that
        -- module is only returned for Trainee/Probationary even if a stray row
        -- exists for another role.
        select coalesce(jsonb_agg(resource order by resource),'[]'::jsonb) into v_views
        from public.lso_role_permissions
        where role_name=v_role and permission_key='view' and allowed=true
          and resource in (
            'dashboardView','membersView','contractView','interviewView','monthlyReportView',
            'attendanceView','dutyHoursView','ownAttendanceView'
          )
          and (resource <> 'ownAttendanceView' or v_role='Trainee/Probationary');

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
-- 3. ADMIN SAVE — accepts the new module, rejects it for every other role,
--    and keeps the existing dependency validation intact. The new module is
--    view-only, so it deliberately has no action dependency and no column.
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
    'dashboardView','membersView','contractView','interviewView','monthlyReportView',
    'attendanceView','dutyHoursView','ownAttendanceView'
  )
  -- V84: identity-bound module. Only Trainee/Probationary may hold it.
  and (value <> 'ownAttendanceView' or p_role='Trainee/Probationary');

  if p_role <> 'Trainee/Probationary' then
    v_views := array_remove(v_views,'ownAttendanceView');
  end if;

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
  -- module it cannot open. `ownAttendanceView` is read-only and has no action, so it is
  -- intentionally absent from this list.
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
-- 4. ONE-TIME GRANT FOR AN EXISTING SAVED CONFIGURATION
--    A database that already saved the Trainee/Probationary configuration keeps
--    its stored rows (the V82 model never resets saved roles), so the new module
--    must be added to that saved configuration once. The migration marker makes
--    this exactly-once: re-running the script never re-grants a selection that an
--    Administrator later removed. Roles without a saved configuration already
--    receive the module from section 1 defaults.
-- -----------------------------------------------------------------------------
do $v84_self_attendance_grant$
declare
  v_already_installed boolean;
  v_has_saved_modules boolean;
begin
  select exists(
    select 1 from public.lso_schema_migrations where migration_key = '014_self_attendance_view_v84'
  ) into v_already_installed;

  if not v_already_installed then
    select exists(
      select 1 from public.lso_role_permissions
      where role_name = 'Trainee/Probationary' and permission_key = 'view' and allowed = true
    ) into v_has_saved_modules;

    if v_has_saved_modules then
      insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
      values ('Trainee/Probationary','view','ownAttendanceView',true,now())
      on conflict (role_name,permission_key,resource)
      do update set allowed = true, updated_at = excluded.updated_at;
      raise notice 'LSO V84: My Attendance added to the saved Trainee/Probationary module selection.';
    else
      raise notice 'LSO V84: Trainee/Probationary has no saved module selection; the V84 defaults already include My Attendance.';
    end if;
  end if;
end;
$v84_self_attendance_grant$;

-- -----------------------------------------------------------------------------
-- 5. MIGRATION MARKER
-- -----------------------------------------------------------------------------
insert into public.lso_schema_migrations(migration_key,version_number,title,checksum,notes)
values(
  '014_self_attendance_view_v84',
  14,
  'Trainee/Probationary self-monitoring module (My Attendance, read-only)',
  'self-attendance-view-v84-014',
  'Adds the identity-bound ownAttendanceView module for Trainee/Probationary self-monitoring. The module is view-only: it maps to no shared-state column, carries no action, grants no editing permission, and is refused for every other role by the read and save RPCs. Existing saved role selections are preserved; the Trainee/Probationary saved selection receives the module exactly once.'
)
on conflict (migration_key) do update
set version_number = excluded.version_number,
    title = excluded.title,
    checksum = excluded.checksum,
    notes = excluded.notes;

-- -----------------------------------------------------------------------------
-- 6. SECURITY — browser RPCs stay RPC-only and session-validated.
-- -----------------------------------------------------------------------------
do $v84_security$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.lso_get_permission_center(text)',
    'public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb)'
  ] loop
    execute format('revoke all on function %s from public', v_signature);
    execute format('grant execute on function %s to anon, authenticated', v_signature);
  end loop;

  -- Re-affirm the grants owned by the V82 patch when those functions exist.
  foreach v_signature in array array[
    'public.lso_reset_role_permissions(text,text)',
    'public.lso_sync_health_v82(text)'
  ] loop
    if to_regprocedure(v_signature) is not null then
      execute format('grant execute on function %s to anon, authenticated', v_signature);
    end if;
  end loop;
end;
$v84_security$;

commit;
notify pgrst, 'reload schema';

-- -----------------------------------------------------------------------------
-- 7. SQL EDITOR VERIFICATION (read-only result)
--    Expected: result = PASS and every flag true, unexpectedRoleGrants = [].
-- -----------------------------------------------------------------------------
with v84_checks as (
  select
    exists(
      select 1 from public.lso_schema_migrations where migration_key = '014_self_attendance_view_v84'
    ) as migration_installed,
    position('ownAttendanceView' in pg_get_functiondef('public.lso_default_role_configuration(text)'::regprocedure)) > 0 as defaults_include_view,
    position('ownAttendanceView' in pg_get_functiondef('public.lso_get_permission_center(text)'::regprocedure)) > 0 as read_rpc_supports_view,
    position('ownAttendanceView' in pg_get_functiondef('public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb)'::regprocedure)) > 0 as save_rpc_supports_view,
    (public.lso_default_role_configuration('Trainee/Probationary') -> 'views') @> '["ownAttendanceView"]'::jsonb as trainee_default_has_view,
    not ((public.lso_default_role_configuration('Membership') -> 'views') @> '["ownAttendanceView"]'::jsonb)
      and not ((public.lso_default_role_configuration('General Secretary') -> 'views') @> '["ownAttendanceView"]'::jsonb)
      and not ((public.lso_default_role_configuration('Staff Account') -> 'views') @> '["ownAttendanceView"]'::jsonb) as other_role_defaults_exclude_view,
    (public.lso_default_role_configuration('Trainee/Probationary') -> 'columns') = '[]'::jsonb as trainee_default_has_no_write_columns,
    coalesce((
      select array_agg(distinct role_name order by role_name)
      from public.lso_role_permissions
      where permission_key = 'view' and resource = 'ownAttendanceView' and allowed = true
        and role_name <> 'Trainee/Probationary'
    ), array[]::text[]) as unexpected_role_grants,
    case
      when to_regprocedure('public.lso_v82_columns_for_actions(text[])') is null then true
      else coalesce(array_length(public.lso_v82_columns_for_actions(array['ownAttendanceView']),1),0) = 0
    end as view_grants_no_write_column
)
select jsonb_build_object(
  'migrationInstalled', migration_installed,
  'defaultsIncludeMyAttendance', defaults_include_view,
  'readRpcSupportsMyAttendance', read_rpc_supports_view,
  'saveRpcSupportsMyAttendance', save_rpc_supports_view,
  'traineeDefaultHasMyAttendance', trainee_default_has_view,
  'otherRoleDefaultsExcludeMyAttendance', other_role_defaults_exclude_view,
  'traineeDefaultWriteColumns', (public.lso_default_role_configuration('Trainee/Probationary') -> 'columns'),
  'traineeDefaultHasNoWriteColumns', trainee_default_has_no_write_columns,
  'unexpectedRoleGrants', to_jsonb(unexpected_role_grants),
  'viewGrantsNoWriteColumn', view_grants_no_write_column,
  'result', case
    when migration_installed
      and defaults_include_view
      and read_rpc_supports_view
      and save_rpc_supports_view
      and trainee_default_has_view
      and other_role_defaults_exclude_view
      and trainee_default_has_no_write_columns
      and coalesce(array_length(unexpected_role_grants,1),0) = 0
      and view_grants_no_write_column
    then 'PASS'
    else 'REVIEW'
  end
) as v84_self_attendance_status
from v84_checks;

-- -----------------------------------------------------------------------------
-- 8. ROLLBACK
--    This patch only extends the supported resource lists and adds one module
--    row for Trainee/Probationary. To roll back:
--      begin;
--        delete from public.lso_role_permissions
--         where permission_key = 'view' and resource = 'ownAttendanceView';
--        delete from public.lso_schema_migrations
--         where migration_key = '014_self_attendance_view_v84';
--      commit;
--      then re-run LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql to restore the previous
--      function bodies (it is idempotent and preserves saved role selections).
--    Rolling back hides the My Attendance section; it never deletes attendance
--    records, which remain untouched by this patch.
-- -----------------------------------------------------------------------------
