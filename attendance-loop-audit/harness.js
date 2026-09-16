/* Headless (jsdom) reproduction harness for the LSO attendance roster.
   Loads the REAL index.html with the REAL scripts, logs in through the real
   login form against the Supabase RPC mock from responsive-audit/, seeds a
   month of attendance, then measures how often the attendance roster DOM is
   rebuilt (which is what wipes unsaved attendance input).

   Usage:  node harness.js [scenario]
     scenario = draft      -> record attendance on a Draft month (default)
                finalized  -> record, review and finalize the month first
*/
const fs = require('fs');
const path = require('path');
const { JSDOM, ResourceLoader, VirtualConsole } = require('jsdom');

const seed = require('../responsive-audit/seed.js');
const { buildShim } = require('../responsive-audit/mock-supabase.js');

const SCENARIO = process.argv[2] || process.env.LSO_SCENARIO || 'draft';
const MEASURE_MS = Number(process.env.LSO_MEASURE_MS || 12000);

const ROOT = path.resolve(__dirname, '..');
const shim = buildShim({ state: JSON.parse(JSON.stringify(seed.state)), accounts: seed.accounts })
  // The real RPCs return the FULL state row (cloud-staff assigns it to `state`
  // and re-applies it to browser storage) and they PERSIST the written column,
  // so the mock must do the same or the client sees a permanent local/remote
  // divergence and re-queues the save forever.
  .replace(
    "case 'lso_update_state': case 'lso_update_state_v69': case 'lso_replace_state': return { ok: true, state: state() };",
    "case 'lso_update_state': case 'lso_update_state_v69': { SEED.state[params.p_column] = params.p_value; SEED.state.updated_at = new Date().toISOString(); return state(); }\n      case 'lso_replace_state': { SEED.state = params.p_state; SEED.state.updated_at = new Date().toISOString(); return state(); }"
  )
  .replace(
    "case 'lso_get_state': return state();",
    "case 'lso_get_state': return state();"
  )
  .replace("window.__mockRpcLog = [];", "window.__mockRpcLog = []; window.__mockServer = SEED;");

const STUBS = `
try { Object.defineProperty(window, 'scrollTo', { value: function(){}, writable: true, configurable: true }); } catch(e) {}
try { Object.defineProperty(window, 'scrollBy', { value: function(){}, writable: true, configurable: true }); } catch(e) {}
try { Object.defineProperty(window, 'scroll', { value: function(){}, writable: true, configurable: true }); } catch(e) {}
if (typeof Element !== 'undefined') {
  Element.prototype.scrollIntoView = Element.prototype.scrollIntoView || function(){};
  Element.prototype.scrollTo = Element.prototype.scrollTo || function(){};
}
if (typeof window.matchMedia !== 'function') {
  window.matchMedia = function(query){
    return { matches: false, media: query, onchange: null, addListener(){}, removeListener(){}, addEventListener(){}, removeEventListener(){}, dispatchEvent(){ return false; } };
  };
}
window.ResizeObserver = window.ResizeObserver || class { observe(){} unobserve(){} disconnect(){} };
window.IntersectionObserver = window.IntersectionObserver || class { observe(){} unobserve(){} disconnect(){} takeRecords(){return [];} };
try { Object.defineProperty(window, 'confirm', { value: function(){ return true; }, writable: true, configurable: true }); } catch(e) {}
try { Object.defineProperty(window, 'alert', { value: function(){}, writable: true, configurable: true }); } catch(e) {}
try { Object.defineProperty(window, 'prompt', { value: function(){ return ''; }, writable: true, configurable: true }); } catch(e) {}
if (!window.crypto) window.crypto = {};
if (!window.crypto.randomUUID) window.crypto.randomUUID = function(){ return 'uuid-' + Math.random().toString(16).slice(2) + Date.now().toString(16); };
if (!window.crypto.getRandomValues) window.crypto.getRandomValues = function(a){ for (let i=0;i<a.length;i++) a[i] = Math.floor(Math.random()*256); return a; };
window.__LSO_AUDIT__ = { renderStacks: [] };
window.__lsoAudit = { rosterBuilds: [], storageWrites: [], events: [], rosterSnapshots: [], timers: {} };
(function(){
  var origSet = Storage.prototype.setItem;
  Storage.prototype.setItem = function(k, v){
    try { window.__lsoAudit.storageWrites.push({ t: Date.now(), k: k, len: String(v).length }); } catch(e){}
    return origSet.apply(this, arguments);
  };
  var origDispatch = window.dispatchEvent.bind(window);
  window.dispatchEvent = function(ev){
    try {
      if (ev && typeof ev.type === 'string' && ev.type.indexOf('lso:') === 0) {
        var stack = (new Error()).stack || '';
        var frames = stack.split(String.fromCharCode(10)).slice(2, 6).map(function(l){ return l.trim().replace('http://localhost/', ''); }).join(' <= ');
        window.__lsoAudit.events.push({ t: Date.now(), type: ev.type, source: (ev.detail && ev.detail.source) || '', key: (ev.detail && ev.detail.key) || '', stack: frames });
      }
    } catch(e){}
    return origDispatch(ev);
  };
  window.__lsoAudit.summaryBuilds = [];
  var install = function(){
    var body = document.getElementById('attendanceRosterBody');
    var summary = document.getElementById('attendanceSummary');
    if (summary) new MutationObserver(function(){
      var st = (new Error()).stack || '';
      var frames = st.split(String.fromCharCode(10)).slice(2, 7).map(function(l){ return l.trim().replace('http://localhost/', ''); }).join(' | ');
      window.__lsoAudit.summaryBuilds.push(frames);
    }).observe(summary, { childList: true });
    if (!body) return false;
    new MutationObserver(function(){
      window.__lsoAudit.rosterBuilds.push(Date.now());
      var inputs = [];
      body.querySelectorAll('[data-attendance-member]').forEach(function(row){
        var sel = row.querySelector('.attendance-status');
        var rem = row.querySelector('.attendance-remarks');
        inputs.push((sel ? sel.value : '?') + '/' + (rem ? rem.value : '?'));
      });
      window.__lsoAudit.rosterSnapshots.push(inputs.join('|'));
    }).observe(body, { childList: true });
    return true;
  };
  if (!install()) document.addEventListener('DOMContentLoaded', install);
})();
`;

class Loader extends ResourceLoader {
  fetch(url) {
    if (/cdn\.jsdelivr\.net/.test(url)) return Promise.resolve(Buffer.from(shim));
    if (url.startsWith('http://localhost/')) {
      const clean = decodeURIComponent(url.replace('http://localhost/', '').split('?')[0]);
      const p = path.join(ROOT, clean);
      if (p.startsWith(ROOT) && fs.existsSync(p) && fs.statSync(p).isFile() && /\.js$/i.test(p)) {
        return Promise.resolve(fs.readFileSync(p));
      }
      return Promise.resolve(Buffer.from(''));
    }
    return Promise.resolve(Buffer.from(''));
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function summarize(label, list) {
  if (!list.length) return `${label}: 0`;
  const gaps = list.slice(1).map((t, i) => t - list[i]);
  const min = Math.min(...gaps);
  const max = Math.max(...gaps);
  const avg = Math.round(gaps.reduce((a, b) => a + b, 0) / gaps.length);
  return `${label}: ${list.length} (gap min/avg/max = ${min}/${avg}/${max} ms)`;
}

(async () => {
  const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8')
    .replace('<head>', '<head>\n<script>' + STUBS + '</script>');

  const virtualConsole = new VirtualConsole();
  if (process.env.LSO_VERBOSE) virtualConsole.sendTo(console);
  const errors = [];
  virtualConsole.on('jsdomError', (e) => errors.push(String(e.message || e).split('\n')[0]));
  virtualConsole.on('error', (...args) => errors.push('console.error: ' + args.map(String).join(' ').slice(0, 200)));

  if (process.env.LSO_DUMP) { require('fs').writeFileSync('/tmp/dump.html', html); }
  const dom = new JSDOM(html, {
    url: 'http://localhost/index.html',
    runScripts: 'dangerously',
    resources: new Loader(),
    pretendToBeVisual: true,
    virtualConsole
  });
  const { window } = dom;
  const doc = window.document;

  window.addEventListener('error', (e) => console.log('PAGE ERROR:', String(e.message)));
  await new Promise((r) => window.addEventListener('load', r));
  await sleep(1200);
  console.log('audit object present:', typeof window.__lsoAudit, '| errors so far:', errors.slice(0, 5));

  const u = doc.getElementById('loginUsername');
  const p = doc.getElementById('loginPassword');
  if (u && p) { u.value = 'lso.admin'; p.value = 'Sup3rSecret!'; doc.querySelector('.auth-submit')?.click(); }
  await sleep(3000);
  if (doc.body?.dataset.authenticated !== 'true') { console.log('LOGIN FAILED'); process.exit(1); }

  doc.querySelector('.nav-item[data-view="attendanceView"]')?.click();
  await sleep(1500);

  const audit = window.__lsoAudit;
  const eventIds = [...doc.querySelectorAll('#eventList [data-event-id]')].map((n) => n.dataset.eventId);
  console.log('document.hidden:', doc.hidden, '| visibilityState:', doc.visibilityState, '| active view:', doc.querySelector('.view.active:not(.hidden)')?.id);
  console.log('scenario:', SCENARIO);
  console.log('month:', window.LSOAttendanceMonth, '| semester:', window.LSOAttendanceSemester, '| group:', window.LSOAttendanceGroup, '| mode:', window.LSOAttendanceRosterMode);
  console.log('activities in month:', eventIds.length, eventIds.join(','));

  // Mark every roster row Present and save, for every activity of the month.
  for (const id of eventIds) {
    doc.querySelector(`#eventList [data-event-id="${id}"]`)?.click();
    await sleep(120);
    const rows = doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]');
    rows.forEach((row) => { const sel = row.querySelector('.attendance-status'); if (sel && !sel.disabled) sel.value = 'Present'; });
    doc.getElementById('saveAttendanceButton')?.click();
    await sleep(250);
  }
  console.log('attendance records saved:', window.LSOOperations?.getAttendance?.().length);

  if (SCENARIO === 'loa' || SCENARIO === 'finalized-loa') {
    // File an approved LOA for the first roster member so the finalized-month
    // reconciliation (reconcileFinalizedLoaRecords) has work to do.
    doc.querySelector(`#eventList [data-event-id="${eventIds[0]}"]`)?.click();
    await sleep(300);
    const firstMemberId = doc.querySelector('#attendanceRosterBody [data-attendance-member]')?.dataset.attendanceMember;
    const monthKey = String(window.LSOAttendanceMonth || '').slice(0, 7);
    window.LSOStorage.setItem('lso_monthly_reports_v1', JSON.stringify({
      reports: { [monthKey]: { loaRows: [{ memberId: firstMemberId, name: '', startDate: `${monthKey}-01`, endDate: `${monthKey}-28` }] } }
    }));
    console.log('filed LOA for', firstMemberId, 'in', monthKey);
    await sleep(400);
  }

  if (SCENARIO === 'finalized' || SCENARIO === 'finalized-loa') {
    doc.getElementById('reviewAttendanceMonthButton')?.click();
    await sleep(600);
    const checklist = [...doc.querySelectorAll('#attendanceMonthReviewChecklist .attendance-review-item, #attendanceMonthReviewChecklist > *')]
      .map((n) => n.textContent.replace(/\s+/g, ' ').trim().slice(0, 90));
    console.log('review checklist:', JSON.stringify(checklist.slice(0, 8), null, 0));
    console.log('review summary:', doc.getElementById('attendanceMonthReviewSummary')?.textContent);
    doc.getElementById('finalizeAttendanceMonthButton')?.click();
    await sleep(1500);
    const gov = JSON.parse(window.localStorage.getItem('lso_system_settings_v2') || '{}').attendancePeriodGovernance || {};
    console.log('month finalizations:', JSON.stringify(Object.entries(gov.monthFinalizations || {}).map(([k, v]) => [k, v.state])));
    console.log('archives:', (gov.archives || []).length, '| month state:', JSON.stringify(window.LSOAttendanceGovernance?.getMonthState?.()?.state), '| active month:', window.LSOAttendanceMonth, '| mode:', window.LSOAttendanceRosterMode);
    console.log('toast:', [...doc.querySelectorAll('.toast, #toastContainer > *, .lso-toast')].map((n) => n.textContent.trim()).slice(-3));
    // return to the editable Current roster (the finalized view is view-only)
    window.LSOAttendanceWorkspace?.setTab?.('current', { preserveSelection: true });
    window.LSOOperations?.setAttendanceRosterMode?.('Current');
    await sleep(1000);
    console.log('after returning to Current -> mode:', window.LSOAttendanceRosterMode, '| month state:', window.LSOAttendanceGovernance?.getMonthState?.()?.state);
  }

  // pick an activity again and start "taking attendance" like the user does
  doc.querySelector(`#eventList [data-event-id="${eventIds[0]}"]`)?.click();
  await sleep(600);
  const rosterRows = doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]').length;
  console.log('roster rows on screen:', rosterRows);

  // Simulate the user: change a few rows, then wait and see if the DOM is rebuilt.
  const rows = [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')];
  rows.slice(0, 3).forEach((row, i) => {
    const sel = row.querySelector('.attendance-status');
    if (sel && !sel.disabled) { sel.value = i === 0 ? 'Late' : 'Absent'; sel.dispatchEvent(new window.Event('change', { bubbles: true })); }
    const rem = row.querySelector('.attendance-remarks');
    if (rem && !rem.readOnly) { rem.value = 'unsaved note ' + i; rem.dispatchEvent(new window.Event('input', { bubbles: true })); }
  });
  const before = [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')].map((row) => {
    const sel = row.querySelector('.attendance-status');
    const rem = row.querySelector('.attendance-remarks');
    return (sel ? sel.value : '?') + '/' + (rem ? rem.value : '?');
  });
  console.log('user input before wait:', JSON.stringify(before.slice(0, 5)));

  if (SCENARIO === 'noisy') {
    // Simulate another officer recording attendance on another device: the shared
    // database receives a new attendance record every 1000 ms.
    const server = window.__mockServer;
    const memberIds = [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')].map((r) => r.dataset.attendanceMember);
    let tick = 0;
    window.__noise = setInterval(() => {
      tick += 1;
      const list = Array.isArray(server.state.attendance) ? server.state.attendance : (server.state.attendance = []);
      if (tick % 2) {
        // change a row the officer has NOT touched -> the roster must show it
        const target = list.find((r) => String(r.eventId) === String(eventIds[0]) && String(r.memberId) === String(memberIds[3]));
        if (target) { target.status = tick % 4 === 1 ? 'Late' : 'Excused'; target.remarks = 'remote update ' + tick; target.updatedAt = new Date().toISOString(); }
      } else {
        // change a row the officer IS editing (memberIds[0]) -> the draft must win
        const target = list.find((r) => String(r.eventId) === String(eventIds[0]) && String(r.memberId) === String(memberIds[0]));
        if (target) { target.status = 'Excused'; target.remarks = 'remote overwrite ' + tick; target.updatedAt = new Date().toISOString(); }
      }
      server.state.updated_at = new Date().toISOString();
    }, 1000);
  }

  if (SCENARIO === 'smoke') {
    // Regression smoke test: walk every view, then return to attendance and
    // confirm an unsaved roster edit still survives a forced background refresh.
    const views = [...doc.querySelectorAll('.nav-item')].map((n) => n.dataset.view).filter(Boolean);
    console.log('views:', views.join(','));
    for (const view of views) {
      doc.querySelector(`.nav-item[data-view="${view}"]`)?.click();
      await sleep(700);
    }
    doc.querySelector('.nav-item[data-view="attendanceView"]')?.click();
    await sleep(900);
    doc.querySelector(`#eventList [data-event-id="${eventIds[0]}"]`)?.click();
    await sleep(500);
    [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')].slice(0, 2).forEach((row, i) => {
      const sel = row.querySelector('.attendance-status');
      if (sel && !sel.disabled) { sel.value = 'Late'; sel.dispatchEvent(new window.Event('change', { bubbles: true })); }
      const rem = row.querySelector('.attendance-remarks');
      if (rem && !rem.readOnly) { rem.value = 'smoke note ' + i; rem.dispatchEvent(new window.Event('input', { bubbles: true })); }
    });
    doc.getElementById('saveAttendanceButton')?.click();
    await sleep(1500);
    const stored = window.LSOOperations.getAttendance().filter((r) => String(r.eventId) === String(eventIds[0]));
    console.log('saved rows after full navigation:', JSON.stringify(stored.slice(0, 2).map((r) => r.status + '/' + r.remarks)));
    console.log('page errors during navigation:', errors.slice(0, 6));
    process.exit(0);
  }

  if (SCENARIO === 'save') {
    // Mark rows and press Save, then watch whether the saved values survive the
    // cloud round-trip and the following refresh.
    const rows2 = [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')];
    rows2.forEach((row, i) => {
      const sel = row.querySelector('.attendance-status');
      if (sel && !sel.disabled) sel.value = i % 2 ? 'Absent' : 'Late';
      const rem = row.querySelector('.attendance-remarks');
      if (rem && !rem.readOnly) rem.value = 'saved note ' + i;
    });
    doc.getElementById('saveAttendanceButton')?.click();
    await sleep(500);
    const stored1 = window.LSOOperations.getAttendance().filter((r) => String(r.eventId) === String(eventIds[0]));
    console.log('stored right after save:', JSON.stringify(stored1.slice(0, 3).map((r) => r.status + '/' + r.remarks)));
    await sleep(9000);
    const stored2 = window.LSOOperations.getAttendance().filter((r) => String(r.eventId) === String(eventIds[0]));
    console.log('stored 9s later:       ', JSON.stringify(stored2.slice(0, 3).map((r) => r.status + '/' + r.remarks)));
    console.log('roster on screen 9s later:', JSON.stringify([...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')].slice(0, 3).map((row) => {
      const sel = row.querySelector('.attendance-status'); const rem = row.querySelector('.attendance-remarks');
      return (sel ? sel.value : '?') + '/' + (rem ? rem.value : '?');
    })));
    process.exit(0);
  }

  audit.rosterBuilds.length = 0;
  audit.storageWrites.length = 0;
  audit.events.length = 0;
  if (audit.summaryBuilds) audit.summaryBuilds.length = 0;
  if (window.__LSO_AUDIT__?.renderStacks) window.__LSO_AUDIT__.renderStacks.length = 0;
  const attendanceBefore = window.LSOOperations?.getAttendance?.().length || 0;
  window.__lsoAudit.apiCalls = [];
  ['refreshAll', 'replaceAttendance', 'updateEventRecord', 'setSelectedEventId'].forEach((name) => {
    const ops = window.LSOOperations;
    const original = ops?.[name];
    if (typeof original !== 'function') return;
    ops[name] = function(...args) {
      const stack = (new Error()).stack || '';
      const frames = stack.split(String.fromCharCode(10)).slice(1, 5).map((l) => l.trim().replace('http://localhost/', '')).join(' <= ');
      window.__lsoAudit.apiCalls.push(name + ' :: ' + frames);
      return original.apply(this, args);
    };
  });

  await sleep(MEASURE_MS);

  const after = [...doc.querySelectorAll('#attendanceRosterBody [data-attendance-member]')].map((row) => {
    const sel = row.querySelector('.attendance-status');
    const rem = row.querySelector('.attendance-remarks');
    return (sel ? sel.value : '?') + '/' + (rem ? rem.value : '?');
  });
  console.log('user input after wait: ', JSON.stringify(after.slice(0, 5)));
  const indicator = doc.getElementById('attendanceDraftIndicator');
  console.log('unsaved indicator:', indicator && !indicator.hidden ? indicator.textContent.trim().slice(0, 120) : '(hidden)');
  console.log('rows flagged as draft:', doc.querySelectorAll('#attendanceRosterBody tr.attendance-row-draft').length);
  console.log('attendance records before/after wait:', attendanceBefore, '->', window.LSOOperations?.getAttendance?.().length);
  const stacks = {};
  (audit.summaryBuilds || []).forEach((st) => { stacks[st] = (stacks[st] || 0) + 1; });
  const apiCounts = {};
  (audit.apiCalls || []).forEach((k) => { apiCounts[k] = (apiCounts[k] || 0) + 1; });
  console.log('LSOOperations API calls during window:');
  Object.entries(apiCounts).sort((a, b) => b[1] - a[1]).slice(0, 8).forEach(([k, n]) => console.log('  ', n, '|', k.slice(0, 200)));
  console.log('renderAttendance call sites (count | stack):');
  Object.entries(stacks).sort((a, b) => b[1] - a[1]).slice(0, 6).forEach(([st, n]) => console.log('  ', n, '|', st.slice(0, 220)));

  console.log('--- measurement window:', MEASURE_MS, 'ms ---');
  console.log(summarize('roster DOM rebuilds', audit.rosterBuilds));
  const writes = {};
  audit.storageWrites.forEach((w) => { writes[w.k] = (writes[w.k] || 0) + 1; });
  console.log('localStorage writes:', JSON.stringify(writes));
  const events = {};
  audit.events.forEach((e) => { const k = e.type + (e.key ? ':' + e.key : '') + (e.source ? ' [' + e.source + ']' : ''); events[k] = (events[k] || 0) + 1; });
  console.log('lso events:', JSON.stringify(events, null, 1));
  if (process.env.LSO_STACKS) {
    const seen = {};
    audit.events.forEach((e) => { const k = (e.stack || '') + ' >> ' + e.type; seen[k] = (seen[k] || 0) + 1; });
    console.log('event emitters:');
    Object.entries(seen).sort((a, b) => b[1] - a[1]).slice(0, 10).forEach(([k, n]) => console.log('  ', n, '|', k.slice(0, 240)));
  }
  const rs = {};
  (window.__LSO_AUDIT__?.renderStacks || []).forEach((k) => { rs[k] = (rs[k] || 0) + 1; });
  console.log('renderAttendance() callers:');
  Object.entries(rs).sort((a, b) => b[1] - a[1]).slice(0, 8).forEach(([k, n]) => console.log('  ', n, '|', k.slice(0, 230)));
  console.log('errors:', errors.slice(0, 8));
  process.exit(0);
})();
