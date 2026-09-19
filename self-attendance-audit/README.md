# Self-Attendance (V84/V85) verification harness

Interface checks for the read-only **My Attendance** section
(`ownAttendanceView`) that ships with `own-attendance-member-info-v1.js`.

The harness loads the **real** `index.html` with the real application scripts
into a headless DOM (jsdom) and signs in through the real login form. Only the
Supabase RPC endpoint is replaced (via `../responsive-audit/mock-supabase.js`),
so the shell, the permission pipeline, the view switching, and the module under
test are all exercised as shipped.

**V85:** the mock's `lso_get_state` now behaves like the real database function.
A Trainee/Probationary token receives only its own member record, its own
attendance rows, the activities those rows reference and the `scope` marker
(a port of `public.lso_trainee_scoped_state_v85` from
`LSO_SELF_ATTENDANCE_LIVE_FEED_V85.sql`). In `legacy` mode it returns the
pre-V85 production payload (`events: []`, `attendance: []`) — the state that
left the V84 section blank in production while the old full-state mock passed.

## Run

```bash
npm install          # jsdom 22 (only dependency)
node harness.js      # all six scenarios, default
node harness.js granted    # Trainee with the permission granted
node harness.js live       # V85: officer files/corrects a record while the section is open
node harness.js legacy     # V85: database still on the pre-V85 loader (reproduces the blank)
node harness.js revoked    # Trainee with the permission revoked
node harness.js admin      # Administrator
node harness.js center     # Role & Permission Center role locking
```

Exit code is `0` only when every check passes; failures are listed at the end.

## What it proves

Scenario 1 (`granted`) — the signed-in Trainee/Probationary member sees exactly
their own attendance rows, and nothing else:

- navigation exposes only Duty Hours and My Attendance, landing stays Duty Hours;
- the section renders the account's three seeded records (Present, Late,
  Excused/LOA) while two other members' records never appear;
- the attendance rate is Present+Late over rated sessions (LOA/Excused excluded);
- the section contains no editable field (the month filter is a read-only view
  filter), and the only controls are Refresh and Print;
- the module source calls no write API;
- the printable report renders the same own rows only.

Scenario 1b (`live`) — with the section open, a record filed server-side for the
member appears on the next synchronization without a click or reload, a row
filed for another member at the same time never appears, the summary cards
recount, and a later correction of the record is reflected too. (The previous
V84 module fails five of these checks: it rendered before the operations module
refreshed its copy and then suppressed the re-render as unchanged.)

Scenario 1c (`legacy`) — against the pre-V85 loader the section shows no rows
and names `LSO_SELF_ATTENDANCE_LIVE_FEED_V85.sql` as the Administrator action,
with the badge "Database update required".

Scenario 2 (`revoked`) — without the permission the navigation item disappears,
opening the section falls back to Duty Hours, and the section stays hidden.

Scenario 3 (`admin`) — an Administrator cannot open the Trainee self section and
the Role & Permission Center lists "My Attendance" with its read-only scope.

Scenario 4 (`center`) — the module card is selectable for Trainee/Probationary
and locked for Membership, General Secretary, and Staff Account.

## Related evidence

`../TEST_RESULTS_SELF_ATTENDANCE_V84.txt` records the V84 pass list, together
with the 28 database checks executed against a real PostgreSQL instance through
the V82 -> V84 migration sequence. `../TEST_RESULTS_SELF_ATTENDANCE_LIVE_V85.txt`
records the V85 runs (51 interface checks, 23 database checks on PostgreSQL 16).

## Notes

- No real browser binary is required; layout remains covered by the shipped CSS
  contract and the existing `responsive-audit/` suite (which needs Playwright
  and a Chromium download).
- The harness is developer tooling and is not served to users; only the new
  runtime module (`own-attendance-member-info-v1.js`) is uploaded with the site.
