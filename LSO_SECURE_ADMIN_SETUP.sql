-- Lasallian Symphony Orchestra
-- Secure Administrator Setup and Legacy Bootstrap Remediation
--
-- Run this file PRIVATELY in the Supabase SQL Editor after supabase-setup.sql.
-- It is also safe to run once against an existing deployment to remove the
-- legacy public bootstrap route and rotate the protected administrator.
--
-- The final SELECT returns one-time credentials. Save them immediately.
-- Nothing in the website source contains or can recreate the password.

begin;

create extension if not exists pgcrypto;

-- Remove the legacy browser-callable account creator before issuing credentials.
drop function if exists public.lso_bootstrap_default_admin();

create temp table lso_secure_admin_result (
  administrator_username text not null,
  one_time_password text not null,
  action_taken text not null
) on commit preserve rows;

truncate table lso_secure_admin_result;

do $lso_secure_admin$
declare
  v_id uuid;
  v_existing_username text;
  v_username text;
  v_password text := encode(gen_random_bytes(24), 'base64');
  v_action text;
begin
  if to_regclass('public.lso_accounts') is null then
    raise exception 'Run supabase-setup.sql before LSO_SECURE_ADMIN_SETUP.sql.';
  end if;

  select id, username
    into v_id, v_existing_username
  from public.lso_accounts
  where is_default = true
  order by created_at
  limit 1
  for update;

  -- Preserve a customized administrator username. Replace only the exposed
  -- legacy username, or generate a new username for a fresh installation.
  if v_id is not null and lower(coalesce(v_existing_username, '')) <> 'sna1161' then
    v_username := v_existing_username;
  else
    loop
      v_username := 'LSOADMIN_' || upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
      exit when not exists (
        select 1 from public.lso_accounts where lower(username) = lower(v_username)
      );
    end loop;
  end if;

  if v_id is null then
    insert into public.lso_accounts (
      username,
      contact_email,
      display_name,
      password_hash,
      role,
      approval_status,
      disabled,
      is_default,
      requested_at,
      approved_at,
      approved_by,
      rejected_at,
      rejected_by
    ) values (
      v_username,
      null,
      'LSO Administrator',
      crypt(v_password, gen_salt('bf', 12)),
      'Administrator',
      'Approved',
      false,
      true,
      now(),
      now(),
      v_username,
      null,
      null
    )
    returning id into v_id;
    v_action := 'Created protected administrator';
  else
    if exists (
      select 1
      from public.lso_accounts
      where lower(username) = lower(v_username)
        and id <> v_id
    ) then
      raise exception 'The generated administrator username unexpectedly conflicts with another account.';
    end if;

    update public.lso_accounts
    set username = v_username,
        display_name = coalesce(nullif(display_name, ''), 'LSO Administrator'),
        password_hash = crypt(v_password, gen_salt('bf', 12)),
        role = 'Administrator',
        approval_status = 'Approved',
        disabled = false,
        is_default = true,
        approved_at = now(),
        approved_by = v_username,
        rejected_at = null,
        rejected_by = null,
        updated_at = now()
    where id = v_id;

    -- End all old sessions so a previously exposed credential cannot remain active.
    delete from public.lso_sessions where account_id = v_id;
    v_action := 'Rotated and secured protected administrator';
  end if;

  insert into lso_secure_admin_result (
    administrator_username,
    one_time_password,
    action_taken
  ) values (
    v_username,
    v_password,
    v_action
  );
end;
$lso_secure_admin$;

-- Explicit defense in depth. The legacy function was dropped above; these
-- table grants remain denied to browser roles.
revoke all on table public.lso_accounts from anon, authenticated;
revoke all on table public.lso_sessions from anon, authenticated;

commit;
notify pgrst, 'reload schema';

select
  administrator_username,
  one_time_password,
  action_taken,
  'Save these credentials now. This password is not stored in the website source.' as instruction
from lso_secure_admin_result;
