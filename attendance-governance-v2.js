(() => {
  'use strict';
  window.__LSO_ATTENDANCE_GOVERNANCE_VERSION__ = 'v2-month-semester-finalization';

  const EVENTS_KEY = 'lso_events_v2';
  const ATTENDANCE_KEY = 'lso_attendance_v2';
  const SETTINGS_KEY = 'lso_system_settings_v2';
  const GROUPS = ['Official Members', 'Trainee Members', 'Probationary Members'];
  const MODES = ['Current', 'Archive'];
  const SEMESTERS = ['First Semester', 'Second Semester'];
  const PERIOD_SETTINGS_KEY = 'attendancePeriodGovernance';
  const el = (id) => document.getElementById(id);

  let beforeSaveSnapshot = null;
  let saveAuditTimer = null;

  function safeText(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (char) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[char]));
  }

  function csvEscape(value) {
    const text = String(value ?? '');
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  }

  function uid(prefix = 'attendance-audit') {
    return window.crypto?.randomUUID?.() || `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function localISO(date = new Date()) {
    const offset = date.getTimezoneOffset();
    return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 10);
  }

  function today() {
    return window.LSOApp?.getToday?.() || localISO();
  }

  function dateLabel(value, includeTime = false) {
    if (!value) return '—';
    const date = new Date(String(value).length === 10 ? `${value}T00:00:00` : value);
    if (Number.isNaN(date.getTime())) return String(value);
    return new Intl.DateTimeFormat('en-PH', includeTime
      ? { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }
      : { year: 'numeric', month: 'short', day: 'numeric' }).format(date);
  }

  function currentAccount() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function isAdmin() {
    return currentAccount()?.role === 'Administrator';
  }

  function can(action) {
    return window.LSORoleAccess?.can?.(action) ?? isAdmin();
  }

  function canSaveDraftAttendance() { return can('saveDraftAttendance'); }
  function canFinalizeAttendance() { return can('finalizeAttendance'); }
  function canUnlockAttendance() { return can('unlockAttendance'); }

  function activeGroup() {
    const value = window.LSOOperations?.getAttendanceGroup?.() || window.LSOAttendanceGroup;
    const fallback = window.LSORoleAccess?.defaultAttendanceGroup?.(currentAccount()) || 'Official Members';
    const candidate = GROUPS.includes(value) ? value : fallback;
    return window.LSORoleAccess?.canUseAttendanceGroup?.(candidate, currentAccount()) === false ? fallback : candidate;
  }

  function activeMode() {
    const value = window.LSOOperations?.getAttendanceRosterMode?.() || window.LSOAttendanceRosterMode;
    return MODES.includes(value) ? value : 'Current';
  }

  function activeSemester() {
    const value = window.LSOOperations?.getAttendanceSemester?.() || window.LSOAttendanceSemester;
    return SEMESTERS.includes(value) ? value : 'First Semester';
  }


  function activeMonth() {
    const value = window.LSOOperations?.getAttendanceMonth?.() || window.LSOAttendanceMonth || today().slice(0, 7);
    return /^\d{4}-\d{2}$/.test(String(value)) ? String(value) : today().slice(0, 7);
  }

  function periodScopeKey(semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    return `${semester}::${group}::${mode}`;
  }

  function monthScopeKey(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    return `${periodScopeKey(semester, group, mode)}::${month}`;
  }

  function loadSystemSettings() {
    try {
      const parsed = JSON.parse(window.LSOStorage?.getItem(SETTINGS_KEY) || '{}');
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }

  function normalizePeriodGovernance(raw) {
    const value = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
    return {
      version: 1,
      semesterEndDates: value.semesterEndDates && typeof value.semesterEndDates === 'object' ? { ...value.semesterEndDates } : {},
      monthFinalizations: value.monthFinalizations && typeof value.monthFinalizations === 'object' ? { ...value.monthFinalizations } : {},
      semesterFinalizations: value.semesterFinalizations && typeof value.semesterFinalizations === 'object' ? { ...value.semesterFinalizations } : {}
    };
  }

  function loadPeriodGovernance() {
    return normalizePeriodGovernance(loadSystemSettings()[PERIOD_SETTINGS_KEY]);
  }

  function savePeriodGovernance(value) {
    const settings = loadSystemSettings();
    settings[PERIOD_SETTINGS_KEY] = normalizePeriodGovernance(value);
    window.LSOStorage?.setItem(SETTINGS_KEY, JSON.stringify(settings));
    window.dispatchEvent(new CustomEvent('lso:attendance-period-changed', { detail: { semester: activeSemester(), group: activeGroup(), month: activeMonth() } }));
    window.dispatchEvent(new CustomEvent('lso:operations-changed', { detail: { key: SETTINGS_KEY, source: 'attendance-period-governance' } }));
  }

  function periodActor() {
    const account = currentAccount();
    return account?.displayName || account?.username || 'Administrator';
  }

  function periodAudit(action, details = '', reason = '') {
    return { id: uid('attendance-period'), timestamp: new Date().toISOString(), action, details, reason, account: periodActor(), username: currentAccount()?.username || '', semester: activeSemester(), attendanceGroup: activeGroup(), rosterMode: activeMode(), month: activeMonth() };
  }

  function monthState(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    const data = loadPeriodGovernance();
    const raw = data.monthFinalizations[monthScopeKey(month, semester, group, mode)] || {};
    return {
      state: raw.state === 'Finalized' ? 'Finalized' : 'Draft',
      revision: Math.max(0, Number(raw.revision) || 0),
      finalizedAt: raw.finalizedAt || '', finalizedBy: raw.finalizedBy || '',
      reopenedAt: raw.reopenedAt || '', reopenedBy: raw.reopenedBy || '',
      snapshot: raw.snapshot && typeof raw.snapshot === 'object' ? raw.snapshot : null,
      history: Array.isArray(raw.history) ? raw.history : []
    };
  }

  function semesterState(semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    const data = loadPeriodGovernance();
    const raw = data.semesterFinalizations[periodScopeKey(semester, group, mode)] || {};
    return {
      state: raw.state === 'Finalized' ? 'Finalized' : 'Draft',
      revision: Math.max(0, Number(raw.revision) || 0),
      finalizedAt: raw.finalizedAt || '', finalizedBy: raw.finalizedBy || '',
      reopenedAt: raw.reopenedAt || '', reopenedBy: raw.reopenedBy || '',
      endDate: raw.endDate || data.semesterEndDates[semester] || '',
      snapshot: raw.snapshot && typeof raw.snapshot === 'object' ? raw.snapshot : null,
      history: Array.isArray(raw.history) ? raw.history : []
    };
  }

  function eventGroup(event) {
    return window.LSOOperations?.getEventAttendanceGroup?.(event) || event?.attendanceGroup || 'Official Members';
  }

  function eventBelongsToActiveGroup(event, group = activeGroup()) {
    if (window.LSOOperations?.eventBelongsToAttendanceGroup) return window.LSOOperations.eventBelongsToAttendanceGroup(event, group);
    return eventGroup(event) === group;
  }

  function scopedMonthEvents(month = activeMonth(), semester = activeSemester(), group = activeGroup()) {
    return getEvents().filter((event) =>
      (event.semester || 'First Semester') === semester &&
      eventBelongsToActiveGroup(event, group) &&
      String(event.date || '').slice(0, 7) === month &&
      (!event.date || event.date <= today())
    ).sort((a, b) => String(a.date).localeCompare(String(b.date)));
  }

  function statusSnapshot(records) {
    const counts = statusCounts(records);
    return { counts, rate: rateFromCounts(counts), counted: counts.Present + counts.Late + counts.Absent };
  }

  function calculateMonthSnapshot(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode(), attendanceOverride = null) {
    const events = scopedMonthEvents(month, semester, group);
    const eventIds = new Set(events.map((event) => event.id));
    const records = (attendanceOverride || getAttendance()).filter((record) => eventIds.has(record.eventId) && (record.attendanceGroup || group) === group && (record.rosterModeAtEdit || 'Current') === mode && record.status);
    const memberIds = [...new Set(records.map((record) => record.memberId))];
    const members = {};
    memberIds.forEach((memberId) => {
      const memberRecords = records.filter((record) => record.memberId === memberId);
      const result = statusSnapshot(memberRecords);
      members[memberId] = { ...result, eventCount: memberRecords.length, memberName: memberName(memberId) };
    });
    const overall = statusSnapshot(records);
    const ratedMembers = Object.values(members).filter((item) => item.rate !== null);
    const averageMemberRate = ratedMembers.length ? Math.round(ratedMembers.reduce((sum, item) => sum + item.rate, 0) / ratedMembers.length) : null;
    return { month, semester, attendanceGroup: group, rosterMode: mode, eventIds: [...eventIds], eventCount: events.length, recordCount: records.length, counts: overall.counts, pooledRate: overall.rate, groupRate: averageMemberRate, members, calculatedAt: new Date().toISOString() };
  }

  function finalizedMonthsForSemester(semester = activeSemester(), group = activeGroup(), mode = activeMode(), endDate = '') {
    const data = loadPeriodGovernance();
    const prefix = `${periodScopeKey(semester, group, mode)}::`;
    const endMonth = String(endDate || data.semesterEndDates[semester] || '9999-12-31').slice(0, 7);
    return Object.entries(data.monthFinalizations)
      .filter(([key, value]) => key.startsWith(prefix) && value?.state === 'Finalized' && key.slice(prefix.length) <= endMonth && value.snapshot)
      .map(([key, value]) => ({ month: key.slice(prefix.length), ...value.snapshot }))
      .sort((a, b) => a.month.localeCompare(b.month));
  }

  function calculateSemesterSnapshot(semester = activeSemester(), group = activeGroup(), mode = activeMode(), endDate = '') {
    const months = finalizedMonthsForSemester(semester, group, mode, endDate);
    const memberIds = [...new Set(months.flatMap((month) => Object.keys(month.members || {})))];
    const members = {};
    memberIds.forEach((memberId) => {
      const rates = months.map((month) => month.members?.[memberId]?.rate).filter((rate) => Number.isFinite(rate));
      members[memberId] = { memberName: memberName(memberId), monthlyRates: months.map((month) => ({ month: month.month, rate: month.members?.[memberId]?.rate ?? null })), rate: rates.length ? Math.round(rates.reduce((sum, rate) => sum + rate, 0) / rates.length) : null, monthsCounted: rates.length };
    });
    const monthRates = months.map((month) => month.groupRate).filter((rate) => Number.isFinite(rate));
    return { semester, attendanceGroup: group, rosterMode: mode, endDate: endDate || loadPeriodGovernance().semesterEndDates[semester] || '', monthCount: months.length, months: months.map((month) => ({ month: month.month, groupRate: month.groupRate, eventCount: month.eventCount })), groupRate: monthRates.length ? Math.round(monthRates.reduce((sum, rate) => sum + rate, 0) / monthRates.length) : null, members, calculatedAt: new Date().toISOString(), calculationMethod: 'Arithmetic mean of finalized monthly ratings' };
  }

  function workflowKey(group = activeGroup(), mode = activeMode()) {
    return `${group}::${mode}`;
  }

  function normalizeWorkflow(raw) {
    const history = Array.isArray(raw?.history) ? raw.history : [];
    return {
      state: raw?.state === 'Finalized' ? 'Finalized' : 'Draft',
      finalizedAt: raw?.finalizedAt || '',
      finalizedBy: raw?.finalizedBy || '',
      unlockedAt: raw?.unlockedAt || '',
      unlockedBy: raw?.unlockedBy || '',
      revision: Math.max(0, Number(raw?.revision) || 0),
      history
    };
  }

  function getWorkflow(event, group = activeGroup(), mode = activeMode()) {
    if (!event) return normalizeWorkflow(null);
    return normalizeWorkflow(event.attendanceWorkflows?.[workflowKey(group, mode)]);
  }

  function workflowState(event, group = activeGroup(), mode = activeMode()) {
    if (event?.date && monthState(String(event.date).slice(0, 7), event.semester || activeSemester(), group, mode).state === 'Finalized') return 'Finalized';
    return getWorkflow(event, group, mode).state;
  }

  function getEvents() {
    return window.LSOOperations?.getEvents?.() || [];
  }

  function getAttendance() {
    return window.LSOOperations?.getAttendance?.() || [];
  }

  function getMembers() {
    return window.LSOApp?.getMembers?.() || [];
  }

  function selectedEventId() {
    return window.LSOOperations?.getSelectedEventId?.() || document.querySelector('.event-card.active')?.dataset.eventId || '';
  }

  function selectedEvent() {
    const id = selectedEventId();
    return getEvents().find((event) => event.id === id) || null;
  }

  function memberName(memberId) {
    return getMembers().find((member) => member.id === memberId)?.fullName || memberId || 'Unknown member';
  }

  function auditActor() {
    const account = currentAccount();
    return {
      account: account?.displayName || account?.username || 'Administrator',
      username: account?.username || ''
    };
  }

  function auditEntry(action, details = '', reason = '') {
    const actor = auditActor();
    return {
      id: uid(),
      timestamp: new Date().toISOString(),
      action,
      details,
      reason,
      account: actor.account,
      username: actor.username,
      attendanceGroup: activeGroup(),
      rosterMode: activeMode(),
      semester: activeSemester()
    };
  }

  function updateWorkflow(event, updater) {
    const next = clone(event);
    const key = workflowKey();
    const workflows = next.attendanceWorkflows && typeof next.attendanceWorkflows === 'object'
      ? clone(next.attendanceWorkflows)
      : {};
    const current = normalizeWorkflow(workflows[key]);
    const updated = normalizeWorkflow(updater(current));
    updated.history = Array.isArray(updater.__history)
      ? updater.__history
      : (Array.isArray(updated.history) ? updated.history.slice(0, 100) : []);
    workflows[key] = updated;
    next.attendanceWorkflows = workflows;
    return next;
  }

  function persistWorkflow(event, nextWorkflow) {
    const nextEvent = clone(event);
    const workflows = nextEvent.attendanceWorkflows && typeof nextEvent.attendanceWorkflows === 'object'
      ? clone(nextEvent.attendanceWorkflows)
      : {};
    workflows[workflowKey()] = normalizeWorkflow(nextWorkflow);
    nextEvent.attendanceWorkflows = workflows;
    return window.LSOOperations?.updateEventRecord?.(nextEvent) !== false;
  }

  function scopedAttendanceRecords(eventId = selectedEventId()) {
    return getAttendance().filter((entry) =>
      entry.eventId === eventId &&
      (entry.attendanceGroup || activeGroup()) === activeGroup() &&
      (entry.rosterModeAtEdit || 'Current') === activeMode()
    );
  }

  function rosterMembers() {
    return window.LSOOperations?.getAttendanceRosterMembers?.(selectedEventId()) || [];
  }

  function statusCounts(records) {
    const counts = { Present: 0, Late: 0, Absent: 0, Excused: 0, 'Not Required': 0 };
    records.forEach((record) => {
      if (Object.prototype.hasOwnProperty.call(counts, record.status)) counts[record.status] += 1;
    });
    return counts;
  }

  function rateFromCounts(counts) {
    const denominator = counts.Present + counts.Late + counts.Absent;
    return denominator ? Math.round(((counts.Present + counts.Late) / denominator) * 100) : null;
  }

  function attendanceRecordSignature(records) {
    return JSON.stringify(records
      .map((record) => ({ memberId: record.memberId, status: record.status || '', remarks: record.remarks || '' }))
      .sort((a, b) => String(a.memberId).localeCompare(String(b.memberId))));
  }

  function appendDraftSaveAudit(beforeRecords) {
    const event = selectedEvent();
    if (!event || workflowState(event) === 'Finalized') return;
    const afterRecords = scopedAttendanceRecords();
    if (attendanceRecordSignature(beforeRecords || []) === attendanceRecordSignature(afterRecords)) return;

    const beforeMap = new Map((beforeRecords || []).map((record) => [record.memberId, record]));
    const afterMap = new Map(afterRecords.map((record) => [record.memberId, record]));
    const ids = new Set([...beforeMap.keys(), ...afterMap.keys()]);
    let changed = 0;
    ids.forEach((id) => {
      const before = beforeMap.get(id) || {};
      const after = afterMap.get(id) || {};
      if ((before.status || '') !== (after.status || '') || (before.remarks || '') !== (after.remarks || '')) changed += 1;
    });

    const workflow = getWorkflow(event);
    workflow.state = 'Draft';
    workflow.history.unshift(auditEntry('Draft saved', `${changed} member attendance record${changed === 1 ? '' : 's'} changed.`));
    workflow.history = workflow.history.slice(0, 100);
    persistWorkflow(event, workflow);
  }

  function finalizeAttendance() {
    if (!canFinalizeAttendance()) {
      window.LSOApp?.showToast?.('Only the Administrator can finalize attendance.', true);
      return;
    }
    const event = selectedEvent();
    if (!event) return;
    if (event.date && event.date > today()) {
      window.LSOApp?.showToast?.('A future event cannot be finalized.', true);
      return;
    }
    if (workflowState(event) === 'Finalized') {
      window.LSOApp?.showToast?.('This attendance roster is already finalized.', true);
      return;
    }

    const members = rosterMembers();
    if (!members.length) {
      window.LSOApp?.showToast?.('There are no members in this roster to finalize.', true);
      return;
    }
    const currentRecords = getAttendance();
    const recordMap = new Map(scopedAttendanceRecords(event.id).map((record) => [record.memberId, record]));
    const missing = members.filter((member) => !recordMap.get(member.id)?.status);
    const message = missing.length
      ? `Finalize this attendance roster? ${missing.length} unmarked member${missing.length === 1 ? '' : 's'} will automatically be recorded as Absent. The roster will then be locked.`
      : 'Finalize and lock this attendance roster? The Administrator can unlock it later when a correction is required.';
    if (!window.confirm(message)) return;

    const now = new Date().toISOString();
    const actor = auditActor();
    const nextAttendance = currentRecords.map((record) => ({ ...record }));
    missing.forEach((member) => {
      const index = nextAttendance.findIndex((record) =>
        record.eventId === event.id &&
        record.memberId === member.id &&
        (record.attendanceGroup || activeGroup()) === activeGroup() &&
        (record.rosterModeAtEdit || 'Current') === activeMode()
      );
      const existing = index >= 0 ? nextAttendance[index] : {};
      const nextRecord = {
        ...existing,
        eventId: event.id,
        memberId: member.id,
        status: 'Absent',
        remarks: existing.remarks || 'Automatically marked Absent during attendance finalization.',
        attendanceGroup: activeGroup(),
        rosterModeAtEdit: activeMode(),
        createdAt: existing.createdAt || now,
        updatedAt: now,
        updatedBy: actor.account
      };
      if (index >= 0) nextAttendance[index] = nextRecord;
      else nextAttendance.push(nextRecord);
    });

    const finalRecords = nextAttendance.filter((record) =>
      record.eventId === event.id &&
      (record.attendanceGroup || activeGroup()) === activeGroup() &&
      (record.rosterModeAtEdit || 'Current') === activeMode()
    );
    const counts = statusCounts(finalRecords);
    const workflow = getWorkflow(event);
    workflow.state = 'Finalized';
    workflow.finalizedAt = now;
    workflow.finalizedBy = actor.account;
    workflow.revision += 1;
    workflow.history.unshift(auditEntry(
      'Attendance finalized',
      `${members.length} roster members • ${counts.Present} Present • ${counts.Late} Late • ${counts.Absent} Absent • ${counts.Excused} Excused.`,
      missing.length ? `${missing.length} unmarked member${missing.length === 1 ? '' : 's'} automatically marked Absent.` : ''
    ));
    workflow.history = workflow.history.slice(0, 100);

    window.LSOOperations?.replaceAttendance?.(nextAttendance);
    persistWorkflow(event, workflow);
    window.LSOOperations?.logActivity?.('Finalized attendance', 'Attendance Audit', `${event.title} • ${activeGroup()} • ${activeMode()} • revision ${workflow.revision}`);
    window.LSOApp?.showToast?.('Attendance finalized and locked.');
    setTimeout(render, 60);
  }

  function unlockAttendance() {
    if (!canUnlockAttendance()) {
      window.LSOApp?.showToast?.('Only the Administrator can unlock attendance.', true);
      return;
    }
    const event = selectedEvent();
    if (!event || workflowState(event) !== 'Finalized') return;
    const eventMonth = String(event.date || '').slice(0, 7);
    if (eventMonth && monthState(eventMonth, event.semester || activeSemester(), activeGroup(), activeMode()).state === 'Finalized') {
      window.LSOApp?.showToast?.('This event belongs to a finalized month. Reopen the whole month before editing any attendance record.', true);
      return;
    }
    const reason = window.prompt('Enter the reason for unlocking this finalized attendance roster:');
    if (reason === null) return;
    if (reason.trim().length < 3) {
      window.LSOApp?.showToast?.('Please enter a clear reason before unlocking attendance.', true);
      return;
    }
    const now = new Date().toISOString();
    const actor = auditActor();
    const workflow = getWorkflow(event);
    workflow.state = 'Draft';
    workflow.unlockedAt = now;
    workflow.unlockedBy = actor.account;
    workflow.history.unshift(auditEntry('Unlocked for editing', 'Finalized attendance was reopened for an administrator correction.', reason.trim()));
    workflow.history = workflow.history.slice(0, 100);
    persistWorkflow(event, workflow);
    window.LSOOperations?.logActivity?.('Unlocked finalized attendance', 'Attendance Audit', `${event.title} • ${activeGroup()} • ${activeMode()} • ${reason.trim()}`);
    window.LSOApp?.showToast?.('Attendance unlocked. Save corrections, then finalize it again.');
    setTimeout(render, 60);
  }


  function finalizeMonth() {
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can finalize a monthly attendance period.', true);
    const month = activeMonth();
    const events = scopedMonthEvents(month);
    if (!events.length) return window.LSOApp?.showToast?.('There are no completed activities in this calendar month to finalize.', true);
    if (monthState(month).state === 'Finalized') return window.LSOApp?.showToast?.('This monthly attendance period is already finalized.', true);
    if (!window.confirm(`Finalize ${month} for ${activeGroup()}? Unmarked roster entries will be recorded as Absent and the whole month will be locked.`)) return;
    let nextAttendance = getAttendance().map((record) => ({ ...record }));
    const now = new Date().toISOString();
    const actor = periodActor();
    events.forEach((event) => {
      const roster = window.LSOOperations?.getAttendanceRosterMembers?.(event.id) || [];
      roster.forEach((member) => {
        const index = nextAttendance.findIndex((record) => record.eventId === event.id && record.memberId === member.id && (record.attendanceGroup || activeGroup()) === activeGroup() && (record.rosterModeAtEdit || 'Current') === activeMode());
        const existing = index >= 0 ? nextAttendance[index] : {};
        if (existing.status) return;
        const record = { ...existing, eventId: event.id, memberId: member.id, status: 'Absent', remarks: existing.remarks || 'Automatically marked Absent during monthly finalization.', attendanceGroup: activeGroup(), rosterModeAtEdit: activeMode(), createdAt: existing.createdAt || now, updatedAt: now, updatedBy: actor };
        if (index >= 0) nextAttendance[index] = record; else nextAttendance.push(record);
      });
    });
    window.LSOOperations?.replaceAttendance?.(nextAttendance);
    events.forEach((event) => {
      const nextEvent = clone(event);
      const workflows = nextEvent.attendanceWorkflows && typeof nextEvent.attendanceWorkflows === 'object' ? clone(nextEvent.attendanceWorkflows) : {};
      const key = workflowKey();
      const workflow = normalizeWorkflow(workflows[key]);
      workflow.state = 'Finalized'; workflow.finalizedAt = now; workflow.finalizedBy = actor; workflow.revision += 1;
      workflow.history.unshift(periodAudit('Event included in monthly finalization', `${event.title} • ${month}`));
      workflow.history = workflow.history.slice(0, 100); workflows[key] = workflow; nextEvent.attendanceWorkflows = workflows;
      window.LSOOperations?.updateEventRecord?.(nextEvent);
    });
    const data = loadPeriodGovernance();
    const key = monthScopeKey(month);
    const current = monthState(month);
    data.monthFinalizations[key] = { state: 'Finalized', revision: current.revision + 1, finalizedAt: now, finalizedBy: actor, reopenedAt: '', reopenedBy: '', snapshot: calculateMonthSnapshot(month, activeSemester(), activeGroup(), activeMode(), nextAttendance), history: [periodAudit('Monthly attendance finalized', `${events.length} activit${events.length === 1 ? 'y' : 'ies'} locked and rated.`), ...current.history].slice(0, 100) };
    // A changed month invalidates an older semestral snapshot.
    const semesterKey = periodScopeKey();
    if (data.semesterFinalizations[semesterKey]?.state === 'Finalized') data.semesterFinalizations[semesterKey] = { ...data.semesterFinalizations[semesterKey], state: 'Draft', reopenedAt: now, reopenedBy: actor, snapshot: null, history: [periodAudit('Semester snapshot invalidated', `Monthly attendance ${month} was finalized or revised.`), ...(data.semesterFinalizations[semesterKey].history || [])].slice(0, 100) };
    savePeriodGovernance(data);
    window.LSOOperations?.logActivity?.('Finalized monthly attendance', 'Attendance Audit', `${month} • ${activeSemester()} • ${activeGroup()} • ${events.length} activities`);
    window.LSOApp?.showToast?.('Monthly attendance finalized. Its rating is now isolated from other months.');
    setTimeout(() => { window.LSOOperations?.refreshAll?.(); render(); }, 80);
  }

  function reopenMonth() {
    if (!canUnlockAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can reopen a finalized month.', true);
    const month = activeMonth(); const current = monthState(month);
    if (current.state !== 'Finalized') return;
    const reason = window.prompt('Enter the reason for reopening this finalized month:');
    if (reason === null) return; if (reason.trim().length < 3) return window.LSOApp?.showToast?.('A clear correction reason is required.', true);
    const now = new Date().toISOString(); const actor = periodActor();
    scopedMonthEvents(month).forEach((event) => {
      const nextEvent = clone(event); const workflows = nextEvent.attendanceWorkflows && typeof nextEvent.attendanceWorkflows === 'object' ? clone(nextEvent.attendanceWorkflows) : {};
      const key = workflowKey(); const workflow = normalizeWorkflow(workflows[key]); workflow.state = 'Draft'; workflow.unlockedAt = now; workflow.unlockedBy = actor;
      workflow.history.unshift(periodAudit('Event reopened with month', event.title, reason.trim())); workflow.history = workflow.history.slice(0, 100); workflows[key] = workflow; nextEvent.attendanceWorkflows = workflows;
      window.LSOOperations?.updateEventRecord?.(nextEvent);
    });
    const data = loadPeriodGovernance(); const key = monthScopeKey(month);
    data.monthFinalizations[key] = { ...current, state: 'Draft', reopenedAt: now, reopenedBy: actor, snapshot: null, history: [periodAudit('Monthly attendance reopened', `${month} reopened for correction.`, reason.trim()), ...current.history].slice(0, 100) };
    const semesterKey = periodScopeKey();
    if (data.semesterFinalizations[semesterKey]) data.semesterFinalizations[semesterKey] = { ...data.semesterFinalizations[semesterKey], state: 'Draft', snapshot: null, reopenedAt: now, reopenedBy: actor, history: [periodAudit('Semester snapshot invalidated', `Month ${month} was reopened.`, reason.trim()), ...(data.semesterFinalizations[semesterKey].history || [])].slice(0, 100) };
    savePeriodGovernance(data); window.LSOOperations?.logActivity?.('Reopened monthly attendance', 'Attendance Audit', `${month} • ${activeGroup()} • ${reason.trim()}`); window.LSOApp?.showToast?.('Monthly attendance reopened for correction.'); setTimeout(() => { window.LSOOperations?.refreshAll?.(); render(); }, 80);
  }

  function saveSemesterEndDate() {
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can set the semester completion date.', true);
    const input = el('attendanceSemesterEndDate'); const value = input?.value || '';
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return window.LSOApp?.showToast?.('Enter a valid semester completion date.', true);
    const data = loadPeriodGovernance(); data.semesterEndDates[activeSemester()] = value; savePeriodGovernance(data); window.LSOApp?.showToast?.(`${activeSemester()} completion date saved.`); render();
  }

  function finalizeSemester() {
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can finalize a semester rating.', true);
    const data = loadPeriodGovernance(); const endDate = data.semesterEndDates[activeSemester()] || '';
    if (!endDate) return window.LSOApp?.showToast?.('Enter and save the semester completion date first.', true);
    if (endDate > today()) return window.LSOApp?.showToast?.('The semester cannot be finalized before its completion date.', true);
    const eventMonths = [...new Set(getEvents().filter((event) => (event.semester || 'First Semester') === activeSemester() && eventBelongsToActiveGroup(event) && event.date && event.date <= endDate).map((event) => event.date.slice(0, 7)))].sort();
    if (!eventMonths.length) return window.LSOApp?.showToast?.('No attendance activities are available for this semester.', true);
    const unfinished = eventMonths.filter((month) => monthState(month).state !== 'Finalized');
    if (unfinished.length) return window.LSOApp?.showToast?.(`Finalize these monthly attendance periods first: ${unfinished.join(', ')}.`, true);
    const snapshot = calculateSemesterSnapshot(activeSemester(), activeGroup(), activeMode(), endDate);
    if (!snapshot.monthCount) return window.LSOApp?.showToast?.('No finalized monthly ratings are available for the semester.', true);
    if (!window.confirm(`Finalize ${activeSemester()} for ${activeGroup()} using ${snapshot.monthCount} finalized monthly rating${snapshot.monthCount === 1 ? '' : 's'}?`)) return;
    const key = periodScopeKey(); const current = semesterState(); const now = new Date().toISOString();
    data.semesterFinalizations[key] = { state: 'Finalized', revision: current.revision + 1, finalizedAt: now, finalizedBy: periodActor(), reopenedAt: '', reopenedBy: '', endDate, snapshot, history: [periodAudit('Semester attendance finalized', `${snapshot.monthCount} finalized monthly ratings • ${snapshot.groupRate ?? 'No'}% overall.`), ...current.history].slice(0, 100) };
    savePeriodGovernance(data); window.LSOOperations?.logActivity?.('Finalized semester attendance', 'Attendance Audit', `${activeSemester()} • ${activeGroup()} • ${snapshot.monthCount} months • ${snapshot.groupRate ?? '—'}%`); window.LSOApp?.showToast?.('Semester attendance rating finalized.'); render();
  }

  function reopenSemester() {
    if (!canUnlockAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can reopen a semester rating.', true);
    const current = semesterState(); if (current.state !== 'Finalized') return;
    const reason = window.prompt('Enter the reason for reopening the finalized semester rating:'); if (reason === null) return; if (reason.trim().length < 3) return window.LSOApp?.showToast?.('A clear correction reason is required.', true);
    const data = loadPeriodGovernance(); const key = periodScopeKey(); const now = new Date().toISOString();
    data.semesterFinalizations[key] = { ...current, state: 'Draft', snapshot: null, reopenedAt: now, reopenedBy: periodActor(), history: [periodAudit('Semester attendance reopened', 'Semester rating reopened for recalculation.', reason.trim()), ...current.history].slice(0, 100) };
    savePeriodGovernance(data); window.LSOApp?.showToast?.('Semester attendance rating reopened.'); render();
  }

  function renderPeriodCenter() {
    const panel = el('attendancePeriodFinalizationCenter'); if (!panel) return;
    const month = monthState(); const data = loadPeriodGovernance(); const semester = semesterState(); const preview = semester.state === 'Finalized' && semester.snapshot ? semester.snapshot : calculateSemesterSnapshot(activeSemester(), activeGroup(), activeMode(), data.semesterEndDates[activeSemester()] || '');
    const monthSnapshot = month.state === 'Finalized' && month.snapshot ? month.snapshot : calculateMonthSnapshot();
    if (el('attendanceMonthFinalizationBadge')) { el('attendanceMonthFinalizationBadge').textContent = month.state; el('attendanceMonthFinalizationBadge').className = `badge ${month.state === 'Finalized' ? 'badge-green' : 'badge-gold'}`; }
    if (el('attendanceMonthFinalizationTitle')) el('attendanceMonthFinalizationTitle').textContent = `${activeMonth()} • ${activeGroup()}`;
    if (el('attendanceMonthFinalizationMeta')) el('attendanceMonthFinalizationMeta').textContent = month.state === 'Finalized' ? `Final rating ${monthSnapshot.groupRate ?? '—'}% • ${monthSnapshot.eventCount} activities • Revision ${month.revision}` : `${monthSnapshot.eventCount} activities • Draft monthly rating ${monthSnapshot.groupRate ?? '—'}%`;
    el('finalizeAttendanceMonthButton')?.classList.toggle('hidden', month.state === 'Finalized' || !canFinalizeAttendance());
    el('reopenAttendanceMonthButton')?.classList.toggle('hidden', month.state !== 'Finalized' || !canUnlockAttendance());
    const endDate = data.semesterEndDates[activeSemester()] || ''; if (el('attendanceSemesterEndDate')) el('attendanceSemesterEndDate').value = endDate;
    if (el('attendanceSemesterFinalizationBadge')) { el('attendanceSemesterFinalizationBadge').textContent = semester.state; el('attendanceSemesterFinalizationBadge').className = `badge ${semester.state === 'Finalized' ? 'badge-green' : 'badge-gold'}`; }
    if (el('attendanceSemesterRatingValue')) el('attendanceSemesterRatingValue').textContent = preview.groupRate == null ? '—' : `${preview.groupRate}%`;
    if (el('attendanceSemesterRatingMeta')) el('attendanceSemesterRatingMeta').textContent = `${preview.monthCount || 0} finalized month${preview.monthCount === 1 ? '' : 's'} • Average of monthly ratings${endDate ? ` • Ends ${dateLabel(endDate)}` : ' • End date not set'}`;
    el('finalizeAttendanceSemesterButton')?.classList.toggle('hidden', semester.state === 'Finalized' || !canFinalizeAttendance());
    el('reopenAttendanceSemesterButton')?.classList.toggle('hidden', semester.state !== 'Finalized' || !canUnlockAttendance());
    const table = el('attendanceSemesterMonthlyRatesBody');
    if (table) table.innerHTML = preview.months?.length ? preview.months.map((item) => `<tr><td>${safeText(item.month)}</td><td>${safeText(item.eventCount)}</td><td><span class="badge ${item.groupRate == null ? 'badge-gray' : item.groupRate >= 80 ? 'badge-green' : item.groupRate >= 60 ? 'badge-gold' : 'badge-red'}">${item.groupRate == null ? 'No rate' : `${item.groupRate}%`}</span></td><td>Finalized</td></tr>`).join('') : '<tr><td colspan="4"><div class="empty-state compact-empty"><h4>No finalized monthly ratings</h4><p>Finalize each calendar month before completing the semester.</p></div></td></tr>';
  }

  function renderGovernance() {
    const event = selectedEvent();
    const container = el('attendanceGovernancePanel');
    if (!container) return;
    container.classList.toggle('hidden', !event);
    if (!event) return;

    const workflow = getWorkflow(event);
    const eventMonth = String(event.date || '').slice(0, 7);
    const monthlyLocked = Boolean(eventMonth) && monthState(eventMonth, event.semester || activeSemester(), activeGroup(), activeMode()).state === 'Finalized';
    const finalized = monthlyLocked || workflow.state === 'Finalized';
    const badge = el('attendanceWorkflowStatusBadge');
    if (badge) {
      badge.textContent = workflow.state;
      badge.className = `badge ${finalized ? 'badge-green' : 'badge-gold'}`;
    }
    if (el('attendanceWorkflowStatusTitle')) {
      el('attendanceWorkflowStatusTitle').textContent = monthlyLocked ? 'This entire attendance month is finalized and locked' : finalized ? 'Attendance is finalized and locked' : 'Attendance is open as a draft';
    }
    if (el('attendanceWorkflowStatusMeta')) {
      el('attendanceWorkflowStatusMeta').textContent = monthlyLocked
        ? `Monthly rating finalized for ${eventMonth}. Reopen the whole month to correct this activity.`
        : finalized
          ? `Finalized by ${workflow.finalizedBy || 'Administrator'} on ${dateLabel(workflow.finalizedAt, true)} • Revision ${workflow.revision}`
          : workflow.unlockedAt
          ? `Unlocked by ${workflow.unlockedBy || 'Administrator'} on ${dateLabel(workflow.unlockedAt, true)} • Save corrections and finalize again.`
          : 'Changes remain editable until an Administrator finalizes this roster.';
    }

    const finalizeButton = el('finalizeAttendanceButton');
    const unlockButton = el('unlockAttendanceButton');
    if (finalizeButton) finalizeButton.classList.toggle('hidden', finalized || monthlyLocked || !canFinalizeAttendance());
    if (unlockButton) unlockButton.classList.toggle('hidden', !finalized || monthlyLocked || !canUnlockAttendance());

    ['markAllPresent', 'saveAttendanceButton'].forEach((id) => {
      const button = el(id);
      if (!button) return;
      button.disabled = finalized;
      button.setAttribute('aria-disabled', finalized ? 'true' : 'false');
      button.title = finalized ? 'Unlock this attendance roster before editing.' : '';
    });
    document.querySelectorAll('.attendance-status, .attendance-remarks').forEach((control) => {
      control.disabled = finalized || !canSaveDraftAttendance();
      control.classList.toggle('attendance-locked-control', finalized);
      control.title = finalized ? 'Finalized attendance is locked. An Administrator may unlock it for corrections.' : '';
    });

    const history = el('attendanceAuditHistory');
    const empty = el('attendanceAuditEmpty');
    if (history) {
      history.innerHTML = workflow.history.slice(0, 12).map((entry) => `
        <div class="attendance-audit-row">
          <span class="attendance-audit-dot" aria-hidden="true"></span>
          <div><strong>${safeText(entry.action || 'Attendance activity')}</strong><small>${safeText(entry.details || '')}</small>${entry.reason ? `<em>Reason: ${safeText(entry.reason)}</em>` : ''}</div>
          <div class="attendance-audit-meta"><span>${safeText(entry.account || 'Administrator')}</span><time>${safeText(dateLabel(entry.timestamp, true))}</time></div>
        </div>`).join('');
    }
    if (empty) empty.classList.toggle('hidden', Boolean(workflow.history.length));
  }

  function relevantEventsForMember(memberId) {
    const eventMap = new Map(getEvents().map((event) => [event.id, event]));
    const records = getAttendance()
      .filter((record) => record.memberId === memberId)
      .filter((record) => (record.attendanceGroup || activeGroup()) === activeGroup())
      .filter((record) => (record.rosterModeAtEdit || 'Current') === activeMode())
      .map((record) => ({ record, event: eventMap.get(record.eventId) }))
      .filter((item) => item.event && (item.event.semester || 'First Semester') === activeSemester() && eventBelongsToActiveGroup(item.event) && String(item.event.date || '').slice(0, 7) === activeMonth())
      .sort((a, b) => String(a.event.date).localeCompare(String(b.event.date)));
    return records;
  }

  function memberSignals(memberId, threshold = 75) {
    const items = relevantEventsForMember(memberId);
    const counted = items.filter(({ record }) => ['Present', 'Late', 'Absent'].includes(record.status));
    const counts = statusCounts(items.map(({ record }) => record));
    const workingRate = rateFromCounts(counts);
    const month = monthState();
    const finalizedItems = items.filter(({ record, event }) => String(event.date || '').slice(0, 7) === activeMonth() && workflowState(event, record.attendanceGroup || activeGroup(), record.rosterModeAtEdit || 'Current') === 'Finalized');
    const finalizedCounts = statusCounts(finalizedItems.map(({ record }) => record));
    const verifiedRate = month.state === 'Finalized' && month.snapshot?.members?.[memberId]
      ? month.snapshot.members[memberId].rate
      : rateFromCounts(finalizedCounts);
    let absenceStreak = 0;
    for (let index = counted.length - 1; index >= 0; index -= 1) {
      if (counted[index].record.status !== 'Absent') break;
      absenceStreak += 1;
    }
    const onTimeDenominator = counts.Present + counts.Late;
    const onTimeRate = onTimeDenominator ? Math.round((counts.Present / onTimeDenominator) * 100) : null;
    const risks = [];
    const rateForRisk = verifiedRate ?? workingRate;
    if (rateForRisk !== null && counted.length >= 3 && rateForRisk < Number(threshold || 75)) risks.push(`Attendance rate is below ${threshold}%`);
    if (absenceStreak >= 2) risks.push(`${absenceStreak} consecutive absences`);
    if (counts.Late >= 3) risks.push(`${counts.Late} Late records`);
    const draftCount = new Set(items
      .filter(({ record, event }) => workflowState(event, record.attendanceGroup || activeGroup(), record.rosterModeAtEdit || 'Current') !== 'Finalized')
      .map(({ event }) => event.id)).size;
    return {
      totalRecords: items.length,
      counted: counted.length,
      counts,
      workingRate,
      verifiedRate,
      finalizedRecordCount: finalizedItems.length,
      draftEventCount: draftCount,
      absenceStreak,
      lateCount: counts.Late,
      onTimeRate,
      risks,
      items
    };
  }

  function renderVerificationMetrics() {
    const container = el('attendanceVerificationMetrics');
    if (!container) return;
    const events = scopedMonthEvents(activeMonth(), activeSemester(), activeGroup());
    const relevant = events.filter((event) => {
      const records = getAttendance().filter((record) => record.eventId === event.id);
      return records.some((record) => (record.attendanceGroup || activeGroup()) === activeGroup() && (record.rosterModeAtEdit || 'Current') === activeMode());
    });
    const finalized = relevant.filter((event) => workflowState(event) === 'Finalized').length;
    const drafts = relevant.length - finalized;
    const records = relevant.flatMap((event) => getAttendance().filter((record) =>
      record.eventId === event.id &&
      (record.attendanceGroup || activeGroup()) === activeGroup() &&
      (record.rosterModeAtEdit || 'Current') === activeMode()
    ));
    const unresolved = records.filter((record) => !record.status).length;
    const coverage = relevant.length ? Math.round((finalized / relevant.length) * 100) : null;
    container.innerHTML = [
      ['Finalized Events', finalized, `${relevant.length} recorded events`],
      ['Draft Events', drafts, drafts ? 'Requires administrator review' : 'No pending finalization'],
      ['Verification Coverage', coverage === null ? '—' : `${coverage}%`, 'Finalized ÷ recorded events'],
      ['Unmarked Records', unresolved, unresolved ? 'Resolve before finalization' : 'All saved records have status']
    ].map(([label, value, helper]) => `<div class="attendance-kpi"><span>${safeText(label)}</span><strong>${safeText(value)}</strong><small>${safeText(helper)}</small></div>`).join('');
  }

  function renderIndividualRiskSignals() {
    const container = el('individualAttendanceRiskSignals');
    if (!container) return;
    const memberId = el('attendanceIndividualSelect')?.value || '';
    if (!memberId) {
      container.innerHTML = '';
      container.classList.add('hidden');
      return;
    }
    const settings = (() => {
      try { return JSON.parse(window.LSOStorage.getItem(SETTINGS_KEY) || '{}'); } catch { return {}; }
    })();
    const signals = memberSignals(memberId, Number(settings.attendanceThreshold) || 75);
    const member = getMembers().find((item) => item.id === memberId);
    container.classList.remove('hidden');
    const riskMarkup = signals.risks.length
      ? signals.risks.map((risk) => `<span class="attendance-risk-chip risk-active">${safeText(risk)}</span>`).join('')
      : '<span class="attendance-risk-chip risk-clear">No current attendance risk signal</span>';
    container.innerHTML = `
      <div class="individual-analytics-heading"><div><span>Advanced Analytics</span><strong>${safeText(member?.fullName || 'Selected member')}</strong></div><div class="attendance-risk-list">${riskMarkup}</div></div>
      <div class="individual-stat-grid advanced-attendance-grid">
        <div class="attendance-kpi"><span>Working Rate</span><strong>${signals.workingRate === null ? '—' : `${signals.workingRate}%`}</strong><small>Draft + finalized records</small></div>
        <div class="attendance-kpi"><span>Verified Rate</span><strong>${signals.verifiedRate === null ? '—' : `${signals.verifiedRate}%`}</strong><small>Finalized records only</small></div>
        <div class="attendance-kpi"><span>On-Time Rate</span><strong>${signals.onTimeRate === null ? '—' : `${signals.onTimeRate}%`}</strong><small>Present ÷ Present + Late</small></div>
        <div class="attendance-kpi"><span>Consecutive Absences</span><strong>${signals.absenceStreak}</strong><small>Latest counted sequence</small></div>
        <div class="attendance-kpi"><span>Late Records</span><strong>${signals.lateCount}</strong><small>${activeSemester()}</small></div>
        <div class="attendance-kpi"><span>Draft Events</span><strong>${signals.draftEventCount}</strong><small>Not yet verified</small></div>
      </div>`;
  }

  function buildAlerts() {
    const settings = (() => {
      try { return JSON.parse(window.LSOStorage.getItem(SETTINGS_KEY) || '{}'); } catch { return {}; }
    })();
    const alertDays = Math.max(1, Number(settings.alertDays) || 30);
    const now = new Date(`${today()}T00:00:00`).getTime();
    const alerts = [];
    getEvents().forEach((event) => {
      if (!event.date || event.date > today()) return;
      const eventTime = new Date(`${event.date}T00:00:00`).getTime();
      const ageDays = Math.floor((now - eventTime) / 86_400_000);
      if (ageDays > alertDays) return;
      const records = getAttendance().filter((record) => record.eventId === event.id && record.status);
      if (!records.length) {
        alerts.push({
          type: 'attendance', severity: ageDays >= 1 ? 'high' : 'medium',
          title: `${event.title} has no recorded attendance`,
          detail: `${dateLabel(event.date)} • Attendance has not been entered or finalized.`,
          eventId: event.id
        });
        return;
      }
      const pairs = [...new Map(records.map((record) => {
        const group = record.attendanceGroup || 'Official Members';
        const mode = record.rosterModeAtEdit || 'Current';
        return [`${group}::${mode}`, { group, mode }];
      })).values()];
      const drafts = pairs.filter(({ group, mode }) => workflowState(event, group, mode) !== 'Finalized');
      if (drafts.length) {
        const workflows = drafts.map(({ group, mode }) => getWorkflow(event, group, mode));
        const reopened = workflows.some((workflow) => workflow.unlockedAt && workflow.history[0]?.action === 'Unlocked for editing');
        const draftLabels = drafts.map(({ group, mode }) => `${group}${mode === 'Archive' ? ' Archive' : ''}`);
        alerts.push({
          type: 'attendance', severity: reopened || ageDays >= 7 ? 'high' : 'medium',
          title: reopened ? `${event.title} was unlocked and needs re-finalization` : `${event.title} attendance remains Draft`,
          detail: `${dateLabel(event.date)} • ${draftLabels.join(', ')}${reopened ? ' • Corrections are still open.' : ' • Finalize to verify and lock the records.'}`,
          eventId: event.id
        });
      }
    });
    return alerts;
  }

  function downloadCsv(filename, rows) {
    const csv = rows.map((row) => row.map(csvEscape).join(',')).join('\r\n');
    const blob = new Blob([`\uFEFF${csv}`], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 500);
  }

  function exportOverallAnalytics() {
    const settings = (() => {
      try { return JSON.parse(window.LSOStorage.getItem(SETTINGS_KEY) || '{}'); } catch { return {}; }
    })();
    const threshold = Number(settings.attendanceThreshold) || 75;
    const members = getMembers().filter((member) => {
      const group = String(member.periodGroup || '').toLowerCase();
      if (activeGroup() === 'Official Members') return group === 'membership period' || String(member.membershipStage || '').toLowerCase() === 'regular member';
      if (activeGroup() === 'Probationary Members') return group === 'probationary period';
      return group === 'trainee period';
    }).sort((a, b) => String(a.fullName).localeCompare(String(b.fullName)));
    const rows = [[
      'Member', 'Membership ID', 'Attendance Group', 'Semester', 'Present', 'Late', 'Absent', 'Excused',
      'Working Rate', 'Verified Rate', 'On-Time Rate', 'Consecutive Absences', 'Draft Events', 'Risk Signals'
    ]];
    members.forEach((member) => {
      const signals = memberSignals(member.id, threshold);
      rows.push([
        member.fullName, member.membershipId, activeGroup(), activeSemester(), signals.counts.Present, signals.counts.Late,
        signals.counts.Absent, signals.counts.Excused, signals.workingRate ?? '', signals.verifiedRate ?? '', signals.onTimeRate ?? '',
        signals.absenceStreak, signals.draftEventCount, signals.risks.join('; ')
      ]);
    });
    downloadCsv(`LSO_Attendance_Analytics_${activeSemester().replace(/\s+/g, '_')}_${activeGroup().replace(/\s+/g, '_')}_${today()}.csv`, rows);
    window.LSOOperations?.logActivity?.('Exported attendance analytics', 'Attendance Reports', `${activeSemester()} • ${activeGroup()} • ${members.length} members`);
  }

  function exportIndividualAnalytics() {
    const memberId = el('attendanceIndividualSelect')?.value || '';
    const member = getMembers().find((item) => item.id === memberId);
    if (!member) {
      window.LSOApp?.showToast?.('Select a member before exporting the individual report.', true);
      return;
    }
    const signals = memberSignals(memberId);
    const rows = [[
      'Date', 'Event', 'Venue', 'Attendance Group', 'Roster Mode', 'Attendance State', 'Status', 'Remarks'
    ]];
    signals.items.forEach(({ event, record }) => rows.push([
      event.date, event.title, event.venue || '', record.attendanceGroup || activeGroup(), record.rosterModeAtEdit || 'Current',
      workflowState(event, record.attendanceGroup || activeGroup(), record.rosterModeAtEdit || 'Current'), record.status || 'Not marked', record.remarks || ''
    ]));
    downloadCsv(`LSO_${String(member.fullName).replace(/[^a-z0-9]+/gi, '_')}_Attendance_${activeSemester().replace(/\s+/g, '_')}_${today()}.csv`, rows);
    window.LSOOperations?.logActivity?.('Exported individual attendance report', 'Attendance Reports', `${member.fullName} • ${activeSemester()}`);
  }

  function exportAuditHistory() {
    const event = selectedEvent();
    if (!event) return;
    const workflow = getWorkflow(event);
    const rows = [['Timestamp', 'Action', 'Administrator', 'Attendance Group', 'Roster Mode', 'Semester', 'Details', 'Reason']];
    workflow.history.forEach((entry) => rows.push([
      entry.timestamp, entry.action, entry.account, entry.attendanceGroup, entry.rosterMode, entry.semester, entry.details, entry.reason
    ]));
    downloadCsv(`LSO_Attendance_Audit_${String(event.title).replace(/[^a-z0-9]+/gi, '_')}_${today()}.csv`, rows);
  }

  function render() {
    renderPeriodCenter();
    renderGovernance();
    renderVerificationMetrics();
    renderIndividualRiskSignals();
  }

  function interceptLockedEdits(event) {
    const target = event.target;
    const eventRecord = selectedEvent();
    if (!eventRecord || workflowState(eventRecord) !== 'Finalized') return;
    const blocked = target.closest?.('#saveAttendanceButton, #markAllPresent, .attendance-status, .attendance-remarks');
    if (!blocked) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    window.LSOApp?.showToast?.('This attendance roster is finalized. Use “Unlock for Editing” before making corrections.', true);
  }

  function wireEvents() {
    el('finalizeAttendanceButton')?.addEventListener('click', finalizeAttendance);
    el('unlockAttendanceButton')?.addEventListener('click', unlockAttendance);
    el('exportAttendanceAuditCsv')?.addEventListener('click', exportAuditHistory);
    el('exportAttendanceAnalyticsCsv')?.addEventListener('click', exportOverallAnalytics);
    el('exportIndividualAttendanceCsv')?.addEventListener('click', exportIndividualAnalytics);

    el('finalizeAttendanceMonthButton')?.addEventListener('click', finalizeMonth);
    el('reopenAttendanceMonthButton')?.addEventListener('click', reopenMonth);
    el('saveAttendanceSemesterEndDate')?.addEventListener('click', saveSemesterEndDate);
    el('finalizeAttendanceSemesterButton')?.addEventListener('click', finalizeSemester);
    el('reopenAttendanceSemesterButton')?.addEventListener('click', reopenSemester);

    document.addEventListener('click', interceptLockedEdits, true);
    document.addEventListener('change', interceptLockedEdits, true);

    document.addEventListener('click', (event) => {
      const button = event.target.closest?.('#saveAttendanceButton');
      if (!button) return;
      const eventRecord = selectedEvent();
      if (!eventRecord || workflowState(eventRecord) === 'Finalized') return;
      beforeSaveSnapshot = clone(scopedAttendanceRecords());
      clearTimeout(saveAuditTimer);
      saveAuditTimer = setTimeout(() => {
        appendDraftSaveAudit(beforeSaveSnapshot);
        beforeSaveSnapshot = null;
        render();
      }, 140);
    }, true);

    el('attendanceIndividualSelect')?.addEventListener('change', () => setTimeout(renderIndividualRiskSignals, 20));
    el('eventList')?.addEventListener('click', (event) => {
      if (event.target.closest?.('[data-event-id]')) setTimeout(render, 25);
    });
    el('attendanceMemberSearch')?.addEventListener('input', () => setTimeout(renderGovernance, 20));

    ['lso:operations-changed', 'lso:members-changed', 'lso:attendance-semester-changed', 'lso:attendance-group-changed',
      'lso:attendance-roster-mode-changed', 'lso:attendance-month-changed', 'lso:attendance-period-changed', 'lso:cloud-state-changed', 'lso:auth-changed']
      .forEach((name) => window.addEventListener(name, () => setTimeout(render, 40)));
  }

  function initialize() {
    wireEvents();
    render();
    window.LSOOperations?.refreshAll?.();
  }

  window.LSOAttendanceGovernance = {
    getWorkflow,
    workflowState,
    isFinalized: (event, group, mode) => workflowState(event, group, mode) === 'Finalized',
    memberSignals,
    buildAlerts,
    render,
    finalizeAttendance,
    unlockAttendance,
    finalizeMonth,
    reopenMonth,
    finalizeSemester,
    reopenSemester,
    saveSemesterEndDate,
    getMonthState: monthState,
    getSemesterState: semesterState,
    getMonthSnapshot: (month, semester, group, mode) => monthState(month, semester, group, mode).snapshot || calculateMonthSnapshot(month, semester, group, mode),
    getSemesterSnapshot: (semester, group, mode) => semesterState(semester, group, mode).snapshot || calculateSemesterSnapshot(semester, group, mode),
    calculateMonthSnapshot,
    calculateSemesterSnapshot
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
