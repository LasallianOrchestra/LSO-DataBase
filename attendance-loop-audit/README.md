# Attendance loop audit — reproduction harness (V83)

Headless regression harness for the "attendance keeps refreshing by itself and
cannot be saved" defect. It loads the **real** `../index.html` with the **real**
scripts, signs in as an Administrator through the real login form against the
Supabase RPC mock borrowed from `../responsive-audit/`, seeds a month of
attendance, and then measures what a background refresh does to the roster.

## Run

```bash
npm install jsdom@24            # only dependency
node harness.js <scenario>
```

| Scenario | What it does |
| --- | --- |
| `draft` | Mark rows on a Draft month, then idle — default |
| `noisy` | Same, while another device saves to the shared DB every second |
| `finalized` | Record, review and finalize the month first |
| `finalized-loa` | Finalized month plus an approved LOA row |
| `save` | Mark, press Save, and re-check after the cloud round-trip |
| `smoke` | Walk every view, then confirm attendance can still be saved |

Useful overrides: `LSO_MEASURE_MS` (window length, default 12000),
`LSO_VERBOSE=1` (forward page console output).

## What it reports

* `roster DOM rebuilds` — how often `#attendanceRosterBody` was replaced
  (each rebuild is a chance to destroy unsaved input);
* `user input before/after wait` — whether the officer's unsaved marks survived;
* `unsaved indicator` — text of the V83 unsaved-changes banner;
* `localStorage writes` / `lso events` — write and refresh traffic;
* page errors.

## Expected result on the fixed build

Unsaved marks survive every scenario, a row that the officer did not touch still
picks up the other device's change, and rebuild counts stay at 0–1 per 12 s
instead of one per background event.

> The mock (`../responsive-audit/mock-supabase.js`) is patched at load time so
> `lso_update_state*` returns and persists the full state row, exactly like the
> production SQL functions. Without that patch the client sees a permanent
> local/remote divergence and appears to loop.
