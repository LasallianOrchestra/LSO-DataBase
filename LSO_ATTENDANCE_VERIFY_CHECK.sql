-- ============================================================================
-- LSO — READ-ONLY CHECK: does the server actually store "Verified" activities?
-- ----------------------------------------------------------------------------
-- This query CHANGES NOTHING. It lists every attendance activity whose
-- workflow currently has the `verified` flag set on the server.
--
-- WHY THIS MATTERS
--   The "Verify & Lock Activity" button not switching to "Unverify for Editing"
--   was caused by the browser reading a stale in-memory copy of the events
--   (fixed in attendance-governance-v2.js v12). This check confirms the
--   SERVER side is healthy: if you verified an activity and it appears below
--   with verified = true, then no Supabase SQL update is needed for this fix.
--
-- RUN IN: Supabase Dashboard > SQL Editor > New query
-- ============================================================================

select
  s.id as state_row,
  evt.value ->> 'id' as event_id,
  evt.value ->> 'title' as title,
  evt.value ->> 'semester' as semester,
  wk.key as workflow_key,
  wk.value ->> 'verified' as verified,
  wk.value ->> 'verifiedBy' as verified_by,
  wk.value ->> 'verifiedAt' as verified_at,
  wk.value ->> 'state' as workflow_state
from public.system_state s
cross join lateral jsonb_array_elements(coalesce(s.events, '[]'::jsonb)) as evt(value)
cross join lateral jsonb_each(coalesce(evt.value -> 'attendanceWorkflows', '{}'::jsonb)) as wk(key, value)
where s.id = 1
order by wk.value ->> 'verifiedAt' desc nulls last;
