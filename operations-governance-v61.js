(() => {
  'use strict';

  const VERSION = '6.7.0';
  const KEYS = Object.freeze({
    members: 'lso_member_database_v1',
    events: 'lso_events_v2',
    attendance: 'lso_attendance_v2',
    instruments: 'lso_instruments_v2',
    activity: 'lso_activity_log_v2',
    settings: 'lso_system_settings_v2',
    duty: 'lso_duty_hours_v1',
    monthly: 'lso_monthly_reports_v1',
    notifications: 'lso_notification_read_v1'
  });
  const AUDITABLE_KEYS = new Map([
    [KEYS.members, 'Members'], [KEYS.events, 'Attendance Activities'], [KEYS.attendance, 'Attendance'],
    [KEYS.instruments, 'Inventory'], [KEYS.settings, 'System Settings'], [KEYS.duty, 'Duty Hours'], [KEYS.monthly, 'Monthly Reports']
  ]);
  const INBOX_VERSION = 2;
  const MAX_AUDIT_ENTRIES = 800;
  const MAX_AUDIT_CHANGES = 36;
  const VALID_ATTENDANCE = new Set(['Present', 'Late', 'Absent', 'Excused', 'Not Required']);
  const el = (id) => document.getElementById(id);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];
  let originalStorageSet = null;
  let originalStorageRemove = null;
  let auditGuard = false;
  let qualityCache = { at: 0, signature: '', issues: [] };
  let auditPage = 1;
  let auditRenderTimer = 0;
  let qualityRenderTimer = 0;
  let inboxRenderTimer = 0;

  const TEMPLATE_DEFS = Object.freeze({
    membership: {
      label: 'Membership Operations', landing: 'dashboardView',
      views: ['dashboardView','membersView','contractView','monthlyReportView','attendanceView','dutyHoursView'],
      actions: ['manageMembers','generateContract','editMonthlyReport','manageEvents','saveDraftAttendance','reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility'],
      groups: ['Official Members','Trainee Members','Probationary Members']
    },
    secretary: {
      label: 'General Secretary Operations', landing: 'dashboardView',
      views: ['dashboardView','membersView','attendanceView','dutyHoursView'],
      actions: ['manageEvents','saveDraftAttendance','reviewDutyPunches','writeActivityLog','manageAccessibility'],
      groups: ['Official Members','Trainee Members','Probationary Members']
    },
    attendance: {
      label: 'Attendance Officer', landing: 'attendanceView',
      views: ['dashboardView','membersView','attendanceView'],
      actions: ['manageEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance','writeActivityLog','manageAccessibility'],
      groups: ['Official Members','Trainee Members','Probationary Members']
    },
    duty: {
      label: 'Duty Hours Reviewer', landing: 'dutyHoursView',
      views: ['dashboardView','membersView','dutyHoursView'],
      actions: ['reviewDutyPunches','manageDutyHours','manageDutyRequirements','certifyDutyHours','writeActivityLog','manageAccessibility'],
      groups: []
    },
    monitor: {
      label: 'Read-only Operations Monitor', landing: 'dashboardView',
      views: ['dashboardView','membersView','attendanceView','dutyHoursView'],
      actions: ['manageAccessibility'],
      groups: ['Official Members','Trainee Members','Probationary Members']
    },
    trainee: {
      label: 'Trainee / Probationary Self Service', landing: 'dutyHoursView',
      views: ['dutyHoursView'], actions: ['selfDutyPunch','manageAccessibility'], groups: []
    }
  });

  function safe(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[c]));
  }
  function currentAccount() { return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null; }
  function username() { return String(currentAccount()?.username || currentAccount()?.displayName || 'anonymous').toLowerCase(); }
  function isAdmin() { return currentAccount()?.role === 'Administrator'; }
  function can(action) { return window.LSORoleAccess?.can?.(action, currentAccount()) ?? isAdmin(); }
  function toast(message, error = false) { window.LSOApp?.showToast?.(message, error); }
  function uid(prefix='v61') { return window.crypto?.randomUUID?.() || `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`; }
  function clone(value) { try { return JSON.parse(JSON.stringify(value)); } catch { return value; } }
  function normalizeId(value) { return String(value ?? '').trim(); }
  function normalizeText(value) { return String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' '); }
  function storageRaw(key) { try { return window.LSOStorage?.getItem(key) ?? localStorage.getItem(key); } catch { return null; } }
  function parseRaw(raw, fallback) { try { const v = JSON.parse(raw ?? ''); return v ?? fallback; } catch { return fallback; } }
  function loadArray(key) { const v = parseRaw(storageRaw(key), []); return Array.isArray(v) ? v : []; }
  function loadObject(key) { const v = parseRaw(storageRaw(key), {}); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; }
  function dateTime(value) {
    if (!value) return '—';
    const d = new Date(value); if (Number.isNaN(d.getTime())) return String(value);
    return new Intl.DateTimeFormat('en-PH', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Manila' }).format(d);
  }
  function stableValue(value, seen = new WeakSet()) {
    if (value === null || typeof value !== 'object') return value;
    if (seen.has(value)) return '[Circular]'; seen.add(value);
    if (Array.isArray(value)) { const a = value.map((x) => stableValue(x, seen)); seen.delete(value); return a; }
    const out = {}; Object.keys(value).sort().forEach((k) => { const v = value[k]; if (v !== undefined && typeof v !== 'function') out[k] = stableValue(v, seen); }); seen.delete(value); return out;
  }
  function stableSerialize(value) { try { return JSON.stringify(stableValue(value)); } catch { return JSON.stringify(value); } }
  function semanticRawEqual(a, b) {
    if (String(a ?? '') === String(b ?? '')) return true;
    try { return stableSerialize(JSON.parse(String(a ?? 'null'))) === stableSerialize(JSON.parse(String(b ?? 'null'))); } catch { return false; }
  }
  function scalar(value) {
    if (value === null || value === undefined || value === '') return '—';
    if (typeof value === 'string' && /^data:image\//i.test(value)) return `[Profile photo image • ${Math.max(1, Math.round(value.length * 0.75 / 1024))} KB]`;
    if (Array.isArray(value)) return `[${value.length} item${value.length === 1 ? '' : 's'}]`;
    if (typeof value === 'object') {
      const keys = Object.keys(value);
      if (keys.length > 20) return `{${keys.length} fields}`;
      const s = stableSerialize(value); return s.length > 180 ? `${s.slice(0,177)}…` : s;
    }
    const s = String(value); return s.length > 180 ? `${s.slice(0,177)}…` : s;
  }
  function recordIdentity(item, index, key) {
    if (!item || typeof item !== 'object') return `#${index}`;
    if (item.id !== undefined && item.id !== null && item.id !== '') return normalizeId(item.id);
    if (key === KEYS.attendance) return `${normalizeId(item.eventId)}::${normalizeId(item.memberId)}::${normalizeId(item.attendanceGroup || item.group || '')}`;
    if (item.membershipId) return normalizeId(item.membershipId);
    if (item.key) return normalizeId(item.key);
    return `#${index}`;
  }
  function pushChange(out, path, before, after, type='updated') {
    if (out.length >= MAX_AUDIT_CHANGES) return;
    out.push({ path: path || 'record', before: scalar(before), after: scalar(after), type });
  }
  function diffObject(before, after, path, out, depth = 0) {
    if (out.length >= MAX_AUDIT_CHANGES || before === after) return;
    const beforeObject = before !== null && typeof before === 'object';
    const afterObject = after !== null && typeof after === 'object';
    if (!beforeObject || !afterObject) { if (String(before ?? '') !== String(after ?? '')) pushChange(out, path, before, after); return; }
    if (Array.isArray(before) || Array.isArray(after)) {
      if (!Array.isArray(before) || !Array.isArray(after) || stableSerialize(before) !== stableSerialize(after)) pushChange(out, path, before, after);
      return;
    }
    if (depth > 4) { if (stableSerialize(before) !== stableSerialize(after)) pushChange(out, path, before, after); return; }
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    for (const key of keys) {
      if (out.length >= MAX_AUDIT_CHANGES) break;
      const nextPath = path ? `${path}.${key}` : key;
      if (!(key in before)) pushChange(out, nextPath, '—', after[key], 'added');
      else if (!(key in after)) pushChange(out, nextPath, before[key], '—', 'removed');
      else diffObject(before[key], after[key], nextPath, out, depth + 1);
    }
  }
  function buildChanges(key, before, after) {
    const out = [];
    if (Array.isArray(before) && Array.isArray(after)) {
      const beforeMap = new Map(before.map((item, i) => [recordIdentity(item, i, key), item]));
      const afterMap = new Map(after.map((item, i) => [recordIdentity(item, i, key), item]));
      for (const [id, item] of afterMap) {
        if (out.length >= MAX_AUDIT_CHANGES) break;
        if (!beforeMap.has(id)) pushChange(out, `record[${id}]`, '—', item, 'added');
        else if (stableSerialize(beforeMap.get(id)) !== stableSerialize(item)) diffObject(beforeMap.get(id), item, `record[${id}]`, out, 0);
      }
      for (const [id, item] of beforeMap) {
        if (out.length >= MAX_AUDIT_CHANGES) break;
        if (!afterMap.has(id)) pushChange(out, `record[${id}]`, item, '—', 'removed');
      }
      return out;
    }
    diffObject(before, after, '', out, 0);
    return out;
  }
  function auditActionFor(changes, moduleName) {
    const types = new Set(changes.map((c) => c.type));
    if (types.size === 1 && types.has('added')) return `Created ${moduleName} data`;
    if (types.size === 1 && types.has('removed')) return `Removed ${moduleName} data`;
    return `Changed ${moduleName} data`;
  }
  function appendStructuredAudit(key, beforeRaw, afterRaw) {
    if (auditGuard || !AUDITABLE_KEYS.has(key) || semanticRawEqual(beforeRaw, afterRaw)) return;
    const account = currentAccount(); if (!account || !can('writeActivityLog')) return;
    const before = parseRaw(beforeRaw, key === KEYS.members || key === KEYS.events || key === KEYS.attendance || key === KEYS.instruments ? [] : {});
    const after = parseRaw(afterRaw, key === KEYS.members || key === KEYS.events || key === KEYS.attendance || key === KEYS.instruments ? [] : {});
    const changes = buildChanges(key, before, after);
    if (!changes.length) return;
    const moduleName = AUDITABLE_KEYS.get(key);
    const entry = {
      id: uid('audit'), timestamp: new Date().toISOString(), auditV61: true,
      action: auditActionFor(changes, moduleName), category: moduleName,
      details: `${changes.length}${changes.length >= MAX_AUDIT_CHANGES ? '+' : ''} field or record change${changes.length === 1 ? '' : 's'} captured`,
      account: account.displayName || account.username || 'User', username: account.username || '', role: account.role || '',
      storageKey: key, changes, userAgent: navigator.userAgent.slice(0, 180), page: document.querySelector('.view.active:not(.hidden)')?.id || ''
    };
    try {
      auditGuard = true;
      const log = loadArray(KEYS.activity);
      log.unshift(entry);
      originalStorageSet?.call(window.LSOStorage, KEYS.activity, JSON.stringify(log.slice(0, MAX_AUDIT_ENTRIES)));
      window.dispatchEvent(new CustomEvent('lso:audit-trail-changed', { detail: { entry } }));
    } catch (error) {
      console.warn('Audit trail write skipped:', error);
    } finally { auditGuard = false; }
  }
  function queueAudit(key, before, after) {
    if (!AUDITABLE_KEYS.has(key) || auditGuard || before === after) return;
    const run = () => appendStructuredAudit(key, before, after);
    if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(run, { timeout: 1200 });
    else window.setTimeout(run, 40);
  }
  function installAuditStorageInterceptor() {
    if (!window.LSOStorage || window.LSOStorage.__v61Audited) return;
    originalStorageSet = window.LSOStorage.setItem.bind(window.LSOStorage);
    originalStorageRemove = window.LSOStorage.removeItem.bind(window.LSOStorage);
    if (window.__LSO_STORAGE_CHANGE_EVENTS__ === 'v61') {
      window.addEventListener('lso:storage-change', (event) => {
        const detail = event.detail || {};
        queueAudit(detail.key, detail.before, detail.after);
      });
      window.LSOStorage.__v61Audited = true;
      return;
    }
    const wrappedSet = (key, value) => {
      const before = storageRaw(key);
      const result = originalStorageSet(key, value);
      if (result !== false) queueAudit(key, before, value);
      return result;
    };
    const wrappedRemove = (key) => {
      const before = storageRaw(key);
      const result = originalStorageRemove(key);
      if (result !== false && before !== null) queueAudit(key, before, JSON.stringify(Array.isArray(parseRaw(before, null)) ? [] : {}));
      return result;
    };
    window.LSOStorage.setItem = wrappedSet;
    window.LSOStorage.removeItem = wrappedRemove;
    window.LSOStorage.__v61Audited = true;
  }

  function auditEntries() { return loadArray(KEYS.activity).filter((entry) => entry && entry.timestamp); }
  function auditFilters() {
    return {
      q: normalizeText(el('auditTrailSearch')?.value), category: el('auditTrailModuleFilter')?.value || '',
      actor: normalizeText(el('auditTrailActorFilter')?.value), from: el('auditTrailFrom')?.value || '', to: el('auditTrailTo')?.value || ''
    };
  }
  function filteredAuditEntries() {
    const f = auditFilters();
    return auditEntries().filter((entry) => {
      const day = String(entry.timestamp || '').slice(0,10);
      if (f.category && entry.category !== f.category) return false;
      if (f.actor && !normalizeText(`${entry.account} ${entry.username} ${entry.role}`).includes(f.actor)) return false;
      if (f.from && day < f.from) return false;
      if (f.to && day > f.to) return false;
      if (f.q && !normalizeText(`${entry.action} ${entry.details} ${entry.category} ${entry.account} ${entry.username} ${(entry.changes || []).map((c) => `${c.path} ${c.before} ${c.after}`).join(' ')}`).includes(f.q)) return false;
      return true;
    });
  }
  let auditRenderRequest = 0;
  async function renderAuditTrail(resetPage = false) {
    const host = el('fullAuditTrail'); if (!host || !isAdmin()) return;
    if (resetPage) auditPage = 1;
    const requestId = ++auditRenderRequest;
    const f = auditFilters(); const pageSize = 25;
    const categories = [...new Set(auditEntries().map((e) => e.category).filter(Boolean))].sort();
    const moduleFilter = el('auditTrailModuleFilter');
    if (moduleFilter && moduleFilter.options.length !== categories.length + 1) moduleFilter.innerHTML = `<option value="">All modules</option>${categories.map((x) => `<option>${safe(x)}</option>`).join('')}`;

    // V69 server pagination is used when filters can be represented safely by the
    // server text search. Module/account/date filters keep the proven local path
    // so existing audit semantics are not changed.
    const canServerPage = Boolean(window.LSOCloud?.getCollectionPage) && !f.category && !f.actor && !f.from && !f.to;
    let entries = null, total = 0, pages = 1, serverPaged = false;
    if (canServerPage) {
      try {
        const result = await window.LSOCloud.getCollectionPage('activity_log', (auditPage - 1) * pageSize, pageSize, f.q || '');
        if (requestId !== auditRenderRequest) return;
        if (result && Array.isArray(result.items)) {
          entries = result.items; total = Number(result.total) || 0; pages = Math.max(1, Math.ceil(total / pageSize));
          if (auditPage > pages) { auditPage = pages; return renderAuditTrail(false); }
          serverPaged = !result.fallback;
        }
      } catch { entries = null; }
    }
    if (!entries) {
      const filtered = filteredAuditEntries(); total = filtered.length; pages = Math.max(1, Math.ceil(total / pageSize)); auditPage = Math.min(auditPage, pages);
      entries = filtered.slice((auditPage - 1) * pageSize, auditPage * pageSize);
    }
    el('auditTrailSummary').textContent = `${total} matching record${total === 1 ? '' : 's'} • Page ${auditPage} of ${pages}${serverPaged ? ' • server-paged' : ''}`;
    host.innerHTML = entries.length ? entries.map((entry) => {
      const changes = Array.isArray(entry.changes) ? entry.changes : [];
      return `<article class="v61-audit-item"><div class="v61-audit-main"><div><span class="v61-audit-category">${safe(entry.category || 'System')}</span><strong>${safe(entry.action || 'Activity')}</strong><small>${safe(entry.details || '')}</small></div><div class="v61-audit-meta"><span>${safe(entry.account || entry.username || 'System')}</span><span>${safe(entry.role || '')}</span><time>${safe(dateTime(entry.timestamp))}</time></div></div>${changes.length ? `<details><summary>View ${changes.length} captured change${changes.length === 1 ? '' : 's'}</summary><div class="v61-change-list">${changes.map((c) => `<div><code>${safe(c.path)}</code><span class="before">${safe(c.before)}</span><span aria-hidden="true">→</span><span class="after">${safe(c.after)}</span></div>`).join('')}</div></details>` : ''}</article>`;
    }).join('') : '<div class="v61-empty"><strong>No audit records match the current filters.</strong><small>New shared-data changes will appear automatically.</small></div>';
    el('auditTrailPrev').disabled = auditPage <= 1; el('auditTrailNext').disabled = auditPage >= pages;
  }
  function auditCsv() {
    const rows = [['Timestamp','Module','Action','Details','Account','Username','Role','Changed Path','Before','After']];
    filteredAuditEntries().forEach((e) => {
      const changes = Array.isArray(e.changes) && e.changes.length ? e.changes : [{path:'',before:'',after:''}];
      changes.forEach((c) => rows.push([e.timestamp,e.category,e.action,e.details,e.account,e.username,e.role,c.path,c.before,c.after]));
    });
    const csv = rows.map((r) => r.map((v) => { const s = String(v ?? ''); return /[",\r\n]/.test(s) ? `"${s.replace(/"/g,'""')}"` : s; }).join(',')).join('\r\n');
    download(`LSO_Audit_Trail_${new Date().toISOString().slice(0,10)}.csv`, csv, 'text/csv;charset=utf-8');
  }

  function issue(severity, module, title, detail, action='none', targetId='') { return { id: uid('quality'), severity, module, title, detail, action, targetId }; }
  function duplicateValues(list, field) {
    const seen = new Map(); const dupes = new Map();
    list.forEach((item) => { const value = normalizeText(item?.[field]); if (!value) return; if (seen.has(value)) dupes.set(value, [seen.get(value), ...(dupes.get(value)?.slice(1) || []), item]); else seen.set(value, item); });
    return [...dupes.entries()];
  }
  function parseTime(value) { const m = String(value || '').match(/^(\d{1,2}):(\d{2})/); return m ? Number(m[1]) * 60 + Number(m[2]) : null; }
  function getDutyEntries(duty) { return Array.isArray(duty?.entries) ? duty.entries : Array.isArray(duty) ? duty : []; }
  function dataSignature() {
    return [KEYS.members,KEYS.events,KEYS.attendance,KEYS.duty,KEYS.monthly,KEYS.settings].map((k) => {
      const raw = storageRaw(k) || ''; return `${k}:${raw.length}:${raw.slice(0,48)}:${raw.slice(-48)}`;
    }).join('|');
  }
  function scanDataQuality(force = false) {
    const signature = dataSignature(); const now = Date.now();
    // A scan is recomputed only after a storage/cloud change invalidates the cache or the Administrator explicitly requests it.
    if (!force && qualityCache.signature === signature) return qualityCache.issues;
    const issues = []; const members = loadArray(KEYS.members); const events = loadArray(KEYS.events); const attendance = loadArray(KEYS.attendance); const duty = loadObject(KEYS.duty); const monthly = loadObject(KEYS.monthly);
    const memberIds = new Set(members.map((m) => normalizeId(m.id)).filter(Boolean)); const eventIds = new Set(events.map((e) => normalizeId(e.id)).filter(Boolean));
    duplicateValues(members, 'membershipId').forEach(([value, rows]) => issues.push(issue('critical','Members','Duplicate Membership ID',`${value} is used by ${rows.length} member records.`,'member',rows[0]?.id)));
    duplicateValues(members, 'studentNumber').forEach(([value, rows]) => issues.push(issue('critical','Members','Duplicate Student Number',`${value} is used by ${rows.length} member records.`,'member',rows[0]?.id)));
    duplicateValues(members, 'outlook').forEach(([value, rows]) => issues.push(issue('warning','Members','Duplicate Outlook Account',`${value} is linked to ${rows.length} member records.`,'member',rows[0]?.id)));
    members.forEach((m) => {
      if (!normalizeText(m.fullName)) issues.push(issue('critical','Members','Member name is missing',`Membership record ${m.membershipId || m.id || 'unknown'} has no full name.`,'member',m.id));
      if (!normalizeText(m.studentNumber)) issues.push(issue('warning','Members','Student Number is missing',`${m.fullName || m.membershipId || 'A member'} has no Student Number.`,'member',m.id));
      const t = String(m.traineeStartDate || ''), p = String(m.probationaryStartDate || ''), r = String(m.regularMemberDate || '');
      if (t && p && p < t) issues.push(issue('critical','Members','Invalid membership timeline',`${m.fullName || m.membershipId}: Probationary start is before Trainee start.`,'member',m.id));
      if (p && r && r < p) issues.push(issue('critical','Members','Invalid membership timeline',`${m.fullName || m.membershipId}: Membership start is before Probationary start.`,'member',m.id));
    });
    const eventSeen = new Set(); events.forEach((e) => {
      const id = normalizeId(e.id); if (!id) issues.push(issue('critical','Attendance','Activity has no ID',`${e.title || 'Untitled activity'} cannot be reliably linked to attendance.`,'attendance',''));
      else if (eventSeen.has(id)) issues.push(issue('critical','Attendance','Duplicate activity ID',`Activity ID ${id} appears more than once.`,'event',id)); else eventSeen.add(id);
      if (!e.title || !e.date) issues.push(issue('warning','Attendance','Incomplete activity information',`${e.title || id || 'Activity'} is missing ${!e.title ? 'a title' : 'a date'}.`,'event',id));
    });
    const attendanceSeen = new Set(); attendance.forEach((a) => {
      const eventId = normalizeId(a.eventId), memberId = normalizeId(a.memberId), group = normalizeText(a.attendanceGroup || a.group || ''), composite = `${eventId}::${memberId}::${group}`;
      if (eventId && !eventIds.has(eventId)) issues.push(issue('critical','Attendance','Orphan attendance record',`Attendance references missing activity ${eventId}.`,'attendance-member',memberId));
      if (memberId && !memberIds.has(memberId)) issues.push(issue('critical','Attendance','Attendance references missing member',`Activity ${eventId || 'unknown'} contains member ID ${memberId} that is no longer in Members.`,'attendance',''));
      if (eventId && memberId && attendanceSeen.has(composite)) issues.push(issue('critical','Attendance','Duplicate attendance row',`Activity ${eventId} contains more than one attendance row for member ${memberId}.`,'attendance-member',memberId)); else attendanceSeen.add(composite);
      if (a.status && !VALID_ATTENDANCE.has(a.status)) issues.push(issue('warning','Attendance','Invalid attendance status',`${a.status} is not a recognized attendance status.`,'attendance-member',memberId));
    });
    const dutyEntries = getDutyEntries(duty); const dutyIds = new Set(); dutyEntries.forEach((d) => {
      const id = normalizeId(d.id); if (id && dutyIds.has(id)) issues.push(issue('critical','Duty Hours','Duplicate duty entry ID',`Duty entry ${id} appears more than once.`,'duty',id)); if (id) dutyIds.add(id);
      const memberId = normalizeId(d.memberId); if (memberId && !memberIds.has(memberId)) issues.push(issue('critical','Duty Hours','Duty entry references missing member',`${d.date || 'Duty entry'} references member ${memberId}.`,'duty',id));
      if (!d.date) issues.push(issue('warning','Duty Hours','Duty entry date is missing',`Entry ${id || 'without ID'} has no date.`,'duty',id));
      if (Number(d.minutes) < 0) issues.push(issue('critical','Duty Hours','Negative duty duration',`Entry ${id || d.date || ''} has ${d.minutes} minutes.`,'duty',id));
      const tin = parseTime(d.timeIn), tout = parseTime(d.timeOut); if (tin !== null && tout !== null && tout < tin) issues.push(issue('critical','Duty Hours','Time Out is before Time In',`${d.date || 'Duty entry'} has an invalid time range.`,'duty',id));
    });
    try {
      const accounts = window.LSOAuth?.loadAccounts?.() || []; const users = new Set();
      accounts.forEach((a) => { const u = normalizeText(a.username); if (u && users.has(u)) issues.push(issue('critical','Accounts','Duplicate username',`@${a.username} appears more than once.`,'accounts',a.id)); users.add(u);
        if (a.role === 'Trainee/Probationary' && a.approvalStatus === 'Approved') { const linked = normalizeId(a.linkedMemberId || a.memberId); if (!linked) issues.push(issue('critical','Accounts','Approved trainee account is not linked',`@${a.username} has no linked member.`,'accounts',a.id)); else if (!memberIds.has(linked)) issues.push(issue('critical','Accounts','Account links to missing member',`@${a.username} links to member ${linked}, which is not in Members.`,'accounts',a.id)); }
      });
    } catch { /* account connector can still be loading */ }
    const reports = monthly?.reports && typeof monthly.reports === 'object' ? monthly.reports : {};
    Object.entries(reports).forEach(([key, report]) => { if (!/^\d{4}-\d{2}$/.test(key)) issues.push(issue('warning','Monthly Report','Non-standard report month key',`${key} should use YYYY-MM.`,'monthly-report',key)); if (report?.workflowStatus === 'Finalized' && !report.finalizedAt) issues.push(issue('warning','Monthly Report','Finalized report lacks finalization timestamp',`${key} is finalized but has no finalizedAt value.`,'monthly-report',key)); });
    const pending = window.LSOCloud?.getPendingChanges?.() || []; if (pending.length > 2) issues.push(issue('warning','Database','Multiple changes are waiting to sync',`${pending.length} shared-data areas are currently queued.`,'data',''));
    qualityCache = { at: now, signature, issues }; return issues;
  }
  function qualityCounts(issues = scanDataQuality()) { return { critical: issues.filter((i) => i.severity === 'critical').length, warning: issues.filter((i) => i.severity === 'warning').length, info: issues.filter((i) => i.severity === 'info').length }; }
  function renderDataQuality(force = false) {
    const host = el('dataQualityIssues'); if (!host || !isAdmin()) return;
    const issues = scanDataQuality(force); const counts = qualityCounts(issues); const severity = el('dataQualitySeverity')?.value || ''; const module = el('dataQualityModule')?.value || ''; const q = normalizeText(el('dataQualitySearch')?.value);
    const modules = [...new Set(issues.map((i) => i.module))].sort(); const moduleNode = el('dataQualityModule'); if (moduleNode && moduleNode.options.length !== modules.length + 1) moduleNode.innerHTML = `<option value="">All modules</option>${modules.map((m) => `<option>${safe(m)}</option>`).join('')}`;
    const filtered = issues.filter((i) => (!severity || i.severity === severity) && (!module || i.module === module) && (!q || normalizeText(`${i.title} ${i.detail} ${i.module}`).includes(q)));
    el('dataQualityMetrics').innerHTML = `<div><span>Critical</span><strong>${counts.critical}</strong></div><div><span>Warnings</span><strong>${counts.warning}</strong></div><div><span>Checked Areas</span><strong>6</strong></div><div><span>Total Issues</span><strong>${issues.length}</strong></div>`;
    el('dataQualityStatus').textContent = issues.length ? `${issues.length} issue${issues.length === 1 ? '' : 's'} detected • ${dateTime(new Date().toISOString())}` : `No structural data issues detected • ${dateTime(new Date().toISOString())}`;
    host.innerHTML = filtered.length ? filtered.map((i) => `<article class="v61-quality-item severity-${safe(i.severity)}"><span class="v61-quality-severity">${safe(i.severity)}</span><div><strong>${safe(i.title)}</strong><small>${safe(i.module)} • ${safe(i.detail)}</small></div>${i.action !== 'none' ? `<button class="button button-secondary" data-quality-action="${safe(i.action)}" data-quality-target="${safe(i.targetId)}" type="button">Open Record</button>` : ''}</article>`).join('') : '<div class="v61-empty"><strong>No issues match the current filters.</strong><small>Run the scan again after major imports, restores, or corrections.</small></div>';
    window.dispatchEvent(new CustomEvent('lso:data-quality-updated', { detail: { counts, total: issues.length } }));
  }
  function exportQualityCsv() {
    const rows = [['Severity','Module','Issue','Details','Target']]; scanDataQuality(true).forEach((i) => rows.push([i.severity,i.module,i.title,i.detail,i.targetId]));
    const csv = rows.map((r) => r.map((v) => { const s=String(v??''); return /[",\r\n]/.test(s)?`"${s.replace(/"/g,'""')}"`:s; }).join(',')).join('\r\n'); download(`LSO_Data_Quality_${new Date().toISOString().slice(0,10)}.csv`, csv, 'text/csv;charset=utf-8');
  }

  function inboxAllState() {
    try {
      const parsed = JSON.parse(localStorage.getItem(KEYS.notifications) || '{}');
      if (parsed?.version === INBOX_VERSION && parsed.accounts && typeof parsed.accounts === 'object') return parsed;
      const legacyIds = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.ids) ? parsed.ids : [];
      const legacyFingerprints = Array.isArray(parsed?.fingerprints) ? parsed.fingerprints : [];
      return { version: INBOX_VERSION, accounts: { [username()]: { ids: legacyIds, fingerprints: legacyFingerprints, resolved: [], archived: [], history: {}, updatedAt: new Date().toISOString() } } };
    } catch { return { version: INBOX_VERSION, accounts: {} }; }
  }
  function inboxAccountRaw() {
    const state = inboxAllState(); const key = username();
    return { state, key, account: state.accounts[key] || { ids: [], fingerprints: [], resolved: [], archived: [], history: {}, updatedAt: '' } };
  }
  function readInboxState() {
    const { account } = inboxAccountRaw();
    return { ids: new Set(account.ids || []), fingerprints: new Set(account.fingerprints || []), resolved: new Set(account.resolved || []), archived: new Set(account.archived || []), history: account.history || {} };
  }
  function saveInboxState(next) {
    const { state, key } = inboxAccountRaw();
    state.accounts[key] = {
      ids: [...(next.ids || [])].slice(-1200), fingerprints: [...(next.fingerprints || [])].slice(-1200), resolved: [...(next.resolved || [])].slice(-800), archived: [...(next.archived || [])].slice(-800),
      history: next.history || {}, updatedAt: new Date().toISOString()
    };
    const historyEntries = Object.entries(state.accounts[key].history); if (historyEntries.length > 500) state.accounts[key].history = Object.fromEntries(historyEntries.slice(-500));
    try { localStorage.setItem(KEYS.notifications, JSON.stringify(state)); } catch { /* notification preferences are non-critical */ }
    return true;
  }
  function saveReadStateFromDashboard(state) {
    const current = readInboxState(); current.ids = new Set(state.ids || []); current.fingerprints = new Set(state.fingerprints || []); saveInboxState(current);
  }
  function notificationKey(n) { return n.fingerprint || [n.category,n.actionType,n.targetId,n.title].map(normalizeText).join('::'); }
  function currentNotifications() { return window.LSODashboardNotifications?.buildNotifications?.() || []; }
  function syncInboxHistory(notifications) {
    const state = readInboxState(); let changed = false;
    notifications.forEach((n) => { const key = notificationKey(n); const old = state.history[key]; const snapshot = { id:n.id, fingerprint:key, category:n.category, severity:n.severity, title:n.title, detail:n.detail, timestamp:n.timestamp, actionType:n.actionType, targetId:n.targetId, icon:n.icon, seenAt:new Date().toISOString() }; if (!old || stableSerialize({ ...old, seenAt:'' }) !== stableSerialize({ ...snapshot, seenAt:'' })) { state.history[key] = snapshot; changed = true; } });
    if (changed) saveInboxState(state); return state;
  }
  function setNotificationStatus(fingerprint, status, value=true) {
    const state = readInboxState(); const target = status === 'resolved' ? state.resolved : status === 'archived' ? state.archived : status === 'read' ? state.fingerprints : null; if (!target) return;
    if (value) target.add(fingerprint); else target.delete(fingerprint); saveInboxState(state); window.LSODashboardNotifications?.renderNotifications?.(); scheduleInboxRender(10);
  }
  function markAllInboxRead() {
    const notifications = currentNotifications(); const state = readInboxState();
    notifications.forEach((notification) => { state.ids.add(notification.id); state.fingerprints.add(notificationKey(notification)); });
    saveInboxState(state); window.LSODashboardNotifications?.renderNotifications?.(); scheduleInboxRender(10);
  }
  function notificationRows() {
    const current = currentNotifications(); const state = syncInboxHistory(current); const currentMap = new Map(current.map((n) => [notificationKey(n), n]));
    return Object.entries(state.history).map(([fingerprint, snap]) => {
      const live = currentMap.get(fingerprint) || snap; const current = currentMap.has(fingerprint); const manuallyResolved = state.resolved.has(fingerprint); const resolved = manuallyResolved || !current; const archived = state.archived.has(fingerprint); const read = state.fingerprints.has(fingerprint) || state.ids.has(live.id);
      return { ...live, fingerprint, resolved, manuallyResolved, archived, read, current };
    }).sort((a,b) => Number(a.archived)-Number(b.archived) || Number(a.resolved)-Number(b.resolved) || Number(a.read)-Number(b.read) || String(b.timestamp || b.seenAt || '').localeCompare(String(a.timestamp || a.seenAt || '')));
  }
  function renderNotificationInbox() {
    const host = el('notificationInboxList'); if (!host) return; const rows = notificationRows();
    const status = el('notificationInboxStatus')?.value || 'active'; const severity = el('notificationInboxSeverity')?.value || ''; const module = el('notificationInboxModule')?.value || ''; const q = normalizeText(el('notificationInboxSearch')?.value);
    const modules = [...new Set(rows.map((r) => r.category).filter(Boolean))].sort(); const moduleNode = el('notificationInboxModule'); if (moduleNode && moduleNode.options.length !== modules.length + 1) moduleNode.innerHTML = `<option value="">All modules</option>${modules.map((m) => `<option>${safe(m)}</option>`).join('')}`;
    const filtered = rows.filter((r) => {
      if (status === 'active' && (r.resolved || r.archived)) return false; if (status === 'unread' && (r.read || r.resolved || r.archived)) return false; if (status === 'read' && (!r.read || r.resolved || r.archived)) return false; if (status === 'resolved' && !r.resolved) return false; if (status === 'archived' && !r.archived) return false;
      if (severity && r.severity !== severity) return false; if (module && r.category !== module) return false; if (q && !normalizeText(`${r.title} ${r.detail} ${r.category}`).includes(q)) return false; return true;
    });
    const activeUnread = rows.filter((r) => !r.read && !r.resolved && !r.archived).length; el('notificationInboxSummary').textContent = `${activeUnread} unread active • ${rows.filter((r) => r.resolved).length} resolved • ${rows.filter((r) => r.archived).length} archived`;
    host.innerHTML = filtered.length ? filtered.slice(0,150).map((r) => `<article class="v61-inbox-item ${r.read ? 'is-read' : 'is-unread'} ${r.resolved ? 'is-resolved' : ''}"><span class="v61-inbox-icon">${safe(r.icon || '!')}</span><div class="v61-inbox-copy"><div><span>${safe(r.category || 'System')}</span><em>${safe(r.severity || 'low')}</em>${!r.current ? '<em>History</em>' : ''}</div><strong>${safe(r.title)}</strong><small>${safe(r.detail || '')}</small><time>${safe(r.timestamp ? dateTime(r.timestamp) : 'Current condition')}</time></div><div class="v61-inbox-actions">${r.current ? `<button class="button button-secondary" data-inbox-open="${safe(r.fingerprint)}" type="button">Open</button>` : ''}<button class="text-button" data-inbox-read="${safe(r.fingerprint)}" type="button">${r.read ? 'Mark unread' : 'Mark read'}</button><button class="text-button" data-inbox-resolve="${safe(r.fingerprint)}" type="button">${r.resolved ? 'Reopen' : 'Resolve'}</button><button class="text-button" data-inbox-archive="${safe(r.fingerprint)}" type="button">${r.archived ? 'Restore' : 'Archive'}</button></div></article>`).join('') : '<div class="v61-empty"><strong>No notifications match this inbox view.</strong><small>Use the filters above or refresh notification sources.</small></div>';
  }
  function scheduleInboxRender(delay=80) { clearTimeout(inboxRenderTimer); inboxRenderTimer = setTimeout(renderNotificationInbox, delay); }
  function compactFingerprint(value) {
    const text = String(value || ''); let hash = 2166136261;
    for (let i = 0; i < text.length; i += 1) { hash ^= text.charCodeAt(i); hash = Math.imul(hash, 16777619); }
    return (hash >>> 0).toString(36);
  }
  function externalNotifications() {
    if (!isAdmin()) return [];
    const issues = scanDataQuality(); const counts = qualityCounts(issues); const out = [];
    if (counts.critical) {
      const criticalSignature = compactFingerprint(issues.filter((item) => item.severity === 'critical').map((item) => `${item.module}|${item.title}|${item.targetId}|${item.detail}`).sort().join('||'));
      out.push({ id:`v61-quality:${criticalSignature}`, category:'Data Quality', severity:'high', title:`${counts.critical} critical data quality issue${counts.critical === 1 ? '' : 's'}`, detail:'Open Data Quality Center to review orphan, duplicate, or invalid records.', timestamp:'', actionType:'data-quality', targetId:criticalSignature, icon:'DQ' });
    }
    const maintenance = maintenanceSettings(); if (maintenance.enabled) {
      const maintenanceTarget = maintenance.updatedAt || compactFingerprint(`${maintenance.message}|${maintenance.expectedResume}`);
      out.push({ id:`v61-maintenance:${maintenanceTarget}`, category:'System Administration', severity:'medium', title:'Maintenance Mode is active', detail:maintenance.message || 'Only Administrator accounts can use the management system.', timestamp:maintenance.updatedAt || '', actionType:'maintenance', targetId:maintenanceTarget, icon:'M' });
    }
    return out;
  }

  function permissionTemplateOptions() {
    const select = el('permissionTemplateSelect'); if (!select) return;
    if (!select.options.length) select.innerHTML = `<option value="">Choose a template…</option>${Object.entries(TEMPLATE_DEFS).map(([key,t]) => `<option value="${safe(key)}">${safe(t.label)}</option>`).join('')}`;
  }
  function applyPermissionTemplate() {
    if (!isAdmin()) return; const key = el('permissionTemplateSelect')?.value; const template = TEMPLATE_DEFS[key]; const role = el('permissionRoleSelect')?.value || '';
    if (!template) return toast('Choose a permission template first.', true); if (!role || role === 'Administrator') return toast('Administrator permissions are protected and cannot be replaced by a template.', true);
    const sets = { view:new Set(template.views), action:new Set(template.actions), attendance:new Set(template.groups) };
    qsa('#rolePermissionEditor input[data-permission-kind]').forEach((input) => { if (!input.disabled) input.checked = sets[input.dataset.permissionKind]?.has(input.value) || false; });
    const firstView = document.querySelector('#permissionModuleOptions input:not(:disabled)'); firstView?.dispatchEvent(new Event('change', { bubbles:true }));
    setTimeout(() => { const landing = el('permissionLandingViewSelect'); if (landing && [...landing.options].some((o) => o.value === template.landing)) { landing.value = template.landing; landing.dispatchEvent(new Event('change',{bubbles:true})); } const status=el('permissionEditorStatus'); if(status){status.textContent=`${template.label} applied as a working template for ${role}. Review every permission, then select Save Role Permissions.`;status.className='permission-editor-status is-success';} }, 20);
  }

  function maintenanceSettings() {
    if (window.LSOMaintenanceV62?.getSettings) return window.LSOMaintenanceV62.getSettings();
    const settings = loadObject(KEYS.settings); const m = settings.maintenanceModeV61; return m && typeof m === 'object' ? { enabled:Boolean(m.enabled), message:String(m.message || ''), expectedResume:String(m.expectedResume || ''), updatedAt:m.updatedAt || '', updatedBy:m.updatedBy || '', mutationId:m.mutationId || '', version:Number(m.version)||1 } : { enabled:false, message:'The LSO system is temporarily unavailable while an Administrator performs maintenance.', expectedResume:'', updatedAt:'', updatedBy:'', mutationId:'', version:1 };
  }
  function renderMaintenanceSettings() {
    const m = maintenanceSettings(); if (el('maintenanceModeEnabled')) el('maintenanceModeEnabled').checked = m.enabled; if (el('maintenanceModeMessage')) el('maintenanceModeMessage').value = m.message; if (el('maintenanceExpectedResume')) el('maintenanceExpectedResume').value = m.expectedResume;
    const pending = window.LSOCloud?.getPendingChanges?.() || []; const waiting = Array.isArray(pending) && pending.includes('settings');
    if (el('maintenanceModeStatus')) el('maintenanceModeStatus').textContent = waiting ? 'Saving maintenance status to the shared database…' : (m.enabled ? `Active and shared • Updated ${dateTime(m.updatedAt)}${m.updatedBy ? ` by ${m.updatedBy}` : ''}` : 'Maintenance Mode is off. All approved accounts can use their assigned modules.');
  }
  async function saveMaintenanceSettings() {
    if (!isAdmin() || !can('manageSettings')) return toast('Administrator settings access is required.', true);
    const button = el('saveMaintenanceModeButton'); if (button) { button.disabled = true; button.dataset.originalText = button.textContent; button.textContent = 'Saving & Verifying…'; }
    try {
      const enabled = Boolean(el('maintenanceModeEnabled')?.checked); const message = String(el('maintenanceModeMessage')?.value || '').trim(); const expectedResume = String(el('maintenanceExpectedResume')?.value || '').trim();
      if (!window.LSOMaintenanceV62?.save) throw new Error('The Maintenance Mode controller did not load. Reload the website and try again.');
      const result = await window.LSOMaintenanceV62.save({ enabled, message, expectedResume });
      renderMaintenanceSettings(); applyMaintenanceMode();
      if (result.verified) toast(enabled ? 'Maintenance Mode is active across the shared system.' : 'Maintenance Mode is disabled across the shared system.');
      else toast(`Maintenance status is saved locally but cloud verification is pending. ${result.reason || 'Check the database connection.'}`, true);
    } catch (error) {
      renderMaintenanceSettings(); toast(error?.message || 'Maintenance settings could not be saved.', true);
    } finally { if (button) { button.disabled = false; button.textContent = button.dataset.originalText || 'Save Maintenance Status'; delete button.dataset.originalText; } }
  }
  function applyMaintenanceMode() {
    return window.LSOMaintenanceV62?.apply?.() || { blocked:false, settings:maintenanceSettings() };
  }

  function openSource(action, targetId='') {
    if (action === 'member') { window.LSOApp?.openRecord?.(targetId); return; }
    if (action === 'attendance-member') { if (!window.LSOOperations?.openAttendanceMember?.(targetId)) window.LSOApp?.setView?.('attendanceView'); return; }
    if (action === 'event') { window.LSODashboardNotifications?.performNotificationAction?.('event', targetId); return; }
    if (action === 'attendance') { window.LSOApp?.setView?.('attendanceView'); return; }
    if (action === 'duty') { window.LSOOperations?.openDutyRecord?.(targetId, ''); return; }
    if (action === 'accounts') { window.LSODashboardNotifications?.performNotificationAction?.('accounts', targetId); return; }
    if (action === 'monthly-report') { window.LSODashboardNotifications?.performNotificationAction?.('monthly-report', targetId); return; }
    if (action === 'data' || action === 'data-quality') { window.LSOApp?.setView?.('dataView'); setTimeout(() => { window.LSOEnterprise?.setRecoveryPanel?.('governance'); el('dataQualityCenter')?.scrollIntoView({block:'start',behavior:'smooth'}); },60); return; }
    if (action === 'maintenance') { window.LSOApp?.setView?.('systemHealthView'); setTimeout(() => { document.querySelector('[data-health-panel="access"]')?.click(); el('maintenanceModePanel')?.scrollIntoView({block:'center',behavior:'smooth'}); },60); }
  }
  function download(filename, content, type) { const blob = new Blob([content], { type }); const url = URL.createObjectURL(blob); const a=document.createElement('a'); a.href=url;a.download=filename;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),500); }

  function wireUi() {
    permissionTemplateOptions();
    el('applyPermissionTemplateButton')?.addEventListener('click', applyPermissionTemplate);
    el('saveMaintenanceModeButton')?.addEventListener('click', saveMaintenanceSettings);
    el('maintenanceModeLogoutButton')?.addEventListener('click', () => el('logoutButton')?.click());
    ['auditTrailSearch','auditTrailActorFilter','auditTrailFrom','auditTrailTo'].forEach((id) => el(id)?.addEventListener('input', () => renderAuditTrail(true)));
    el('auditTrailModuleFilter')?.addEventListener('change', () => renderAuditTrail(true));
    el('auditTrailPrev')?.addEventListener('click', () => { auditPage=Math.max(1,auditPage-1);renderAuditTrail(); }); el('auditTrailNext')?.addEventListener('click', () => { auditPage+=1;renderAuditTrail(); }); el('exportAuditTrailButton')?.addEventListener('click', auditCsv);
    ['dataQualitySearch'].forEach((id) => el(id)?.addEventListener('input', () => renderDataQuality())); ['dataQualitySeverity','dataQualityModule'].forEach((id) => el(id)?.addEventListener('change', () => renderDataQuality())); el('runDataQualityScan')?.addEventListener('click', () => { qualityCache.at=0;renderDataQuality(true);toast('Data quality scan completed.'); }); el('exportDataQualityButton')?.addEventListener('click', exportQualityCsv);
    el('dataQualityIssues')?.addEventListener('click', (event) => { const b=event.target.closest('[data-quality-action]'); if(b)openSource(b.dataset.qualityAction,b.dataset.qualityTarget||''); });
    ['notificationInboxSearch'].forEach((id) => el(id)?.addEventListener('input', scheduleInboxRender)); ['notificationInboxStatus','notificationInboxSeverity','notificationInboxModule'].forEach((id) => el(id)?.addEventListener('change', scheduleInboxRender));
    el('refreshNotificationInbox')?.addEventListener('click', async () => { try { await window.LSOCloud?.pollNow?.(); } catch {} window.LSODashboardNotifications?.renderNotifications?.(); scheduleInboxRender(20); });
    el('markAllInboxRead')?.addEventListener('click', markAllInboxRead);
    el('notificationInboxList')?.addEventListener('click', (event) => {
      const open=event.target.closest('[data-inbox-open]'), read=event.target.closest('[data-inbox-read]'), resolve=event.target.closest('[data-inbox-resolve]'), archive=event.target.closest('[data-inbox-archive]'); const fp=(open||read||resolve||archive)?.dataset?.inboxOpen || read?.dataset?.inboxRead || resolve?.dataset?.inboxResolve || archive?.dataset?.inboxArchive; if(!fp)return; const row=notificationRows().find((r)=>r.fingerprint===fp); if(!row)return;
      if(open){setNotificationStatus(fp,'read',true);window.LSODashboardNotifications?.performNotificationAction?.(row.actionType,row.targetId);}
      if(read)setNotificationStatus(fp,'read',!row.read); if(resolve)setNotificationStatus(fp,'resolved',!row.resolved); if(archive)setNotificationStatus(fp,'archived',!row.archived);
    });
    document.querySelector('[data-view="dataView"]')?.addEventListener('click', () => { setTimeout(() => { renderAuditTrail(); renderDataQuality(); }, 40); });
    
    document.querySelector('[data-view="systemHealthView"]')?.addEventListener('click', () => setTimeout(() => { permissionTemplateOptions(); renderMaintenanceSettings(); }, 50));
  }
  function scheduleAuditRender() { clearTimeout(auditRenderTimer); auditRenderTimer=setTimeout(()=>{if(window.LSORuntimeStability?.isViewActive?.('dataView'))renderAuditTrail();},100); }
  function scheduleQualityRender() { clearTimeout(qualityRenderTimer); qualityRenderTimer=setTimeout(()=>{qualityCache.at=0;if(window.LSORuntimeStability?.isViewActive?.('dataView'))renderDataQuality(true);window.LSODashboardNotifications?.renderNotifications?.();},180); }
  function wireEvents() {
    ['lso:members-changed','lso:operations-changed','lso:duty-hours-changed','lso:monthly-report-changed','lso:accounts-changed','lso:cloud-state-changed'].forEach((name)=>window.addEventListener(name,()=>{scheduleQualityRender();scheduleInboxRender(180);}));
    window.addEventListener('lso:audit-trail-changed', scheduleAuditRender);
    window.addEventListener('lso:auth-changed',()=>setTimeout(()=>{applyMaintenanceMode();renderMaintenanceSettings();permissionTemplateOptions();scheduleInboxRender(30);},120));
    window.addEventListener('lso:permissions-changed',()=>setTimeout(permissionTemplateOptions,50));
    window.addEventListener('lso:cloud-state-changed',(event)=>{if(!event.detail?.key||event.detail.key===KEYS.settings)applyMaintenanceMode();});
    window.addEventListener('focus',applyMaintenanceMode);
  }
  function initialize() {
    installAuditStorageInterceptor(); wireUi(); wireEvents(); renderMaintenanceSettings(); applyMaintenanceMode();
    setTimeout(()=>{if(window.LSORuntimeStability?.isViewActive?.('dataView')){renderAuditTrail();renderDataQuality();}window.LSODashboardNotifications?.renderNotifications?.();},350);
    window.dispatchEvent(new CustomEvent('lso:v61-ready',{detail:{version:VERSION}}));
  }

  window.LSONotificationInbox = { readState: readInboxState, saveReadState: saveReadStateFromDashboard, render: renderNotificationInbox, externalNotifications, setStatus: setNotificationStatus };
  window.LSOOperationsGovernanceV61 = { VERSION, scanDataQuality, renderDataQuality, renderAuditTrail, applyMaintenanceMode, maintenanceSettings, templates: TEMPLATE_DEFS, openSource };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once:true }); else initialize();
})();
