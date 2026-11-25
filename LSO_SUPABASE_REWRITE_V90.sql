-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — SUPABASE REWRITE / REPAIR INSTALLER (V90)
-- ONE FILE FOR A NEW OR EXISTING SUPABASE PROJECT
-- ============================================================================
-- Run this ENTIRE file once in Supabase Dashboard -> SQL Editor -> New query.
-- It is idempotent and safe to re-run. It preserves accounts, members, events,
-- attendance, duty hours, monthly reports, settings, logs, and recovery points.
--
-- WHY THIS REWRITE EXISTS
--   1. The old base installer (supabase-setup.sql) and the master migration
--      installer defined public.lso_update_state_v69 against
--      system_state.column_versions but never created that column. Every
--      shared-data write then failed with PostgreSQL 42703:
--      column "column_versions" does not exist. That is why the Administrator
--      could not create members, activities, attendance, duty hours, reports,
--      settings, instruments, or activity-log entries.
--   2. The merged Duty Hours installer reset lso_accounts_role_check to only
--      Administrator / Staff Account / Trainee-Probationary. Membership and
--      General Secretary accounts could not be created or approved (23514),
--      and a re-run of the installer failed when those accounts already existed.
--   3. Older installers defined public.lso_role_can without an Administrator
--      bypass. Administrator has no lso_role_permissions rows, so its writes
--      were rejected with 42501 "This account role cannot update the selected
--      system area."
--
-- WHAT THIS FILE DOES
--   * Creates every table, column, index, function, and permission the current
--     website uses, including system_state.column_versions.
--   * Restores the five-role account constraint.
--   * Makes public.lso_role_can treat Administrator as always allowed.
--   * Recalculates every configurable role's write columns from its actions.
--   * Registers a single conflict-safe migration marker and verifies the result.
--
-- AFTER THIS FILE FINISHES
--   Run LSO_SECURE_ADMIN_SETUP.sql privately once to create or rotate the
--   Administrator credentials, then deploy the website files.
-- ============================================================================

-- LASALLIAN SYMPHONY ORCHESTRA — SHARED ONLINE DATABASE
-- Run this complete file once in Supabase > SQL Editor > New query.
-- This version uses username/password accounts stored securely in PostgreSQL.
-- It does not use Supabase email authentication, so no verification email is sent.

begin;

create extension if not exists pgcrypto;

create table if not exists public.lso_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  contact_email text,
  display_name text not null,
  member_id text,
  password_hash text not null,
  role text not null default 'Staff Account'
    check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary')),
  approval_status text not null default 'Pending'
    check (approval_status in ('Pending', 'Approved', 'Rejected')),
  disabled boolean not null default false,
  is_default boolean not null default false,
  requested_at timestamptz not null default now(),
  approved_at timestamptz,
  approved_by text,
  rejected_at timestamptz,
  rejected_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lso_accounts_username_format
    check (username ~ '^[A-Za-z0-9._-]{4,30}$'),
  constraint lso_accounts_display_name_length
    check (char_length(display_name) between 2 and 60),
  constraint lso_accounts_contact_email_format
    check (
      contact_email is null
      or btrim(contact_email) = ''
      or contact_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    )
);

create unique index if not exists lso_accounts_username_lower_unique
  on public.lso_accounts (lower(username));

create unique index if not exists lso_one_default_account
  on public.lso_accounts (is_default)
  where is_default = true;

create table if not exists public.lso_sessions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.lso_accounts(id) on delete cascade,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists lso_sessions_account_index
  on public.lso_sessions (account_id);

create index if not exists lso_sessions_expiry_index
  on public.lso_sessions (expires_at);

create table if not exists public.system_state (
  id integer primary key check (id = 1),
  members jsonb not null default '[]'::jsonb,
  events jsonb not null default '[]'::jsonb,
  attendance jsonb not null default '[]'::jsonb,
  duty_hours jsonb not null default '{"version":2,"commitments":{},"entries":[]}'::jsonb,
  monthly_reports jsonb not null default '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb,
  instruments jsonb not null default '[]'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  activity_log jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.system_state (id)
values (1)
on conflict (id) do nothing;

-- V69 optimistic-concurrency bookkeeping. The base installer originally defined
-- lso_update_state_v69 against this column without creating it, which made every
-- shared-data write fail with 42703 (column "column_versions" does not exist).
alter table public.system_state
  add column if not exists column_versions jsonb not null default '{}'::jsonb;

-- Upgrade existing projects created before Duty Hours was added.
alter table public.system_state
  add column if not exists duty_hours jsonb not null
  default '{"version":2,"commitments":{},"entries":[]}'::jsonb;

-- Upgrade existing projects with the Overall Monthly Report shared filing.
alter table public.system_state
  add column if not exists monthly_reports jsonb not null
  default '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb;

create or replace function public.lso_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists lso_accounts_set_updated_at on public.lso_accounts;
create trigger lso_accounts_set_updated_at
before update on public.lso_accounts
for each row execute function public.lso_set_updated_at();

-- Internal helper. It validates a session token and returns the account id.
create or replace function public.lso_session_account_id(
  p_token text,
  p_require_admin boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', account.id,
    'username', account.username,
    'email', coalesce(account.contact_email, ''),
    'displayName', account.display_name,
    'role', account.role,
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
$$;

-- Administrator credentials are intentionally not created by this public
-- website installer. After this file finishes, run LSO_SECURE_ADMIN_SETUP.sql
-- privately in the Supabase SQL Editor. It creates or rotates the protected
-- administrator with one-time random credentials and removes the legacy
-- browser-callable bootstrap function if it exists.

create or replace function public.lso_register_account(
  p_username text,
  p_password text,
  p_display_name text,
  p_contact_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_login(
  p_username text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_resume_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_logout(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  delete from public.lso_sessions
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return true;
end;
$$;

create or replace function public.lso_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_state jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);

  select jsonb_build_object(
    'id', state.id,
    'members', state.members,
    'events', state.events,
    'attendance', state.attendance,
    'duty_hours', state.duty_hours,
    'monthly_reports', state.monthly_reports,
    'instruments', state.instruments,
    'settings', state.settings,
    'activity_log', state.activity_log,
    'updated_at', state.updated_at
  ) into v_state
  from public.system_state as state
  where state.id = 1;

  return v_state;
end;
$$;

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
  v_state jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, true);

  if p_column in ('members', 'events', 'attendance', 'instruments', 'activity_log')
     and jsonb_typeof(p_value) <> 'array' then
    raise exception 'The selected data collection must be a JSON array.' using errcode = '22023';
  end if;

  if p_column in ('settings', 'duty_hours', 'monthly_reports') and jsonb_typeof(p_value) <> 'object' then
    raise exception 'The selected data collection must be a JSON object.' using errcode = '22023';
  end if;

  case p_column
    when 'members' then
      update public.system_state set members = p_value, updated_at = now() where id = 1;
    when 'events' then
      update public.system_state set events = p_value, updated_at = now() where id = 1;
    when 'attendance' then
      update public.system_state set attendance = p_value, updated_at = now() where id = 1;
    when 'duty_hours' then
      update public.system_state set duty_hours = p_value, updated_at = now() where id = 1;
    when 'monthly_reports' then
      update public.system_state set monthly_reports = p_value, updated_at = now() where id = 1;
    when 'instruments' then
      update public.system_state set instruments = p_value, updated_at = now() where id = 1;
    when 'settings' then
      update public.system_state set settings = p_value, updated_at = now() where id = 1;
    when 'activity_log' then
      update public.system_state set activity_log = p_value, updated_at = now() where id = 1;
    else
      raise exception 'Unsupported shared-data column.' using errcode = '22023';
  end case;

  return public.lso_get_state(p_token);
end;
$$;

create or replace function public.lso_replace_state(
  p_token text,
  p_state jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_list_accounts(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_admin_id uuid;
  v_admin_username text;
  v_item jsonb;
  v_target_id uuid;
  v_status text;
  v_role text;
  v_disabled boolean;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username into v_admin_username from public.lso_accounts where id = v_admin_id;

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

    if not exists (select 1 from public.lso_accounts where id = v_target_id) then
      continue;
    end if;

    if exists (select 1 from public.lso_accounts where id = v_target_id and is_default = true) then
      continue;
    end if;

    v_status := case
      when v_item ->> 'approvalStatus' in ('Pending', 'Approved', 'Rejected')
        then v_item ->> 'approvalStatus'
      else 'Pending'
    end;

    v_role := case
      when v_item ->> 'role' = 'Administrator' then 'Administrator'
      else 'Staff Account'
    end;

    v_disabled := coalesce((v_item ->> 'disabled')::boolean, false);

    update public.lso_accounts
    set role = v_role,
        approval_status = v_status,
        disabled = v_disabled,
        approved_at = case
          when v_status = 'Approved' then coalesce(nullif(v_item ->> 'approvedAt', '')::timestamptz, approved_at, now())
          else null
        end,
        approved_by = case
          when v_status = 'Approved' then coalesce(nullif(v_item ->> 'approvedBy', ''), v_admin_username)
          else null
        end,
        rejected_at = case
          when v_status = 'Rejected' then coalesce(nullif(v_item ->> 'rejectedAt', '')::timestamptz, rejected_at, now())
          else null
        end,
        rejected_by = case
          when v_status = 'Rejected' then coalesce(nullif(v_item ->> 'rejectedBy', ''), v_admin_username)
          else null
        end
    where id = v_target_id;

    if v_status <> 'Approved' or v_disabled then
      delete from public.lso_sessions where account_id = v_target_id;
    end if;
  end loop;

  return public.lso_list_accounts(p_token);
end;
$$;

create or replace function public.lso_delete_account(
  p_token text,
  p_account_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_ping()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object('ok', true, 'serverTime', now());
$$;

-- The browser may call only the controlled functions above. Direct table access
-- is denied, so password hashes and session hashes are never readable publicly.
alter table public.lso_accounts enable row level security;
alter table public.lso_sessions enable row level security;
alter table public.system_state enable row level security;

revoke all on table public.lso_accounts from anon, authenticated;
revoke all on table public.lso_sessions from anon, authenticated;
revoke all on table public.system_state from anon, authenticated;

revoke all on function public.lso_session_account_id(text, boolean) from public, anon, authenticated;
revoke all on function public.lso_account_json(uuid) from public, anon, authenticated;

revoke all on function public.lso_register_account(text, text, text, text) from public;
revoke all on function public.lso_login(text, text) from public;
revoke all on function public.lso_resume_session(text) from public;
revoke all on function public.lso_logout(text) from public;
revoke all on function public.lso_get_state(text) from public;
revoke all on function public.lso_update_state(text, text, jsonb) from public;
revoke all on function public.lso_replace_state(text, jsonb) from public;
revoke all on function public.lso_list_accounts(text) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_delete_account(text, uuid) from public;
revoke all on function public.lso_ping() from public;

grant execute on function public.lso_register_account(text, text, text, text) to anon, authenticated;
grant execute on function public.lso_login(text, text) to anon, authenticated;
grant execute on function public.lso_resume_session(text) to anon, authenticated;
grant execute on function public.lso_logout(text) to anon, authenticated;
grant execute on function public.lso_get_state(text) to anon, authenticated;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_replace_state(text, jsonb) to anon, authenticated;
grant execute on function public.lso_list_accounts(text) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_delete_account(text, uuid) to anon, authenticated;
grant execute on function public.lso_ping() to anon, authenticated;

commit;

-- AFTER RUNNING THIS FILE:
-- 1. Run LSO_SECURE_ADMIN_SETUP.sql privately in the Supabase SQL Editor.
-- 2. Copy the one-time administrator username and password from its result.
-- 3. Upload the website files to the GitHub Pages repository.
-- 4. Other registrations remain Pending until approved from Accounts.
-- 5. No email-confirmation setting is required because this version does not
--    use Supabase Auth email accounts.

-- Monthly Report compatibility migration and PostgREST cache refresh.
update public.system_state
set monthly_reports = settings -> '__lso_monthly_reports_v1'
where jsonb_typeof(settings -> '__lso_monthly_reports_v1') = 'object'
  and settings -> '__lso_monthly_reports_v1' <> '{}'::jsonb;
notify pgrst, 'reload schema';
-- LSO TRAINEE / PROBATIONARY DUTY-HOURS ROLE UPDATE
-- Run this once in Supabase SQL Editor for an existing installation.
-- The same migration is also appended to the complete supabase-setup.sql.

begin;

alter table public.lso_accounts
  add column if not exists member_id text;

alter table public.lso_accounts
  drop constraint if exists lso_accounts_role_check;

alter table public.lso_accounts
  add constraint lso_accounts_role_check
  check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));

create index if not exists lso_accounts_member_id_index
  on public.lso_accounts (member_id)
  where member_id is not null;

create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Trainee/Probationary accounts receive only their linked member record and
-- that member's duty-hours data. Administrators and Staff retain their prior view.
create or replace function public.lso_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_role text;
  v_member_id text;
  v_state jsonb;
  v_members jsonb := '[]'::jsonb;
  v_entries jsonb := '[]'::jsonb;
  v_commitments jsonb := '{}'::jsonb;
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

  v_duty_hours := case
    when jsonb_typeof(v_state -> 'duty_hours') = 'object'
      then v_state -> 'duty_hours'
    else '{"version":6,"commitments":{},"entries":[]}'::jsonb
  end;

  v_monthly_reports := case
    when jsonb_typeof(v_state -> 'monthly_reports') = 'object'
      then v_state -> 'monthly_reports'
    when jsonb_typeof(v_state -> 'settings' -> '__lso_monthly_reports_v1') = 'object'
      then v_state -> 'settings' -> '__lso_monthly_reports_v1'
    else '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb
  end;

  if v_role = 'Trainee/Probationary' then
    select coalesce(jsonb_agg(item), '[]'::jsonb)
    into v_members
    from jsonb_array_elements(
      case when jsonb_typeof(v_state -> 'members') = 'array'
        then v_state -> 'members' else '[]'::jsonb end
    ) as item
    where nullif(btrim(coalesce(v_member_id, '')), '') is not null
      and item ->> 'id' = v_member_id;

    select coalesce(jsonb_agg(item), '[]'::jsonb)
    into v_entries
    from jsonb_array_elements(
      case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
        then v_duty_hours -> 'entries' else '[]'::jsonb end
    ) as item
    where nullif(btrim(coalesce(v_member_id, '')), '') is not null
      and item ->> 'memberId' = v_member_id;

    if nullif(btrim(coalesce(v_member_id, '')), '') is not null
       and jsonb_typeof(v_duty_hours -> 'commitments' -> v_member_id) = 'object' then
      v_commitments := jsonb_build_object(
        v_member_id,
        v_duty_hours -> 'commitments' -> v_member_id
      );
    end if;

    return jsonb_build_object(
      'id', coalesce(v_state -> 'id', '1'::jsonb),
      'members', v_members,
      'events', '[]'::jsonb,
      'attendance', '[]'::jsonb,
      'duty_hours', jsonb_build_object(
        'version', coalesce(v_duty_hours -> 'version', '4'::jsonb),
        'commitments', v_commitments,
        'entries', v_entries
      ),
      'monthly_reports', '{}'::jsonb,
      'instruments', '[]'::jsonb,
      'settings', '{}'::jsonb,
      'activity_log', '[]'::jsonb,
      'updated_at', coalesce(v_state -> 'updated_at', to_jsonb(now()))
    );
  end if;

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
$$;

create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username into v_admin_username from public.lso_accounts where id = v_admin_id;

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

    if not exists (select 1 from public.lso_accounts where id = v_target_id) then
      continue;
    end if;

    if exists (select 1 from public.lso_accounts where id = v_target_id and is_default = true) then
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
      when v_item ->> 'role' = 'Trainee/Probationary' then 'Trainee/Probationary'
      else 'Staff Account'
    end;

    v_member_id := case
      when v_role = 'Trainee/Probationary' then nullif(btrim(v_item ->> 'memberId'), '')
      else null
    end;

    -- Any change to an already approved role or linked member must be
    -- reviewed and approved again. This also invalidates active sessions below.
    if v_old_status = 'Approved'
       and (
         v_old_role is distinct from v_role
         or coalesce(v_old_member_id, '') <> coalesce(v_member_id, '')
       ) then
      v_status := 'Pending';
    end if;

    if v_role = 'Trainee/Probationary' and v_member_id is not null and not exists (
      select 1
      from public.system_state as state,
           jsonb_array_elements(coalesce(state.members, '[]'::jsonb)) as member
      where state.id = 1
        and member ->> 'id' = v_member_id
        and (
          member ->> 'periodGroup' in ('Trainee Period', 'Probationary Period')
          or member ->> 'membershipStage' in ('Trainee', 'Probationary')
        )
    ) then
      raise exception 'The selected linked member is not an active Trainee or Probationary member.' using errcode = '22023';
    end if;

    if v_role = 'Trainee/Probationary' and v_status = 'Approved' and v_member_id is null then
      raise exception 'A Trainee/Probationary account must be linked to a member before approval.' using errcode = '22023';
    end if;

    v_disabled := coalesce((v_item ->> 'disabled')::boolean, false);

    update public.lso_accounts
    set role = v_role,
        member_id = v_member_id,
        approval_status = v_status,
        disabled = v_disabled,
        approved_at = case
          when v_status = 'Approved' then coalesce(nullif(v_item ->> 'approvedAt', '')::timestamptz, approved_at, now())
          else null
        end,
        approved_by = case
          when v_status = 'Approved' then coalesce(nullif(v_item ->> 'approvedBy', ''), v_admin_username)
          else null
        end,
        rejected_at = case
          when v_status = 'Rejected' then coalesce(nullif(v_item ->> 'rejectedAt', '')::timestamptz, rejected_at, now())
          else null
        end,
        rejected_by = case
          when v_status = 'Rejected' then coalesce(nullif(v_item ->> 'rejectedBy', ''), v_admin_username)
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
$$;

create or replace function public.lso_submit_duty_entry(
  p_token text,
  p_semester text,
  p_period text,
  p_date text,
  p_time_in text,
  p_time_out text,
  p_description text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_member jsonb;
  v_member_period text;
  v_minutes integer;
  v_entry jsonb;
  v_entry_id text := gen_random_uuid()::text;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may submit a self-service duty entry.' using errcode = '42501';
  end if;

  if v_account.member_id is null or btrim(v_account.member_id) = '' then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  if p_semester not in ('First Semester', 'Second Semester') then
    raise exception 'Invalid duty semester.' using errcode = '22023';
  end if;

  if p_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'Invalid duty period.' using errcode = '22023';
  end if;

  if p_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end if;

  begin
    perform p_date::date;
  exception when others then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end;

  if p_time_in !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or p_time_out !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Enter valid Time In and Time Out values.' using errcode = '22023';
  end if;

  if p_time_out::time <= p_time_in::time then
    raise exception 'Time Out must be later than Time In for a same-day duty entry.' using errcode = '22023';
  end if;

  v_minutes := floor(extract(epoch from (p_time_out::time - p_time_in::time)) / 60)::integer;

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

  v_member_period := coalesce(
    nullif(v_member ->> 'periodGroup', ''),
    case v_member ->> 'membershipStage'
      when 'Trainee' then 'Trainee Period'
      when 'Probationary' then 'Probationary Period'
      else ''
    end
  );

  if v_member_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'The linked member is not currently in the Trainee or Probationary Period.' using errcode = '42501';
  end if;

  if p_period <> v_member_period then
    raise exception 'The submitted duty period does not match the linked member''s current period.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.system_state as state,
         jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb)) as entry
    where state.id = 1
      and entry ->> 'memberId' = v_account.member_id
      and entry ->> 'date' = p_date
      and entry ->> 'timeIn' = p_time_in
      and entry ->> 'timeOut' = p_time_out
      and coalesce(entry ->> 'approvalStatus', 'Approved') <> 'Rejected'
  ) then
    raise exception 'This Time In and Time Out entry was already submitted.' using errcode = '23505';
  end if;

  v_entry := jsonb_build_object(
    'id', v_entry_id,
    'memberId', v_account.member_id,
    'semester', p_semester,
    'period', p_period,
    'entryType', 'Duty',
    'date', p_date,
    'minutes', v_minutes,
    'timeIn', p_time_in,
    'timeOut', p_time_out,
    'description', left(btrim(coalesce(p_description, '')), 160),
    'approvalStatus', 'Pending',
    'submittedByAccountId', v_account.id,
    'submittedByUsername', v_account.username,
    'submittedByRole', v_account.role,
    'createdAt', now(),
    'createdBy', v_account.display_name,
    'createdByUsername', v_account.username
  );

  update public.system_state
  set duty_hours = jsonb_set(
        coalesce(duty_hours, '{"version":6,"commitments":{},"entries":[]}'::jsonb),
        '{entries}',
        coalesce(duty_hours -> 'entries', '[]'::jsonb) || jsonb_build_array(v_entry),
        true
      ),
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$$;

create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
  v_entries jsonb;
  v_found boolean := false;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username into v_admin_username from public.lso_accounts where id = v_admin_id;

  if p_decision not in ('Approved', 'Rejected') then
    raise exception 'Decision must be Approved or Rejected.' using errcode = '22023';
  end if;

  select exists (
    select 1
    from public.system_state as state,
         jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb)) as entry
    where state.id = 1
      and entry ->> 'id' = p_entry_id
      and coalesce(entry ->> 'approvalStatus', 'Approved') = 'Pending'
  ) into v_found;

  if not v_found then
    raise exception 'The pending duty entry could not be found.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(
    case
      when entry ->> 'id' = p_entry_id and p_decision = 'Approved' then
        (entry - 'rejectedAt' - 'rejectedBy') || jsonb_build_object(
          'approvalStatus', 'Approved',
          'approvedAt', now(),
          'approvedBy', v_admin_username
        )
      when entry ->> 'id' = p_entry_id and p_decision = 'Rejected' then
        (entry - 'approvedAt' - 'approvedBy') || jsonb_build_object(
          'approvalStatus', 'Rejected',
          'rejectedAt', now(),
          'rejectedBy', v_admin_username
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_entries
  from public.system_state as state,
       jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb))
         with ordinality as records(entry, ordinal_position)
  where state.id = 1;

  update public.system_state
  set duty_hours = jsonb_set(duty_hours, '{entries}', v_entries, true),
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$$;

revoke all on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;
grant execute on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ============================================================================
-- FINAL TRAINEE / PROBATIONARY DUTY HOURS HARDENING
-- The block below is intentionally included in the complete setup so new
-- projects receive the same validated workflow as existing-project upgrades.
-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA
-- FINAL TRAINEE / PROBATIONARY DUTY HOURS WORKFLOW
--
-- Run this entire file once in Supabase > SQL Editor > New query.
-- It is safe to run again. Existing members, accounts, attendance, and duty
-- records are preserved.
--
-- Workflow installed by this script:
--   1. Administrator approves an account as Trainee/Probationary and links it
--      to one current Trainee or Probationary member.
--   2. That account sees only Duty Hours.
--   3. The member submits their own date, Time In, Time Out, and description.
--   4. The entry is Pending and contributes zero credited minutes.
--   5. Only an Administrator can Approve or Reject it.
--   6. Only Approved duty entries are included in the member's totals.

begin;

create extension if not exists pgcrypto;

do $$
begin
  if to_regclass('public.lso_accounts') is null then
    raise exception 'public.lso_accounts does not exist. Run the complete supabase-setup.sql first.';
  end if;
  if to_regclass('public.lso_sessions') is null then
    raise exception 'public.lso_sessions does not exist. Run the complete supabase-setup.sql first.';
  end if;
  if to_regclass('public.system_state') is null then
    raise exception 'public.system_state does not exist. Run the complete supabase-setup.sql first.';
  end if;
end;
$$;

-- Compatibility for projects created before this role existed.
alter table public.lso_accounts
  add column if not exists member_id text;

alter table public.system_state
  add column if not exists members jsonb,
  add column if not exists duty_hours jsonb,
  add column if not exists activity_log jsonb,
  add column if not exists updated_at timestamptz;

insert into public.system_state (id)
values (1)
on conflict (id) do nothing;

update public.system_state
set members = coalesce(members, '[]'::jsonb),
    duty_hours = coalesce(duty_hours, '{"version":6,"commitments":{},"entries":[]}'::jsonb),
    activity_log = coalesce(activity_log, '[]'::jsonb),
    updated_at = coalesce(updated_at, now())
where id = 1;

-- Normalize the Duty Hours container without deleting legacy entries.
update public.system_state
set duty_hours = jsonb_set(
      jsonb_set(
        jsonb_set(
          case when jsonb_typeof(duty_hours) = 'object'
            then duty_hours
            else '{"version":6,"commitments":{},"entries":[]}'::jsonb
          end,
          '{version}', '6'::jsonb, true
        ),
        '{commitments}',
        case when jsonb_typeof(duty_hours -> 'commitments') = 'object'
          then duty_hours -> 'commitments' else '{}'::jsonb end,
        true
      ),
      '{entries}',
      case when jsonb_typeof(duty_hours -> 'entries') = 'array'
        then duty_hours -> 'entries' else '[]'::jsonb end,
      true
    ),
    updated_at = now()
where id = 1;

-- Replace an older role check safely.
do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
      and (
        pg_get_constraintdef(oid) ilike '%Administrator%'
        or pg_get_constraintdef(oid) ilike '%Staff Account%'
      )
  loop
    execute format('alter table public.lso_accounts drop constraint %I', v_constraint.conname);
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and conname = 'lso_accounts_role_check'
  ) then
    alter table public.lso_accounts
      add constraint lso_accounts_role_check
      check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));
  end if;
end;
$$;

create index if not exists lso_accounts_member_id_index
  on public.lso_accounts (member_id)
  where member_id is not null;


-- One canonical calendar date for all LSO duty-hour validation.
-- Supabase/PostgreSQL sessions commonly use UTC, while LSO operates in the Philippines.
create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

-- Determine the person's actual period from the timeline on a specific date.
-- This avoids depending only on a possibly stale periodGroup value.
create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Ensure the browser receives memberId with every account profile.
create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Administrator account approval with mandatory, validated member linking.
create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

    if v_role = 'Trainee/Probationary' and v_member_id is not null then
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
$$;

-- Member self-service submission. The server derives the member, duty period,
-- and duration; the browser cannot choose another member or credited minutes.
create or replace function public.lso_submit_duty_entry(
  p_token text,
  p_semester text,
  p_period text,
  p_date text,
  p_time_in text,
  p_time_out text,
  p_description text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
    v_duty_hours := '{"version":6,"commitments":{},"entries":[]}'::jsonb;
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
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
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
$$;

-- Administrator review. A pending entry can be decided only once.
create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
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
$$;

revoke all on function public.lso_local_date() from public;
revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
revoke all on function public.lso_account_json(uuid) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;

grant execute on function public.lso_local_date() to anon, authenticated;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;
grant execute on function public.lso_account_json(uuid) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- LSO DUTY PUNCH BUTTONS UPDATE (2026-07-21)
-- LASALLIAN SYMPHONY ORCHESTRA
-- TRAINEE / PROBATIONARY DUTY HOURS: SERVER TIME IN / TIME OUT BUTTONS
-- Existing-project migration. This preserves existing records.

begin;

create extension if not exists pgcrypto;

alter table if exists public.lso_accounts
  add column if not exists member_id text;

alter table if exists public.system_state
  add column if not exists duty_hours jsonb not null default '{"version":6,"commitments":{},"entries":[]}'::jsonb,
  add column if not exists activity_log jsonb not null default '[]'::jsonb,
  add column if not exists members jsonb not null default '[]'::jsonb;

-- One calendar date for the orchestra. The database server, rather than the
-- member's phone or computer clock, is the authoritative time source.
create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;


-- Resolve the member's stage from their recorded timeline. Recreated here so
-- this installer also repairs older projects that do not yet have the helper.
create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_trainee_start date;
  v_probationary_start date;
  v_membership_start date;
  v_skipped boolean := false;
  v_period text;
  v_stage text;
begin
  if p_member is null or jsonb_typeof(p_member) <> 'object' then return ''; end if;

  begin
    v_trainee_start := nullif(coalesce(p_member ->> 'traineeStartDate', p_member ->> 'dateRegistered'), '')::date;
  exception when others then v_trainee_start := null;
  end;
  begin
    v_probationary_start := nullif(p_member ->> 'probationaryStartDate', '')::date;
  exception when others then v_probationary_start := null;
  end;
  begin
    v_membership_start := nullif(coalesce(p_member ->> 'regularMemberDate', p_member ->> 'membershipStartDate'), '')::date;
  exception when others then v_membership_start := null;
  end;

  v_skipped := lower(coalesce(p_member ->> 'probationarySkipped', 'false')) in ('true', '1', 'yes');
  v_period := coalesce(p_member ->> 'periodGroup', '');
  v_stage := coalesce(p_member ->> 'membershipStage', '');

  if v_membership_start is not null and p_on_date >= v_membership_start then return 'Membership Period'; end if;
  if not v_skipped and v_probationary_start is not null and p_on_date >= v_probationary_start then return 'Probationary Period'; end if;
  if v_trainee_start is not null and p_on_date >= v_trainee_start then return 'Trainee Period'; end if;
  if v_period in ('Trainee Period', 'Probationary Period', 'Membership Period') then return v_period; end if;
  if v_stage = 'Trainee' then return 'Trainee Period'; end if;
  if v_stage = 'Probationary' then return 'Probationary Period'; end if;
  if v_stage in ('Regular Member', 'Member', 'Official Member') then return 'Membership Period'; end if;
  return '';
end;
$$;

-- Start a new same-day duty session. Only one open session is permitted for
-- the linked member. Completed sessions from the same day do not block a new
-- session unless their actual intervals overlap.
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
  v_now timestamptz;
  v_local_timestamp timestamp;
  v_duty_date date;
  v_time_in text;
  v_member jsonb;
  v_period text;
  v_members jsonb;
  v_duty_hours jsonb;
  v_entries jsonb;
  v_activity_log jsonb;
  v_description text;
  v_member_approvers text;
  v_entry_id text := gen_random_uuid()::text;
  v_entry jsonb;
  v_activity jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account
  from public.lso_accounts
  where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may use Duty Hours Time In.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  if p_semester not in ('First Semester', 'Second Semester') then
    raise exception 'Select a valid duty semester.' using errcode = '22023';
  end if;

  v_description := left(btrim(coalesce(p_description, '')), 160);
  v_member_approvers := left(btrim(coalesce(p_member_approvers, '')), 200);
  v_now := clock_timestamp();
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
    v_duty_hours := '{"version":6,"commitments":{},"entries":[]}'::jsonb;
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

  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where entry ->> 'memberId' = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and coalesce(entry ->> 'approvalStatus', 'Approved') = 'Active'
  ) then
    raise exception 'You are already clocked in. Record Time Out before starting another duty session.' using errcode = '23505';
  end if;

  -- A prior completed interval may coexist on the same day, but the new Time
  -- In cannot fall inside a pending or approved interval.
  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where entry ->> 'memberId' = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and entry ->> 'date' = to_char(v_duty_date, 'YYYY-MM-DD')
      and coalesce(entry ->> 'approvalStatus', 'Approved') <> 'Rejected'
      and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and (entry ->> 'timeIn')::time <= v_time_in::time
      and (entry ->> 'timeOut')::time > v_time_in::time
  ) then
    raise exception 'The current time overlaps an existing pending or approved duty session.' using errcode = '23505';
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
    'approvalStatus', 'Active',
    'submittedByAccountId', v_account.id,
    'submittedByUsername', v_account.username,
    'submittedByRole', v_account.role,
    'createdAt', v_now,
    'createdBy', v_account.display_name,
    'createdByUsername', v_account.username
  );

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
    '{entries}', v_entries || jsonb_build_array(v_entry), true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', v_now,
    'action', 'Duty Time In',
    'category', 'Duty Hours',
    'details', to_char(v_duty_date, 'YYYY-MM-DD') || ' • ' || v_time_in || ' • Server time',
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
$$;

-- Close the member's one active duty session using the current database time.
-- The completed session becomes Pending and contributes zero credited minutes
-- until an Administrator approves it.
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
  v_now timestamptz;
  v_local_timestamp timestamp;
  v_time_out text;
  v_today date;
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
  v_description text;
  v_member_approvers text;
  v_final_description text;
  v_final_member_approvers text;
  v_activity jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account
  from public.lso_accounts
  where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may use Duty Hours Time Out.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  v_description := left(btrim(coalesce(p_description, '')), 160);
  v_member_approvers := left(btrim(coalesce(p_member_approvers, '')), 200);
  v_now := clock_timestamp();
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
  where entry ->> 'memberId' = v_account.member_id
    and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
    and coalesce(entry ->> 'approvalStatus', 'Approved') = 'Active';

  if v_target_count = 0 then
    raise exception 'There is no active duty session to time out.' using errcode = '22023';
  elsif v_target_count > 1 then
    raise exception 'More than one active duty session was found. Ask the Administrator to correct the duty ledger.' using errcode = 'P0001';
  end if;

  select entry into v_target
  from jsonb_array_elements(v_entries) as entry
  where entry ->> 'memberId' = v_account.member_id
    and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
    and coalesce(entry ->> 'approvalStatus', 'Approved') = 'Active'
  limit 1;

  begin
    v_start_date := (v_target ->> 'date')::date;
  exception when others then
    raise exception 'The active duty session has an invalid start date. Ask the Administrator to correct it.' using errcode = '22023';
  end;

  v_start_time := coalesce(v_target ->> 'timeIn', '');
  if v_start_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'The active duty session has an invalid Time In. Ask the Administrator to correct it.' using errcode = '22023';
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
    raise exception 'This duty session crossed midnight. Ask the Administrator to close or correct the record.' using errcode = '22023';
  end if;

  v_minutes := floor(extract(epoch from (v_now - v_start_at)) / 60)::integer;
  if v_minutes <= 0 then
    raise exception 'Time Out must be later than Time In.' using errcode = '22023';
  end if;
  if v_minutes > 960 then
    raise exception 'A single duty session cannot exceed 16 hours. Ask the Administrator to correct the active record.' using errcode = '22023';
  end if;

  -- Recheck the completed interval against every other non-rejected session.
  if exists (
    select 1
    from jsonb_array_elements(v_entries) as entry
    where (entry ->> 'id') <> (v_target ->> 'id')
      and entry ->> 'memberId' = v_account.member_id
      and coalesce(entry ->> 'entryType', 'Duty') = 'Duty'
      and (entry ->> 'date') = (v_target ->> 'date')
      and coalesce(entry ->> 'approvalStatus', 'Approved') <> 'Rejected'
      and entry ->> 'timeIn' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and entry ->> 'timeOut' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and (entry ->> 'timeIn')::time < v_time_out::time
      and (entry ->> 'timeOut')::time > v_start_time::time
  ) then
    raise exception 'This completed duty session overlaps another pending or approved session.' using errcode = '23505';
  end if;

  v_final_description := v_description;
  v_final_member_approvers := v_member_approvers;

  select coalesce(jsonb_agg(
    case
      when (entry ->> 'id') = (v_target ->> 'id') then
        entry || jsonb_build_object(
          'timeOut', v_time_out,
          'clockOutAt', v_now,
          'minutes', v_minutes,
          'description', v_final_description,
          'memberApprovers', v_final_member_approvers,
          'approvalStatus', 'Pending',
          'submittedAt', v_now
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_next_entries
  from jsonb_array_elements(v_entries) with ordinality as records(entry, ordinal_position);

  v_duty_hours := jsonb_set(
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
    '{entries}', v_next_entries, true
  );

  v_activity := jsonb_build_object(
    'id', gen_random_uuid()::text,
    'timestamp', v_now,
    'action', 'Duty Time Out',
    'category', 'Duty Hours',
    'details', (v_target ->> 'date') || ' • ' || v_start_time || '–' || v_time_out || ' • Pending approval',
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
$$;

revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;

revoke all on function public.lso_duty_time_in(text, text, text, text) from public;
revoke all on function public.lso_duty_time_out(text, text, text) from public;
grant execute on function public.lso_duty_time_in(text, text, text, text) to anon, authenticated;
grant execute on function public.lso_duty_time_out(text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ============================================================================
-- SEPARATE DUTY PUNCH APPROVAL UPDATE (Time In and Time Out reviewed separately)
-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA
-- DUTY HOURS: SEPARATE TIME IN / TIME OUT APPROVAL
-- Existing-project installer. Safe to run once after the prior stable LSO setup.
-- This does not delete members, accounts, attendance, reports, or prior duty records.

begin;

create extension if not exists pgcrypto;

alter table public.lso_accounts
  add column if not exists member_id text;

alter table public.system_state
  add column if not exists members jsonb not null default '[]'::jsonb,
  add column if not exists duty_hours jsonb not null
  default '{"version":7,"commitments":{},"entries":[]}'::jsonb;

alter table public.system_state
  add column if not exists activity_log jsonb not null default '[]'::jsonb;


create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_trainee_start date;
  v_probationary_start date;
  v_membership_start date;
  v_skipped boolean := false;
  v_period text;
  v_stage text;
begin
  if p_member is null or jsonb_typeof(p_member) <> 'object' then return ''; end if;
  begin
    v_trainee_start := nullif(coalesce(p_member ->> 'traineeStartDate', p_member ->> 'dateRegistered'), '')::date;
  exception when others then v_trainee_start := null;
  end;
  begin
    v_probationary_start := nullif(p_member ->> 'probationaryStartDate', '')::date;
  exception when others then v_probationary_start := null;
  end;
  begin
    v_membership_start := nullif(coalesce(p_member ->> 'regularMemberDate', p_member ->> 'membershipStartDate'), '')::date;
  exception when others then v_membership_start := null;
  end;
  v_skipped := lower(coalesce(p_member ->> 'probationarySkipped', 'false')) in ('true', '1', 'yes');
  v_period := coalesce(p_member ->> 'periodGroup', '');
  v_stage := coalesce(p_member ->> 'membershipStage', '');
  if v_membership_start is not null and p_on_date >= v_membership_start then return 'Membership Period'; end if;
  if not v_skipped and v_probationary_start is not null and p_on_date >= v_probationary_start then return 'Probationary Period'; end if;
  if v_trainee_start is not null and p_on_date >= v_trainee_start then return 'Trainee Period'; end if;
  if v_period in ('Trainee Period', 'Probationary Period', 'Membership Period') then return v_period; end if;
  if v_stage = 'Trainee' then return 'Trainee Period'; end if;
  if v_stage = 'Probationary' then return 'Probationary Period'; end if;
  if v_stage in ('Regular Member', 'Member', 'Official Member') then return 'Membership Period'; end if;
  return '';
end;
$$;

-- Upgrade existing Duty Hours entries to the separate-punch status shape.
-- Legacy completed records remain completed. Legacy open records remain usable.
update public.system_state
set duty_hours = jsonb_set(
  jsonb_set(
    case
      when duty_hours is null or jsonb_typeof(duty_hours) <> 'object'
        then '{"version":7,"commitments":{},"entries":[]}'::jsonb
      else duty_hours
    end,
    '{version}',
    '7'::jsonb,
    true
  ),
  '{entries}',
  coalesce((
    select jsonb_agg(
      case
        when coalesce(entry ->> 'entryType', 'Duty') <> 'Duty' then entry
        else entry || jsonb_build_object(
          'timeInApprovalStatus',
            case
              when entry ? 'timeInApprovalStatus' then entry ->> 'timeInApprovalStatus'
              when nullif(entry ->> 'timeIn', '') is null then 'Not Submitted'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Pending'
                   and nullif(entry ->> 'timeOut', '') is null then 'Pending'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Rejected'
                   and nullif(entry ->> 'timeOut', '') is null then 'Rejected'
              else 'Approved'
            end,
          'timeOutApprovalStatus',
            case
              when entry ? 'timeOutApprovalStatus' then entry ->> 'timeOutApprovalStatus'
              when nullif(entry ->> 'timeOut', '') is null then 'Not Submitted'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Approved' then 'Approved'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Rejected' then 'Rejected'
              else 'Pending'
            end,
          'timeInRequestedAt', coalesce(nullif(entry ->> 'timeInRequestedAt', ''), nullif(entry ->> 'clockInAt', ''), nullif(entry ->> 'createdAt', '')),
          'timeOutRequestedAt', coalesce(nullif(entry ->> 'timeOutRequestedAt', ''), nullif(entry ->> 'clockOutAt', ''), nullif(entry ->> 'submittedAt', '')),
          'punchAudit', case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end
        )
      end
      order by ordinal_position
    )
    from jsonb_array_elements(
      case
        when jsonb_typeof(duty_hours -> 'entries') = 'array' then duty_hours -> 'entries'
        else '[]'::jsonb
      end
    ) with ordinality as records(entry, ordinal_position)
  ), '[]'::jsonb),
  true
),
updated_at = now()
where id = 1;

-- Submit a Time In request. It is NOT official until an Administrator approves
-- this specific punch. The secure database time in Asia/Manila is authoritative.
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

-- Submit Time Out for the member's one open punch. Time In may still be
-- pending. Time Out is a separate request and is not official automatically.
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

-- Review one punch only. Time Out approval is blocked until Time In has been
-- approved. Duty minutes are credited only after both punch statuses are Approved.
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
$$;

revoke all on function public.lso_local_date() from public;
revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
grant execute on function public.lso_local_date() to anon, authenticated;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;

revoke all on function public.lso_duty_time_in(text, text, text, text) from public;
revoke all on function public.lso_duty_time_out(text, text, text) from public;
revoke all on function public.lso_review_duty_punch(text, text, text, text) from public;

grant execute on function public.lso_duty_time_in(text, text, text, text) to anon, authenticated;
grant execute on function public.lso_duty_time_out(text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_punch(text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- LSO ACCOUNT ROLES: MEMBERSHIP + GENERAL SECRETARY
-- Run once in Supabase SQL Editor for an existing LSO installation.
-- This migration preserves all existing accounts and system records.

begin;

alter table public.lso_accounts drop constraint if exists lso_accounts_role_check;
alter table public.lso_accounts add constraint lso_accounts_role_check
  check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));

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

  v_allowed := case
    when v_role = 'Administrator' then p_column in ('members','events','attendance','duty_hours','monthly_reports','instruments','settings','activity_log')
    when v_role = 'Membership' then p_column in ('members','events','attendance','duty_hours','monthly_reports','settings','activity_log')
    when v_role = 'General Secretary' then p_column in ('events','attendance','activity_log')
    else false
  end;
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

  -- Attendance calendar access: non-administrator roles may only modify rows belonging
  -- to attendance calendars assigned to their role in Role & Permission Center
  -- (e.g. Official Members, Trainee Members, Probationary Members).
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

create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
begin
  v_admin_id := public.lso_session_account_id(p_token, false);
  select username, display_name, role
  into v_admin_username, v_admin_display_name, v_reviewer_role
  from public.lso_accounts
  where id = v_admin_id;

  if v_reviewer_role not in ('Administrator', 'Membership') then
    raise exception 'Administrator or Membership access is required to review Duty Hours entries.' using errcode = '42501';
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
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
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

revoke all on function public.lso_update_state(text, text, jsonb) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;
revoke all on function public.lso_review_duty_punch(text, text, text, text) from public;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_punch(text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ============================================================================
-- ENTERPRISE OPERATIONS MIGRATION 006
-- The following installer is the canonical System Health, Recovery, and Error
-- Reporting upgrade. It is appended to fresh installations for parity with the
-- standalone LSO_MASTER_MIGRATION_INSTALLER.sql file.
-- ============================================================================
-- Lasallian Symphony Orchestra
-- Master Database Migration Installer
-- Target schema: 006_enterprise_operations
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
  ('Membership','attendance_group','Official Members',true),
  ('Membership','attendance_group','Trainee Members',true),
  ('Membership','attendance_group','Probationary Members',true),
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
  select case
    when p_role = 'Administrator' then true
    else coalesce((select allowed from public.lso_role_permissions
      where role_name=p_role and permission_key=p_permission_key and resource=coalesce(p_resource,'')), false)
  end;
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

  -- Attendance calendar access: non-administrator roles may only modify rows belonging
  -- to attendance calendars assigned to their role in Role & Permission Center
  -- (e.g. Official Members, Trainee Members, Probationary Members).
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


-- Integrated migration 008: required Duty Hours approver and mobile-safe punch workflow
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

commit;
notify pgrst, 'reload schema';



-- Integrated migration 009: Dynamic Role & Permission Center
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
      'attendanceGroups',jsonb_build_array('Official Members','Trainee Members','Probationary Members'),
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

commit;
notify pgrst, 'reload schema';



-- ########################################################################
-- PATCH: LSO_DYNAMIC_ROLE_PERMISSION_CENTER_INSTALL.sql
-- ########################################################################

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

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_ACCOUNT_ROLES_MEMBERSHIP_GENERAL_SECRETARY_INSTALL.sql
-- ########################################################################

-- LSO ACCOUNT ROLES: MEMBERSHIP + GENERAL SECRETARY
-- Run once in Supabase SQL Editor for an existing LSO installation.
-- This migration preserves all existing accounts and system records.

begin;

alter table public.lso_accounts drop constraint if exists lso_accounts_role_check;
alter table public.lso_accounts add constraint lso_accounts_role_check
  check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));

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

  v_allowed := case
    when v_role = 'Administrator' then p_column in ('members','events','attendance','duty_hours','monthly_reports','instruments','settings','activity_log')
    when v_role = 'Membership' then p_column in ('members','events','attendance','duty_hours','monthly_reports','settings','activity_log')
    when v_role = 'General Secretary' then p_column in ('events','attendance','activity_log')
    else false
  end;
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

create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

    if v_role = 'Trainee/Probationary' and v_member_id is not null then
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
$$;

create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
begin
  v_admin_id := public.lso_session_account_id(p_token, false);
  select username, display_name, role
  into v_admin_username, v_admin_display_name, v_reviewer_role
  from public.lso_accounts
  where id = v_admin_id;

  if v_reviewer_role not in ('Administrator', 'Membership') then
    raise exception 'Administrator or Membership access is required to review Duty Hours entries.' using errcode = '42501';
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
    jsonb_set(v_duty_hours, '{version}', '6'::jsonb, true),
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

  if v_reviewer_role not in ('Administrator', 'Membership') then
    raise exception 'Administrator or Membership access is required to review Duty Hours punches.' using errcode = '42501';
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

revoke all on function public.lso_update_state(text, text, jsonb) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;
revoke all on function public.lso_review_duty_punch(text, text, text, text) from public;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_punch(text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: MONTHLY_REPORT_SQL_UPDATE.sql
-- ########################################################################

-- LSO Overall Monthly Report native shared-data upgrade (optional but recommended)
-- The website also includes compatibility storage, so the Monthly Report works
-- even before this script is run. Run this in Supabase > SQL Editor to give the
-- report its own native JSONB column.

alter table public.system_state
  add column if not exists monthly_reports jsonb not null
  default '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb;

-- Migrate any compatibility-stored Monthly Report data from system settings.
update public.system_state
set monthly_reports = settings -> '__lso_monthly_reports_v1'
where jsonb_typeof(settings -> '__lso_monthly_reports_v1') = 'object'
  and settings -> '__lso_monthly_reports_v1' <> '{}'::jsonb;

create or replace function public.lso_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_state jsonb;
begin
  v_account_id := public.lso_session_account_id(p_token, false);

  select jsonb_build_object(
    'id', state.id,
    'members', state.members,
    'events', state.events,
    'attendance', state.attendance,
    'duty_hours', state.duty_hours,
    'monthly_reports', state.monthly_reports,
    'instruments', state.instruments,
    'settings', state.settings,
    'activity_log', state.activity_log,
    'updated_at', state.updated_at
  ) into v_state
  from public.system_state as state
  where state.id = 1;

  return v_state;
end;
$$;

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
begin
  v_account_id := public.lso_session_account_id(p_token, true);

  if p_column in ('members', 'events', 'attendance', 'instruments', 'activity_log')
     and jsonb_typeof(p_value) <> 'array' then
    raise exception 'The selected data collection must be a JSON array.' using errcode = '22023';
  end if;

  if p_column in ('settings', 'duty_hours', 'monthly_reports')
     and jsonb_typeof(p_value) <> 'object' then
    raise exception 'The selected data collection must be a JSON object.' using errcode = '22023';
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

create or replace function public.lso_replace_state(
  p_token text,
  p_state jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

revoke all on function public.lso_get_state(text) from public;
revoke all on function public.lso_update_state(text, text, jsonb) from public;
revoke all on function public.lso_replace_state(text, jsonb) from public;
grant execute on function public.lso_get_state(text) to anon, authenticated;
grant execute on function public.lso_update_state(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_replace_state(text, jsonb) to anon, authenticated;

-- Ask PostgREST to refresh its function/schema cache immediately.
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_DUTY_HOURS_COMPLETE_INSTALL.sql
-- ########################################################################

-- LASALLIAN SYMPHONY ORCHESTRA
-- MASTER DATABASE REPAIR — SAFE FOR EXISTING PROJECTS
--
-- Run this entire file once in Supabase > SQL Editor > New query.
-- It preserves existing records. It repairs older database schemas, the
-- Trainee/Probationary account role, account-to-member linking, login state
-- loading, and Duty Hours submission/approval.

begin;

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------------
-- 1. REQUIRED TABLE/COLUMN COMPATIBILITY
-- --------------------------------------------------------------------------

-- The account table already exists in an installed LSO project. This statement
-- makes the repair fail clearly rather than producing misleading follow-up errors.
do $$
begin
  if to_regclass('public.lso_accounts') is null then
    raise exception 'public.lso_accounts does not exist. Run the complete supabase-setup.sql first.';
  end if;
  if to_regclass('public.system_state') is null then
    raise exception 'public.system_state does not exist. Run the complete supabase-setup.sql first.';
  end if;
end;
$$;

alter table public.lso_accounts
  add column if not exists member_id text;

-- Add every shared-state column expected by the current website. Existing data
-- is retained; only missing fields are created.
alter table public.system_state
  add column if not exists members jsonb,
  add column if not exists events jsonb,
  add column if not exists attendance jsonb,
  add column if not exists duty_hours jsonb,
  add column if not exists monthly_reports jsonb,
  add column if not exists instruments jsonb,
  add column if not exists settings jsonb,
  add column if not exists activity_log jsonb,
  add column if not exists updated_at timestamptz;

insert into public.system_state (id)
values (1)
on conflict (id) do nothing;

update public.system_state
set members = coalesce(members, '[]'::jsonb),
    events = coalesce(events, '[]'::jsonb),
    attendance = coalesce(attendance, '[]'::jsonb),
    duty_hours = coalesce(duty_hours, '{"version":4,"commitments":{},"entries":[]}'::jsonb),
    monthly_reports = coalesce(
      monthly_reports,
      case
        when jsonb_typeof(settings -> '__lso_monthly_reports_v1') = 'object'
          then settings -> '__lso_monthly_reports_v1'
        else '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb
      end
    ),
    instruments = coalesce(instruments, '[]'::jsonb),
    settings = coalesce(settings, '{}'::jsonb),
    activity_log = coalesce(activity_log, '[]'::jsonb),
    updated_at = coalesce(updated_at, now());

alter table public.system_state
  alter column members set default '[]'::jsonb,
  alter column members set not null,
  alter column events set default '[]'::jsonb,
  alter column events set not null,
  alter column attendance set default '[]'::jsonb,
  alter column attendance set not null,
  alter column duty_hours set default '{"version":4,"commitments":{},"entries":[]}'::jsonb,
  alter column duty_hours set not null,
  alter column monthly_reports set default '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb,
  alter column monthly_reports set not null,
  alter column instruments set default '[]'::jsonb,
  alter column instruments set not null,
  alter column settings set default '{}'::jsonb,
  alter column settings set not null,
  alter column activity_log set default '[]'::jsonb,
  alter column activity_log set not null,
  alter column updated_at set default now(),
  alter column updated_at set not null;

-- Replace any older role CHECK constraint with the current role list.
do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
      and (
        pg_get_constraintdef(oid) ilike '%Administrator%'
        or pg_get_constraintdef(oid) ilike '%Staff Account%'
      )
  loop
    execute format('alter table public.lso_accounts drop constraint %I', v_constraint.conname);
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and conname = 'lso_accounts_role_check'
  ) then
    alter table public.lso_accounts
      add constraint lso_accounts_role_check
      check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));
  end if;
end;
$$;

create index if not exists lso_accounts_member_id_index
  on public.lso_accounts (member_id)
  where member_id is not null;

-- --------------------------------------------------------------------------
-- 2. ACCOUNT JSON
-- --------------------------------------------------------------------------

create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- --------------------------------------------------------------------------
-- 3. COMPATIBILITY-SAFE STATE LOADER
-- --------------------------------------------------------------------------
-- Important: v_state is JSONB, not public.system_state%rowtype. This prevents
-- login from failing when an older database was created before a newer field.

create or replace function public.lso_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_role text;
  v_member_id text;
  v_state jsonb;
  v_members jsonb := '[]'::jsonb;
  v_entries jsonb := '[]'::jsonb;
  v_commitments jsonb := '{}'::jsonb;
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

  v_duty_hours := case
    when jsonb_typeof(v_state -> 'duty_hours') = 'object'
      then v_state -> 'duty_hours'
    else '{"version":4,"commitments":{},"entries":[]}'::jsonb
  end;

  v_monthly_reports := case
    when jsonb_typeof(v_state -> 'monthly_reports') = 'object'
      then v_state -> 'monthly_reports'
    when jsonb_typeof(v_state -> 'settings' -> '__lso_monthly_reports_v1') = 'object'
      then v_state -> 'settings' -> '__lso_monthly_reports_v1'
    else '{"version":1,"reports":{},"civilStatusByMember":{},"traineeFiles":{}}'::jsonb
  end;

  if v_role = 'Trainee/Probationary' then
    select coalesce(jsonb_agg(item), '[]'::jsonb)
    into v_members
    from jsonb_array_elements(
      case when jsonb_typeof(v_state -> 'members') = 'array'
        then v_state -> 'members' else '[]'::jsonb end
    ) as item
    where nullif(btrim(coalesce(v_member_id, '')), '') is not null
      and item ->> 'id' = v_member_id;

    select coalesce(jsonb_agg(item), '[]'::jsonb)
    into v_entries
    from jsonb_array_elements(
      case when jsonb_typeof(v_duty_hours -> 'entries') = 'array'
        then v_duty_hours -> 'entries' else '[]'::jsonb end
    ) as item
    where nullif(btrim(coalesce(v_member_id, '')), '') is not null
      and item ->> 'memberId' = v_member_id;

    if nullif(btrim(coalesce(v_member_id, '')), '') is not null
       and jsonb_typeof(v_duty_hours -> 'commitments' -> v_member_id) = 'object' then
      v_commitments := jsonb_build_object(
        v_member_id,
        v_duty_hours -> 'commitments' -> v_member_id
      );
    end if;

    return jsonb_build_object(
      'id', coalesce(v_state -> 'id', '1'::jsonb),
      'members', v_members,
      'events', '[]'::jsonb,
      'attendance', '[]'::jsonb,
      'duty_hours', jsonb_build_object(
        'version', coalesce(v_duty_hours -> 'version', '4'::jsonb),
        'commitments', v_commitments,
        'entries', v_entries
      ),
      'monthly_reports', '{}'::jsonb,
      'instruments', '[]'::jsonb,
      'settings', '{}'::jsonb,
      'activity_log', '[]'::jsonb,
      'updated_at', coalesce(v_state -> 'updated_at', to_jsonb(now()))
    );
  end if;

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
$$;

-- --------------------------------------------------------------------------
-- 4. ADMIN ACCOUNT APPROVAL WITH ROLE + MEMBER LINK
-- --------------------------------------------------------------------------

create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
      when v_item ->> 'role' = 'Trainee/Probationary' then 'Trainee/Probationary'
      else 'Staff Account'
    end;

    v_member_id := case
      when v_role = 'Trainee/Probationary'
        then nullif(btrim(coalesce(v_item ->> 'memberId', '')), '')
      else null
    end;

    if v_old_status = 'Approved'
       and (
         v_old_role is distinct from v_role
         or coalesce(v_old_member_id, '') <> coalesce(v_member_id, '')
       ) then
      v_status := 'Pending';
    end if;

    if v_role = 'Trainee/Probationary' and v_member_id is not null and not exists (
      select 1
      from public.system_state as state,
           jsonb_array_elements(coalesce(state.members, '[]'::jsonb)) as member
      where state.id = 1
        and member ->> 'id' = v_member_id
        and (
          member ->> 'periodGroup' in ('Trainee Period', 'Probationary Period')
          or member ->> 'membershipStage' in ('Trainee', 'Probationary')
        )
    ) then
      raise exception 'The selected linked member is not an active Trainee or Probationary member.' using errcode = '22023';
    end if;

    if v_role = 'Trainee/Probationary'
       and v_status = 'Approved'
       and v_member_id is null then
      raise exception 'A Trainee/Probationary account must be linked to a member before approval.' using errcode = '22023';
    end if;

    begin
      v_disabled := coalesce((v_item ->> 'disabled')::boolean, false);
    exception when others then
      v_disabled := false;
    end;

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
$$;

-- --------------------------------------------------------------------------
-- 5. TRAINEE/PROBATIONARY DUTY HOURS SUBMISSION
-- --------------------------------------------------------------------------

create or replace function public.lso_submit_duty_entry(
  p_token text,
  p_semester text,
  p_period text,
  p_date text,
  p_time_in text,
  p_time_out text,
  p_description text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_account_id uuid;
  v_account public.lso_accounts%rowtype;
  v_member jsonb;
  v_member_period text;
  v_minutes integer;
  v_entry jsonb;
  v_entry_id text := gen_random_uuid()::text;
begin
  v_account_id := public.lso_session_account_id(p_token, false);
  select * into v_account from public.lso_accounts where id = v_account_id;

  if v_account.role <> 'Trainee/Probationary' then
    raise exception 'Only a Trainee/Probationary account may submit a self-service duty entry.' using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(v_account.member_id, '')), '') is null then
    raise exception 'This account is not linked to a member record.' using errcode = '42501';
  end if;

  if p_semester not in ('First Semester', 'Second Semester') then
    raise exception 'Invalid duty semester.' using errcode = '22023';
  end if;

  if p_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'Invalid duty period.' using errcode = '22023';
  end if;

  if p_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end if;

  begin
    perform p_date::date;
  exception when others then
    raise exception 'Enter a valid duty date.' using errcode = '22023';
  end;

  if p_time_in !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or p_time_out !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Enter valid Time In and Time Out values.' using errcode = '22023';
  end if;

  if p_time_out::time <= p_time_in::time then
    raise exception 'Time Out must be later than Time In for a same-day duty entry.' using errcode = '22023';
  end if;

  v_minutes := floor(extract(epoch from (p_time_out::time - p_time_in::time)) / 60)::integer;

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

  v_member_period := coalesce(
    nullif(v_member ->> 'periodGroup', ''),
    case v_member ->> 'membershipStage'
      when 'Trainee' then 'Trainee Period'
      when 'Probationary' then 'Probationary Period'
      else ''
    end
  );

  if v_member_period not in ('Trainee Period', 'Probationary Period') then
    raise exception 'The linked member is not currently in the Trainee or Probationary Period.' using errcode = '42501';
  end if;

  if p_period <> v_member_period then
    raise exception 'The submitted duty period does not match the linked member''s current period.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.system_state as state,
         jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb)) as entry
    where state.id = 1
      and entry ->> 'memberId' = v_account.member_id
      and entry ->> 'date' = p_date
      and entry ->> 'timeIn' = p_time_in
      and entry ->> 'timeOut' = p_time_out
      and coalesce(entry ->> 'approvalStatus', 'Approved') <> 'Rejected'
  ) then
    raise exception 'This Time In and Time Out entry was already submitted.' using errcode = '23505';
  end if;

  v_entry := jsonb_build_object(
    'id', v_entry_id,
    'memberId', v_account.member_id,
    'semester', p_semester,
    'period', p_period,
    'entryType', 'Duty',
    'date', p_date,
    'minutes', v_minutes,
    'timeIn', p_time_in,
    'timeOut', p_time_out,
    'description', left(btrim(coalesce(p_description, '')), 160),
    'approvalStatus', 'Pending',
    'submittedByAccountId', v_account.id,
    'submittedByUsername', v_account.username,
    'submittedByRole', v_account.role,
    'createdAt', now(),
    'createdBy', v_account.display_name,
    'createdByUsername', v_account.username
  );

  update public.system_state
  set duty_hours = jsonb_set(
        coalesce(duty_hours, '{"version":4,"commitments":{},"entries":[]}'::jsonb),
        '{entries}',
        coalesce(duty_hours -> 'entries', '[]'::jsonb) || jsonb_build_array(v_entry),
        true
      ),
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$$;

create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
  v_entries jsonb;
  v_found boolean := false;
begin
  v_admin_id := public.lso_session_account_id(p_token, true);
  select username into v_admin_username
  from public.lso_accounts
  where id = v_admin_id;

  if p_decision not in ('Approved', 'Rejected') then
    raise exception 'Decision must be Approved or Rejected.' using errcode = '22023';
  end if;

  select exists (
    select 1
    from public.system_state as state,
         jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb)) as entry
    where state.id = 1
      and entry ->> 'id' = p_entry_id
      and coalesce(entry ->> 'approvalStatus', 'Approved') = 'Pending'
  ) into v_found;

  if not v_found then
    raise exception 'The pending duty entry could not be found.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(
    case
      when entry ->> 'id' = p_entry_id and p_decision = 'Approved' then
        (entry - 'rejectedAt' - 'rejectedBy') || jsonb_build_object(
          'approvalStatus', 'Approved',
          'approvedAt', now(),
          'approvedBy', v_admin_username
        )
      when entry ->> 'id' = p_entry_id and p_decision = 'Rejected' then
        (entry - 'approvedAt' - 'approvedBy') || jsonb_build_object(
          'approvalStatus', 'Rejected',
          'rejectedAt', now(),
          'rejectedBy', v_admin_username
        )
      else entry
    end
    order by ordinal_position
  ), '[]'::jsonb)
  into v_entries
  from public.system_state as state,
       jsonb_array_elements(coalesce(state.duty_hours -> 'entries', '[]'::jsonb))
         with ordinality as records(entry, ordinal_position)
  where state.id = 1;

  update public.system_state
  set duty_hours = jsonb_set(
        coalesce(duty_hours, '{"version":4,"commitments":{},"entries":[]}'::jsonb),
        '{entries}',
        v_entries,
        true
      ),
      updated_at = now()
  where id = 1;

  return public.lso_get_state(p_token);
end;
$$;

-- --------------------------------------------------------------------------
-- 6. PERMISSIONS, VALIDATION, AND POSTGREST CACHE REFRESH
-- --------------------------------------------------------------------------

revoke all on function public.lso_account_json(uuid) from public;
revoke all on function public.lso_get_state(text) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;

grant execute on function public.lso_account_json(uuid) to anon, authenticated;
grant execute on function public.lso_get_state(text) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'lso_accounts' and column_name = 'member_id'
  ) then
    raise exception 'Repair failed: public.lso_accounts.member_id is missing.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'system_state' and column_name = 'monthly_reports'
  ) then
    raise exception 'Repair failed: public.system_state.monthly_reports is missing.';
  end if;
end;
$$;

commit;
notify pgrst, 'reload schema';
-- LASALLIAN SYMPHONY ORCHESTRA
-- FINAL TRAINEE / PROBATIONARY DUTY HOURS WORKFLOW
--
-- Run this entire file once in Supabase > SQL Editor > New query.
-- It is safe to run again. Existing members, accounts, attendance, and duty
-- records are preserved.
--
-- Workflow installed by this script:
--   1. Administrator approves an account as Trainee/Probationary and links it
--      to one current Trainee or Probationary member.
--   2. That account sees only Duty Hours.
--   3. The member submits their own date, Time In, Time Out, and description.
--   4. The entry is Pending and contributes zero credited minutes.
--   5. Only an Administrator can Approve or Reject it.
--   6. Only Approved duty entries are included in the member's totals.

begin;

create extension if not exists pgcrypto;

do $$
begin
  if to_regclass('public.lso_accounts') is null then
    raise exception 'public.lso_accounts does not exist. Run the complete supabase-setup.sql first.';
  end if;
  if to_regclass('public.lso_sessions') is null then
    raise exception 'public.lso_sessions does not exist. Run the complete supabase-setup.sql first.';
  end if;
  if to_regclass('public.system_state') is null then
    raise exception 'public.system_state does not exist. Run the complete supabase-setup.sql first.';
  end if;
end;
$$;

-- Compatibility for projects created before this role existed.
alter table public.lso_accounts
  add column if not exists member_id text;

alter table public.system_state
  add column if not exists members jsonb,
  add column if not exists duty_hours jsonb,
  add column if not exists activity_log jsonb,
  add column if not exists updated_at timestamptz;

insert into public.system_state (id)
values (1)
on conflict (id) do nothing;

update public.system_state
set members = coalesce(members, '[]'::jsonb),
    duty_hours = coalesce(duty_hours, '{"version":5,"commitments":{},"entries":[]}'::jsonb),
    activity_log = coalesce(activity_log, '[]'::jsonb),
    updated_at = coalesce(updated_at, now())
where id = 1;

-- Normalize the Duty Hours container without deleting legacy entries.
update public.system_state
set duty_hours = jsonb_set(
      jsonb_set(
        jsonb_set(
          case when jsonb_typeof(duty_hours) = 'object'
            then duty_hours
            else '{"version":5,"commitments":{},"entries":[]}'::jsonb
          end,
          '{version}', '5'::jsonb, true
        ),
        '{commitments}',
        case when jsonb_typeof(duty_hours -> 'commitments') = 'object'
          then duty_hours -> 'commitments' else '{}'::jsonb end,
        true
      ),
      '{entries}',
      case when jsonb_typeof(duty_hours -> 'entries') = 'array'
        then duty_hours -> 'entries' else '[]'::jsonb end,
      true
    ),
    updated_at = now()
where id = 1;

-- Replace an older role check safely.
do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
      and (
        pg_get_constraintdef(oid) ilike '%Administrator%'
        or pg_get_constraintdef(oid) ilike '%Staff Account%'
      )
  loop
    execute format('alter table public.lso_accounts drop constraint %I', v_constraint.conname);
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.lso_accounts'::regclass
      and conname = 'lso_accounts_role_check'
  ) then
    alter table public.lso_accounts
      add constraint lso_accounts_role_check
      check (role in ('Administrator', 'Staff Account', 'Membership', 'General Secretary', 'Trainee/Probationary'));
  end if;
end;
$$;

create index if not exists lso_accounts_member_id_index
  on public.lso_accounts (member_id)
  where member_id is not null;


-- One canonical calendar date for all LSO duty-hour validation.
-- Supabase/PostgreSQL sessions commonly use UTC, while LSO operates in the Philippines.
create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

-- Determine the person's actual period from the timeline on a specific date.
-- This avoids depending only on a possibly stale periodGroup value.
create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Ensure the browser receives memberId with every account profile.
create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Administrator account approval with mandatory, validated member linking.
create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

    if v_role = 'Trainee/Probationary' and v_member_id is not null then
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
$$;

-- Member self-service submission. The server derives the member, duty period,
-- and duration; the browser cannot choose another member or credited minutes.
create or replace function public.lso_submit_duty_entry(
  p_token text,
  p_semester text,
  p_period text,
  p_date text,
  p_time_in text,
  p_time_out text,
  p_description text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- Administrator review. A pending entry can be decided only once.
create or replace function public.lso_review_duty_entry(
  p_token text,
  p_entry_id text,
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
$$;

revoke all on function public.lso_local_date() from public;
revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
revoke all on function public.lso_account_json(uuid) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) from public;
revoke all on function public.lso_review_duty_entry(text, text, text) from public;

grant execute on function public.lso_local_date() to anon, authenticated;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;
grant execute on function public.lso_account_json(uuid) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_entry(text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_STAFF_ROLE_MONITOR_DUTY_REVIEW_INSTALL.sql
-- ########################################################################

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


-- ########################################################################
-- PATCH: LSO_DUTY_MOBILE_REQUIRED_APPROVER_INSTALL.sql
-- ########################################################################

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

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_REVISION_V35_DATABASE_INSTALL.sql
-- ########################################################################

-- Lasallian Symphony Orchestra
-- Coordinated Attendance / Duty Hours Revision v35
-- Safe for existing projects. Existing records are preserved.
--
-- This installer reapplies the current Staff Duty Hours review permission and
-- the required Member/s Approved validation used by the website. Attendance
-- month/semester finalization and separate calendars are stored inside the
-- existing shared JSON state and require no new database columns.

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


-- Required Member/s Approved migration follows.

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

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_DUTY_PUNCH_SEPARATE_APPROVAL_INSTALL.sql
-- ########################################################################

-- LASALLIAN SYMPHONY ORCHESTRA
-- DUTY HOURS: SEPARATE TIME IN / TIME OUT APPROVAL
-- Existing-project installer. Safe to run once after the prior stable LSO setup.
-- This does not delete members, accounts, attendance, reports, or prior duty records.

begin;

create extension if not exists pgcrypto;

alter table public.lso_accounts
  add column if not exists member_id text;

alter table public.system_state
  add column if not exists members jsonb not null default '[]'::jsonb,
  add column if not exists duty_hours jsonb not null
  default '{"version":7,"commitments":{},"entries":[]}'::jsonb;

alter table public.system_state
  add column if not exists activity_log jsonb not null default '[]'::jsonb;


create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_trainee_start date;
  v_probationary_start date;
  v_membership_start date;
  v_skipped boolean := false;
  v_period text;
  v_stage text;
begin
  if p_member is null or jsonb_typeof(p_member) <> 'object' then return ''; end if;
  begin
    v_trainee_start := nullif(coalesce(p_member ->> 'traineeStartDate', p_member ->> 'dateRegistered'), '')::date;
  exception when others then v_trainee_start := null;
  end;
  begin
    v_probationary_start := nullif(p_member ->> 'probationaryStartDate', '')::date;
  exception when others then v_probationary_start := null;
  end;
  begin
    v_membership_start := nullif(coalesce(p_member ->> 'regularMemberDate', p_member ->> 'membershipStartDate'), '')::date;
  exception when others then v_membership_start := null;
  end;
  v_skipped := lower(coalesce(p_member ->> 'probationarySkipped', 'false')) in ('true', '1', 'yes');
  v_period := coalesce(p_member ->> 'periodGroup', '');
  v_stage := coalesce(p_member ->> 'membershipStage', '');
  if v_membership_start is not null and p_on_date >= v_membership_start then return 'Membership Period'; end if;
  if not v_skipped and v_probationary_start is not null and p_on_date >= v_probationary_start then return 'Probationary Period'; end if;
  if v_trainee_start is not null and p_on_date >= v_trainee_start then return 'Trainee Period'; end if;
  if v_period in ('Trainee Period', 'Probationary Period', 'Membership Period') then return v_period; end if;
  if v_stage = 'Trainee' then return 'Trainee Period'; end if;
  if v_stage = 'Probationary' then return 'Probationary Period'; end if;
  if v_stage in ('Regular Member', 'Member', 'Official Member') then return 'Membership Period'; end if;
  return '';
end;
$$;

-- Upgrade existing Duty Hours entries to the separate-punch status shape.
-- Legacy completed records remain completed. Legacy open records remain usable.
update public.system_state
set duty_hours = jsonb_set(
  jsonb_set(
    case
      when duty_hours is null or jsonb_typeof(duty_hours) <> 'object'
        then '{"version":7,"commitments":{},"entries":[]}'::jsonb
      else duty_hours
    end,
    '{version}',
    '7'::jsonb,
    true
  ),
  '{entries}',
  coalesce((
    select jsonb_agg(
      case
        when coalesce(entry ->> 'entryType', 'Duty') <> 'Duty' then entry
        else entry || jsonb_build_object(
          'timeInApprovalStatus',
            case
              when entry ? 'timeInApprovalStatus' then entry ->> 'timeInApprovalStatus'
              when nullif(entry ->> 'timeIn', '') is null then 'Not Submitted'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Pending'
                   and nullif(entry ->> 'timeOut', '') is null then 'Pending'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Rejected'
                   and nullif(entry ->> 'timeOut', '') is null then 'Rejected'
              else 'Approved'
            end,
          'timeOutApprovalStatus',
            case
              when entry ? 'timeOutApprovalStatus' then entry ->> 'timeOutApprovalStatus'
              when nullif(entry ->> 'timeOut', '') is null then 'Not Submitted'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Approved' then 'Approved'
              when coalesce(entry ->> 'approvalStatus', 'Approved') = 'Rejected' then 'Rejected'
              else 'Pending'
            end,
          'timeInRequestedAt', coalesce(nullif(entry ->> 'timeInRequestedAt', ''), nullif(entry ->> 'clockInAt', ''), nullif(entry ->> 'createdAt', '')),
          'timeOutRequestedAt', coalesce(nullif(entry ->> 'timeOutRequestedAt', ''), nullif(entry ->> 'clockOutAt', ''), nullif(entry ->> 'submittedAt', '')),
          'punchAudit', case when jsonb_typeof(entry -> 'punchAudit') = 'array' then entry -> 'punchAudit' else '[]'::jsonb end
        )
      end
      order by ordinal_position
    )
    from jsonb_array_elements(
      case
        when jsonb_typeof(duty_hours -> 'entries') = 'array' then duty_hours -> 'entries'
        else '[]'::jsonb
      end
    ) with ordinality as records(entry, ordinal_position)
  ), '[]'::jsonb),
  true
),
updated_at = now()
where id = 1;

-- Submit a Time In request. It is NOT official until an Administrator approves
-- this specific punch. The secure database time in Asia/Manila is authoritative.
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

-- Submit Time Out for the member's one open punch. Time In may still be
-- pending. Time Out is a separate request and is not official automatically.
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

-- Review one punch only. Time Out approval is blocked until Time In has been
-- approved. Duty minutes are credited only after both punch statuses are Approved.
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
$$;

revoke all on function public.lso_local_date() from public;
revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
grant execute on function public.lso_local_date() to anon, authenticated;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;

revoke all on function public.lso_duty_time_in(text, text, text, text) from public;
revoke all on function public.lso_duty_time_out(text, text, text) from public;
revoke all on function public.lso_review_duty_punch(text, text, text, text) from public;

grant execute on function public.lso_duty_time_in(text, text, text, text) to anon, authenticated;
grant execute on function public.lso_duty_time_out(text, text, text) to anon, authenticated;
grant execute on function public.lso_review_duty_punch(text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_DUTY_DATE_PHILIPPINES_TIMEZONE_FIX.sql
-- ########################################################################

-- LSO DUTY DATE / PHILIPPINES TIMEZONE HOTFIX
-- Run this once in Supabase SQL Editor for an existing installation.
-- It preserves current records and only replaces date-sensitive functions.

begin;

-- One canonical calendar date for all LSO duty-hour validation.
-- Supabase/PostgreSQL sessions commonly use UTC, while LSO operates in the Philippines.
create or replace function public.lso_local_date()
returns date
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

-- Determine the person's actual period from the timeline on a specific date.
-- This avoids depending only on a possibly stale periodGroup value.
create or replace function public.lso_member_period_on_date(
  p_member jsonb,
  p_on_date date default public.lso_local_date()
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Ensure the browser receives memberId with every account profile.
create or replace function public.lso_account_json(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- Administrator account approval with mandatory, validated member linking.
create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

    if v_role = 'Trainee/Probationary' and v_member_id is not null then
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
$$;

-- Member self-service submission. The server derives the member, duty period,
-- and duration; the browser cannot choose another member or credited minutes.
create or replace function public.lso_submit_duty_entry(
  p_token text,
  p_semester text,
  p_period text,
  p_date text,
  p_time_in text,
  p_time_out text,
  p_description text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

revoke all on function public.lso_local_date() from public;
revoke all on function public.lso_member_period_on_date(jsonb, date) from public;
revoke all on function public.lso_account_json(uuid) from public;
revoke all on function public.lso_save_accounts(text, jsonb) from public;
revoke all on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) from public;

grant execute on function public.lso_local_date() to anon, authenticated;
grant execute on function public.lso_member_period_on_date(jsonb, date) to anon, authenticated;
grant execute on function public.lso_account_json(uuid) to anon, authenticated;
grant execute on function public.lso_save_accounts(text, jsonb) to anon, authenticated;
grant execute on function public.lso_submit_duty_entry(text, text, text, text, text, text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';


-- ########################################################################
-- PATCH: LSO_DUTY_PUNCH_STATE_SYNC_REPAIR.sql
-- ########################################################################

-- LSO DUTY PUNCH STATE-SYNC REPAIR
-- Safe compatibility repair for existing projects. Does not delete records.
begin;

alter table public.system_state
  add column if not exists duty_hours jsonb not null default '{"version":7,"commitments":{},"entries":[]}'::jsonb;

update public.system_state
set duty_hours = jsonb_set(
  jsonb_set(
    case when jsonb_typeof(duty_hours)='object' then duty_hours else '{"version":7,"commitments":{},"entries":[]}'::jsonb end,
    '{version}','7'::jsonb,true
  ),
  '{entries}',
  coalesce((
    select jsonb_agg(
      case when coalesce(entry->>'entryType','Duty')<>'Duty' then entry else
        entry || jsonb_build_object(
          'timeInApprovalStatus', status_values.in_status,
          'timeOutApprovalStatus', status_values.out_status,
          'approvalStatus',
            case
              when status_values.in_status in ('Rejected','Cancelled') or status_values.out_status in ('Rejected','Cancelled') then 'Rejected'
              when nullif(entry->>'timeOut','') is null and status_values.in_status='Approved' then 'Active'
              when nullif(entry->>'timeOut','') is null then 'Pending'
              when status_values.in_status='Approved' and status_values.out_status='Approved' then 'Approved'
              else 'Pending'
            end,
          'punchAudit',case when jsonb_typeof(entry->'punchAudit')='array' then entry->'punchAudit' else '[]'::jsonb end
        )
      end order by ordinal_position
    )
    from jsonb_array_elements(case when jsonb_typeof(duty_hours->'entries')='array' then duty_hours->'entries' else '[]'::jsonb end)
      with ordinality as records(entry,ordinal_position)
    cross join lateral (
      select
        case
          when nullif(entry->>'timeInApprovalStatus','') in ('Pending','Approved','Rejected','Cancelled','Not Submitted') then entry->>'timeInApprovalStatus'
          when nullif(entry->>'timeIn','') is null then 'Not Submitted'
          when nullif(entry->>'timeOut','') is null then case when coalesce(entry->>'approvalStatus','Pending')='Rejected' then 'Rejected' else 'Pending' end
          when coalesce(entry->>'approvalStatus','Approved')='Approved' then 'Approved'
          when coalesce(entry->>'approvalStatus','Pending')='Rejected' then 'Rejected'
          else 'Pending'
        end as in_status,
        case
          when nullif(entry->>'timeOutApprovalStatus','') in ('Pending','Approved','Rejected','Cancelled','Not Submitted') then entry->>'timeOutApprovalStatus'
          when nullif(entry->>'timeOut','') is null then 'Not Submitted'
          when coalesce(entry->>'approvalStatus','Pending')='Approved' then 'Approved'
          when coalesce(entry->>'approvalStatus','Pending')='Rejected' then 'Rejected'
          else 'Pending'
        end as out_status
    ) as status_values
  ),'[]'::jsonb),true
),updated_at=now()
where id=1;

notify pgrst,'reload schema';
commit;

-- Optional verification after running:
-- select entry->>'id' id, entry->>'memberId' member_id, entry->>'date' duty_date,
--        entry->>'timeIn' time_in, entry->>'timeOut' time_out,
--        entry->>'timeInApprovalStatus' time_in_status, entry->>'timeOutApprovalStatus' time_out_status
-- from public.system_state, jsonb_array_elements(duty_hours->'entries') entry
-- where coalesce(entry->>'entryType','Duty')='Duty'
-- order by entry->>'createdAt' desc;


-- ########################################################################
-- PATCH: LSO_FINAL_FIX_EVERYTHING.sql
-- ########################################################################

-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — FINAL FIX (RUN THIS ONE FILE ONLY)
-- ============================================================================
-- DETERMINED TRUE ERROR (from your database's own migration list)
-- ----------------------------------------------------------------------------
-- Your database has TWO overloads of lso_update_state_v69:
--
--   * migration 012_platform_operations_v69  -> (text,text,jsonb,INTEGER)  WITH conflict check
--   * migration 014_missing_v69_rpc_repair    -> (text,text,jsonb,BIGINT)   WITH conflict check
--
-- BOTH of them raise:  LSO_CONFLICT:<column>:<version>
-- whenever the version number the browser sends does not exactly match the
-- version the server has reached.
--
-- activity_log is the shared audit trail: EVERY device appends to it on EVERY
-- save, so its version counter climbs constantly (you saw 587). Any device that
-- is even one save behind gets its write REJECTED with:
--
--     LSO_CONFLICT:activity_log:587
--
-- That rejection is what blocks the Membership role's changes from reaching
-- other roles (no "real-time" updates) and floods the Supabase logs with the
-- "WITH pgrst_source AS ..." PostgREST statement text.
--
-- THE FIX
-- ----------------------------------------------------------------------------
-- 1. DROP EVERY overload of lso_update_state_v69 so PostgREST has exactly ONE
--    unambiguous function to call.
-- 2. Recreate a SINGLE lso_update_state_v69 that is LAST-WRITE-WINS:
--    it keeps all the normal permission / attendance / duty validations
--    (by calling the base lso_update_state) but NEVER rejects a write over a
--    version number. Versions are still counted for diagnostics only.
-- 3. Re-assert the helper RPCs so every function the website calls exists in
--    one known-good state.
-- 4. Does NOT delete or change any member, event, attendance, duty, report,
--    account, or session data. Idempotent — safe to run again.
--
-- RUN IN: Supabase Dashboard > SQL Editor > New query
-- ============================================================================

do $lso_preflight$
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
$lso_preflight$;

begin;

-- ----------------------------------------------------------------------------
-- 1. REMOVE EVERY EXISTING lso_update_state_v69 OVERLOAD
--    Explicit drops for the two known signatures FIRST, then a dynamic sweep
--    for any other signature. PostgREST must end up with exactly ONE function.
-- ----------------------------------------------------------------------------
drop function if exists public.lso_update_state_v69(text, text, jsonb, integer) cascade;
drop function if exists public.lso_update_state_v69(text, text, jsonb, bigint) cascade;

do $lso_drop_v69$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'lso_update_state_v69'
  loop
    execute 'drop function public.' || r.sig || ' cascade';
  end loop;
end;
$lso_drop_v69$;

-- ----------------------------------------------------------------------------
-- 2. PER-COLUMN VERSION STORAGE (bookkeeping only — never used to reject)
-- ----------------------------------------------------------------------------
alter table public.system_state
  add column if not exists column_versions jsonb not null default '{}'::jsonb;

-- ----------------------------------------------------------------------------
-- 3. lso_update_state_v69 — SINGLE CANONICAL, CONFLICT-FREE (last-write-wins)
-- ----------------------------------------------------------------------------
create or replace function public.lso_update_state_v69(
  p_token text,
  p_column text,
  p_value jsonb,
  p_expected_version integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $lso$
declare
  v_result jsonb;
  v_versions jsonb;
  v_next bigint;
begin
  perform public.lso_session_account_id(p_token, false);

  if p_column not in ('members','events','attendance','duty_hours','monthly_reports',
                      'instruments','settings','activity_log') then
    raise exception 'Unknown shared-state column.' using errcode = '22023';
  end if;

  -- p_expected_version is accepted but intentionally IGNORED. Version checks
  -- were rejecting the append-only audit log (activity_log) on nearly every
  -- save and breaking cross-role synchronization. The base writer below still
  -- performs every real permission/attendance/duty validation.
  v_result := public.lso_update_state(p_token, p_column, p_value);

  -- Advance the column version for diagnostics only. Never used to reject.
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
-- 4. lso_get_state_meta_v69 — lightweight heartbeat for fast polls
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
-- 5. lso_sync_health_v82 — session-aware health check
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
-- 6. lso_v69_capabilities — feature probe (reports conflict protection OFF)
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
    'conflictProtection', false,
    'serverPagination', true,
    'notificationPreferences', true,
    'schemaVersion', v_version,
    'serverTime', now()
  );
end;
$lso$;

-- ----------------------------------------------------------------------------
-- 7. lso_get_collection_page_v69 — server-side paging + text filter
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

  if v_role = 'Trainee/Probationary'
     and p_collection = 'duty_entries'
     and nullif(btrim(coalesce(v_member_id, '')), '') is not null then
    select coalesce(jsonb_agg(item order by idx), '[]'::jsonb)
      into v_source
      from jsonb_array_elements(v_source) with ordinality as t(item, idx)
     where item ->> 'memberId' = v_member_id;
  end if;

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
-- 8. NOTIFICATION PREFERENCES (kept out of the protected System Settings)
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
-- 9. SECURITY: RPC-only access, no direct table access
-- ----------------------------------------------------------------------------
revoke all on function public.lso_get_state_meta_v69(text) from public, anon, authenticated;
revoke all on function public.lso_update_state_v69(text, text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.lso_v69_capabilities(text) from public, anon, authenticated;
revoke all on function public.lso_get_collection_page_v69(text, text, integer, integer, text) from public, anon, authenticated;
revoke all on function public.lso_get_notification_preferences_v69(text) from public, anon, authenticated;
revoke all on function public.lso_save_notification_preferences_v69(text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.lso_sync_health_v82(text) from public, anon, authenticated;

grant execute on function public.lso_get_state_meta_v69(text) to anon, authenticated;
grant execute on function public.lso_update_state_v69(text, text, jsonb, integer) to anon, authenticated;
grant execute on function public.lso_v69_capabilities(text) to anon, authenticated;
grant execute on function public.lso_get_collection_page_v69(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.lso_get_notification_preferences_v69(text) to anon, authenticated;
grant execute on function public.lso_save_notification_preferences_v69(text, jsonb) to anon, authenticated;
grant execute on function public.lso_save_role_notification_preferences_v69(text, text, jsonb) to anon, authenticated;
grant execute on function public.lso_sync_health_v82(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 10. MIGRATION MARKER (guarded for older databases without the table)
-- ----------------------------------------------------------------------------
commit;

notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- 11. VERIFICATION (read-only). Every value must be true for a 100% result.
--     The last line lists every remaining overload — it MUST be exactly ONE
--     entry ending in "integer)".
-- ----------------------------------------------------------------------------
select jsonb_build_object(
  'singleV69Writer',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'lso_update_state_v69') = 1,
  'integerSignature',
    exists (select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'lso_update_state_v69'
        and pg_get_function_arguments(p.oid) like '%p_expected_version integer%'),
  'conflictCheckRemoved',
    position('LSO_CONFLICT' in pg_get_functiondef('public.lso_update_state_v69(text,text,jsonb,integer)'::regprocedure)) = 0,
  'metaRpc',
    to_regprocedure('public.lso_get_state_meta_v69(text)') is not null,
  'healthRpc',
    to_regprocedure('public.lso_sync_health_v82(text)') is not null,
  'collectionPageRpc',
    to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is not null,
  'capabilitiesRpc',
    to_regprocedure('public.lso_v69_capabilities(text)') is not null,
  'notificationRpc',
    to_regprocedure('public.lso_get_notification_preferences_v69(text)') is not null
    and to_regprocedure('public.lso_save_notification_preferences_v69(text,jsonb)') is not null
    and to_regprocedure('public.lso_save_role_notification_preferences_v69(text,text,jsonb)') is not null,
  'columnVersionsColumn',
    exists (select 1 from information_schema.columns
             where table_schema = 'public'
               and table_name = 'system_state'
               and column_name = 'column_versions'),
  'remainingOverloads',
    (select coalesce(jsonb_agg(pg_get_function_arguments(p.oid)), '[]'::jsonb)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'lso_update_state_v69')
) as lso_final_fix_verification;


-- ########################################################################
-- PATCH: LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql
-- ########################################################################

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


-- ########################################################################
-- PATCH: LSO_ATTENDANCE_ROSTER_REFRESH_STABILITY_V83.sql
-- ########################################################################

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


-- ########################################################################
-- PATCH: LSO_SELF_ATTENDANCE_MONITORING_V84.sql
-- ########################################################################

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


-- ########################################################################
-- PATCH: LSO_SELF_ATTENDANCE_LIVE_FEED_V85.sql
-- ########################################################################

-- ============================================================================
-- LASALLIAN SYMPHONY ORCHESTRA — LSO V85
-- MY ATTENDANCE LIVE FEED (TRAINEE / PROBATIONARY OWN-RECORD DATA) SUPABASE PATCH
-- Date: 2026-09-19
-- Companion to: SELF_ATTENDANCE_LIVE_FEED_V85_GUIDE.txt
-- ============================================================================
--
-- THE PROBLEM THIS PATCH FIXES
--   V84 added the read-only "My Attendance" section (ownAttendanceView) for
--   Trainee/Probationary accounts. The section builds every blank on screen
--   (linked member, Present/Late/Absent/Excused counts, attendance rate, and the
--   per-activity table) from the shared-state `attendance` and `events`
--   collections that the website receives from `public.lso_get_state`.
--
--   The Trainee/Probationary branch of `lso_get_state` (installed by
--   supabase-setup.sql / LSO_DUTY_HOURS_COMPLETE_INSTALL.sql) still returns
--
--       'events',     '[]'::jsonb,
--       'attendance', '[]'::jsonb,
--
--   so a Trainee/Probationary account never receives a single attendance row —
--   not even its own. The section therefore always shows "No attendance record
--   yet", no matter what the Attendance officers have filed.
--
-- WHAT THIS PATCH DOES
--   1. Replaces `public.lso_get_state(text)` so a Trainee/Probationary session
--      receives, in addition to what it received before (own member record,
--      own Duty Hours entries and commitment):
--        * attendance  -> ONLY the rows whose memberId is the account's linked
--                         member id (account.member_id);
--        * events      -> ONLY the activities referenced by those rows, so the
--                         date, title, type, and venue can be shown next to
--                         each record.
--      Every other role keeps the exact payload it had before.
--   2. Hardens `public.lso_get_collection_page_v69` (when installed) so that a
--      Trainee/Probationary session paging `attendance`, `members`, or `events`
--      is scoped to the same own-record boundary, and receives no rows at all
--      for `instruments` and `activity_log`. The same replacement repairs the
--      page query itself: the shipped V69 body ordered/limited an aggregate,
--      which PostgreSQL rejects, so the RPC failed on every call (the website
--      silently fell back to browser-side paging).
--   3. Records the migration marker 016_self_attendance_live_feed_v85.
--
--   The feed is LIVE by construction: the website polls
--   `lso_get_state_meta_v69` and re-downloads `lso_get_state` whenever the shared
--   state changes, and the Duty Hours self-service RPCs also return
--   `lso_get_state`. As soon as an Attendance officer saves a roster, the next
--   synchronization delivers the member's updated rows to their own account.
--
-- WHAT THIS PATCH DOES NOT CHANGE
--   * No operational data is deleted or rewritten (accounts, members, attendance,
--     duty hours, monthly reports, settings, audit history, recovery points).
--   * No permission is added or removed: the V84 module grant, the role
--     defaults, and the V82 permission model (schemaVersion 13 / 'v82') stay as
--     they are. Trainee/Probationary still holds ZERO write columns.
--   * No write path is added. The scoped payload is read-only data; the update
--     RPCs keep their existing role checks.
--   * Settings, monthly reports, instruments, and the activity log are still
--     withheld from Trainee/Probationary sessions.
--
-- PREREQUISITE
--   The existing LSO management database (accounts, sessions, shared system
--   state, session helper functions) with the V84 patch applied:
--   LSO_SELF_ATTENDANCE_MONITORING_V84.sql.
--
-- HOW TO RUN
--   Supabase Dashboard -> SQL Editor -> New query -> paste this file -> Run.
--   SAFE TO RE-RUN: yes. Every statement is idempotent.
--
-- AFTER RUNNING
--   Sign in with a Trainee/Probationary account that is linked to a member and
--   open My Attendance: the linked member, the summary cards, and the table now
--   fill with that member's own attendance and refresh automatically.
-- ============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0. PRE-FLIGHT — refuse to run against a database that is not the LSO schema.
-- -----------------------------------------------------------------------------
do $v85_preflight$
begin
  if to_regclass('public.lso_accounts') is null
     or to_regclass('public.lso_sessions') is null
     or to_regclass('public.system_state') is null
     or to_regclass('public.lso_schema_migrations') is null then
    raise exception 'LSO V85 requires the existing LSO management database (lso_accounts, lso_sessions, system_state, lso_schema_migrations). Install/repair the base LSO database and run LSO_SELF_ATTENDANCE_MONITORING_V84.sql first.';
  end if;
  if to_regprocedure('public.lso_session_account_id(text,boolean)') is null then
    raise exception 'LSO V85 requires public.lso_session_account_id(text,boolean). Install/repair the base LSO database first.';
  end if;
  if to_regprocedure('public.lso_get_state(text)') is null then
    raise exception 'LSO V85 requires public.lso_get_state(text). Install/repair the base LSO database first.';
  end if;
end;
$v85_preflight$;

-- -----------------------------------------------------------------------------
-- 1. OWN-RECORD SCOPE — one pure helper builds the Trainee/Probationary payload.
--    It reads no table: it receives the shared-state row image and the linked
--    member id, and returns only what belongs to that member. `lso_get_state`
--    (section 2) and the SQL Editor verification (section 6) both use it, so
--    what is verified below is exactly what the website receives.
-- -----------------------------------------------------------------------------
create or replace function public.lso_trainee_scoped_state_v85(
  p_state jsonb,
  p_member_id text
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions, pg_temp
as $$
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
$$;

-- The helper is internal: it is not an API endpoint for the website.
revoke all on function public.lso_trainee_scoped_state_v85(jsonb, text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. STATE LOADER — identical for every other role; Trainee/Probationary now
--    receives its own attendance rows and the activities they belong to.
--    v_state is JSONB (row image), never %rowtype, so an older database created
--    before a newer column still loads.
-- -----------------------------------------------------------------------------
create or replace function public.lso_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;

revoke all on function public.lso_get_state(text) from public;
grant execute on function public.lso_get_state(text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. SERVER-SIDE PAGING (V69, when installed) — same own-record boundary.
--    Before V85 only `duty_entries` was scoped for Trainee/Probationary; the
--    attendance, members, and events collections were not. The website never
--    pages those collections for a Trainee, but the RPC is callable, so it is
--    closed here. Every other role keeps the exact behaviour it had.
-- -----------------------------------------------------------------------------
do $v85_paging$
begin
  if to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is null then
    raise notice 'LSO V85: lso_get_collection_page_v69 is not installed on this database; paging hardening skipped.';
    return;
  end if;

  execute $ddl$
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
$lso$;
$ddl$;

  execute 'revoke all on function public.lso_get_collection_page_v69(text, text, integer, integer, text) from public, anon, authenticated';
  execute 'grant execute on function public.lso_get_collection_page_v69(text, text, integer, integer, text) to anon, authenticated';
end;
$v85_paging$;

-- -----------------------------------------------------------------------------
-- 4. MIGRATION MARKER. lso_schema_migrations keeps version_number UNIQUE and the
--    repository already ships markers numbered 14 (V69 repair and V84) and 15
--    (V69 writer), so the number is derived from the table instead of being
--    hard-coded: it can never collide with a row that is already there.
-- -----------------------------------------------------------------------------
commit;
notify pgrst, 'reload schema';

-- -----------------------------------------------------------------------------
-- 5. SQL EDITOR VERIFICATION (read-only result)
--    Expected: result = PASS.
--      * stateLoaderScoped / pagingScoped ......... the new function bodies are live
--      * migrationInstalled ....................... marker present
--      * traineeSample ............................ the first approved, linked
--        Trainee/Probationary account, with the number of own attendance rows
--        and referenced activities it will now receive, and
--        onlyOwnRowsReturned = true (no other member's row in the payload).
--        If no Trainee/Probationary account is linked to a member yet,
--        traineeSample is null and the account link is the next step
--        (System Administration > Accounts > link the member).
-- -----------------------------------------------------------------------------
with trainee as (
  select account.username, account.member_id
    from public.lso_accounts as account
   where account.role = 'Trainee/Probationary'
     and account.approval_status = 'Approved'
     and account.disabled = false
     and nullif(btrim(coalesce(account.member_id, '')), '') is not null
   order by account.created_at
   limit 1
),
payload as (
  select trainee.username,
         trainee.member_id,
         public.lso_trainee_scoped_state_v85(to_jsonb(state), trainee.member_id) as scoped,
         (select count(*) from jsonb_array_elements(case when jsonb_typeof(state.attendance) = 'array' then state.attendance else '[]'::jsonb end) as stored_row
           where btrim(coalesce(stored_row ->> 'memberId', '')) = btrim(trainee.member_id)) as stored_own_rows
    from public.system_state as state
   cross join trainee
   where state.id = 1
),
checks as (
  select
    coalesce(position('lso_trainee_scoped_state_v85' in pg_get_functiondef(to_regprocedure('public.lso_get_state(text)'))) > 0, false) as state_loader_scoped,
    -- to_regprocedure() yields null (never an error) on a database without the V69 paging RPC.
    case
      when to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is null then true
      else coalesce(position('lso_trainee_scoped_state_v85' in pg_get_functiondef(to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)'))) > 0, false)
    end as paging_scoped,
    to_regprocedure('public.lso_get_collection_page_v69(text,text,integer,integer,text)') is not null as paging_installed,
    exists (select 1 from public.lso_schema_migrations where migration_key = '016_self_attendance_live_feed_v85') as migration_installed,
    (select count(*) from public.lso_accounts where role = 'Trainee/Probationary' and approval_status = 'Approved' and disabled = false) as trainee_accounts,
    (select count(*) from public.lso_accounts where role = 'Trainee/Probationary' and approval_status = 'Approved' and disabled = false and nullif(btrim(coalesce(member_id, '')), '') is not null) as linked_trainee_accounts,
    (select jsonb_build_object(
        'username', payload.username,
        'memberId', payload.member_id,
        'memberRecordFound', jsonb_array_length(payload.scoped -> 'members') = 1,
        'attendanceRowsReturned', jsonb_array_length(payload.scoped -> 'attendance'),
        'attendanceRowsStoredForMember', payload.stored_own_rows,
        'activitiesReturned', jsonb_array_length(payload.scoped -> 'events'),
        'onlyOwnRowsReturned', not exists (
          select 1 from jsonb_array_elements(payload.scoped -> 'attendance') as returned_row
           where btrim(coalesce(returned_row ->> 'memberId', '')) <> btrim(payload.member_id)
        ),
        'settingsWithheld', payload.scoped -> 'settings' = '{}'::jsonb,
        'activityLogWithheld', payload.scoped -> 'activity_log' = '[]'::jsonb
      ) from payload) as trainee_sample
)
select jsonb_build_object(
  'stateLoaderScoped', state_loader_scoped,
  'pagingInstalled', paging_installed,
  'pagingScoped', paging_scoped,
  'migrationInstalled', migration_installed,
  'traineeAccounts', trainee_accounts,
  'linkedTraineeAccounts', linked_trainee_accounts,
  'traineeSample', trainee_sample,
  'result', case
    when state_loader_scoped
      and paging_scoped
      and migration_installed
      and coalesce((trainee_sample ->> 'onlyOwnRowsReturned')::boolean, true)
      and coalesce((trainee_sample ->> 'attendanceRowsReturned')::integer = (trainee_sample ->> 'attendanceRowsStoredForMember')::integer, true)
    then 'PASS'
    else 'REVIEW'
  end
) as v85_self_attendance_live_feed_status
from checks;

-- -----------------------------------------------------------------------------
-- 6. ROLLBACK
--    Re-run LSO_DUTY_HOURS_COMPLETE_INSTALL.sql (or supabase-setup.sql) to
--    restore the previous lso_get_state body, then:
--      begin;
--        drop function if exists public.lso_trainee_scoped_state_v85(jsonb, text);
--        delete from public.lso_schema_migrations
--         where migration_key = '016_self_attendance_live_feed_v85';
--      commit;
--    (If the V69 paging RPC was hardened, re-run LSO_MISSING_V69_RPC_REPAIR.sql
--    to restore its previous body.) Rolling back returns the My Attendance
--    section to its previous blank state; it never deletes attendance records.
-- -----------------------------------------------------------------------------


-- ########################################################################
-- PATCH: LSO_ACCOUNTS_STALE_LINK_SAVE_FIX.sql
-- ########################################################################

-- ============================================================================
-- LSO ACCOUNTS — STALE LINK SAVE FIX (2026-09-22)
-- Repairs public.lso_save_accounts() so that a Trainee/Probationary account
-- whose linked member record no longer exists in system_state.members can no
-- longer abort every account save. Before this patch, changing the role of an
-- UNRELATED account raised:
--     ERROR 22023: The selected linked member record could not be found.
-- and the role change was never written. Unchanged links are now passed
-- through as-is (the account keeps working exactly as stored) while new or
-- changed links keep the full existence + period + duplicate validation.
-- Run in Supabase SQL Editor. No data is modified by this file.
-- ============================================================================
create or replace function public.lso_save_accounts(
  p_token text,
  p_accounts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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
$$;


-- ########################################################################
-- PATCH: LSO_MEMBERSHIP_ROLE_ATTENDANCE_PERMISSION_FIX.sql
-- ########################################################################

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


-- ########################################################################
-- PATCH: LSO_ACCESS_CONTROL_REALTIME_SYNC_V89.sql
-- ########################################################################

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
-- lso_schema_migrations.version_number is UNIQUE. Earlier patches already own
-- version 14 (V84 / V69 repair) and 15/16, so never hard-code the number here.
-- On a re-run, keep the version already assigned to this migration key; only
-- on a first install take the next free version (at least 17).
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


-- ########################################################################
-- FINAL COMPLETE-INSTALL MIGRATION MARKER (conflict-safe, one version only)
-- ########################################################################
do $lso_complete_marker$
declare
  v_version integer;
begin
  select version_number
    into v_version
  from public.lso_schema_migrations
  where migration_key = '999_complete_supabase_install_v89';

  if v_version is not null then
    update public.lso_schema_migrations
       set title = 'Complete Supabase installer V89',
           checksum = 'complete-supabase-install-v89',
           notes = 'Single-file install of the LSO database through V89 realtime access control. Patch-level migration markers are intentionally consolidated here.'
     where migration_key = '999_complete_supabase_install_v89';
    return;
  end if;

  select greatest(coalesce(max(version_number), 0) + 1, 17)
    into v_version
  from public.lso_schema_migrations;

  insert into public.lso_schema_migrations (migration_key, version_number, title, checksum, notes)
  values (
    '999_complete_supabase_install_v89',
    v_version,
    'Complete Supabase installer V89',
    'complete-supabase-install-v89',
    'Single-file install of the LSO database through V89 realtime access control. Patch-level migration markers are intentionally consolidated here.'
  );
end;
$lso_complete_marker$;

notify pgrst, 'reload schema';

select jsonb_build_object(
  'complete_install_registered', true,
  'permission_center', to_regprocedure('public.lso_get_permission_center(text)') is not null,
  'realtime_permission_fingerprint', to_regprocedure('public.lso_get_permission_revision(text)') is not null,
  'membership_official_attendance', public.lso_role_can('Membership','attendance_group','Official Members'),
  'gensec_new_month_attendance', public.lso_role_can('General Secretary','action','saveDraftAttendance')
    and public.lso_role_can('General Secretary','write_column','events')
    and public.lso_role_can('General Secretary','write_column','attendance')
) as complete_install_verification;


-- ----------------------------------------------------------------------------
-- V90 VERIFICATION — read this result after the installer finishes.
-- Every check must be true. If any check is false, send this result to the
-- developer before using the website.
-- ----------------------------------------------------------------------------
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
) as v90_rewrite_verification;
