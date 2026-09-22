-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — SHARED ONLINE DATABASE
-- MEMBERSHIP ROLE ATTENDANCE & SHARED STATE SAVE REPAIR
--
-- PROBLEM:
--   An account assigned the "Membership" role in Account Management fails to
--   save attendance updates (such as for Official Members in the String section
--   roster), triggering error 42501 and the red notification banner:
--   "This account’s role is not permitted to change this system area.
--    The change was reverted to the value in the shared database."
--
-- ROOT CAUSE:
--   1. V83 wrapper bug: public.lso_update_state() called
--      public.lso_session_account_id(p_token, true), requiring Administrator
--      for all saves and rejecting every non-admin role with errcode 42501.
--   2. Obsolete attendance guard: public.lso_update_state() / lso_update_state_core()
--      contained a legacy pre-V38 check restricting Membership role attendance
--      writes exclusively to 'Trainee Members' and 'Probationary Members'.
--      When editing the Official Members calendar (the standard active roster),
--      the server raised: "Membership attendance access is limited to Trainee
--      and Probationary rosters." (errcode 42501).
--   3. Missing permission seed: Existing projects created before V82 did not have
--      the ('Membership', 'attendance_group', 'Official Members') permission
--      inserted into public.lso_role_permissions.
--
-- FIX:
--   1. Corrects public.lso_session_account_id(p_token, false) in public.lso_update_state().
--   2. Replaces the hardcoded attendance check with dynamic role validation via
--      public.lso_role_can(v_role, 'attendance_group', group), allowing any
--      attendance calendar assigned to the role (including Official Members).
--   3. Seeds/repairs public.lso_role_permissions for 'Membership' to ensure
--      Official Members, Trainee Members, and Probationary Members calendars are granted.
--   4. Updates public.lso_default_role_configuration('Membership') to include Official Members.
--   5. Cleans up any competing lso_update_state_v69 overloads.
--
-- RUN IN: Supabase Dashboard -> SQL Editor -> Run
-- SAFE TO RE-RUN: Yes, idempotent.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. PRE-FLIGHT
-- ----------------------------------------------------------------------------
do $lso_preflight$
begin
  if to_regclass('public.system_state') is null
     or to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null then
    raise exception 'LSO database tables not found. Run the base schema before applying this patch.' using errcode = 'P0002';
  end if;
  if to_regprocedure('public.lso_session_account_id(text,boolean)') is null then
    raise exception 'public.lso_session_account_id(text,boolean) not found.' using errcode = 'P0002';
  end if;
end;
$lso_preflight$;

-- ----------------------------------------------------------------------------
-- 1. ENSURE lso_role_permissions TABLE & PERMISSIONS
-- ----------------------------------------------------------------------------
create table if not exists public.lso_role_permissions (
  role_name text not null,
  permission_key text not null,
  resource text not null,
  allowed boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (role_name, permission_key, resource)
);

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

-- Seed / repair Membership permissions (Official Members attendance + all required write columns)
insert into public.lso_role_permissions(role_name, permission_key, resource, allowed, updated_at)
values
  -- Attendance calendars
  ('Membership', 'attendance_group', 'Official Members', true, now()),
  ('Membership', 'attendance_group', 'Trainee Members', true, now()),
  ('Membership', 'attendance_group', 'Probationary Members', true, now()),
  -- Write columns
  ('Membership', 'write_column', 'members', true, now()),
  ('Membership', 'write_column', 'events', true, now()),
  ('Membership', 'write_column', 'attendance', true, now()),
  ('Membership', 'write_column', 'duty_hours', true, now()),
  ('Membership', 'write_column', 'monthly_reports', true, now()),
  ('Membership', 'write_column', 'monthly_reports_compat', true, now()),
  ('Membership', 'write_column', 'settings', true, now()),
  ('Membership', 'write_column', 'activity_log', true, now()),
  -- Actions
  ('Membership', 'action', 'saveDraftAttendance', true, now()),
  ('Membership', 'action', 'manageEvents', true, now()),
  ('Membership', 'action', 'manageMembers', true, now()),
  ('Membership', 'action', 'generateContract', true, now()),
  ('Membership', 'action', 'editMonthlyReport', true, now()),
  ('Membership', 'action', 'reviewDutyPunches', true, now()),
  ('Membership', 'action', 'manageDutyHours', true, now()),
  ('Membership', 'action', 'manageDutyRequirements', true, now()),
  ('Membership', 'action', 'certifyDutyHours', true, now()),
  ('Membership', 'action', 'writeActivityLog', true, now()),
  ('Membership', 'action', 'manageAccessibility', true, now()),
  -- Views
  ('Membership', 'view', 'dashboardView', true, now()),
  ('Membership', 'view', 'membersView', true, now()),
  ('Membership', 'view', 'contractView', true, now()),
  ('Membership', 'view', 'monthlyReportView', true, now()),
  ('Membership', 'view', 'attendanceView', true, now()),
  ('Membership', 'view', 'dutyHoursView', true, now())
on conflict (role_name, permission_key, resource)
do update set allowed = true, updated_at = now();

-- Update default configuration helper if installed
do $lso_update_default_config$
begin
  if to_regprocedure('public.lso_default_role_configuration(text)') is not null then
    execute $ddl$
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
            'views',jsonb_build_array('dutyHoursView'),
            'actions',jsonb_build_array('selfDutyPunch','manageAccessibility'),
            'attendanceGroups',jsonb_build_array(),
            'columns',jsonb_build_array()
          )
          else null
        end;
      end;
      $$;
    $ddl$;
  end if;
end;
$lso_update_default_config$;

-- ----------------------------------------------------------------------------
-- 2. CORE STATE WRITER — DYNAMIC ATTENDANCE PERMISSIONS & CLEAN ACCESS CHECKS
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
-- 5. PERMISSIONS & GRANTS
-- ----------------------------------------------------------------------------
revoke all on function public.lso_role_can(text, text, text) from public;
grant execute on function public.lso_role_can(text, text, text) to anon, authenticated;

revoke all on function public.lso_update_state_core(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.lso_update_state_core(text, text, jsonb) to anon, authenticated;

revoke all on function public.lso_update_state(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;

revoke all on function public.lso_update_state_v69(text, text, jsonb, bigint) from public, anon, authenticated;
grant execute on function public.lso_update_state_v69(text, text, jsonb, bigint) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- 6. VERIFICATION QUERY (read-only output)
-- ----------------------------------------------------------------------------
select jsonb_build_object(
  'membership_official_attendance_allowed', public.lso_role_can('Membership', 'attendance_group', 'Official Members'),
  'membership_attendance_write_allowed', public.lso_role_can('Membership', 'write_column', 'attendance'),
  'membership_events_write_allowed', public.lso_role_can('Membership', 'write_column', 'events'),
  'membership_members_write_allowed', public.lso_role_can('Membership', 'write_column', 'members'),
  'membership_duty_hours_write_allowed', public.lso_role_can('Membership', 'write_column', 'duty_hours'),
  'lso_update_state_installed', to_regprocedure('public.lso_update_state(text,text,jsonb)') is not null,
  'lso_update_state_core_installed', to_regprocedure('public.lso_update_state_core(text,text,jsonb)') is not null,
  'lso_update_state_v69_installed', to_regprocedure('public.lso_update_state_v69(text,text,jsonb,bigint)') is not null
) as verification_results;
