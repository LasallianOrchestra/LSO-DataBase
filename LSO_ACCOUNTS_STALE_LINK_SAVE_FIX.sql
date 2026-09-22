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
