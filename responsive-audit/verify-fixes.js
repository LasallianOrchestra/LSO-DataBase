/* Verifies each V74 fix numerically at the viewports where the defect was measured. */
const path = require('path');
const OUT = process.env.LSO_AUDIT_OUT || path.join(__dirname, 'results');
const { chromium } = require('playwright-core');
const seed = require('./seed');
const { buildShim } = require('./mock-supabase');

async function login(page) {
  await page.goto((process.env.LSO_URL || 'http://localhost:8080/index.html'), { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1400);
  await page.fill('#loginUsername', 'lso.admin');
  await page.fill('#loginPassword', 'x');
  await page.click('.auth-submit');
  await page.waitForFunction(() => document.body.dataset.authenticated === 'true', null, { timeout: 20000 });
  await page.waitForTimeout(1600);
}

(async () => {
  const browser = await chromium.connectOverCDP((process.env.LSO_CDP || 'http://127.0.0.1:9222'));
  const out = {};

  /* F0 — coarse pointer at 1194 and 1024 and 1368 */
  for (const w of [1194, 1024, 1368]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 834 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, serviceWorkers: 'block', timezoneId: 'Asia/Manila' });
    const page = await ctx.newPage();
    await page.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await login(page);
    await page.evaluate(() => window.LSOApp.setView('attendanceView'));
    await page.waitForTimeout(900);
    out['F0_' + w] = await page.evaluate(() => {
      const main = document.querySelector('main.main-content');
      const shell = document.getElementById('appShell');
      const grid = document.getElementById('attendanceSharedGroupControls');
      const clipped = Array.from(document.querySelectorAll('.view.active *')).filter(el => {
        const cs = getComputedStyle(el);
        return (cs.overflowX === 'hidden' || cs.overflowX === 'clip') && el.scrollWidth > el.clientWidth + 60 && el.clientWidth > 0;
      }).map(el => ({ sel: el.id || el.className.toString().slice(0, 40), lost: el.scrollWidth - el.clientWidth }));
      return {
        mainWidth: Math.round(main.getBoundingClientRect().width),
        shellDisplay: getComputedStyle(shell).display,
        shellInline: shell.style.display,
        gridLost: grid ? grid.scrollWidth - grid.clientWidth : null,
        bigClips: clipped.slice(0, 4),
        innerWidth: innerWidth
      };
    });
    await page.screenshot({ path: path.join(OUT, 'shots', 'FIXED-F0-.png') });
    await ctx.close();
  }

  /* F1/F2/F4/F5/F7/F8 at 390 phone */
  {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, serviceWorkers: 'block', timezoneId: 'Asia/Manila' });
    const page = await ctx.newPage();
    await page.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await login(page);
    out.F1_topbar = await page.evaluate(() => {
      const actions = document.querySelector('.topbar-actions');
      const kids = Array.from(actions.children).map(el => {
        const r = el.getBoundingClientRect();
        return { id: el.id || el.className.toString().slice(0, 30), left: Math.round(r.left), right: Math.round(r.right), visible: el.getClientRects().length > 0 && getComputedStyle(el).display !== 'none' };
      });
      return { innerWidth: innerWidth, actionsRight: Math.round(actions.getBoundingClientRect().right), kids, allInside: kids.filter(k => k.visible).every(k => k.right <= innerWidth + 1) };
    });
    out.F5_inputs = await page.evaluate(() => Array.from(document.querySelectorAll('input,select,textarea')).slice(0, 400).map(el => parseFloat(getComputedStyle(el).fontSize)).filter(s => s < 16).length);
    // F2 modal footer
    await page.evaluate(() => window.LSOApp.setView('membersView'));
    await page.waitForTimeout(700);
    await page.evaluate(() => window.LSOApp.openMember(window.LSOApp.getMembers()[0].id));
    await page.waitForTimeout(800);
    out.F2_footer = await page.evaluate(() => {
      const f = document.querySelector('#memberModal .modal-footer');
      if (!f) return { missing: true };
      const cs = getComputedStyle(f);
      return { background: cs.backgroundColor, position: cs.position, backdrop: cs.backdropFilter };
    });
    await page.screenshot({ path: path.join(OUT, 'shots', 'FIXED-F2-modal-footer-390.png') });
    await page.evaluate(() => document.querySelector('#closeMemberModal').click());
    await page.waitForTimeout(500);
    // F4 tap targets in members table
    out.F4_targets = await page.evaluate(() => Array.from(document.querySelectorAll('.table-action, .segment-button, .monthly-report-tab')).filter(el => el.getClientRects().length > 0).slice(0, 10).map(el => { const r = el.getBoundingClientRect(); return { sel: el.className.toString().slice(0, 26), w: Math.round(r.width), h: Math.round(r.height) }; }));
    // F7 drawer aria
    await page.evaluate(() => document.querySelector('.mobile-menu').click());
    await page.waitForTimeout(500);
    const openAria = await page.evaluate(() => document.querySelector('.mobile-menu').getAttribute('aria-expanded'));
    await page.evaluate(() => document.querySelector('.sidebar-close').click());
    await page.waitForTimeout(500);
    const closedAria = await page.evaluate(() => document.querySelector('.mobile-menu').getAttribute('aria-expanded'));
    out.F7_aria = { open: openAria, closed: closedAria, controls: await page.evaluate(() => document.querySelector('.mobile-menu').getAttribute('aria-controls')) };
    // F8 toast pointer events
    out.F8_toast = await page.evaluate(() => { const t = document.getElementById('toastRegion'); return t ? getComputedStyle(t).pointerEvents : 'none-found'; });
    await page.screenshot({ path: path.join(OUT, 'shots', 'FIXED-F1-topbar-390.png') });
    await ctx.close();
  }

  /* F3 — 280px login + app */
  {
    const ctx = await browser.newContext({ viewport: { width: 280, height: 653 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, serviceWorkers: 'block', timezoneId: 'Asia/Manila' });
    const page = await ctx.newPage();
    await page.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await page.goto((process.env.LSO_URL || 'http://localhost:8080/index.html'), { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1500);
    out.F3_login = await page.evaluate(() => ({ docScroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
    await page.screenshot({ path: path.join(OUT, 'shots', 'FIXED-F3-login-280.png') });
    await login(page);
    out.F3_app = await page.evaluate(() => ({ docScroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
    await page.screenshot({ path: path.join(OUT, 'shots', 'FIXED-F3-app-280.png') });
    await ctx.close();
  }

  /* F4-full (V75) — every remaining tap target on a 390px touch phone must be >= 44px */
  {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, serviceWorkers: 'block', timezoneId: 'Asia/Manila' });
    const page = await ctx.newPage();
    await page.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await page.goto((process.env.LSO_URL || 'http://localhost:8080/index.html'), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#loginTab', { state: 'attached', timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(600);
    out.F4_login_tabs = await page.evaluate(() => ['loginTab', 'registerTab'].map(id => { const el = document.getElementById(id); if (!el) return { id, missing: true }; const r = el.getBoundingClientRect(); return { id, w: Math.round(r.width), h: Math.round(r.height) }; }));
    await login(page);
    const small = {};
    for (const v of ['dashboardView', 'membersView', 'attendanceView', 'dutyHoursView', 'monthlyReportView', 'accountsView']) {
      await page.evaluate(id => window.LSOApp.setView(id), v);
      await page.waitForTimeout(700);
      small[v] = await page.evaluate(() => {
        const sel = 'a[href],button,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]),select,textarea,summary,[role="button"],[tabindex]:not([tabindex="-1"])';
        const bad = [];
        for (const el of document.querySelectorAll(sel)) {
          if (el.disabled || el.hidden) continue;
          const view = el.closest('.view');
          if (view && !view.classList.contains('active')) continue;
          if (!el.getClientRects().length) continue;
          const cs = getComputedStyle(el);
          if (cs.pointerEvents === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.15) continue;
          const r = el.getBoundingClientRect();
          if (r.width < 1 || r.height < 1) continue;
          if (r.width < 44 || r.height < 44) bad.push({ sel: el.id ? '#' + el.id : (el.className.toString().slice(0, 40) || el.tagName), w: Math.round(r.width), h: Math.round(r.height) });
        }
        return bad;
      });
    }
    out.F4_full = { perView: Object.fromEntries(Object.entries(small).map(([k, v]) => [k, v.length])), offenders: Object.values(small).flat().slice(0, 25) };
    await ctx.close();
  }

  /* F9 (V75) — single shared shell-layout contract */
  {
    const ctx = await browser.newContext({ viewport: { width: 1194, height: 834 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, serviceWorkers: 'block', timezoneId: 'Asia/Manila' });
    const page = await ctx.newPage();
    await page.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await page.goto((process.env.LSO_URL || 'http://localhost:8080/index.html'), { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1500);
    out.F9_touch = await page.evaluate(() => {
      const L = window.LSOShellLayout;
      return { present: !!L, query: L ? L.QUERY : null, isMobileShell: L ? L.isMobileShell() : null, hasOnChange: !!(L && typeof L.onChange === 'function') };
    });
    await ctx.close();
    const ctx2 = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
    const page2 = await ctx2.newPage();
    await page2.route('**://cdn.jsdelivr.net/**', r => r.fulfill({ status: 200, contentType: 'application/javascript', body: buildShim(seed) }));
    await page2.goto((process.env.LSO_URL || 'http://localhost:8080/index.html'), { waitUntil: 'domcontentloaded' });
    await page2.waitForTimeout(1500);
    out.F9_desktop = await page2.evaluate(() => window.LSOShellLayout ? window.LSOShellLayout.isMobileShell() : null);
    await ctx2.close();
  }

  require('fs').writeFileSync(require('path').join(OUT, 'fix-verification.json'), JSON.stringify(out, null, 1));
  console.log(JSON.stringify(out, null, 1));
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
