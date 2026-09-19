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
do $v85_marker$
declare
  v_next integer;
begin
  if exists (select 1 from public.lso_schema_migrations where migration_key = '016_self_attendance_live_feed_v85') then
    update public.lso_schema_migrations
       set title = 'Trainee/Probationary My Attendance live feed (own attendance rows + referenced activities)',
           checksum = 'self-attendance-live-feed-v85-016',
           notes = 'lso_get_state now returns the linked member''s own attendance rows and the activities they reference to Trainee/Probationary sessions; lso_get_collection_page_v69 applies the same own-record boundary. No permission, write path, or operational data is changed.'
     where migration_key = '016_self_attendance_live_feed_v85';
    return;
  end if;

  select greatest(coalesce(max(version_number), 0) + 1, 16)
    into v_next
    from public.lso_schema_migrations;

  insert into public.lso_schema_migrations (migration_key, version_number, title, checksum, notes)
  values (
    '016_self_attendance_live_feed_v85',
    v_next,
    'Trainee/Probationary My Attendance live feed (own attendance rows + referenced activities)',
    'self-attendance-live-feed-v85-016',
    'lso_get_state now returns the linked member''s own attendance rows and the activities they reference to Trainee/Probationary sessions; lso_get_collection_page_v69 applies the same own-record boundary. No permission, write path, or operational data is changed.'
  );
end;
$v85_marker$;

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
