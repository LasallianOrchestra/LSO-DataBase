/* CI regression guards for the LSO responsive layout.
   Run after harness.js (+ optionally verify-fixes.js); exits non-zero on violation.

   Guards (mapped to RESPONSIVE_DEVICE_AUDIT.md findings):
     1. no page-level horizontal overflow on any device/view          (F3)
     2. no content-column collapse on wide touch screens              (F0)
     3. no topbar control parked off-screen on phones                 (F1)
     4. modal footer opaque while open on phones                      (F2, needs fix-verification.json)
     5. no form control below 16px on touch devices (iOS zoom)        (F5)
     6. drawer exposes aria-expanded/aria-controls                    (F7, needs fix-verification.json)
     7. every tap target >=44px on touch devices                      (F4/V75)
     8. single shared shell-layout contract present and correct       (F9/V75, needs fix-verification.json)
     9. navigation drawer reachable on EVERY coarse-pointer profile,
        including those wider than 920px                              (F10/V76)
    10. the mouse shell is untouched by the drawer contract — no
        hamburger, sidebar stays docked                               (F10/V76 regression control)

   G9/G10 exist because of F10: the drawer toggle's `display` rule lived only in
   width-only `@media (max-width: 920px)` blocks while the drawer itself followed
   `(max-width: 920px), (pointer: coarse)`, so iPad Pro 11" landscape / iPad Pro
   12.9" / Surface Pro rendered an off-canvas sidebar with no way to open it.
   The old harness gated its drawer test on the same width-only query and skipped
   those three profiles, which is why the defect was never measured.
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
    if (d.touch) check((m.tapTargetsSmall || []).length === 0, `G7 tap target <44px on touch`, `${d.id}/${viewId}: ${(m.tapTargetsSmall || []).slice(0, 3).map(t => `${t.sel}(${t.w}x${t.h})`).join(', ')}`);
  }
  if ((rec.login || {}).pageOverflowX > 0) failures.push(`G1 horizontal overflow — ${d.id}/login: ${rec.login.pageOverflowX}px`);
  if (d.touch && (((rec.login || {}).tapTargetsSmall) || []).length) failures.push(`G7 tap target <44px on touch — ${d.id}/login: ${((rec.login||{}).tapTargetsSmall||[]).slice(0,3).map(t=>`${t.sel}(${t.w}x${t.h})`).join(', ')}`);

  /* G9/G10 — the drawer contract. The harness asks the page (LSOShellLayout)
     whether it rendered the mobile shell, so this now covers wide touch too. */
  const drawer = (rec.behaviour || {}).drawer;
  if (d.touch) {
    check(!!drawer, 'G9 drawer exercised on touch profile', `${d.id}: no drawer record — harness gate drifted from the shell contract?`);
    if (drawer) {
      const btn = drawer.mobileMenuButton;
      check(!!btn && btn.found && btn.display !== 'none', 'G9 drawer toggle visible', `${d.id}: ${btn ? btn.display : 'not found'}`);
      check(!!btn && btn.w >= 44 && btn.h >= 44, 'G9 drawer toggle >=44px', `${d.id}: ${btn ? `${btn.w}x${btn.h}` : 'not found'}`);
      check(!!btn && btn.left >= 0 && btn.top >= 0, 'G9 drawer toggle inside viewport', `${d.id}: left=${btn && btn.left} top=${btn && btn.top}`);
      check(!!(drawer.openState && drawer.openState.sidebarOpenClass === true), 'G9 drawer opens from the toggle', `${d.id}: open=${drawer.openState && drawer.openState.sidebarOpenClass}`);
      const sr = drawer.openState && drawer.openState.sidebarRect;
      check(!!sr && sr.left >= -1 && sr.width > 0, 'G9 drawer panel on screen when open', `${d.id}: ${JSON.stringify(sr)}`);
      check(!!(drawer.openState && drawer.openState.ariaExpanded === 'true'), 'G9 drawer toggle aria-expanded when open', `${d.id}: ${drawer.openState && drawer.openState.ariaExpanded}`);
      check(Array.isArray(drawer.navTargets) && drawer.navTargets.length > 0 && drawer.navTargets.every(t => t.visible), 'G9 drawer nav targets visible', `${d.id}: ${(drawer.navTargets || []).length} targets`);
      check(!!(drawer.closedState && drawer.closedState.sidebarOpenClass === false), 'G9 drawer closes again', `${d.id}: open=${drawer.closedState && drawer.closedState.sidebarOpenClass}`);
    }
  } else {
    check(!drawer, 'G10 mouse profile must not render the drawer shell', `${d.id}: drawer record present`);
  }
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
  if (fix.F4_full) check(Object.values(fix.F4_full.perView).every(n => n === 0), 'G7 every tap target >=44px on touch (V75)', JSON.stringify((fix.F4_full.offenders || []).slice(0, 6)));
  if (fix.F4_login_tabs) check(fix.F4_login_tabs.every(t => !t.missing && t.w >= 44 && t.h >= 44), 'G7 login tabs >=44px on touch (V75)', JSON.stringify(fix.F4_login_tabs));
  if (fix.F9_touch) check(fix.F9_touch.present === true && fix.F9_touch.isMobileShell === true && fix.F9_desktop === false, 'G8 shared shell-layout contract (LSOShellLayout)', JSON.stringify({ touch: fix.F9_touch, desktop: fix.F9_desktop }));

  /* G9 — F10 at the three coarse-pointer widths above 920px (V76) */
  if (fix.F10_wide_touch) {
    for (const r of fix.F10_wide_touch) {
      const tag = `F10@${r.width}px`;
      check(r.before.shellIsMobile === true, 'G9 wide touch profile is in the drawer shell', `${tag}: isMobileShell=${r.before.shellIsMobile}`);
      check(r.before.toggleDisplay !== 'none' && r.before.toggleDisplay !== 'missing', 'G9 drawer toggle visible on wide touch', `${tag}: ${r.before.toggleDisplay}`);
      check(!!r.before.toggleBox && r.before.toggleBox.w >= 44 && r.before.toggleBox.h >= 44, 'G9 drawer toggle >=44px on wide touch', `${tag}: ${JSON.stringify(r.before.toggleBox)}`);
      check(r.before.toggleInsideViewport === true, 'G9 drawer toggle inside viewport on wide touch', `${tag}: ${JSON.stringify(r.before.toggleBox)}`);
      check(r.opened.hitTest === 'hit' && r.opened.clicked === true, 'G9 drawer toggle tappable (centre hit-test)', `${tag}: ${r.opened.hitTest}`);
      check(r.after.sidebarOpenClass === true && r.after.sidebarOnScreen === true, 'G9 drawer opens on wide touch', `${tag}: open=${r.after.sidebarOpenClass} left=${r.after.sidebarLeft}`);
      check(r.after.navItemCount > 0 && r.after.navItemsHitTestable === r.after.navItemCount, 'G9 every nav item tappable when open on wide touch', `${tag}: ${r.after.navItemsHitTestable}/${r.after.navItemCount}`);
      check(r.after.ariaExpanded === 'true', 'G9 drawer toggle aria-expanded on wide touch', `${tag}: ${r.after.ariaExpanded}`);
      check(r.closed.sidebarOpenClass === false, 'G9 drawer closes on wide touch', `${tag}: open=${r.closed.sidebarOpenClass}`);
      check(r.closed.bodyPosition !== 'fixed', 'G9 no scroll-lock leak after closing on wide touch', `${tag}: body position=${r.closed.bodyPosition}`);
    }
  }

  /* G10 — regression control: the V76 layer is coarse-pointer scoped, so the
     mouse shell must keep its docked sidebar and no hamburger. */
  if (fix.F10_desktop) {
    const dt = fix.F10_desktop;
    check(dt.shellIsMobile === false && dt.toggleDisplay === 'none', 'G10 desktop renders no hamburger', JSON.stringify({ isMobileShell: dt.shellIsMobile, toggle: dt.toggleDisplay }));
    check(dt.sidebarPosition === 'sticky' && dt.sidebarDocked === true && dt.shellDisplay === 'grid', 'G10 desktop sidebar stays docked', JSON.stringify(dt));
  }
} else {
  console.log('note: fix-verification.json absent — guards G4/G6/G8 and the F10 half of G9/G10 skipped (run `node verify-fixes.js`).');
}

if (failures.length) {
  console.error(`RESPONSIVE AUDIT FAILED (${failures.length}):`);
  failures.slice(0, 40).forEach(f => console.error('  ✗ ' + f));
  process.exit(1);
}
console.log(`RESPONSIVE AUDIT PASSED — ${R.devices.length} device profiles, ${R.devices.reduce((n, r) => n + Object.values(r.views || {}).filter(v => v && v.activeView).length, 0)} view measurements, all guards green.`);
