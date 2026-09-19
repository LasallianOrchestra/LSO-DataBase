/* ============================================================================
   LSO V84/V85 — "MY ATTENDANCE" verification harness (headless, real page).

   Loads the REAL index.html with the REAL scripts (no mocks of application
   code) against the Supabase RPC shim from responsive-audit/, signs in through
   the real login form as:
     * trainee.one  (Trainee/Probationary, linked to its own member record)
     * lso.admin    (Administrator)
   then verifies that the section:
     1. appears for the Trainee only, next to Duty Hours;
     2. shows ONLY the signed-in member's own attendance rows;
     3. contains no editing control of any kind (inputs/selects/contenteditable);
     4. is refused for an account whose permission was revoked;
     5. is refused and hidden for every other role;
     6. is listed as a permission module in the Role & Permission Center, and is
        locked for every role except Trainee/Probationary;
     7. (V85) fills in live: a record filed by an officer after the section is
        open appears on the next synchronization without any user action;
     8. (V85) names the required Supabase patch when the shared database still
        runs the pre-V85 state loader.

   V85 note — the shim now behaves like the REAL `lso_get_state`:
     * serverMode 'v85'    -> a Trainee/Probationary token receives only its own
                              member record, its own attendance rows, the
                              activities those rows reference, and the
                              `scope` marker (port of lso_trainee_scoped_state_v85);
     * serverMode 'legacy' -> the pre-V85 production loader, which sent
                              events: [] and attendance: [] to Trainees. This is
                              the state that left the V84 section blank in
                              production while the old full-state mock passed.

   Usage:  node harness.js [granted|live|legacy|revoked|admin|center|all]
   Requires: jsdom (devDependency of this folder).
   ============================================================================ */
const fs = require('fs');
const path = require('path');
const { JSDOM, ResourceLoader, VirtualConsole } = require('jsdom');

const seed = require('../responsive-audit/seed.js');
const { buildShim } = require('../responsive-audit/mock-supabase.js');

const MODE = process.argv[2] || process.env.LSO_SCENARIO || 'all';
const ROOT = path.resolve(__dirname, '..');
const TRAINEE_USERNAME = 'trainee.one';
const ADMIN_USERNAME = 'lso.admin';
const VIEW_ID = 'ownAttendanceView';

const results = [];
function check(name, condition, detail = '') {
  results.push({ name, ok: Boolean(condition), detail });
  console.log(`${condition ? '[PASS]' : '[FAIL]'} ${name}${detail ? ` — ${detail}` : ''}`);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Synthetic shared database: the trainee has three records, another member has
// two, and one record belongs to a third member in a different calendar. The
// self view must show exactly the trainee's three and nothing else.
// ---------------------------------------------------------------------------
const traineeAccount = seed.accounts.find((account) => account.username === TRAINEE_USERNAME);
const traineeMember = seed.members.find((member) => member.id === traineeAccount.memberId);
const otherMember = seed.members.find((member) => member.id !== traineeAccount.memberId && member.periodGroup === 'Trainee Period');
const outsiderMember = seed.members.find((member) => !['Trainee Period', 'Probationary Period'].includes(member.periodGroup));
const traineeEvents = seed.events.filter((event) => event.requiredSections).slice(0, 3);
const otherEvent = seed.events[seed.events.length - 1];

const state = JSON.parse(JSON.stringify(seed.state));
state.attendance = [
  { eventId: traineeEvents[0].id, memberId: traineeMember.id, status: 'Present', remarks: '', attendanceGroup: 'Trainee Members', rosterModeAtEdit: 'Current', createdBy: 'General Secretary', createdAt: `${traineeEvents[0].date}T10:00:00Z`, updatedAt: `${traineeEvents[0].date}T10:00:00Z` },
  { eventId: traineeEvents[1].id, memberId: traineeMember.id, status: 'Late', remarks: 'Arrived 12 minutes after call time', attendanceGroup: 'Trainee Members', rosterModeAtEdit: 'Current', createdBy: 'General Secretary', createdAt: `${traineeEvents[1].date}T10:00:00Z`, updatedAt: `${traineeEvents[1].date}T10:00:00Z` },
  { eventId: traineeEvents[2].id, memberId: traineeMember.id, status: 'Excused', remarks: 'Approved LOA', attendanceGroup: 'Trainee Members', rosterModeAtEdit: 'Current', loaAutoExcused: true, createdBy: 'General Secretary', createdAt: `${traineeEvents[2].date}T10:00:00Z`, updatedAt: `${traineeEvents[2].date}T10:00:00Z` },
  { eventId: otherEvent.id, memberId: otherMember.id, status: 'Absent', remarks: 'No notice', attendanceGroup: 'Trainee Members', rosterModeAtEdit: 'Current', createdBy: 'General Secretary', createdAt: `${otherEvent.date}T10:00:00Z`, updatedAt: `${otherEvent.date}T10:00:00Z` },
  { eventId: otherEvent.id, memberId: outsiderMember.id, status: 'Present', remarks: '', attendanceGroup: 'Official Members', rosterModeAtEdit: 'Current', createdBy: 'General Secretary', createdAt: `${otherEvent.date}T10:00:00Z`, updatedAt: `${otherEvent.date}T10:00:00Z` }
];

// Expectations derived from the seeded records (never hard-coded).
const traineeRows = state.attendance.filter((record) => record.memberId === traineeMember.id);
const ratedCounts = traineeRows.reduce((totals, record) => {
  if (record.status in { Present: 1, Late: 1, Absent: 1 }) totals[record.status] += 1;
  return totals;
}, { Present: 0, Late: 0, Absent: 0 });
const ratedSessions = ratedCounts.Present + ratedCounts.Late + ratedCounts.Absent;
const expectedRate = ratedSessions ? Math.round(((ratedCounts.Present + ratedCounts.Late) / ratedSessions) * 100) : null;
const traineeMonths = [...new Set(traineeRows.map((record) => String(record.eventId)).map((id) => (state.events.find((event) => event.id === id) || {}).date).filter(Boolean).map((date) => date.slice(0, 7)))].sort().reverse();

const permissionPayload = (ownAttendance) => ({
  ok: true,
  schemaVersion: 13,
  permissionModel: 'v82',
  updatedAt: new Date().toISOString(),
  roles: [
    { roleName: 'Membership', landingView: 'dashboardView', views: ['dashboardView', 'membersView', 'contractView', 'monthlyReportView', 'attendanceView', 'dutyHoursView'], actions: ['manageMembers', 'generateContract', 'editMonthlyReport', 'manageEvents', 'saveDraftAttendance', 'reviewDutyPunches', 'manageDutyHours', 'manageDutyRequirements', 'certifyDutyHours', 'writeActivityLog', 'manageAccessibility'], attendanceGroups: ['Official Members', 'Trainee Members', 'Probationary Members'], columns: ['members', 'events', 'attendance', 'duty_hours', 'monthly_reports', 'monthly_reports_compat', 'settings', 'activity_log'] },
    { roleName: 'General Secretary', landingView: 'dashboardView', views: ['dashboardView', 'membersView', 'attendanceView', 'dutyHoursView'], actions: ['manageEvents', 'saveDraftAttendance', 'reviewDutyPunches', 'writeActivityLog', 'manageAccessibility'], attendanceGroups: ['Official Members', 'Trainee Members', 'Probationary Members'], columns: ['events', 'attendance', 'activity_log'] },
    { roleName: 'Staff Account', landingView: 'dashboardView', views: ['dashboardView', 'membersView', 'attendanceView', 'dutyHoursView'], actions: ['reviewDutyPunches', 'manageAccessibility'], attendanceGroups: ['Official Members', 'Trainee Members', 'Probationary Members'], columns: [] },
    { roleName: 'Trainee/Probationary', landingView: 'dutyHoursView', views: ownAttendance ? ['dutyHoursView', 'ownAttendanceView'] : ['dutyHoursView'], actions: ['selfDutyPunch', 'manageAccessibility'], attendanceGroups: [], columns: [] }
  ]
});

function buildShimFor({ ownAttendance = true, serverMode = 'v85' } = {}) {
  const replaced = buildShim({ state: JSON.parse(JSON.stringify(state)), accounts: seed.accounts })
    // Expose the seed so a scenario can act as an officer filing a new record.
    .replace('window.__mockRpcLog = [];', 'window.__mockRpcLog = []; window.__mockSeed = SEED;')
    // The stock shim always signs in as accounts[0]; sign in as the account the
    // form actually names so the Trainee path is exercised.
    .replace(
      "case 'lso_login': return { ok: true, token: 'mock-token-administrator', account: accounts()[0] };",
      "case 'lso_login': { var list = accounts(); var wanted = list.filter(function(a){ return a.username === (params && params.p_username); }); return { ok: true, token: 'mock-token-' + ((wanted[0] || list[0]).username), account: wanted[0] || list[0] }; }"
    )
    // V85: behave like the real state loader — the payload depends on the role
    // of the session that asks for it (see window.__lsoServerScope in STUBS).
    .replace(
      "case 'lso_get_state': return state();",
      "case 'lso_get_state': return window.__lsoServerScope(state(), accounts(), String((params && params.p_token) || ''));"
    )
    .replace(
      "case 'lso_get_permission_center': return { ok: true, roles: [], templates: [], permissions: {}, matrix: [], version: 39 };",
      `case 'lso_get_permission_center': return ${JSON.stringify(permissionPayload(ownAttendance))};`
    );
  if (!replaced.includes('__lsoServerScope')) throw new Error('shim replacement for lso_get_state did not apply');
  return replaced.replace('var SEED = ', `window.__lsoServerMode = ${JSON.stringify(serverMode)}; var SEED = `);
}

const STUBS = `
try { Object.defineProperty(window, 'scrollTo', { value: function(){}, writable: true, configurable: true }); } catch (e) {}
if (typeof Element !== 'undefined') {
  Element.prototype.scrollIntoView = Element.prototype.scrollIntoView || function(){};
  Element.prototype.scrollTo = Element.prototype.scrollTo || function(){};
}
if (typeof window.matchMedia !== 'function') {
  window.matchMedia = function(query){ return { matches: false, media: query, onchange: null, addListener(){}, removeListener(){}, addEventListener(){}, removeEventListener(){}, dispatchEvent(){ return false; } }; };
}
window.ResizeObserver = window.ResizeObserver || class { observe(){} unobserve(){} disconnect(){} };
window.IntersectionObserver = window.IntersectionObserver || class { observe(){} unobserve(){} disconnect(){} takeRecords(){return [];} };
try { Object.defineProperty(window, 'confirm', { value: function(){ return true; }, writable: true, configurable: true }); } catch (e) {}
try { Object.defineProperty(window, 'alert', { value: function(){}, writable: true, configurable: true }); } catch (e) {}
window.__openedReports = [];
try { Object.defineProperty(window, 'open', { value: function(){ var doc = { write: function(html){ window.__openedReports.push(html); }, close: function(){} }; return { document: doc }; }, writable: true, configurable: true }); } catch (e) {}
/* Port of public.lso_trainee_scoped_state_v85 (LSO_SELF_ATTENDANCE_LIVE_FEED_V85.sql)
   plus the pre-V85 production branch, selected by window.__lsoServerMode. */
window.__lsoServerScope = function (full, accounts, token) {
  var username = token.indexOf('mock-token-') === 0 ? token.slice('mock-token-'.length) : '';
  var account = accounts.filter(function (a) { return a.username === username; })[0];
  if (!account || account.role !== 'Trainee/Probationary') return full;
  var trim = function (v) { return String(v === undefined || v === null ? '' : v).trim(); };
  var memberId = trim(account.memberId);
  var members = Array.isArray(full.members) ? full.members : [];
  var attendance = Array.isArray(full.attendance) ? full.attendance : [];
  var events = Array.isArray(full.events) ? full.events : [];
  var duty = full.duty_hours && typeof full.duty_hours === 'object' ? full.duty_hours : { version: 6, commitments: {}, entries: [] };
  var ownMembers = memberId ? members.filter(function (m) { return trim(m.id) === memberId; }) : [];
  var ownEntries = memberId ? (duty.entries || []).filter(function (e) { return trim(e.memberId) === memberId; }) : [];
  var commitments = {}; if (memberId && duty.commitments && duty.commitments[memberId]) commitments[memberId] = duty.commitments[memberId];
  var base = { id: full.id || 1, members: ownMembers, duty_hours: { version: duty.version || 6, commitments: commitments, entries: ownEntries }, monthly_reports: {}, instruments: [], settings: {}, activity_log: [], updated_at: full.updated_at || new Date().toISOString() };
  if (window.__lsoServerMode === 'legacy') { base.events = []; base.attendance = []; return base; }
  var ownAttendance = memberId ? attendance.filter(function (r) { return trim(r.memberId) === memberId; }) : [];
  var referenced = {}; ownAttendance.forEach(function (r) { referenced[trim(r.eventId)] = true; });
  base.attendance = ownAttendance;
  base.events = events.filter(function (e) { return trim(e.id) !== '' && referenced[trim(e.id)]; });
  base.scope = { role: 'Trainee/Probationary', memberId: memberId, model: 'v85-own-record' };
  return base;
};
if (!window.crypto) window.crypto = {};
if (!window.crypto.randomUUID) window.crypto.randomUUID = function(){ return 'uuid-' + Math.random().toString(16).slice(2) + Date.now().toString(16); };
if (!window.crypto.getRandomValues) window.crypto.getRandomValues = function(a){ for (var i=0;i<a.length;i++) a[i] = Math.floor(Math.random()*256); return a; };
`;

class Loader extends ResourceLoader {
  constructor(shim) { super(); this.shim = shim; }
  fetch(url) {
    if (/cdn\.jsdelivr\.net/.test(url)) return Promise.resolve(Buffer.from(this.shim));
    if (url.startsWith('http://localhost/')) {
      const clean = decodeURIComponent(url.replace('http://localhost/', '').split('?')[0]);
      const target = path.join(ROOT, clean);
      if (target.startsWith(ROOT) && fs.existsSync(target) && fs.statSync(target).isFile()) return Promise.resolve(fs.readFileSync(target));
      return Promise.resolve(Buffer.from(''));
    }
    return Promise.resolve(Buffer.from(''));
  }
}

async function boot({ username, ownAttendance = true, serverMode = 'v85' }) {
  const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8').replace('<head>', `<head>\n<script>${STUBS}</script>`);
  const virtualConsole = new VirtualConsole();
  const errors = [];
  virtualConsole.on('jsdomError', (error) => errors.push(String(error.message || error).split('\n')[0]));
  const dom = new JSDOM(html, {
    url: 'http://localhost/index.html',
    runScripts: 'dangerously',
    resources: new Loader(buildShimFor({ ownAttendance, serverMode })),
    pretendToBeVisual: true,
    virtualConsole
  });
  const { window } = dom;
  const doc = window.document;
  await new Promise((resolve) => window.addEventListener('load', resolve));
  await sleep(900);
  const user = doc.getElementById('loginUsername');
  const password = doc.getElementById('loginPassword');
  if (user && password) { user.value = username; password.value = 'Sup3rSecret!'; doc.querySelector('.auth-submit')?.click(); }
  await sleep(2600);
  const authenticated = doc.body?.dataset?.authenticated === 'true';
  return { window, dom, doc, authenticated, errors };
}

function visibleNav(doc) {
  return [...doc.querySelectorAll('.nav-item')]
    .filter((node) => !node.classList.contains('role-hidden') && !node.classList.contains('hidden') && !node.closest('.hidden'))
    .map((node) => node.dataset.view);
}

async function runTraineeGranted() {
  console.log('\n=== SCENARIO 1 — Trainee/Probationary with My Attendance granted ===');
  const { doc, authenticated, errors, window } = await boot({ username: TRAINEE_USERNAME, ownAttendance: true });
  check('Trainee signs in through the real login form', authenticated);
  const nav = visibleNav(doc);
  check('Trainee navigation exposes Duty Hours and My Attendance only', JSON.stringify(nav.sort()) === JSON.stringify(['dutyHoursView', 'ownAttendanceView'].sort()), JSON.stringify(nav));
  check('Trainee landing is still Duty Hours', doc.querySelector('.view.active')?.id === 'dutyHoursView', doc.querySelector('.view.active')?.id);

  doc.querySelector('.nav-item[data-view="ownAttendanceView"]')?.click();
  await sleep(600);
  const active = doc.querySelector('.view.active:not(.hidden)')?.id;
  check('My Attendance opens as the active view', active === VIEW_ID, String(active));

  const view = doc.getElementById(VIEW_ID);
  const rows = [...view.querySelectorAll('#ownAttendanceTableBody tr')];
  check('Exactly the signed-in member attendance rows are rendered', rows.length === traineeRows.length, `rows = ${rows.length}, expected = ${traineeRows.length}`);
  const bodyText = view.textContent;
  check('Own member name is shown', bodyText.includes(traineeMember.fullName), traineeMember.fullName);
  check('No other member name appears in the section', !bodyText.includes(otherMember.fullName) && !bodyText.includes(outsiderMember.fullName));
  check('Statuses come from the stored records', rows.map((row) => row.textContent).join(' ').includes('Present') && rows.map((row) => row.textContent).join(' ').includes('Late'));
  check('Approved LOA row is marked Excused', rows.some((row) => /Excused/.test(row.textContent) && /Approved LOA/.test(row.textContent)));
  const rateText = doc.getElementById('ownAttendanceSummary')?.textContent || '';
  check(`Attendance rate matches Present+Late over rated sessions (${expectedRate}%)`, rateText.includes(`${expectedRate}%`) && rateText.includes(`${ratedSessions} rated session`), rateText.replace(/\s+/g, ' ').trim().slice(0, 180));

  const editable = [...view.querySelectorAll('input, textarea, select, [contenteditable="true"]')].filter((node) => node.id !== 'ownAttendanceMonthFilter');
  check('Section has no editable field', editable.length === 0, editable.map((node) => `${node.tagName}#${node.id}`).join(', '));
  const buttons = [...view.querySelectorAll('button')].map((node) => node.id);
  check('Only refresh/print controls exist', JSON.stringify(buttons) === JSON.stringify(['ownAttendanceRefreshButton', 'ownAttendancePrintButton']), JSON.stringify(buttons));
  const moduleSource = fs.readFileSync(path.join(ROOT, 'own-attendance-member-info-v1.js'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '');
  check('Module source calls no write API', !/\.replaceAttendance\s*\(|saveAttendanceRoster\s*\(|submitDutyEntry\s*\(|LSOCloud\.[A-Za-z]*save[A-Za-z]*\s*\(|LSOStorage\??\.(setItem|removeItem)|localStorage\.(setItem|removeItem)|\.rpc\s*\(|lso_update_state|lso_replace_state/.test(moduleSource));
  check('Live badge reports "Live" once the shared database is synchronized', doc.getElementById('ownAttendanceLiveBadge')?.dataset.state === 'live' && /Live/.test(doc.getElementById('ownAttendanceLiveBadge')?.textContent || ''), doc.getElementById('ownAttendanceLiveBadge')?.textContent);
  check('Status line states the record is live/synchronized', /Live/.test(doc.getElementById('ownAttendanceStatus')?.textContent || ''), (doc.getElementById('ownAttendanceStatus')?.textContent || '').slice(0, 120));
  check('Server scope marker (v85-own-record) is visible to diagnostics', window.LSOOwnAttendance?.getServerScope?.()?.model === 'v85-own-record' && window.LSOOwnAttendance?.getFeedState?.() === 'live', JSON.stringify(window.LSOOwnAttendance?.getServerScope?.()));

  // Month filter is a read-only view filter.
  const monthSelect = doc.getElementById('ownAttendanceMonthFilter');
  check('Month filter lists only own recorded months', [...monthSelect.options].length === traineeMonths.length + 1, `${[...monthSelect.options].length} options for ${traineeMonths.length} recorded months`);
  monthSelect.value = [...monthSelect.options][1].value;
  monthSelect.dispatchEvent(new window.Event('change', { bubbles: true }));
  await sleep(250);
  const expectedMonthRows = traineeRows.filter((record) => String((state.events.find((event) => event.id === record.eventId) || {}).date || '').slice(0, 7) === [...monthSelect.options][1].value).length;
  check('Month filter narrows the rows', [...view.querySelectorAll('#ownAttendanceTableBody tr')].length === expectedMonthRows, `rows = ${[...view.querySelectorAll('#ownAttendanceTableBody tr')].length}, expected = ${expectedMonthRows}`);

  doc.getElementById('ownAttendancePrintButton')?.click();
  await sleep(200);
  const report = (window.__openedReports || [])[0] || '';
  check('Printable report renders the same own rows', report.includes(traineeMember.fullName) && !report.includes(otherMember.fullName));
  check('No uncaught browser errors', errors.length === 0, errors.slice(0, 2).join(' | '));
}

async function runTraineeLive() {
  console.log('\n=== SCENARIO 1b — V85 live feed: a record filed while the section is open appears automatically ===');
  const { doc, authenticated, errors, window } = await boot({ username: TRAINEE_USERNAME, ownAttendance: true, serverMode: 'v85' });
  check('Trainee signs in', authenticated);
  doc.querySelector('.nav-item[data-view="ownAttendanceView"]')?.click();
  await sleep(600);
  const before = doc.querySelectorAll('#ownAttendanceTableBody tr').length;
  check('Section shows the seeded own rows first', before === traineeRows.length, `rows = ${before}`);

  // Only the rows the server sends reach the browser: the synchronized cache
  // must contain the Trainee's rows and nothing from any other member.
  const cached = JSON.parse(window.localStorage.getItem('lso_attendance_v2') || '[]');
  check('Browser cache holds only the own rows sent by the scoped loader', cached.length === traineeRows.length && cached.every((row) => row.memberId === traineeMember.id), `cached = ${cached.length}`);
  const cachedEvents = JSON.parse(window.localStorage.getItem('lso_events_v2') || '[]');
  check('Browser cache holds only the activities referenced by the own rows', cachedEvents.length === new Set(traineeRows.map((row) => row.eventId)).size && cachedEvents.every((event) => traineeRows.some((row) => row.eventId === event.id)), `events = ${cachedEvents.length}`);

  // An Attendance officer files a new record for this member (server side),
  // then the regular synchronization runs — no click, no reload.
  const newEvent = seed.events.find((event) => !traineeRows.some((row) => row.eventId === event.id) && event.id !== otherEvent.id) || otherEvent;
  const officerRecord = { eventId: newEvent.id, memberId: traineeMember.id, status: 'Absent', remarks: 'Filed live by the officer', attendanceGroup: 'Trainee Members', rosterModeAtEdit: 'Current', createdBy: 'General Secretary', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  window.__mockSeed.state.attendance.push(officerRecord);
  window.__mockSeed.state.attendance.push({ ...officerRecord, memberId: otherMember.id, remarks: 'Other member — must never appear' });
  window.__mockSeed.state.updated_at = new Date().toISOString();
  await window.LSOCloud.pollNow();
  await sleep(500);
  const after = [...doc.querySelectorAll('#ownAttendanceTableBody tr')];
  check('New own record appears without any user action after the next synchronization', after.length === before + 1, `rows = ${after.length}, expected = ${before + 1}`);
  check('The new row shows the officer status, remarks, and the referenced activity', after.some((row) => /Absent/.test(row.textContent) && /Filed live by the officer/.test(row.textContent) && row.textContent.includes(newEvent.title)));
  check('The other member row filed at the same time never appears', !doc.getElementById('ownAttendanceView').textContent.includes('Other member — must never appear'));
  const summaryText = doc.getElementById('ownAttendanceSummary')?.textContent || '';
  check('Summary cards recount live (Absent = 1, sessions + 1)', /Absent1/.test(summaryText.replace(/\s+/g, '')) && summaryText.includes(`Recorded sessions${before + 1}`), summaryText.replace(/\s+/g, ' ').slice(0, 120));
  check('Live badge remains "Live" after the update', doc.getElementById('ownAttendanceLiveBadge')?.dataset.state === 'live');

  // The officer corrects the record: the change must be reflected as well.
  window.__mockSeed.state.attendance = window.__mockSeed.state.attendance.map((row) => (row.remarks === 'Filed live by the officer' ? { ...row, status: 'Excused', remarks: 'Corrected: excused', updatedAt: new Date().toISOString() } : row));
  window.__mockSeed.state.updated_at = new Date().toISOString();
  await window.LSOCloud.pollNow();
  await sleep(500);
  const corrected = [...doc.querySelectorAll('#ownAttendanceTableBody tr')];
  check('A corrected record is reflected on the next synchronization', corrected.some((row) => /Excused/.test(row.textContent) && /Corrected: excused/.test(row.textContent)) && !corrected.some((row) => /Filed live by the officer/.test(row.textContent)));
  check('No uncaught browser errors in the live scenario', errors.length === 0, errors.slice(0, 2).join(' | '));
}

async function runTraineeLegacyServer() {
  console.log('\n=== SCENARIO 1c — shared database still on the pre-V85 loader (the production blank) ===');
  const { doc, authenticated, window } = await boot({ username: TRAINEE_USERNAME, ownAttendance: true, serverMode: 'legacy' });
  check('Trainee signs in', authenticated);
  doc.querySelector('.nav-item[data-view="ownAttendanceView"]')?.click();
  await sleep(700);
  const rows = doc.querySelectorAll('#ownAttendanceTableBody tr').length;
  check('Pre-V85 loader sends no attendance rows to the Trainee (reproduces the blank section)', rows === 0, `rows = ${rows}`);
  const status = doc.getElementById('ownAttendanceStatus')?.textContent || '';
  check('Section explains the cause and names the Supabase patch to run', /LSO_SELF_ATTENDANCE_LIVE_FEED_V85\.sql/.test(status) && /Administrator/.test(status), status.slice(0, 160));
  check('Live badge reports "Database update required"', doc.getElementById('ownAttendanceLiveBadge')?.dataset.state === 'server-outdated', doc.getElementById('ownAttendanceLiveBadge')?.textContent);
  check('Diagnostics report the server-outdated feed state', window.LSOOwnAttendance?.getFeedState?.() === 'server-outdated' && window.LSOOwnAttendance?.getServerScope?.() === null);
}

async function runTraineeRevoked() {
  console.log('\n=== SCENARIO 2 — Trainee/Probationary with the permission revoked ===');
  const { doc, authenticated, window } = await boot({ username: TRAINEE_USERNAME, ownAttendance: false });
  check('Trainee signs in', authenticated);
  const nav = visibleNav(doc);
  check('Revoked Trainee keeps Duty Hours only', JSON.stringify(nav) === JSON.stringify(['dutyHoursView']), JSON.stringify(nav));
  window.LSOApp?.setView?.(VIEW_ID);
  await sleep(300);
  check('Opening the revoked section falls back to Duty Hours', doc.querySelector('.view.active')?.id === 'dutyHoursView', doc.querySelector('.view.active')?.id);
  check('Revoked section is hidden in the DOM', doc.getElementById(VIEW_ID)?.classList.contains('hidden') === true);
}

async function runAdmin() {
  console.log('\n=== SCENARIO 3 — Administrator ===');
  const { doc, authenticated, errors } = await boot({ username: ADMIN_USERNAME, ownAttendance: true });
  check('Administrator signs in', authenticated);
  const nav = visibleNav(doc);
  check('Administrator navigation does not include My Attendance', !nav.includes(VIEW_ID), JSON.stringify(nav));
  doc.querySelector('.nav-item[data-view="ownAttendanceView"]')?.click();
  await new Promise((resolve) => setTimeout(resolve, 400));
  const active = doc.querySelector('.view.active:not(.hidden)')?.id;
  check('Administrator cannot open the Trainee self section', active !== VIEW_ID, String(active));
  const cards = [...doc.querySelectorAll('#permissionModuleOptions .permission-toggle-card')];
  const card = cards.find((node) => node.querySelector('input')?.value === VIEW_ID);
  check('Role & Permission Center lists "My Attendance" as a module', Boolean(card));
  const label = card?.textContent || '';
  check('Module description states the read-only, own-record scope', /read-only/i.test(label) && /own attendance record/i.test(label), label.replace(/\s+/g, ' ').trim().slice(0, 140));
  check('No uncaught browser errors in the Administrator session', errors.length === 0, errors.slice(0, 2).join(' | '));
}

async function runAdminPermissionCenterRoleLocks() {
  console.log('\n=== SCENARIO 4 — Permission Center role locking for the new module ===');
  const { doc } = await boot({ username: ADMIN_USERNAME, ownAttendance: true });
  doc.querySelector('.nav-item[data-view="systemHealthView"]')?.click();
  await sleep(400);
  const select = doc.getElementById('permissionRoleSelect');
  const readCard = () => {
    const card = [...doc.querySelectorAll('#permissionModuleOptions .permission-toggle-card')]
      .find((node) => node.querySelector('input')?.value === VIEW_ID);
    return { present: Boolean(card), disabled: card?.querySelector('input')?.disabled === true, checked: card?.querySelector('input')?.checked === true };
  };
  select.value = 'Trainee/Probationary';
  select.dispatchEvent(new doc.defaultView.Event('change', { bubbles: true }));
  await sleep(250);
  const traineeCard = readCard();
  check('Trainee/Probationary: module card is selectable', traineeCard.present && !traineeCard.disabled, JSON.stringify(traineeCard));
  check('Trainee/Probationary: module card is granted in the working copy', traineeCard.checked === true, JSON.stringify(traineeCard));
  for (const roleName of ['Membership', 'General Secretary', 'Staff Account']) {
    select.value = roleName;
    select.dispatchEvent(new doc.defaultView.Event('change', { bubbles: true }));
    await sleep(200);
    const state = readCard();
    check(`${roleName}: module card is locked`, state.present && state.disabled === true, JSON.stringify(state));
  }
}

(async () => {
  const scenarios = {
    granted: runTraineeGranted,
    live: runTraineeLive,
    legacy: runTraineeLegacyServer,
    revoked: runTraineeRevoked,
    admin: runAdmin,
    center: runAdminPermissionCenterRoleLocks
  };
  const ordering = MODE === 'all' ? ['granted', 'live', 'legacy', 'revoked', 'admin', 'center'] : [MODE];
  for (const name of ordering) {
    if (!scenarios[name]) { console.error(`Unknown scenario: ${name}`); process.exit(2); }
    await scenarios[name]();
  }
  const failed = results.filter((row) => !row.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('FAILED CHECKS:\n' + failed.map((row) => ` - ${row.name} ${row.detail}`).join('\n'));
    process.exit(1);
  }
  process.exit(0);
})().catch((error) => { console.error('HARNESS ERROR:', error); process.exit(2); });
