-- Lasallian Symphony Orchestra
-- Dynamic Role & Permission Center
-- Migration: 009_dynamic_role_permissions
-- Safe to run repeatedly. Existing accounts and operational records are preserved.

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
      'views',jsonb_build_array('dashboardView','membersView','lookupView','contractView','monthlyReportView','attendanceView','dutyHoursView','alertsView','accountsView','systemHealthView','dataView'),
      'actions',jsonb_build_array('manageAccounts','manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport','manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','manageSettings','manageInventory','manageData','manageRecovery','viewSystemHealth','manageSystemErrors','writeActivityLog','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','instruments','settings','activity_log')
    )
    when 'Membership' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','membersView','lookupView','contractView','monthlyReportView','attendanceView','dutyHoursView'),
      'actions',jsonb_build_array('manageMembers','generateContract','editMonthlyReport','manageEvents','saveDraftAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility'),
      'attendanceGroups',jsonb_build_array('Trainee Members','Probationary Members'),
      'columns',jsonb_build_array('members','events','attendance','duty_hours','monthly_reports','monthly_reports_compat','settings','activity_log')
    )
    when 'General Secretary' then jsonb_build_object(
      'landingView','dashboardView',
      'views',jsonb_build_array('dashboardView','attendanceView'),
      'actions',jsonb_build_array('manageEvents','saveDraftAttendance','writeActivityLog','manageAccessibility'),
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
  v_resource text;
begin
  v_config := public.lso_default_role_configuration(p_role);
  if v_config is null then
    raise exception 'Unknown LSO account role.' using errcode = '22023';
  end if;

  delete from public.lso_role_permissions
  where role_name = p_role
    and permission_key in ('view','action','attendance_group','write_column');

  for v_resource in select jsonb_array_elements_text(v_config -> 'views') loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'view',v_resource,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true,updated_at=now();
  end loop;
  for v_resource in select jsonb_array_elements_text(v_config -> 'actions') loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'action',v_resource,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true,updated_at=now();
  end loop;
  for v_resource in select jsonb_array_elements_text(v_config -> 'attendanceGroups') loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'attendance_group',v_resource,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true,updated_at=now();
  end loop;
  for v_resource in select jsonb_array_elements_text(v_config -> 'columns') loop
    insert into public.lso_role_permissions(role_name,permission_key,resource,allowed,updated_at)
    values(p_role,'write_column',v_resource,true,now())
    on conflict(role_name,permission_key,resource) do update set allowed=true,updated_at=now();
  end loop;

  insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
  values(p_role,v_config ->> 'landingView',now(),coalesce(nullif(p_updated_by,''),'migration-009'))
  on conflict(role_name) do update
  set landing_view=excluded.landing_view,updated_at=now(),updated_by=excluded.updated_by;
end;
$$;

-- Preserve any current role grants from earlier releases. Only roles without a
-- complete dynamic profile are initialized with the packaged defaults.
do $$
declare v_role text;
begin
  foreach v_role in array array['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary'] loop
    if not exists(select 1 from public.lso_role_profiles where role_name=v_role) then
      perform public.lso_apply_default_role_configuration(v_role,'migration-009');
    end if;
  end loop;
end;
$$;

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

create or replace function public.lso_get_permission_center(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_roles jsonb;
  v_updated_at timestamptz;
begin
  v_account_id := public.lso_session_account_id(p_token,false);
  select * into v_account from public.lso_accounts where id=v_account_id;
  if not found then raise exception 'Account not found.' using errcode='42501'; end if;

  with role_list(role_name,sort_order) as (
    values ('Administrator',1),('Membership',2),('General Secretary',3),('Staff Account',4),('Trainee/Probationary',5)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'roleName',r.role_name,
    'landingView',coalesce(p.landing_view,public.lso_default_role_configuration(r.role_name)->>'landingView'),
    'views',coalesce((select jsonb_agg(resource order by resource) from public.lso_role_permissions where role_name=r.role_name and permission_key='view' and allowed),'[]'::jsonb),
    'actions',coalesce((select jsonb_agg(resource order by resource) from public.lso_role_permissions where role_name=r.role_name and permission_key='action' and allowed),'[]'::jsonb),
    'attendanceGroups',coalesce((select jsonb_agg(resource order by resource) from public.lso_role_permissions where role_name=r.role_name and permission_key='attendance_group' and allowed),'[]'::jsonb),
    'columns',coalesce((select jsonb_agg(resource order by resource) from public.lso_role_permissions where role_name=r.role_name and permission_key='write_column' and allowed),'[]'::jsonb),
    'updatedAt',p.updated_at,
    'updatedBy',p.updated_by
  ) order by r.sort_order),'[]'::jsonb)
  into v_roles
  from role_list r
  left join public.lso_role_profiles p on p.role_name=r.role_name
  where v_account.role='Administrator' or r.role_name=v_account.role;

  select greatest(
    coalesce((select max(updated_at) from public.lso_role_profiles),'-infinity'::timestamptz),
    coalesce((select max(updated_at) from public.lso_role_permissions),'-infinity'::timestamptz)
  ) into v_updated_at;

  return jsonb_build_object(
    'ok',true,
    'version','dynamic-permissions-v1',
    'editable',v_account.role='Administrator',
    'requestedRole',v_account.role,
    'roles',v_roles,
    'updatedAt',v_updated_at
  );
end;
$$;

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
  v_columns text[] := array[]::text[];
  v_value text;
begin
  v_admin := public.lso_admin_account(p_token);
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode='22023';
  end if;

  select coalesce(array_agg(distinct value),array[]::text[]) into v_views
  from jsonb_array_elements_text(coalesce(p_views,'[]'::jsonb)) as value
  where value in ('dashboardView','membersView','lookupView','contractView','monthlyReportView','attendanceView','dutyHoursView','alertsView');
  if coalesce(array_length(v_views,1),0)=0 then
    raise exception 'Assign at least one visible module.' using errcode='22023';
  end if;
  if not (coalesce(p_landing_view,'')=any(v_views)) then
    raise exception 'The landing page must be one of the assigned modules.' using errcode='22023';
  end if;

  select coalesce(array_agg(distinct value),array[]::text[]) into v_actions
  from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb)) as value
  where value in ('manageMembers','generateContract','editMonthlyReport','finalizeMonthlyReport','reopenMonthlyReport','manageEvents','deleteEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility','selfDutyPunch')
    and (value <> 'reviewDutyPunches' or p_role in ('Membership','Staff Account'))
    and (value <> 'selfDutyPunch' or p_role='Trainee/Probationary');

  if not ('manageAccessibility'=any(v_actions)) then v_actions:=array_append(v_actions,'manageAccessibility'); end if;
  if p_role='Trainee/Probationary' and not ('selfDutyPunch'=any(v_actions)) then v_actions:=array_append(v_actions,'selfDutyPunch'); end if;
  if p_role<>'Trainee/Probationary' then v_actions:=array_remove(v_actions,'selfDutyPunch'); end if;

  select coalesce(array_agg(distinct value),array[]::text[]) into v_groups
  from jsonb_array_elements_text(coalesce(p_attendance_groups,'[]'::jsonb)) as value
  where value in ('Official Members','Trainee Members','Probationary Members');

  if 'manageMembers'=any(v_actions) then v_columns:=array_append(v_columns,'members'); end if;
  if 'manageEvents'=any(v_actions) or 'deleteEvents'=any(v_actions) then v_columns:=array_append(v_columns,'events'); end if;
  if 'saveDraftAttendance'=any(v_actions) or 'finalizeAttendance'=any(v_actions) or 'unlockAttendance'=any(v_actions) then v_columns:=array_append(v_columns,'attendance'); end if;
  if 'manageDutyHours'=any(v_actions) or 'manageDutyRequirements'=any(v_actions) then v_columns:=array_append(v_columns,'duty_hours'); end if;
  if 'editMonthlyReport'=any(v_actions) or 'finalizeMonthlyReport'=any(v_actions) or 'reopenMonthlyReport'=any(v_actions) then
    v_columns:=array_cat(v_columns,array['monthly_reports','monthly_reports_compat','settings']);
  end if;
  if coalesce(array_length(v_columns,1),0)>0 or 'writeActivityLog'=any(v_actions) then v_columns:=array_append(v_columns,'activity_log'); end if;
  select coalesce(array_agg(distinct item),array[]::text[]) into v_columns from unnest(v_columns) item;

  delete from public.lso_role_permissions where role_name=p_role and permission_key in ('view','action','attendance_group','write_column');
  foreach v_value in array v_views loop insert into public.lso_role_permissions values(p_role,'view',v_value,true,now()); end loop;
  foreach v_value in array v_actions loop insert into public.lso_role_permissions values(p_role,'action',v_value,true,now()); end loop;
  foreach v_value in array v_groups loop insert into public.lso_role_permissions values(p_role,'attendance_group',v_value,true,now()); end loop;
  foreach v_value in array v_columns loop insert into public.lso_role_permissions values(p_role,'write_column',v_value,true,now()); end loop;

  insert into public.lso_role_profiles(role_name,landing_view,updated_at,updated_by)
  values(p_role,p_landing_view,now(),v_admin.username)
  on conflict(role_name) do update set landing_view=excluded.landing_view,updated_at=now(),updated_by=excluded.updated_by;

  return public.lso_get_permission_center(p_token);
end;
$$;

create or replace function public.lso_reset_role_permissions(p_token text,p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_admin public.lso_accounts%rowtype;
begin
  v_admin:=public.lso_admin_account(p_token);
  if p_role not in ('Membership','General Secretary','Staff Account','Trainee/Probationary') then
    raise exception 'The selected role is protected or invalid.' using errcode='22023';
  end if;
  perform public.lso_apply_default_role_configuration(p_role,v_admin.username);
  return public.lso_get_permission_center(p_token);
end;
$$;

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

  if not public.lso_role_can(v_reviewer_role, 'action', 'reviewDutyPunches') then
    raise exception 'This role is not assigned to review Duty Hours punches.' using errcode = '42501';
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

alter table public.lso_role_profiles enable row level security;
revoke all on table public.lso_role_profiles from anon, authenticated;
revoke all on function public.lso_default_role_configuration(text) from public;
revoke all on function public.lso_apply_default_role_configuration(text,text) from public;
revoke all on function public.lso_get_permission_center(text) from public;
revoke all on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) from public;
revoke all on function public.lso_reset_role_permissions(text,text) from public;
grant execute on function public.lso_get_permission_center(text) to anon, authenticated;
grant execute on function public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb) to anon, authenticated;
grant execute on function public.lso_reset_role_permissions(text,text) to anon, authenticated;

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
$$;

insert into public.lso_schema_migrations(migration_key,version_number,title,checksum,notes)
values('009_dynamic_role_permissions',9,'Dynamic Role and Permission Center','role-permission-009-v1','Administrator-controlled role landing pages, visible modules, action permissions, Attendance calendars, and derived server write access.')
on conflict(migration_key) do update set title=excluded.title,checksum=excluded.checksum,notes=excluded.notes;

commit;
notify pgrst, 'reload schema';
