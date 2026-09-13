# LSO Responsive Audit — regression suite

Cross-device responsiveness & behaviour tests for the LSO Orchestra Management
System. Companion to `../RESPONSIVE_DEVICE_AUDIT.md` (findings F0–F9 and the V74
fix layer appended to `lso-ui-bundle-v73.css`).

## What it does

`harness.js` drives the **real application** (`../index.html`) in headless
Chromium over the Chrome DevTools Protocol:

* 17 device profiles, 280 px → 2560 px, portrait + landscape, touch + mouse;
* logs in through the real login form against a faithful Supabase RPC mock
  (`mock-supabase.js` implements `lso_login`, `lso_get_state`, `lso_ping`, …) so
  the suite runs without touching the production database;
* seeds a realistic dataset (`seed.js`: 34 members, 90 duty entries, 16 accounts);
* walks all 11 views and measures: page overflow, clipped/unreachable content,
  off-screen controls, tap-target sizes, sub-16px form controls (iOS
  zoom-on-focus), hit-test blocking, sticky/fixed layering, scroll containers;
* exercises behaviour: navigation drawer (open/close/Esc/backdrop/scroll-lock/
  scroll-restore), member modal (fit, footer opacity, close), orientation flips;
* writes `results/results.json` + screenshots to `results/shots/`.

`verify-fixes.js` re-measures each V74 fix at the exact viewport where the defect
was found and writes `results/fix-verification.json`.

`ci-check.js` turns the measurements into pass/fail guards (G1–G6) and exits
non-zero on violation — suitable for CI.

## Running locally

```bash
npm install                      # playwright-core
npm run serve                    # static server for the app on :8080 (from repo root)
# any Chromium with a DevTools port works; e.g.:
npx playwright install chromium
node -e "require('playwright-core').chromium.launch({headless:true,args:['--remote-debugging-port=9222']})"
npm run ci                       # audit + verify + guards
```

Useful environment overrides: `LSO_URL` (app URL), `LSO_CDP` (DevTools endpoint),
`LSO_AUDIT_OUT` (results directory).

## Guards

| Guard | Assertion | Finding |
|---|---|---|
| G1 | `scrollWidth === clientWidth` for every view × device | F3 |
| G2 | no clipped/unreachable content; main column ≥ 95% of viewport on wide touch screens | F0 |
| G3 | every visible topbar control inside the viewport on phones | F1 |
| G4 | member-modal footer opaque while open at ≤680 px | F2 |
| G5 | no `input/select/textarea` below 16 px computed font-size on touch | F5 |
| G6 | hamburger exposes `aria-expanded` + `aria-controls` | F7 |
