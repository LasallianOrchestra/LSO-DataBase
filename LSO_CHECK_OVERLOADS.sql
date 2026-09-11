-- ============================================================================
-- LSO — CHECK WHICH lso_update_state_v69 IS LIVE (READ-ONLY, CHANGES NOTHING)
-- ----------------------------------------------------------------------------
-- Run this in Supabase > SQL Editor and paste the result back.
-- If you still see LSO_CONFLICT errors, this tells us exactly why:
--   * more than one row            -> an old overload is still present
--   * contains_conflict_check=true -> that row is the one rejecting saves
-- The result must be exactly ONE row with contains_conflict_check = false.
-- ============================================================================
select
  p.oid::regprocedure as signature,
  pg_get_function_arguments(p.oid) as arguments,
  position('LSO_CONFLICT' in pg_get_functiondef(p.oid)) > 0 as contains_conflict_check
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'lso_update_state_v69';
