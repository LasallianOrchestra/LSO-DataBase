/* Real-browser responsive behaviour audit for the LSO Management System.
   Drives Chromium over CDP: logs in through the real UI against a mocked Supabase
   backend, walks every view at 17 device profiles, and measures layout + behaviour. */
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const seed = require('./seed');
const { buildShim } = require('./mock-supabase');

const OUT = process.env.LSO_AUDIT_OUT || require('path').join(__dirname, 'results');
const SHOTS = path.join(OUT, 'shots');
const BASE = process.env.LSO_URL || 'http://localhost:8080/index.html';
fs.mkdirSync(SHOTS, { recursive: true });

const DEVICES = [
  { id: 'galaxy-fold-cover', label: 'Galaxy Fold (cover screen)', w: 280, h: 653, dpr: 3, mobile: true, touch: true },
  { id: 'iphone-se-1st', label: 'iPhone SE 1st gen (smallest common iOS)', w: 320, h: 568, dpr: 2, mobile: true, touch: true },
  { id: 'android-360', label: 'Typical Android phone (360dp)', w: 360, h: 740, dpr: 3, mobile: true, touch: true },
  { id: 'iphone-14', label: 'iPhone 14 / 15 (390dp)', w: 390, h: 844, dpr: 3, mobile: true, touch: true },
  { id: 'pixel-7', label: 'Pixel 7 (412dp)', w: 412, h: 915, dpr: 2.625, mobile: true, touch: true },
  { id: 'iphone-pro-max', label: 'iPhone 15 Pro Max (430dp)', w: 430, h: 932, dpr: 3, mobile: true, touch: true },
  { id: 'phone-landscape', label: 'iPhone 14 landscape', w: 844, h: 390, dpr: 3, mobile: true, touch: true },
  { id: 'pixel-landscape', label: 'Pixel 7 landscape', w: 915, h: 412, dpr: 2.625, mobile: true, touch: true },
  { id: 'ipad-mini', label: 'iPad mini portrait (744dp)', w: 744, h: 1133, dpr: 2, mobile: true, touch: true },
  { id: 'ipad-9', label: 'iPad 9.7/10.2 portrait (768dp)', w: 768, h: 1024, dpr: 2, mobile: true, touch: true },
  { id: 'ipad-pro-11-land', label: 'iPad Pro 11" landscape (1194dp)', w: 1194, h: 834, dpr: 2, mobile: true, touch: true },
  { id: 'ipad-pro-129', label: 'iPad Pro 12.9" portrait (1024dp)', w: 1024, h: 1366, dpr: 2, mobile: true, touch: true },
  { id: 'surface-pro', label: 'Surface Pro / touch laptop (1368dp)', w: 1368, h: 912, dpr: 1.5, mobile: false, touch: true },
  { id: 'laptop-1280', label: 'Small laptop 1280x720', w: 1280, h: 720, dpr: 1, mobile: false, touch: false },
  { id: 'laptop-1366', label: 'Common laptop 1366x768', w: 1366, h: 768, dpr: 1, mobile: false, touch: false },
  { id: 'desktop-1920', label: 'Desktop 1920x1080', w: 1920, h: 1080, dpr: 1, mobile: false, touch: false },
  { id: 'ultrawide-2560', label: 'Ultra-wide 2560x1080', w: 2560, h: 1080, dpr: 1, mobile: false, touch: false }
];

const ONLY = process.env.ONLY_DEVICE ? process.env.ONLY_DEVICE.split(',') : null;
const DEVICE_LIST = ONLY ? DEVICES.filter(d => ONLY.includes(d.id)) : DEVICES;
const VIEWS = ['dashboardView', 'membersView', 'attendanceView', 'dutyHoursView', 'monthlyReportView', 'accountsView', 'contractView', 'interviewView', 'instrumentsView', 'dataView', 'systemHealthView'];

/* ---------------- in-page probe ---------------- */
function probe(options) {
  const opts = options || {};
  const docEl = document.documentElement;
  const iw = window.innerWidth;
  const cw = docEl.clientWidth;

  function describe(el) {
    if (!el || el.nodeType !== 1) return '(none)';
    const parts = [];
    let node = el;
    let depth = 0;
    while (node && node.nodeType === 1 && depth < 4) {
      let s = node.tagName.toLowerCase();
      if (node.id) { parts.unshift('#' + node.id); break; }
      const cls = (typeof node.className === 'string' ? node.className : '').trim().split(/\s+/)
        .filter(c => c && !['hidden', 'active', 'open', 'role-hidden'].includes(c)).slice(0, 2);
      if (cls.length) s += '.' + cls.join('.');
      parts.unshift(s);
      node = node.parentElement;
      depth++;
    }
    return parts.join(' > ');
  }
  function visible(el) { return el.getClientRects().length > 0; }
  function inactiveView(el) {
    const v = el.closest ? el.closest('.view') : null;
    return v && (!v.classList.contains('active') || v.hidden);
  }
  function ancestorOverflow(el) {
    let p = el.parentElement;
    while (p && p !== docEl) {
      const cs = getComputedStyle(p);
      if (cs.overflowX === 'auto' || cs.overflowX === 'scroll') return { node: p, mode: 'scroll' };
      if (cs.overflowX === 'hidden' || cs.overflowX === 'clip') return { node: p, mode: 'clip' };
      p = p.parentElement;
    }
    const bodyOx = getComputedStyle(document.body).overflowX;
    const htmlOx = getComputedStyle(docEl).overflowX;
    if (['hidden', 'clip'].includes(bodyOx) || ['hidden', 'clip'].includes(htmlOx)) return { node: document.body, mode: 'clip' };
    return { node: null, mode: 'page' };
  }

  const out = {
    innerWidth: iw, clientWidth: cw, innerHeight: window.innerHeight,
    docScrollWidth: docEl.scrollWidth, bodyScrollWidth: document.body.scrollWidth,
    pageOverflowX: Math.max(docEl.scrollWidth, document.body.scrollWidth) - cw,
    bodyOverflowX: getComputedStyle(document.body).overflowX,
    htmlOverflowX: getComputedStyle(docEl).overflowX,
    bodyOverflowY: getComputedStyle(document.body).overflowY,
    scrollPaddingTop: getComputedStyle(docEl).scrollPaddingTop,
    scrollY: Math.round(window.scrollY),
    overflowers: [], clippedContent: [], scrollableContainers: [],
    tapTargetsSmall: [], tapTargetsFail: [], tapTargetCount: 0,
    smallText: [], minFontSize: null, smallInputs: [], inputCount: 0,
    truncated: [], blockedHits: [], stickyOverlaps: [], headingCovered: null,
    domNodes: document.querySelectorAll('*').length,
    visibleScanned: 0
  };

  /* 1. overflow + clipping scan */
  const offenders = [];
  const clipped = [];
  const all = document.querySelectorAll('body *');
  for (const el of all) {
    if (el.hidden) continue;
    if (inactiveView(el)) continue;
    if (!visible(el)) continue;
    out.visibleScanned++;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    /* containers that clip their own content */
    const cs = getComputedStyle(el);
    if ((cs.overflowX === 'hidden' || cs.overflowX === 'clip') && el.scrollWidth > el.clientWidth + 2 && el.clientWidth > 0) {
      clipped.push({ sel: describe(el), clientWidth: Math.round(el.clientWidth), scrollWidth: Math.round(el.scrollWidth), lost: Math.round(el.scrollWidth - el.clientWidth), ellipsis: cs.textOverflow === 'ellipsis', nowrap: cs.whiteSpace === 'nowrap', text: (el.textContent || '').trim().slice(0, 40), cls: 'clippedContent' });
    }
    if ((cs.overflowX === 'auto' || cs.overflowX === 'scroll') && el.scrollWidth > el.clientWidth + 2) {
      out.scrollableContainers.push({ sel: describe(el), clientWidth: Math.round(el.clientWidth), scrollWidth: Math.round(el.scrollWidth) });
    }
    if (r.right > cw + 1 || r.left < -1) {
      if (r.right <= 0 || r.left >= cw) { out.parkedOffcanvas = (out.parkedOffcanvas || []); if (out.parkedOffcanvas.length < 8) out.parkedOffcanvas.push({ sel: describe(el), left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width) }); continue; }
      const a = ancestorOverflow(el);
      const rec = { sel: describe(el), w: Math.round(r.width), right: Math.round(r.right), left: Math.round(r.left), over: Math.round(Math.max(r.right - cw, -r.left)), mode: a.mode, container: a.node ? describe(a.node) : null, el };
      if (a.mode === 'scroll') out.scrollableContainers.push({ sel: rec.sel, insideScrollContainer: rec.container, clientWidth: rec.w });
      else offenders.push(rec);
    }
  }
  /* keep outermost offenders only */
  const kept = offenders.filter(o => !offenders.some(p => p !== o && o.el && p.el && p.el.contains(o.el)));
  out.overflowers = kept.sort((a, b) => b.over - a.over).slice(0, 14).map(({ el, ...rest }) => rest);
  out.clippedContent = clipped.sort((a, b) => b.lost - a.lost).slice(0, 14);

  /* 2. tap targets */
  const interactive = document.querySelectorAll('a[href],button,input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]),select,textarea,summary,[role="button"],[tabindex]:not([tabindex="-1"])');
  const seen = new Set();
  for (const el of interactive) {
    if (el.disabled || el.hidden) continue;
    if (inactiveView(el)) continue;
    if (!visible(el)) continue;
    const cs = getComputedStyle(el);
    if (cs.pointerEvents === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.15) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    out.tapTargetCount++;
    const key = describe(el) + Math.round(r.width) + 'x' + Math.round(r.height);
    if (seen.has(key)) continue;
    seen.add(key);
    const rec = { sel: describe(el), w: Math.round(r.width), h: Math.round(r.height), label: (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 40) };
    if (r.height < 24 || r.width < 24) out.tapTargetsFail.push(rec);
    else if (r.height < 44 || r.width < 44) out.tapTargetsSmall.push(rec);
  }

  /* 3. text sizes + iOS input zoom + truncation */
  const textSeen = new Set();
  const inputSeen = new Set();
  for (const el of all) {
    if (el.hidden || inactiveView(el) || !visible(el)) continue;
    const cs = getComputedStyle(el);
    const hasText = Array.from(el.childNodes).some(n => n.nodeType === 3 && n.textContent.trim().length > 1);
    if (hasText) {
      const fs = parseFloat(cs.fontSize);
      if (out.minFontSize === null || fs < out.minFontSize) out.minFontSize = fs;
      if (fs < 12 && out.smallText.length < 60) {
        const k = describe(el) + '|' + fs;
        if (!textSeen.has(k)) { textSeen.add(k); out.smallText.push({ sel: describe(el), size: fs, text: el.textContent.trim().slice(0, 45) }); }
      }
      if (cs.textOverflow === 'ellipsis' && el.scrollWidth > el.clientWidth + 2 && out.truncated.length < 40) {
        out.truncated.push({ sel: describe(el), clientWidth: Math.round(el.clientWidth), scrollWidth: Math.round(el.scrollWidth), text: el.textContent.trim().slice(0, 40) });
      }
    }
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName) && !el.disabled) {
      out.inputCount++;
      const fs = parseFloat(cs.fontSize);
      if (fs < 16 && out.smallInputs.length < 40) {
        const k = describe(el) + '|' + fs;
        if (!inputSeen.has(k)) {
          inputSeen.add(k);
          out.smallInputs.push({ sel: describe(el), size: fs, type: el.type || el.tagName.toLowerCase(), inputmode: el.getAttribute('inputmode') || '' });
        }
      }
    }
  }

  /* 4. hit testing: is the control actually clickable? */
  const targets = Array.from(document.querySelectorAll('#appShell button, #appShell a[href], #appShell input[type=submit], #appShell [role=button]'))
    .filter(el => {
      if (!visible(el) || el.disabled || inactiveView(el)) return false;
      const cs = getComputedStyle(el);
      if (cs.pointerEvents === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.15) return false;
      const r = el.getBoundingClientRect();
      // off-canvas parked elements (e.g. closed drawer) are not expected to be clickable
      if (r.right <= 0 || r.left >= cw) return false;
      return true;
    }).slice(0, 40);
  for (const el of targets) {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    const cx = Math.round(r.left + r.width / 2);
    const cy = Math.round(r.top + r.height / 2);
    if (cx < 0 || cy < 0 || cx >= cw || cy >= window.innerHeight) continue;
    const hit = document.elementFromPoint(cx, cy);
    if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) {
      out.blockedHits.push({ sel: describe(el), blockedBy: describe(hit), label: (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 40) });
    }
  }

  /* 5. fixed / sticky layering */
  const layers = [];
  for (const el of all) {
    if (el.hidden || !visible(el)) continue;
    const cs = getComputedStyle(el);
    if (cs.position !== 'fixed' && cs.position !== 'sticky') continue;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    layers.push({ el, sel: describe(el), pos: cs.position, z: parseInt(cs.zIndex || '0', 10) || 0, r });
  }
  for (let i = 0; i < layers.length; i++) {
    for (let j = i + 1; j < layers.length; j++) {
      const a = layers[i], b = layers[j];
      const ox = Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left);
      const oy = Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top);
      if (ox > 4 && oy > 4) {
        const inter = ox * oy;
        const smaller = Math.min(a.r.width * a.r.height, b.r.width * b.r.height);
        if (smaller > 0 && inter / smaller > 0.3 && out.stickyOverlaps.length < 12) {
          out.stickyOverlaps.push({ a: a.sel, b: b.sel, overlapPct: Math.round((inter / smaller) * 100), za: a.z, zb: b.z });
        }
      }
    }
  }
  const activeView = document.querySelector('.view.active:not(.hidden)');
  if (activeView) {
    const heading = activeView.querySelector('h1,h2,h3');
    if (heading) {
      const hr = heading.getBoundingClientRect();
      for (const L of layers) {
        if (L.r.bottom > hr.top + 1 && L.r.top < hr.bottom - 1 && L.r.width > cw * 0.5) {
          out.headingCovered = { heading: heading.textContent.trim().slice(0, 50), coveredBy: L.sel, headingTop: Math.round(hr.top), layerBottom: Math.round(L.r.bottom) };
          break;
        }
      }
    }
  }
  out.layers = layers.slice(0, 20).map(L => ({ sel: L.sel, pos: L.pos, z: L.z, top: Math.round(L.r.top), height: Math.round(L.r.height), width: Math.round(L.r.width) }));
  return out;
}

/* ---------------- helpers ---------------- */
async function safeClick(page, selector, timeout = 4000) {
  try {
    await page.click(selector, { timeout });
    return true;
  } catch (e) { return false; }
}

async function setView(page, viewId) {
  return page.evaluate((vid) => {
    try {
      if (window.LSOApp && typeof window.LSOApp.setView === 'function') { window.LSOApp.setView(vid); return 'api'; }
      const item = document.querySelector('.nav-item[data-view="' + vid + '"]');
      if (item) { item.click(); return 'click'; }
      return 'none';
    } catch (e) { return 'error:' + e.message; }
  }, viewId);
}

/* V76 (audit fix F10): the harness must ask the PAGE which shell it rendered,
   through the same shared contract the app uses (lso-shell-layout-v75.js).
   Gating on a local `matchMedia('(max-width: 920px)')` is what let F10 through:
   the drawer test was silently skipped on the three coarse-pointer profiles
   wider than 920px (iPad Pro 11" landscape, iPad Pro 12.9", Surface Pro), which
   is exactly where the toggle was missing. Falls back to the contract query if
   the page has not loaded LSOShellLayout. */
async function shellIsMobile(page) {
  return page.evaluate(() => window.LSOShellLayout
    ? window.LSOShellLayout.isMobileShell()
    : window.matchMedia('(max-width: 920px), (pointer: coarse)').matches);
}

async function openDrawerIfNeeded(page, device) {
  const isMobileShell = await shellIsMobile(page);
  if (!isMobileShell) return false;
  const opened = await page.evaluate(() => {
    const btn = document.querySelector('.mobile-menu') || document.querySelector('#mobileMenuButton') || document.querySelector('[data-action="toggle-sidebar"]');
    if (!btn) return 'no-button';
    btn.click();
    return 'clicked';
  });
  await page.waitForTimeout(450);
  return opened;
}

async function measureView(page, device, viewId, extra) {
  return page.evaluate(({ opts }) => {
    // probe is injected globally by the harness
    return window.__probe(opts);
  }, { opts: Object.assign({ touch: device.touch }, extra || {}) });
}

(async () => {
  const shimSource = buildShim(seed);
  const browser = await chromium.connectOverCDP((process.env.LSO_CDP || 'http://127.0.0.1:9222'));
  const results = { generatedAt: new Date().toISOString(), devices: [], summary: {} };
  const probeSource = '(' + probe.toString() + ')';

  for (const device of DEVICE_LIST) {
    const context = await browser.newContext({
      viewport: { width: device.w, height: device.h },
      deviceScaleFactor: device.dpr,
      isMobile: device.mobile,
      hasTouch: device.touch,
      serviceWorkers: 'block',
      locale: 'en-US',
      timezoneId: 'Asia/Manila',
      userAgent: device.mobile
        ? `Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Mobile Safari/537.36`
        : `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36`
    });
    const page = await context.newPage();
    const consoleErrors = [];
    const pageErrors = [];
    page.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text().slice(0, 220)); });
    page.on('pageerror', (err) => pageErrors.push(String(err.message || err).slice(0, 220)));

    await page.route('**://cdn.jsdelivr.net/**', route => route.fulfill({ status: 200, contentType: 'application/javascript', body: shimSource }));
    await page.route('**://*.supabase.co/**', route => route.abort());
    await page.addInitScript(`window.__probe = ${probeSource};`);

    const record = { device, login: null, views: {}, behaviour: {}, consoleErrors: [], pageErrors: [], notes: [] };
    const t0 = Date.now();
    try {
      await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 45000 });
      await page.waitForTimeout(1800);

      /* --- login screen audit (what every user sees first) --- */
      record.login = await page.evaluate(() => window.__probe({ touch: true }));
      const loginVisible = await page.evaluate(() => {
        const a = document.getElementById('authScreen');
        return !!a && a.getClientRects().length > 0;
      });
      record.notes.push(loginVisible ? 'login screen visible' : 'LOGIN SCREEN NOT VISIBLE');
      if (['galaxy-fold-cover', 'iphone-se-1st', 'iphone-14', 'ipad-9', 'desktop-1920', 'phone-landscape'].includes(device.id)) {
        await page.screenshot({ path: path.join(SHOTS, `${device.id}-01-login.png`) });
      }

      /* --- real login through the UI --- */
      await page.fill('#loginUsername', 'lso.admin').catch(() => {});
      await page.fill('#loginPassword', 'Sup3rSecret!').catch(() => {});
      await safeClick(page, '.auth-submit');
      let unlocked = false;
      try {
        await page.waitForFunction(() => document.body.dataset.authenticated === 'true' && document.getElementById('appShell') && document.getElementById('appShell').getClientRects().length > 0, null, { timeout: 20000 });
        unlocked = true;
      } catch (e) { /* handled below */ }
      if (!unlocked) {
        const msg = await page.evaluate(() => (document.getElementById('loginMessage') || {}).textContent || '');
        record.notes.push('LOGIN DID NOT UNLOCK SHELL: ' + msg.slice(0, 120));
        // forced unlock so the rest of the layout can still be audited
        await page.evaluate(() => {
          window.LSOCurrentAccount = { id: 'acc-1', username: 'lso.admin', displayName: 'Amadeus Testado', role: 'Administrator', memberId: 'mem-1000', approvalStatus: 'Approved', disabled: false, isDefault: true };
          document.body.dataset.authenticated = 'true';
          const auth = document.getElementById('authScreen');
          if (auth) { auth.classList.add('hidden'); auth.hidden = true; auth.style.setProperty('display', 'none', 'important'); }
          const shell = document.getElementById('appShell');
          if (shell) {
            shell.classList.remove('hidden', 'auth-locked');
            shell.hidden = false;
            // V76 F10: mirror the shared shell contract (LSOShellLayout) rather
            // than a width-only query, so a forced unlock on a wide touch screen
            // still gets the block/drawer shell.
            const mobile = window.LSOShellLayout
              ? window.LSOShellLayout.isMobileShell()
              : window.matchMedia('(max-width: 920px), (pointer: coarse)').matches;
            shell.style.setProperty('display', mobile ? 'block' : 'grid', 'important');
            shell.style.setProperty('min-height', '100dvh', 'important');
            shell.style.setProperty('overflow', 'visible', 'important');
          }
          document.documentElement.classList.remove('lso-auth-locked');
        });
        await page.waitForTimeout(1200);
        record.forcedUnlock = true;
      } else {
        record.forcedUnlock = false;
      }
      await page.waitForTimeout(1500);

      /* --- per-view layout audit --- */
      for (const viewId of VIEWS) {
        const openedDrawer = await openDrawerIfNeeded(page, device);
        const navClicked = await page.evaluate((vid) => {
          const item = document.querySelector('.nav-item[data-view="' + vid + '"]');
          if (!item) return 'no-nav-item';
          if (item.classList.contains('role-hidden')) return 'role-hidden';
          item.click();
          return 'clicked';
        }, viewId);
        await page.waitForTimeout(700);
        if (navClicked === 'no-nav-item' || navClicked === 'role-hidden') {
          await setView(page, viewId);
          await page.waitForTimeout(700);
        }
        // close drawer after navigation, like a user would
        await page.evaluate(() => {
          document.body.classList.remove('sidebar-open');
          const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
          if (sb) sb.classList.remove('open');
        });
        await page.waitForTimeout(250);
        const m = await measureView(page, device, viewId);
        m.nav = navClicked;
        m.activeView = await page.evaluate(() => (document.querySelector('.view.active:not(.hidden)') || {}).id || '');
        record.views[viewId] = m;
        if ((device.id === 'iphone-14' || device.id === 'desktop-1920' || device.id === 'ipad-9') &&
          ['dashboardView', 'membersView', 'attendanceView', 'dutyHoursView', 'monthlyReportView', 'accountsView'].includes(viewId)) {
          await page.screenshot({ path: path.join(SHOTS, `${device.id}-${viewId}.png`) });
        }
      }

      /* --- behaviour: mobile navigation drawer --- */
      // V76 F10: gated on the page's shared shell contract, not a local width
      // query, so wide coarse-pointer profiles are exercised too.
      const isMobileShell = await shellIsMobile(page);
      if (isMobileShell) {
        await setView(page, 'dashboardView');
        await page.waitForTimeout(400);
        await page.evaluate(() => window.scrollTo(0, 400));
        await page.waitForTimeout(200);
        const scrollBefore = await page.evaluate(() => Math.round(window.scrollY));
        const btnInfo = await page.evaluate(() => {
          const btn = document.querySelector('.mobile-menu');
          if (!btn) return null;
          const r = btn.getBoundingClientRect();
          const cs = getComputedStyle(btn);
          return { found: true, w: Math.round(r.width), h: Math.round(r.height), display: cs.display, top: Math.round(r.top), left: Math.round(r.left), ariaExpanded: btn.getAttribute('aria-expanded'), ariaControls: btn.getAttribute('aria-controls'), label: btn.getAttribute('aria-label') || btn.textContent.trim() };
        });
        const clicked = await page.evaluate(() => { const b = document.querySelector('.mobile-menu'); if (b) { b.click(); return true; } return false; });
        await page.waitForTimeout(600);
        const openState = await page.evaluate(() => {
          const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
          const r = sb ? sb.getBoundingClientRect() : null;
          const backdrops = Array.from(document.querySelectorAll('body *')).filter(el => {
            const cs = getComputedStyle(el);
            if (cs.position !== 'fixed' && cs.position !== 'absolute') return false;
            if (el.getClientRects().length === 0) return false;
            const rr = el.getBoundingClientRect();
            return rr.width >= window.innerWidth * 0.9 && rr.height >= window.innerHeight * 0.9 && parseFloat(cs.opacity) > 0.05 && cs.pointerEvents !== 'none';
          }).map(el => ({ cls: el.className && String(el.className).slice(0, 60), z: getComputedStyle(el).zIndex }));
          return {
            sidebarOpenClass: sb ? sb.classList.contains('open') : null,
            bodyClass: document.body.className.slice(0, 80),
            sidebarRect: r ? { left: Math.round(r.left), right: Math.round(r.right), width: Math.round(r.width), height: Math.round(r.height) } : null,
            sidebarTransform: sb ? getComputedStyle(sb).transform : null,
            bodyOverflow: getComputedStyle(document.body).overflow,
            htmlOverflow: getComputedStyle(document.documentElement).overflow,
            scrollY: Math.round(window.scrollY),
            backdrops,
            ariaExpanded: (document.querySelector('.mobile-menu') || {}).getAttribute ? document.querySelector('.mobile-menu').getAttribute('aria-expanded') : null,
            navItemCount: document.querySelectorAll('.sidebar .nav-item:not(.role-hidden)').length,
            closeBtn: !!document.querySelector('.sidebar-close'),
            firstNavItemFocus: document.activeElement ? (document.activeElement.className || document.activeElement.tagName) : null
          };
        });
        const navTargets = await page.evaluate(() => Array.from(document.querySelectorAll('.sidebar .nav-item:not(.role-hidden)')).map(el => {
          const r = el.getBoundingClientRect();
          return { label: el.textContent.trim().slice(0, 28), w: Math.round(r.width), h: Math.round(r.height), visible: el.getClientRects().length > 0 };
        }));
        // close via close button
        const closeOk = await page.evaluate(() => { const b = document.querySelector('.sidebar-close'); if (b) { b.click(); return true; } return false; });
        await page.waitForTimeout(600);
        const closedState = await page.evaluate(() => {
          const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
          const r = sb ? sb.getBoundingClientRect() : null;
          return {
            sidebarOpenClass: sb ? sb.classList.contains('open') : null,
            bodyClass: document.body.className.slice(0, 80),
            sidebarLeft: r ? Math.round(r.left) : null,
            sidebarRight: r ? Math.round(r.right) : null,
            bodyOverflow: getComputedStyle(document.body).overflow,
            htmlOverflow: getComputedStyle(document.documentElement).overflow,
            scrollY: Math.round(window.scrollY),
            pageScrollable: document.documentElement.scrollHeight > window.innerHeight
          };
        });
        // does the page still scroll after the drawer closes? (classic scroll-lock leak)
        const scrollTest = await page.evaluate(() => {
          const before = Math.round(window.scrollY);
          window.scrollTo(0, before + 200);
          const after = Math.round(window.scrollY);
          window.scrollTo(0, before);
          return { before, after, moved: after !== before };
        });
        record.behaviour.drawer = { mobileMenuButton: btnInfo, clicked, scrollBefore, openState, navTargets, closeOk, closedState, scrollTest };
        await page.screenshot({ path: path.join(SHOTS, `${device.id}-drawer-open.png`) }).catch(() => {});
        // re-open for the screenshot, then close with Escape and with backdrop tap
        await page.evaluate(() => { const b = document.querySelector('.mobile-menu'); if (b) b.click(); });
        await page.waitForTimeout(500);
        await page.screenshot({ path: path.join(SHOTS, `${device.id}-drawer-open-2.png`) }).catch(() => {});
        const escClosed = await page.evaluate(() => {
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
          window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
          return new Promise(res => setTimeout(() => {
            const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
            res({ openAfterEscape: sb ? sb.classList.contains('open') : null, bodyClass: document.body.className.slice(0, 60) });
          }, 400));
        });
        const backdropClosed = await page.evaluate(() => {
          const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
          const stillOpen = sb && sb.classList.contains('open');
          if (!stillOpen) return { skipped: true };
          const bd = Array.from(document.querySelectorAll('body *')).find(el => {
            const cs = getComputedStyle(el);
            if (el.getClientRects().length === 0) return false;
            const rr = el.getBoundingClientRect();
            return (cs.position === 'fixed' || cs.position === 'absolute') && rr.width >= window.innerWidth * 0.9 && rr.height >= window.innerHeight * 0.9 && parseFloat(cs.opacity) > 0.05 && cs.pointerEvents !== 'none' && !el.contains(sb);
          });
          if (!bd) return { backdropFound: false };
          bd.click();
          return new Promise(res => setTimeout(() => res({ backdropFound: true, openAfterBackdropClick: sb.classList.contains('open') }), 450));
        });
        await page.evaluate(() => { document.body.classList.remove('sidebar-open'); const sb = document.getElementById('sidebar') || document.querySelector('.sidebar'); if (sb) sb.classList.remove('open'); document.body.style.overflow = ''; });
        record.behaviour.drawerEscape = escClosed;
        record.behaviour.drawerBackdrop = backdropClosed;
      }

      /* --- behaviour: modal on this viewport --- */
      await setView(page, 'membersView');
      await page.waitForTimeout(800);
      const modal = await page.evaluate(() => {
        try {
          const members = window.LSOApp && window.LSOApp.getMembers ? window.LSOApp.getMembers() : [];
          if (members && members.length && window.LSOApp.openMember) { window.LSOApp.openMember(members[0].id); return { opened: 'api', count: members.length }; }
          return { opened: 'no-members', count: members ? members.length : 0 };
        } catch (e) { return { opened: 'error:' + e.message }; }
      });
      await page.waitForTimeout(900);
      const modalState = await page.evaluate(() => {
        const cards = Array.from(document.querySelectorAll('.modal-card,.compact-modal,.dcc-modal-card,[role=dialog]')).filter(el => el.getClientRects().length > 0);
        if (!cards.length) return { present: false };
        const card = cards[0];
        const r = card.getBoundingClientRect();
        const cs = getComputedStyle(card);
        const footer = card.querySelector('footer,.modal-actions,.form-actions');
        const closeBtn = card.querySelector('button[aria-label*=lose i],.modal-close,button.close');
        const fr = footer ? footer.getBoundingClientRect() : null;
        const cr = closeBtn ? closeBtn.getBoundingClientRect() : null;
        let closeHit = null;
        if (cr && cr.width > 2) {
          const hit = document.elementFromPoint(Math.round(cr.left + cr.width / 2), Math.round(cr.top + cr.height / 2));
          closeHit = hit === closeBtn || (closeBtn && closeBtn.contains(hit)) || (hit && hit.contains(closeBtn));
        }
        return {
          present: true, count: cards.length,
          rect: { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width), h: Math.round(r.height) },
          viewport: { w: window.innerWidth, h: window.innerHeight },
          tallerThanViewport: r.height > window.innerHeight + 1,
          widerThanViewport: r.width > window.innerWidth + 1,
          belowFold: r.bottom > window.innerHeight + 1,
          offTop: r.top < -1,
          overflowY: cs.overflowY, maxHeight: cs.maxHeight,
          contentScrollable: card.scrollHeight > card.clientHeight + 2,
          footerVisibleWithoutScroll: fr ? (fr.bottom <= window.innerHeight + 1 && fr.top >= 0) : null,
          footerRect: fr ? { top: Math.round(fr.top), bottom: Math.round(fr.bottom) } : null,
          closeBtnRect: cr ? { w: Math.round(cr.width), h: Math.round(cr.height), top: Math.round(cr.top) } : null,
          closeBtnClickable: closeHit,
          bodyOverflow: getComputedStyle(document.body).overflow,
          safeAreaBottom: cs.paddingBottom
        };
      });
      await page.screenshot({ path: path.join(SHOTS, `${device.id}-member-modal.png`) }).catch(() => {});
      const modalClosed = await page.evaluate(() => {
        const card = Array.from(document.querySelectorAll('.modal-card,.compact-modal,[role=dialog]')).find(el => el.getClientRects().length > 0);
        if (!card) return { nothing: true };
        const btn = card.querySelector('button[aria-label*=lose i],.modal-close,button.close') || Array.from(card.querySelectorAll('button')).find(b => /close|cancel/i.test(b.textContent || ''));
        if (btn) btn.click();
        return new Promise(res => setTimeout(() => {
          const still = Array.from(document.querySelectorAll('.modal-card,.compact-modal,[role=dialog]')).filter(el => el.getClientRects().length > 0);
          res({ stillOpen: still.length, bodyOverflow: getComputedStyle(document.body).overflow });
        }, 500));
      });
      record.behaviour.modal = { open: modal, state: modalState, closed: modalClosed };

      /* --- behaviour: orientation flip --- */
      if (device.touch) {
        await page.evaluate(() => { const b = document.querySelector('.mobile-menu'); if (b && (document.getElementById('sidebar') || {}).classList && document.getElementById('sidebar').classList.contains('open')) b.click(); });
        const before = await page.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight, bodyOverflow: getComputedStyle(document.body).overflow, sidebarOpen: (document.getElementById('sidebar') || { classList: { contains: () => false } }).classList.contains('open'), scrollY: Math.round(window.scrollY) }));
        await page.setViewportSize({ width: device.h, height: device.w });
        await page.waitForTimeout(900);
        const after = await page.evaluate(() => {
          const sb = document.getElementById('sidebar') || document.querySelector('.sidebar');
          const r = sb ? sb.getBoundingClientRect() : null;
          return {
            w: window.innerWidth, h: window.innerHeight,
            bodyOverflow: getComputedStyle(document.body).overflow,
            htmlOverflow: getComputedStyle(document.documentElement).overflow,
            sidebarOpen: sb ? sb.classList.contains('open') : null,
            sidebarVisibleOnScreen: r ? (r.left < window.innerWidth - 2 && r.right > 2) : null,
            sidebarRect: r ? { left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width) } : null,
            bodyClass: document.body.className.slice(0, 60),
            docOverflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            appShellDisplay: getComputedStyle(document.getElementById('appShell')).display,
            appShellInlineDisplay: (document.getElementById('appShell') || {}).style ? document.getElementById('appShell').style.display : null,
            probe: window.__probe({ touch: true })
          };
        });
        await page.setViewportSize({ width: device.w, height: device.h });
        await page.waitForTimeout(700);
        const back = await page.evaluate(() => ({
          w: window.innerWidth, bodyOverflow: getComputedStyle(document.body).overflow,
          appShellDisplay: getComputedStyle(document.getElementById('appShell')).display,
          appShellInlineDisplay: (document.getElementById('appShell') || {}).style ? document.getElementById('appShell').style.display : null,
          docOverflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          sidebarOpen: (document.getElementById('sidebar') || { classList: { contains: () => false } }).classList.contains('open')
        }));
        record.behaviour.orientation = { before, after, back };
      }

      /* --- behaviour: input focus (mobile keyboard) + scroll-into-view --- */
      await setView(page, 'membersView');
      await page.waitForTimeout(500);
      const focusTest = await page.evaluate(() => {
        const input = Array.from(document.querySelectorAll('.view.active input,.view.active select,.view.active textarea')).find(el => el.getClientRects().length > 0 && !el.disabled);
        if (!input) return { noInput: true };
        const before = Math.round(window.scrollY);
        input.focus();
        return new Promise(res => setTimeout(() => {
          const r = input.getBoundingClientRect();
          res({
            tag: input.tagName, type: input.type, size: parseFloat(getComputedStyle(input).fontSize),
            inViewportAfterFocus: r.top >= 0 && r.bottom <= window.innerHeight,
            rectTop: Math.round(r.top), rectBottom: Math.round(r.bottom),
            scrollDelta: Math.round(window.scrollY) - before,
            viewportScale: window.visualViewport ? +window.visualViewport.scale.toFixed(3) : null
          });
        }, 500));
      });
      record.behaviour.inputFocus = focusTest;

      record.consoleErrors = [...new Set(consoleErrors)].slice(0, 12);
      record.pageErrors = [...new Set(pageErrors)].slice(0, 12);
      record.elapsedMs = Date.now() - t0;
    } catch (err) {
      record.fatal = String(err && err.message || err).slice(0, 300);
    }
    results.devices.push(record);
    console.log(`[${device.id}] ${device.w}x${device.h} done in ${record.elapsedMs || 0}ms ${record.fatal ? 'FATAL ' + record.fatal : ''}`);
    fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 1));
    await context.close();
  }

  fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 1));
  console.log('WROTE', path.join(OUT, 'results.json'));
  await browser.close();
})().catch(e => { console.error('HARNESS FAILURE', e); process.exit(1); });
