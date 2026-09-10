-- =============================================================================
-- VERIFY THE V82 MIGRATION MARKER  (read-only)
-- =============================================================================
-- Answers what the dashboard leaves open after you paste a patch: did V82
-- really commit, and are its functions live and reachable by the browser role?
--
-- WHY A SEPARATE QUERY IS NEEDED
--   The patch ends with
--       select jsonb_build_object(...) as v82_role_sync_status;
--   which is easy to misread as "no data" in the dashboard panel. This returns
--   ONE ROW OF PLAIN TEXT instead, and stays accurate even when the answer is
--   "not installed".
--
-- Every "is it wired up" test below reads pg_proc + pg_get_functiondef rather
-- than calling an LSO function, so this query can never fail halfway because a
-- function the patch was supposed to create is missing.
--
-- PREREQUISITE: public.lso_schema_migrations and public.lso_role_permissions,
--   both created by supabase-setup.sql. If this errors with
--     relation "public.lso_schema_migrations" does not exist
--   that error IS the finding -- the base LSO database is not installed, which
--   is exactly why the V82 patch aborts and why the site renders with no data.
--   Use tools/check-v82-prerequisites.sql for the full breakdown.
--
-- RUN IN: Supabase Dashboard > SQL Editor > New query
-- EXPECT: column "v82_status", one row, ending in VERDICT.
-- =============================================================================

with marker as (
  select
    coalesce(bool_or(m.migration_key = '013_role_sync_interview_v82'), false) as installed,
    count(*)                                                                  as applied_total,
    max(m.applied_at)                                                         as last_applied
  from public.lso_schema_migrations m
),
-- The seven functions the patch defines, in the patch's own order.
fn(name, required_sig) as (
  values
    ('lso_v82_columns_for_actions',      'public.lso_v82_columns_for_actions(text[])'),
    ('lso_default_role_configuration',   'public.lso_default_role_configuration(text)'),
    ('lso_v82_write_role_configuration', null),
    ('lso_get_permission_center',        'public.lso_get_permission_center(text)'),
    ('lso_save_role_permissions',        'public.lso_save_role_permissions(text,text,text,jsonb,jsonb,jsonb)'),
    ('lso_reset_role_permissions',       'public.lso_reset_role_permissions(text,text)'),
    ('lso_sync_health_v82',              'public.lso_sync_health_v82(text)')
),
fn_state as (
  select
    f.name,
    f.required_sig,
    x.oid is not null                                   as created,
    -- anon is the role the browser's publishable key connects as. The patch ends
    -- with "revoke all ... from public" then "grant execute ... to anon,authenticated",
    -- so a revoked-but-not-regranted function is invisible to the website.
    case
      when x.oid is null                                  then 'no function'
      when not exists (select 1 from pg_roles where rolname = 'anon') then 'role anon absent'
      when has_function_privilege('anon', x.oid, 'execute')           then 'anon can execute'
      else 'NOT EXECUTABLE BY ANON'
    end                                                  as access
  from fn f
  left join lateral (
    select min(p.oid) as oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
     where p.proname = f.name
  ) x on true
),
-- Mirror of the patch's two pg_get_functiondef checks, done over catalogs so a
-- missing function yields false instead of an error.
wired as (
  select
    coalesce(bool_or(case when p.proname = 'lso_save_role_permissions'
                          then pg_get_functiondef(p.oid) like '%interviewView%' end), false)
      as native_interview,
    coalesce(bool_or(case when p.proname = 'lso_get_permission_center'
                          then position('''columns''' in pg_get_functiondef(p.oid)) > 0 end), false)
      as payload_includes_columns
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.proname in ('lso_save_role_permissions', 'lso_get_permission_center')
),
-- What the permission rows actually look like per configurable role.
roles as (
  select
    r.role_name,
    count(*) filter (where r.permission_key = 'view' and r.allowed)          as views,
    count(*) filter (where r.permission_key = 'action' and r.allowed)        as actions,
    count(*) filter (where r.permission_key = 'write_column' and r.allowed)  as write_columns,
    bool_or(r.permission_key = 'view' and r.resource = 'interviewView' and r.allowed) as interview
  from public.lso_role_permissions r
  where r.role_name in ('Membership', 'General Secretary', 'Staff Account', 'Trainee/Probationary', 'Administrator')
  group by r.role_name
)
select concat_ws(
  chr(10),
  'LSO V82 MIGRATION STATUS',
  '  database : ' || current_database(),
  '',
  '  migration key 013_role_sync_interview_v82 : '
    || case when (select installed from marker) then 'INSTALLED' else 'NOT INSTALLED' end,
  '  rows in lso_schema_migrations             : ' || (select applied_total from marker)
    || '   last applied ' || coalesce(to_char((select last_applied from marker), 'YYYY-MM-DD HH24:MI'), '(unknown)'),
  '',
  '  FUNCTIONS CREATED BY THE PATCH',
  '  (created = exists; access = can the browser role call it)',
  (
    select coalesce(string_agg(
             '     ' || case when created then '[created]' else '[ ABSENT ]' end
               || '  ' || rpad(name, 34, ' ')
               || rpad(access, 22, ' ')
               || coalesce('sig: ' || replace(required_sig, 'public.', ''), 'overloaded'),
             chr(10) order by name), '     none')
    from fn_state
  ),
  '',
  '  BEHAVIOUR WIRED INTO THE FUNCTION BODIES',
  '     interviewView handled natively by lso_save_role_permissions : '
    || case when (select native_interview from wired) then 'yes' else 'NO -- V82 body not applied' end,
  '     lso_get_permission_center returns a columns payload          : '
    || case when (select payload_includes_columns from wired) then 'yes' else 'NO -- V82 body not applied' end,
  '',
  '  ROLE PERMISSION ROWS (expected: views/actions/write_columns populated)',
  (
    select coalesce(string_agg(
             '     ' || rpad(role_name, 24, ' ')
               || 'views ' || lpad(views::text, 3, ' ')
               || '  actions ' || lpad(actions::text, 3, ' ')
               || '  write_columns ' || lpad(write_columns::text, 3, ' ')
               || '  interview ' || case when interview then 'granted' else 'NO' end,
             chr(10) order by role_name),
             '     no role permission rows at all -- lso_role_permissions is empty')
    from roles
  ),
  '',
  '  VERDICT: ' || case
    when not (select installed from marker) then
      'NOT APPLIED. The marker row is absent, so the website still sees the older'
      || chr(10) ||
      '     schema target and System Health will keep flagging "Run the master installer".'
      || chr(10) ||
      '     Run the patch, then re-run this query.'
    when (select count(*) from fn_state where not created) > 0 then
      'PARTIALLY APPLIED. Marker exists but ' || (select count(*) from fn_state where not created)::text
      || ' function(s) are missing -- the patch transaction did not complete.'
      || chr(10) ||
      '     Re-run it (it is idempotent) and read the red error text this time.'
    when (select count(*) from fn_state where created and access <> 'anon can execute') > 0 then
      'APPLIED BUT UNREACHABLE. Functions exist; the browser role cannot execute them,'
      || chr(10) ||
      '     which reproduces "app loads, no data". The patch''s final grant block did not run.'
    when not (select native_interview from wired) or not (select payload_includes_columns from wired) then
      'STALE BODY. Functions exist but their bodies lack the V82 logic, i.e. an older'
      || chr(10) ||
      '     version of these functions is still in place. Re-run the V82 patch.'
    else 'FULLY APPLIED AND REACHABLE -- V82 matches the website target'
      || chr(10) ||
      '     013_role_sync_interview_v82. If the site still shows no data, the database is'
      || chr(10) ||
      '     not the cause; look at the CDN client load and the login session instead.'
  end
) as v82_status;
