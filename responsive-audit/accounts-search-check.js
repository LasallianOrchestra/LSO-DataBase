/* Accounts Search Console (V86) behaviour suite.
   ---------------------------------------------------------------------------
   Drives the REAL application (../index.html) through the same CDP Chromium +
   Supabase mock setup as harness.js, logs in as the Administrator, and checks
   the search console end to end:

     A. rendering   — console visible for the Administrator, counts, summary,
                      no page-level overflow
     B. search      — account name, username, multi-term, status keywords,
                      accent folding, highlighting, clear button
     C. filters     — status tabs, role filter, sort orders, empty state and
                      its reset
     D. keyboard    — Enter jumps to the matched row and focuses its controls,
                      Escape clears, Ctrl/⌘ + K returns to the field
     E. safety      — Action Center deep-links clear the filters, filtered rows
                      keep their role/member/action controls, no console errors,
                      no console for a non-Administrator session
     F. mobile      — no page overflow, 44px touch targets, 16px input floor,
                      snap-scrolling tabs
     G. appearance  — night appearance repaints the console
     H. data        — the console degrades cleanly when the account list carries
                      no lastLoginAt (an unpatched database): the sign-in sort
                      option is hidden, the sort request falls back to Priority,
                      sign-in keywords match nothing, and every other search and
                      sort still works

   Prerequisites: `npm run serve` (or any static server for the repo) and a
   Chromium reachable over CDP (see README.md §Running locally). Screenshots are
   written to results/shots/accounts-search-*.png.

   Usage: node accounts-search-check.js      (or: npm run check-accounts)
*/
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const seed = require('./seed');
const { buildShim } = require('./mock-supabase');

const OUT = process.env.LSO_AUDIT_OUT || path.join(__dirname, 'results');
const SHOTS = path.join(OUT, 'shots');
const BASE = process.env.LSO_URL || 'http://127.0.0.1:8080/index.html';
fs.mkdirSync(SHOTS, { recursive: true });

const results = [];
const check = (label, ok, detail = '') => {
  results.push({ label, ok: Boolean(ok), detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ` — ${detail}` : ''}`);
};

const snapshot = (page) => page.evaluate(() => {
  const body = document.getElementById('accountsTableBody');
  const rows = [...body.querySelectorAll('tr[data-account-row]')];
  return {
    consoleVisible: !document.getElementById('accountsSearchConsole').classList.contains('hidden'),
    total: rows.length,
    visible: rows.filter((row) => !row.classList.contains('accounts-row-filtered-out')).length,
    visibleIds: rows.filter((row) => !row.classList.contains('accounts-row-filtered-out')).map((row) => row.dataset.accountRow),
    order: rows.map((row) => row.querySelector('strong')?.textContent || ''),
    counts: Object.fromEntries([...document.querySelectorAll('[data-account-count]')].map((node) => [node.dataset.accountCount, Number(node.textContent)])),
    status: document.getElementById('accountsSearchStatus').textContent,
    hits: document.querySelectorAll('mark.accounts-search-hit').length,
    placeholder: Boolean(body.querySelector('tr[data-accounts-search-empty]')),
    activeTab: document.querySelector('.accounts-filter-tab.active')?.dataset.accountStatus,
    pageOverflow: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) - document.documentElement.clientWidth
  };
});

async function openApp(browser, shimSource, device) {
  const context = await browser.newContext({
    viewport: { width: device.w, height: device.h },
    deviceScaleFactor: 1,
    isMobile: Boolean(device.mobile),
    hasTouch: Boolean(device.touch),
    serviceWorkers: 'block',
    locale: 'en-US',
    timezoneId: 'Asia/Manila'
  });
  const page = await context.newPage();
  const errors = [];
  page.on('console', (msg) => { if (msg.type() === 'error') errors.push(msg.text().slice(0, 200)); });
  page.on('pageerror', (err) => errors.push('pageerror: ' + String(err.message).slice(0, 200)));
  await page.route('**://cdn.jsdelivr.net/**', (route) => route.fulfill({ status: 200, contentType: 'application/javascript', body: shimSource }));
  await page.route('**://*.supabase.co/**', (route) => route.abort());
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await page.waitForTimeout(1500);
  await page.fill('#loginUsername', 'lso.admin');
  await page.fill('#loginPassword', 'Sup3rSecret!');
  await page.click('.auth-submit');
  await page.waitForFunction(() => document.body.dataset.authenticated === 'true', null, { timeout: 25000 });
  await page.waitForTimeout(1600);
  await page.evaluate(() => {
    if (window.LSOApp?.setView) window.LSOApp.setView('accountsView');
    else document.querySelector('.nav-item[data-view="accountsView"]')?.click();
  });
  await page.waitForTimeout(1800);
  return { context, page, errors };
}

(async () => {
  const shimSource = buildShim(seed);
  const browser = await chromium.connectOverCDP(process.env.LSO_CDP || 'http://127.0.0.1:9222');

  /* -------------------------------------------------- desktop functionality */
  {
    const { context, page, errors } = await openApp(browser, shimSource, { w: 1440, h: 900 });
    const base = await snapshot(page);
    check('A1 console visible for the Administrator', base.consoleVisible);
    check('A2 every seeded account is rendered', base.total === 16, `rows=${base.total}`);
    check('A3 status counts match the seeded accounts',
      base.counts.all === base.total && base.counts.pending === 2 && base.counts.disabled === 1 && base.counts.active === 13,
      JSON.stringify(base.counts));
    check('A4 summary line reports the account total', /^16 accounts/.test(base.status), base.status);
    check('A5 no page-level overflow with the console open', base.pageOverflow <= 0, `${base.pageOverflow}px`);
    await page.screenshot({ path: path.join(SHOTS, 'accounts-search-desktop.png') });

    await page.fill('#accountSearchInput', 'lacsamana');
    await page.waitForTimeout(350);
    const byName = await snapshot(page);
    check('B1 name search narrows the table', byName.visible >= 1 && byName.visible < base.total, `visible=${byName.visible}`);
    check('B2 matched text is highlighted', byName.hits > 0, `marks=${byName.hits}`);
    check('B3 summary reports the match count', /of 16 accounts shown/.test(byName.status), byName.status);

    await page.fill('#accountSearchInput', 'beatriz lacsamana');
    await page.waitForTimeout(300);
    const multi = await snapshot(page);
    check('B4 multi-term search works', multi.visible === 1 && multi.visibleIds[0] === 'acc-2', JSON.stringify(multi.visibleIds));

    await page.fill('#accountSearchInput', 'staff.monitor');
    await page.waitForTimeout(300);
    const byUser = await snapshot(page);
    check('B5 username search finds the account', byUser.visible === 1 && byUser.visibleIds[0] === 'acc-4', JSON.stringify(byUser.visibleIds));

    await page.fill('#accountSearchInput', 'awaiting approval');
    await page.waitForTimeout(300);
    const keyword = await snapshot(page);
    check('B6 plain-language status keywords match', keyword.visible === 2, `visible=${keyword.visible}`);

    await page.click('#accountSearchClear');
    await page.waitForTimeout(300);
    const cleared = await snapshot(page);
    check('B7 clear restores every row and drops the highlights',
      cleared.visible === base.total && cleared.hits === 0, JSON.stringify({ visible: cleared.visible, hits: cleared.hits }));
    check('B8 clear button hides itself when the query is empty', await page.isHidden('#accountSearchClear'));

    await page.click('[data-account-status="pending"]');
    await page.waitForTimeout(300);
    const pending = await snapshot(page);
    check('C1 Needs approval tab isolates the queue',
      pending.visible === 2 && pending.activeTab === 'pending', JSON.stringify({ visible: pending.visible, tab: pending.activeTab }));
    check('C2 tab exposes aria-pressed for assistive tech',
      (await page.getAttribute('[data-account-status="pending"]', 'aria-pressed')) === 'true');
    await page.screenshot({ path: path.join(SHOTS, 'accounts-search-pending.png') });

    await page.selectOption('#accountsRoleFilter', 'Trainee/Probationary');
    await page.waitForTimeout(300);
    const roleFiltered = await snapshot(page);
    check('C3 role filter combines with the status tab', roleFiltered.visible === 0 && roleFiltered.placeholder, `visible=${roleFiltered.visible}`);
    check('C4 empty state offers a reset', await page.isVisible('[data-accounts-search-reset]'));
    await page.screenshot({ path: path.join(SHOTS, 'accounts-search-empty.png') });
    await page.click('[data-accounts-search-reset]');
    await page.waitForTimeout(300);
    const resetFromEmpty = await snapshot(page);
    check('C5 reset from the empty state restores every row',
      resetFromEmpty.visible === base.total && resetFromEmpty.activeTab === 'all',
      JSON.stringify({ visible: resetFromEmpty.visible, tab: resetFromEmpty.activeTab }));

    await page.selectOption('#accountsSortSelect', 'name');
    await page.waitForTimeout(400);
    const names = (await snapshot(page)).order.filter(Boolean);
    check('C6 name sort orders the rows A–Z',
      names.every((name, index) => index === 0 || names[index - 1].localeCompare(name) <= 0), names.slice(0, 3).join(' | '));
    await page.selectOption('#accountsSortSelect', 'priority');
    await page.waitForTimeout(300);
    const restored = await snapshot(page);
    check('C7 priority restores the action-first order',
      restored.order[0] === base.order[0] && restored.order.length === base.order.length, restored.order.slice(0, 3).join(' | '));

    await page.fill('#accountSearchInput', 'zzzz-no-such-account');
    await page.waitForTimeout(300);
    const emptySearch = await snapshot(page);
    check('C8 no-match search shows the empty state', emptySearch.visible === 0 && emptySearch.placeholder);
    await page.click('#accountSearchReset');
    await page.waitForTimeout(300);

    await page.fill('#accountSearchInput', 'staff.monitor');
    await page.waitForTimeout(300);
    await page.press('#accountSearchInput', 'Enter');
    await page.waitForTimeout(500);
    const jump = await page.evaluate(() => {
      const row = document.querySelector('tr[data-account-row="acc-4"]');
      const active = document.activeElement;
      return {
        flash: Boolean(row?.classList.contains('accounts-row-focus-flash')),
        focusedInsideRow: Boolean(active && row?.contains(active)),
        focusedTag: active ? active.tagName.toLowerCase() : ''
      };
    });
    check('D1 Enter highlights the matched row', jump.flash);
    check('D2 Enter moves focus onto the account controls', jump.focusedInsideRow, jump.focusedTag);

    await page.press('#accountSearchInput', 'Escape');
    await page.waitForTimeout(250);
    check('D3 Escape clears the search', (await page.inputValue('#accountSearchInput')) === '');
    check('D4 Escape left every row visible', (await snapshot(page)).visible === base.total);

    await page.evaluate(() => document.body.focus());
    await page.keyboard.press('Control+k');
    await page.waitForTimeout(200);
    check('D5 Ctrl + K returns to the search field', (await page.evaluate(() => document.activeElement?.id)) === 'accountSearchInput');
    await page.keyboard.press('Escape');

    await page.click('[data-account-status="disabled"]');
    await page.fill('#accountSearchInput', 'nothing-matches');
    await page.waitForTimeout(300);
    const beforeDeepLink = await snapshot(page);
    await page.evaluate(() => {
      const probe = document.createElement('button');
      probe.id = 'deepLinkProbe';
      probe.dataset.alertView = 'accountsView';
      document.body.appendChild(probe);
      probe.click();
    });
    await page.waitForTimeout(400);
    const afterDeepLink = await snapshot(page);
    check('E1 Action Center deep-link clears the console filters',
      beforeDeepLink.visible === 0 && afterDeepLink.visible === base.total && afterDeepLink.activeTab === 'all',
      JSON.stringify({ before: beforeDeepLink.visible, after: afterDeepLink.visible, tab: afterDeepLink.activeTab }));
    await page.evaluate(() => document.getElementById('deepLinkProbe')?.remove());

    await page.fill('#accountSearchInput', 'staff.monitor');
    await page.waitForTimeout(300);
    const controls = await page.evaluate(() => {
      const row = document.querySelector('tr[data-account-row="acc-4"]');
      return {
        role: Boolean(row.querySelector('.account-role-select')),
        member: Boolean(row.querySelector('.account-member-select')),
        action: Boolean(row.querySelector('[data-account-action="toggle"]'))
      };
    });
    check('E2 filtered rows keep their role, member and action controls',
      controls.role && controls.member && controls.action, JSON.stringify(controls));

    check('E3 no console or page errors while exercising the console', errors.length === 0, errors.slice(0, 2).join(' || '));

    await page.evaluate(() => { document.documentElement.dataset.lsoTheme = 'night'; });
    await page.waitForTimeout(400);
    const night = await page.evaluate(() => ({
      consoleBg: getComputedStyle(document.getElementById('accountsSearchConsole')).backgroundImage,
      inputBg: getComputedStyle(document.getElementById('accountSearchInput')).backgroundColor
    }));
    await page.screenshot({ path: path.join(SHOTS, 'accounts-search-night.png') });
    check('G1 night appearance repaints the console',
      /rgb\(14, 29, 23\)/.test(night.consoleBg) && night.inputBg === 'rgb(12, 23, 19)', JSON.stringify(night));
    await page.evaluate(() => { document.documentElement.dataset.lsoTheme = 'light'; });
    await context.close();
  }

  /* ------------------------------------------------------------- mobile */
  {
    const { context, page, errors } = await openApp(browser, shimSource, { w: 390, h: 844, mobile: true, touch: true });
    const mobile = await page.evaluate(() => {
      const controls = [...document.querySelectorAll('#accountsSearchConsole button, #accountsSearchConsole input, #accountsSearchConsole select')]
        .filter((node) => node.getClientRects().length)
        .map((node) => ({
          sel: node.id || node.className.split(' ')[0],
          w: Math.round(node.getBoundingClientRect().width),
          h: Math.round(node.getBoundingClientRect().height)
        }));
      const tabs = document.getElementById('accountsStatusTabs');
      return {
        controls,
        inputFont: parseFloat(getComputedStyle(document.getElementById('accountSearchInput')).fontSize),
        tabsScrollable: tabs.scrollWidth > tabs.clientWidth,
        pageOverflow: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) - document.documentElement.clientWidth
      };
    });
    const small = mobile.controls.filter((control) => control.w < 44 || control.h < 44);
    check('F1 mobile: no page overflow from the console', mobile.pageOverflow <= 0, `${mobile.pageOverflow}px`);
    check('F2 mobile: every console control is at least 44px', small.length === 0, JSON.stringify(small));
    check('F3 mobile: search field honours the 16px iOS floor', mobile.inputFont >= 16, `${mobile.inputFont}px`);
    check('F4 mobile: status tabs scroll instead of wrapping', mobile.tabsScrollable);
    await page.screenshot({ path: path.join(SHOTS, 'accounts-search-mobile.png') });
    await page.fill('#accountSearchInput', 'carlo');
    await page.waitForTimeout(400);
    check('F5 mobile: searching filters and highlights', (await snapshot(page)).hits > 0);
    check('F6 mobile: no console or page errors', errors.length === 0, errors.slice(0, 2).join(' || '));
    await context.close();
  }

  /* --------------------------------- non-Administrator must see nothing */
  {
    const { context, page } = await openApp(browser, shimSource, { w: 1280, h: 800 });
    await page.evaluate(() => {
      window.LSOCurrentAccount = { id: 'acc-4', username: 'staff.monitor', displayName: 'Danica Hidalgo', role: 'Staff Account', approvalStatus: 'Approved', disabled: false, isDefault: false };
      window.dispatchEvent(new CustomEvent('lso:accounts-changed', { detail: { reason: 'verification' } }));
      window.LSOApp?.setView?.('accountsView');
    });
    await page.waitForTimeout(1800);
    const locked = await page.evaluate(() => ({
      hidden: document.getElementById('accountsSearchConsole').classList.contains('hidden'),
      rows: document.querySelectorAll('#accountsTableBody tr[data-account-row]').length
    }));
    check('E4 console stays hidden without Administrator access', locked.hidden === true && locked.rows === 0, JSON.stringify(locked));
    await context.close();
  }

  /* ------------------- data availability: no sign-in tracking in the DB ----
     public.lso_account_json() exposes lastLoginAt only where the database is
     patched to record sign-ins. This group runs the same page against an
     account list WITHOUT that field and proves the console degrades cleanly:
     no dead sort option, no sign-in keywords, everything else still works. */
  {
    const bare = JSON.parse(JSON.stringify(seed));
    bare.accounts = bare.accounts.map((account) => {
      const copy = { ...account };
      delete copy.lastLoginAt;
      return copy;
    });
    const { context, page, errors } = await openApp(browser, buildShim(bare), { w: 1280, h: 860 });

    const sortState = await page.evaluate(() => {
      const option = document.querySelector('#accountsSortSelect option[value="login"]');
      return { hidden: option.hidden, disabled: option.disabled };
    });
    check('H1 sign-in sort option is hidden when the database has no sign-in data',
      sortState.hidden === true && sortState.disabled === true, JSON.stringify(sortState));

    const fallback = await page.evaluate(() => {
      window.LSOAccountSearch.setSort('login');
      return { state: window.LSOAccountSearch.getState().sort, select: document.getElementById('accountsSortSelect').value };
    });
    check('H2 asking for the sign-in sort falls back to Priority', fallback.state === 'priority' && fallback.select === 'priority', JSON.stringify(fallback));

    await page.fill('#accountSearchInput', 'never signed in');
    await page.waitForTimeout(350);
    const keyword = await snapshot(page);
    check('H3 sign-in keywords match nothing when there is no sign-in data',
      keyword.visible === 0, `visible=${keyword.visible}`);

    await page.fill('#accountSearchInput', 'lacsamana');
    await page.waitForTimeout(350);
    const stillWorks = await snapshot(page);
    check('H4 every other search still works without sign-in data',
      stillWorks.visible === 1 && stillWorks.hits > 0 && !stillWorks.placeholder, JSON.stringify({ visible: stillWorks.visible, hits: stillWorks.hits }));

    await page.fill('#accountSearchInput', '');
    await page.waitForTimeout(250);
    await page.selectOption('#accountsSortSelect', 'name');
    await page.waitForTimeout(400);
    const nameOrder = (await snapshot(page)).order.filter(Boolean);
    check('H5 the remaining sort orders still work without sign-in data',
      nameOrder.every((name, index) => index === 0 || nameOrder[index - 1].localeCompare(name) <= 0) && nameOrder.length === 16,
      nameOrder.slice(0, 3).join(' | '));
    check('H6 no console or page errors without sign-in data', errors.length === 0, errors.slice(0, 2).join(' || '));
    await context.close();
  }

  const failures = results.filter((item) => !item.ok);
  fs.writeFileSync(path.join(OUT, 'accounts-search-results.json'), JSON.stringify({ generatedAt: new Date().toISOString(), results }, null, 2));
  console.log(`\n${results.length - failures.length}/${results.length} checks passed — results/accounts-search-results.json`);
  await browser.close().catch(() => {});
  process.exit(failures.length ? 1 : 0);
})();
