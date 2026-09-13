/* CI regression guards for the LSO responsive layout.
   Run after harness.js (+ optionally verify-fixes.js); exits non-zero on violation.

   Guards (mapped to RESPONSIVE_DEVICE_AUDIT.md findings):
     1. no page-level horizontal overflow on any device/view          (F3)
     2. no content-column collapse on wide touch screens              (F0)
     3. no topbar control parked off-screen on phones                 (F1)
     4. modal footer opaque while open on phones                      (F2, needs fix-verification.json)
     5. no form control below 16px on touch devices (iOS zoom)        (F5)
     6. drawer exposes aria-expanded/aria-controls                    (F7, needs fix-verification.json)
*/
const fs = require('fs');
const path = require('path');
const OUT = process.env.LSO_AUDIT_OUT || path.join(__dirname, 'results');
const resultsPath = path.join(OUT, 'results.json');
if (!fs.existsSync(resultsPath)) {
  console.error('responsive-audit: results.json not found — run `node harness.js` first.');
  process.exit(2);
}
const R = JSON.parse(fs.readFileSync(resultsPath, 'utf8'));
let fix = null;
const fixPath = path.join(OUT, 'fix-verification.json');
if (fs.existsSync(fixPath)) fix = JSON.parse(fs.readFileSync(fixPath, 'utf8'));

const BENIGN = /dcc-hero|command-header|futuristic-command-header|dcc-snapshot-strip|data-recovery-hero|system-health-hero|monthly-report-command|contract-command-header|data-recovery-status-card|recovery-primary-card/;
const TOPBAR = /addMemberTop|notificationButton|notificationCenter|accessibilityButton|exportCsvTop/;
const failures = [];
const check = (ok, label, detail) => { if (!ok) failures.push(`${label}${detail ? ' — ' + detail : ''}`); };

for (const rec of R.devices) {
  const d = rec.device;
  const views = Object.entries(rec.views || {}).filter(([, m]) => m && m.activeView);
  for (const [viewId, m] of views) {
    check(m.pageOverflowX <= 0, `G1 horizontal overflow`, `${d.id}/${viewId}: ${m.pageOverflowX}px`);
    const realClips = (m.clippedContent || []).filter(c => !c.ellipsis && c.lost > 60 && !BENIGN.test(c.sel));
    check(realClips.length === 0, `G2 clipped/collapsed content`, `${d.id}/${viewId}: ${realClips.map(c => `${c.sel}(-${c.lost}px)`).join(', ')}`);
    const parkedTopbar = [...(m.overflowers || []), ...(m.parkedOffcanvas || [])].filter(o => TOPBAR.test(o.sel));
    check(parkedTopbar.length === 0, `G3 topbar control off-screen`, `${d.id}/${viewId}: ${parkedTopbar.map(o => o.sel).join(', ')}`);
    if (d.touch) check((m.smallInputs || []).length === 0, `G5 input <16px on touch`, `${d.id}/${viewId}: ${(m.smallInputs || []).slice(0, 3).map(s => s.sel).join(', ')}`);
  }
  if ((rec.login || {}).pageOverflowX > 0) failures.push(`G1 horizontal overflow — ${d.id}/login: ${rec.login.pageOverflowX}px`);
}

if (fix) {
  for (const k of Object.keys(fix).filter(k => k.startsWith('F0_'))) {
    const v = fix[k];
    check(v.mainWidth >= v.innerWidth * 0.95, `G2 content-column collapse`, `${k}: main ${v.mainWidth}px of ${v.innerWidth}px`);
  }
  if (fix.F1_topbar) check(fix.F1_topbar.allInside === true, 'G3 topbar controls inside viewport', JSON.stringify(fix.F1_topbar.kids.filter(k => k.visible && k.right > fix.F1_topbar.innerWidth)));
  if (fix.F2_footer) check(/rgb\(255, 255, 255\)|rgba\(255, 255, 255/.test(fix.F2_footer.background || ''), 'G4 modal footer transparent', fix.F2_footer.background);
  if (fix.F5_inputs !== undefined) check(fix.F5_inputs === 0, 'G5 inputs below 16px on touch', String(fix.F5_inputs));
  if (fix.F7_aria) check(fix.F7_aria.open === 'true' && fix.F7_aria.closed === 'false' && fix.F7_aria.controls === 'sidebar', 'G6 drawer ARIA state', JSON.stringify(fix.F7_aria));
} else {
  console.log('note: fix-verification.json absent — guards G4/G6 skipped (run `node verify-fixes.js`).');
}

if (failures.length) {
  console.error(`RESPONSIVE AUDIT FAILED (${failures.length}):`);
  failures.slice(0, 40).forEach(f => console.error('  ✗ ' + f));
  process.exit(1);
}
console.log(`RESPONSIVE AUDIT PASSED — ${R.devices.length} device profiles, ${R.devices.reduce((n, r) => n + Object.values(r.views || {}).filter(v => v && v.activeView).length, 0)} view measurements, all guards green.`);
