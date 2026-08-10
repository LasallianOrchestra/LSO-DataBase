(() => {
  'use strict';
  window.__LSO_ATTENDANCE_GOVERNANCE_VERSION__ = 'v10-attendance-lifecycle-workflow';

  const EVENTS_KEY = 'lso_events_v2';
  const ATTENDANCE_KEY = 'lso_attendance_v2';
  const SETTINGS_KEY = 'lso_system_settings_v2';
  const MONTHLY_KEY = 'lso_monthly_reports_v1';
  const GROUPS = ['Official Members', 'Trainee Members', 'Probationary Members'];
  const MODES = ['Current', 'Archive'];
  const SEMESTERS = ['First Semester', 'Second Semester'];
  const MONTH_STATES = ['Draft', 'In Review', 'Finalized', 'Reopened'];
  const PERIOD_SETTINGS_KEY = 'attendancePeriodGovernance';
  const el = (id) => document.getElementById(id);

  let beforeSaveSnapshot = null;
  let saveAuditTimer = null;
  let semesterTransaction = null;
  let semesterTransactionTimer = 0;
  let selectedArchiveId = String(window.LSOSelectedAttendanceArchiveId || '');

  function scopeIdentity(semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    return { semester, group, mode, key: periodScopeKey(semester, group, mode) };
  }

  function mutationTimestamp(entry) {
    const candidates = [entry?.updatedAt, entry?.reopenedAt, entry?.finalizedAt].filter(Boolean).map((value) => Date.parse(value) || 0);
    return candidates.length ? Math.max(...candidates) : 0;
  }

  function setSemesterTransaction(action, scope, expectedState) {
    clearTimeout(semesterTransactionTimer);
    semesterTransaction = { action, scope, expectedState, startedAt: Date.now() };
    semesterTransactionTimer = window.setTimeout(() => {
      semesterTransaction = null;
      scheduleRender(0, true);
    }, 12000);
  }

  function clearSemesterTransaction(scopeKey = '') {
    if (scopeKey && semesterTransaction?.scope?.key !== scopeKey) return;
    clearTimeout(semesterTransactionTimer);
    semesterTransactionTimer = 0;
    semesterTransaction = null;
  }

  function setStateOwnedVisibility(node, visible) {
    if (!node) return;
    node.dataset.stateVisible = visible ? 'true' : 'false';
    node.classList.toggle('hidden', !visible);
    node.setAttribute('aria-hidden', visible ? 'false' : 'true');
    node.tabIndex = visible ? 0 : -1;
  }

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

  let settingsCacheRaw = null;
  let settingsCacheValue = {};
  let governanceCacheRaw = null;
  let governanceCacheValue = null;

  function rawSystemSettings() {
    try { return window.LSOStorage?.getItem(SETTINGS_KEY) || '{}'; }
    catch { return '{}'; }
  }

  function loadSystemSettings() {
    const raw = rawSystemSettings();
    if (raw === settingsCacheRaw) return settingsCacheValue;
    settingsCacheRaw = raw;
    try {
      const parsed = JSON.parse(raw);
      settingsCacheValue = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      settingsCacheValue = {};
    }
    return settingsCacheValue;
  }

  function normalizePeriodGovernance(raw) {
    const value = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
    return {
      version: 1,
      semesterEndDates: value.semesterEndDates && typeof value.semesterEndDates === 'object' ? { ...value.semesterEndDates } : {},
      monthFinalizations: value.monthFinalizations && typeof value.monthFinalizations === 'object' ? { ...value.monthFinalizations } : {},
      semesterFinalizations: value.semesterFinalizations && typeof value.semesterFinalizations === 'object' ? { ...value.semesterFinalizations } : {},
      semesterEndDateUpdates: value.semesterEndDateUpdates && typeof value.semesterEndDateUpdates === 'object' ? { ...value.semesterEndDateUpdates } : {},
      archives: Array.isArray(value.archives) ? value.archives.map((entry) => ({ ...entry })) : [],
      loaPolicyVersion: Math.max(0, Number(value.loaPolicyVersion) || 0),
      updatedAt: value.updatedAt || '',
      updatedBy: value.updatedBy || '',
      mutationId: value.mutationId || ''
    };
  }

  function loadPeriodGovernance(mutable = false) {
    const raw = rawSystemSettings();
    if (raw !== governanceCacheRaw || !governanceCacheValue) {
      governanceCacheRaw = raw;
      governanceCacheValue = normalizePeriodGovernance(loadSystemSettings()[PERIOD_SETTINGS_KEY]);
    }
    return mutable ? clone(governanceCacheValue) : governanceCacheValue;
  }

  function savePeriodGovernance(value, options = {}) {
    const source = options.source || 'attendance-period-governance';
    const next = normalizePeriodGovernance(value);
    if (!options.preserveMutationStamp) {
      next.updatedAt = new Date().toISOString();
      next.updatedBy = periodActor();
      next.mutationId = uid('attendance-governance');
    }
    const settings = { ...loadSystemSettings(), [PERIOD_SETTINGS_KEY]: next };
    let serialized = '';
    try { serialized = JSON.stringify(settings); }
    catch {
      window.LSOApp?.showToast?.('Attendance archive data could not be prepared for saving. Please reload and try again.', true);
      return false;
    }
    const saved = window.LSOStorage?.setItem(SETTINGS_KEY, serialized);
    if (saved === false) return false;
    settingsCacheRaw = serialized;
    settingsCacheValue = settings;
    governanceCacheRaw = serialized;
    governanceCacheValue = next;
    window.dispatchEvent(new CustomEvent('lso:attendance-period-changed', { detail: { semester: activeSemester(), group: activeGroup(), month: activeMonth(), source } }));
    window.dispatchEvent(new CustomEvent('lso:operations-changed', { detail: { key: SETTINGS_KEY, source } }));
    return true;
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
    let state = MONTH_STATES.includes(raw.state) ? raw.state : (raw.state === 'Finalized' ? 'Finalized' : 'Draft');
    // V56 and earlier represented reopened months as Draft plus reopenedAt.
    // Preserve that intent during migration without rewriting the stored data.
    if (state === 'Draft' && raw.reopenedAt && Math.max(0, Number(raw.revision) || 0) > 0 && !raw.snapshot) state = 'Reopened';
    return {
      state,
      revision: Math.max(0, Number(raw.revision) || 0),
      finalizedAt: raw.finalizedAt || '', finalizedBy: raw.finalizedBy || '',
      reviewedAt: raw.reviewedAt || '', reviewedBy: raw.reviewedBy || '',
      reopenedAt: raw.reopenedAt || '', reopenedBy: raw.reopenedBy || '', reopenReason: raw.reopenReason || '',
      validation: raw.validation && typeof raw.validation === 'object' ? raw.validation : null,
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
      history: Array.isArray(raw.history) ? raw.history : [],
      updatedAt: raw.updatedAt || raw.reopenedAt || raw.finalizedAt || '',
      stateVersion: Math.max(0, Number(raw.stateVersion) || Number(raw.revision) || 0),
      mutationId: raw.mutationId || ''
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
    const eventIds = new Set(events.map((event) => String(event.id ?? '')));
    const records = (attendanceOverride || getAttendance()).filter((record) =>
      eventIds.has(String(record.eventId ?? '')) &&
      String(record.attendanceGroup || group) === String(group) &&
      String(record.rosterModeAtEdit || 'Current') === String(mode) &&
      Boolean(record.status)
    );
    const memberIds = [...new Set(records.map((record) => String(record.memberId ?? '')))].filter(Boolean);
    const members = {};
    memberIds.forEach((memberId) => {
      const memberRecords = records.filter((record) => String(record.memberId ?? '') === memberId);
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

  function hasManagedMonthState(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    const raw = loadPeriodGovernance().monthFinalizations[monthScopeKey(month, semester, group, mode)];
    return Boolean(raw && typeof raw === 'object' && Object.keys(raw).length);
  }

  function workflowState(event, group = activeGroup(), mode = activeMode()) {
    if (event?.date) {
      const eventMonth = String(event.date).slice(0, 7);
      const monthly = monthState(eventMonth, event.semester || activeSemester(), group, mode);
      if (monthly.state === 'Finalized') return 'Finalized';
      // Once a month enters the lifecycle workflow, its monthly state becomes
      // authoritative. This also releases legacy event locks when a finalized
      // month is reopened or returned for corrections.
      if (hasManagedMonthState(eventMonth, event.semester || activeSemester(), group, mode) && ['Draft', 'In Review', 'Reopened'].includes(monthly.state)) return 'Draft';
    }
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

  function normalizeText(value) {
    return String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
  }

  let monthlyReportsCacheRaw = null;
  let monthlyReportsCacheValue = {};

  function loadMonthlyReports() {
    let raw = '{}';
    try { raw = window.LSOStorage?.getItem(MONTHLY_KEY) || '{}'; } catch { raw = '{}'; }
    if (raw === monthlyReportsCacheRaw) return monthlyReportsCacheValue;
    monthlyReportsCacheRaw = raw;
    try {
      const parsed = JSON.parse(raw);
      monthlyReportsCacheValue = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      monthlyReportsCacheValue = {};
    }
    return monthlyReportsCacheValue;
  }

  function memberPhaseOnDate(member, value) {
    const date = String(value || today()).slice(0, 10);
    const regularStart = String(member?.regularMemberDate || '').slice(0, 10);
    const probationaryStart = String(member?.probationaryStartDate || '').slice(0, 10);
    if (regularStart && date >= regularStart) return 'Official Members';
    if (!member?.probationarySkipped && probationaryStart && date >= probationaryStart) return 'Probationary Members';

    // Older/imported profiles may have the stage but not complete timeline dates.
    // Use the stored stage as a fallback so an Official Member on LOA is not
    // omitted from the Official Members roster and attendance reconciliation.
    const period = normalizeText(member?.periodGroup);
    const stage = normalizeText(member?.membershipStage);
    if (!regularStart && (period === 'membership period' || period.startsWith('regular') || stage === 'regular member' || stage === 'official member')) return 'Official Members';
    if (!probationaryStart && !regularStart && (period === 'probationary period' || stage === 'probationary')) return 'Probationary Members';
    return 'Trainee Members';
  }

  function validIsoDate(value) {
    const normalized = String(value || '').trim().slice(0, 10);
    return /^\d{4}-\d{2}-\d{2}$/.test(normalized) ? normalized : '';
  }

  function memberOnLeaveForDate(member, value) {
    if (!member) return false;
    const date = String(value || today()).slice(0, 10);
    const month = date.slice(0, 7);
    const reports = loadMonthlyReports().reports || {};
    const memberId = String(member.id || '');
    const name = normalizeText(member.fullName);
    const rowMatches = (item) => (memberId && String(item?.memberId || '') === memberId) || (!item?.memberId && name && normalizeText(item?.name) === name);

    const report = reports[month] || {};
    const row = (Array.isArray(report.loaRows) ? report.loaRows : []).find(rowMatches);
    if (row) {
      // The Monthly Report LOA row covers the whole filing month by default.
      // Only actual YYYY-MM-DD values narrow the coverage; text such as
      // “Second Semester” or “Until further notice” must not create absences.
      const startDate = validIsoDate(row.startDate || row.start || row.from || row.dateFrom);
      const endDate = validIsoDate(row.endDate || row.end || row.to || row.dateTo || row.until);
      if (startDate && date < startDate) return false;
      if (endDate && date > endDate) return false;
      return true;
    }

    // Carry a filed LOA forward only when a real end date explicitly covers
    // this event. Descriptive text is not treated as a date range.
    const continuingRow = Object.entries(reports)
      .filter(([key]) => /^\d{4}-\d{2}$/.test(key) && key <= month)
      .sort(([a], [b]) => b.localeCompare(a))
      .map(([key, item]) => ({ key, row: (Array.isArray(item?.loaRows) ? item.loaRows : []).find(rowMatches) }))
      .find(({ row: candidate }) => {
        const endDate = validIsoDate(candidate?.endDate || candidate?.end || candidate?.to || candidate?.dateTo || candidate?.until);
        return Boolean(endDate && endDate >= date);
      });
    if (continuingRow) {
      const startDate = validIsoDate(continuingRow.row.startDate || continuingRow.row.start || continuingRow.row.from || continuingRow.row.dateFrom);
      return !startDate || date >= startDate;
    }

    // Before the Monthly Report is filed, the current LOA status applies to
    // the current month. Historical periods are controlled by report rows.
    return normalizeText(member.memberStatus) === 'loa' && month === today().slice(0, 7);
  }

  function rosterMembersForEvent(event, group = activeGroup()) {
    const regular = window.LSOOperations?.getAttendanceRosterMembers?.(event?.id) || [];
    const byId = new Map(regular.map((member) => [String(member.id), member]));
    getMembers().forEach((member) => {
      if (!member?.id || !memberOnLeaveForDate(member, event?.date)) return;
      if (memberPhaseOnDate(member, event?.date) !== group) return;
      byId.set(String(member.id), member);
    });
    return [...byId.values()].sort((a, b) => String(a.fullName || '').localeCompare(String(b.fullName || '')));
  }

  function archiveId(prefix = 'attendance-month-archive') {
    return window.crypto?.randomUUID?.() || `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }


  function archiveScopeKey(entry) {
    if (entry?.scopeKey) return String(entry.scopeKey);
    return monthScopeKey(entry?.month, entry?.semester, entry?.attendanceGroup, entry?.rosterMode || 'Current');
  }

  const ARCHIVE_STATUS_CODES = Object.freeze({ Present: 'P', Late: 'L', Absent: 'A', Excused: 'E' });
  const ARCHIVE_STATUS_LABELS = Object.freeze({ P: 'Present', L: 'Late', A: 'Absent', E: 'Excused' });

  function compactArchiveSnapshot(snapshot, events = [], records = []) {
    const source = snapshot && typeof snapshot === 'object' ? clone(snapshot) : {};
    const sourceEvents = Array.isArray(events) && events.length ? events : (Array.isArray(source.events) ? source.events : []);
    const sourceRecords = Array.isArray(records) && records.length ? records : (Array.isArray(source.records) ? source.records : []);
    const eventDirectory = [];
    const eventIndex = new Map();
    sourceEvents.forEach((event) => {
      const id = String(event?.id ?? '');
      if (!id || eventIndex.has(id)) return;
      eventIndex.set(id, eventDirectory.length);
      eventDirectory.push([id, String(event?.title || event?.name || 'Attendance activity'), String(event?.date || '')]);
    });
    const memberDirectory = [];
    const memberIndex = new Map();
    const remarksDirectory = [''];
    const remarksIndex = new Map([['', 0]]);
    const recordRows = [];
    sourceRecords.forEach((record) => {
      const eventId = String(record?.eventId ?? '');
      const memberId = String(record?.memberId ?? '');
      if (!eventId || !memberId) return;
      if (!eventIndex.has(eventId)) {
        eventIndex.set(eventId, eventDirectory.length);
        eventDirectory.push([eventId, String(record?.eventTitle || 'Attendance activity'), String(record?.eventDate || '')]);
      }
      if (!memberIndex.has(memberId)) {
        memberIndex.set(memberId, memberDirectory.length);
        memberDirectory.push([memberId, String(record?.memberName || memberName(memberId) || memberId)]);
      }
      const remarks = String(record?.remarks || '');
      if (!remarksIndex.has(remarks)) {
        remarksIndex.set(remarks, remarksDirectory.length);
        remarksDirectory.push(remarks);
      }
      recordRows.push([eventIndex.get(eventId), memberIndex.get(memberId), ARCHIVE_STATUS_CODES[record?.status] || String(record?.status || ''), remarksIndex.get(remarks), record?.loaAutoExcused ? 1 : 0]);
    });
    delete source.events;
    delete source.records;
    source.archiveFormat = 'compact-v1';
    source.eventDirectory = eventDirectory;
    source.memberDirectory = memberDirectory;
    source.remarksDirectory = remarksDirectory;
    source.recordRows = recordRows;
    source.recordCount = Math.max(Number(source.recordCount) || 0, recordRows.length);
    return source;
  }

  function isCompactArchiveSnapshot(snapshot) {
    return snapshot?.archiveFormat === 'compact-v1' && Array.isArray(snapshot.recordRows);
  }

  function archiveRecordCount(entry) {
    const snapshot = entry?.snapshot || {};
    const records = Array.isArray(snapshot.records) ? snapshot.records : [];
    const compactRows = Array.isArray(snapshot.recordRows) ? snapshot.recordRows : [];
    return Math.max(Number(snapshot.recordCount) || 0, records.length, compactRows.length);
  }

  function archiveQuality(entry) {
    const snapshot = entry?.snapshot || {};
    const count = archiveRecordCount(entry);
    const hasRate = snapshot.groupRate !== null && snapshot.groupRate !== undefined && Number.isFinite(Number(snapshot.groupRate));
    const statusTotal = Object.values(snapshot.counts || {}).reduce((sum, value) => sum + (Number(value) || 0), 0);
    return count * 1000
      + (hasRate ? 100 : 0)
      + Math.min(statusTotal, 99)
      + Math.max(0, Number(entry?.revision) || 0);
  }

  function groupedAttendanceArchives() {
    const groups = new Map();
    visibleAttendanceArchives().forEach((entry) => {
      const key = archiveScopeKey(entry);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(entry);
    });

    return [...groups.entries()].map(([scopeKey, entries]) => {
      const sample = entries[0] || {};
      const live = monthState(sample.month, sample.semester, sample.attendanceGroup, sample.rosterMode || 'Current');
      const matchingLive = live.state === 'Finalized' && live.snapshot
        ? entries.find((entry) => monthSnapshotSignature(entry?.snapshot) === monthSnapshotSignature(live.snapshot))
        : null;
      const sorted = entries.slice().sort((a, b) => {
        const quality = archiveQuality(b) - archiveQuality(a);
        if (quality) return quality;
        return String(b.finalizedAt || '').localeCompare(String(a.finalizedAt || ''));
      });
      const primary = matchingLive || sorted[0];
      return {
        scopeKey,
        primary,
        revisions: entries.slice().sort((a, b) => String(b.finalizedAt || '').localeCompare(String(a.finalizedAt || ''))),
        previous: entries.filter((entry) => entry !== primary).sort((a, b) => String(b.finalizedAt || '').localeCompare(String(a.finalizedAt || '')))
      };
    }).sort((a, b) => String(b.primary?.finalizedAt || '').localeCompare(String(a.primary?.finalizedAt || '')));
  }

  function archiveSnapshotRows(entry) {
    const snapshot = entry?.snapshot || {};
    if (Array.isArray(snapshot.records)) return snapshot.records;
    if (!isCompactArchiveSnapshot(snapshot)) return [];
    const events = snapshot.eventDirectory || [];
    const members = snapshot.memberDirectory || [];
    const remarks = snapshot.remarksDirectory || [''];
    return snapshot.recordRows.map((row) => {
      const event = events[Number(row?.[0])] || [];
      const member = members[Number(row?.[1])] || [];
      return {
        eventId: event[0] || '', eventTitle: event[1] || 'Attendance activity', eventDate: event[2] || '',
        memberId: member[0] || '', memberName: member[1] || member[0] || 'Unknown member',
        status: ARCHIVE_STATUS_LABELS[row?.[2]] || row?.[2] || '', remarks: remarks[Number(row?.[3])] || '', loaAutoExcused: Boolean(row?.[4])
      };
    });
  }

  function archiveStatusLabel(entry, group) {
    const liveState = monthState(entry.month, entry.semester, entry.attendanceGroup, entry.rosterMode || 'Current');
    if (entry?.isCurrentFinalizedCopy && liveState.state === 'Finalized') return 'Current Finalized Copy';
    if (group.previous.length) return 'Verified Archive Copy';
    return liveState.state === 'Draft' ? 'Finalized Copy · Live Month Reopened' : 'Finalized Copy';
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
    return rosterMembersForEvent(selectedEvent());
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
    if (!event || workflowState(event) === 'Finalized' || monthState(String(event.date || '').slice(0, 7), event.semester || activeSemester(), activeGroup(), activeMode()).state === 'In Review') return;
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
    const recordMap = new Map(scopedAttendanceRecords(event.id).map((record) => [String(record.memberId), record]));
    const missing = members.filter((member) => !recordMap.get(String(member.id))?.status);
    const loaMembers = members.filter((member) => memberOnLeaveForDate(member, event.date));
    const absentCount = missing.filter((member) => !memberOnLeaveForDate(member, event.date)).length;
    const excusedCount = loaMembers.length;
    const message = missing.length || excusedCount
      ? `Finalize this attendance roster? ${absentCount} unmarked active member${absentCount === 1 ? '' : 's'} will be recorded as Absent, while ${excusedCount} member${excusedCount === 1 ? '' : 's'} on approved LOA will be recorded as Excused. The roster will then be locked.`
      : 'Finalize and lock this attendance roster? The Administrator can unlock it later when a correction is required.';
    if (!window.confirm(message)) return;

    const now = new Date().toISOString();
    const actor = auditActor();
    const nextAttendance = currentRecords.map((record) => ({ ...record }));
    members.forEach((member) => {
      const index = nextAttendance.findIndex((record) =>
        String(record.eventId ?? '') === String(event.id ?? '') &&
        String(record.memberId) === String(member.id) &&
        (record.attendanceGroup || activeGroup()) === activeGroup() &&
        (record.rosterModeAtEdit || 'Current') === activeMode()
      );
      const existing = index >= 0 ? nextAttendance[index] : {};
      const onLeave = memberOnLeaveForDate(member, event.date);
      if (existing.status && !onLeave) return;
      const nextRecord = {
        ...existing,
        eventId: event.id,
        memberId: member.id,
        status: onLeave ? 'Excused' : 'Absent',
        remarks: onLeave
          ? 'Automatically marked Excused because the member was on approved LOA for this attendance date.'
          : (existing.remarks || 'Automatically marked Absent during attendance finalization.'),
        attendanceGroup: activeGroup(),
        rosterModeAtEdit: activeMode(),
        loaAutoExcused: onLeave,
        createdAt: existing.createdAt || now,
        updatedAt: now,
        updatedBy: actor.account
      };
      if (index >= 0) nextAttendance[index] = nextRecord;
      else nextAttendance.push(nextRecord);
    });

    const finalRecords = nextAttendance.filter((record) =>
      String(record.eventId ?? '') === String(event.id ?? '') &&
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
      missing.length || loaMembers.length ? `${absentCount} active member${absentCount === 1 ? '' : 's'} marked Absent • ${loaMembers.length} approved LOA member${loaMembers.length === 1 ? '' : 's'} marked Excused.` : ''
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


  let validationDirtyVersion = 1;
  const validationCache = new Map();

  function markValidationDirty() {
    validationDirtyVersion += 1;
    if (validationCache.size > 18) validationCache.clear();
  }

  function validationScopeCacheKey(month, semester, group, mode) {
    return `${monthScopeKey(month, semester, group, mode)}::${validationDirtyVersion}`;
  }

  function monthStateIsEditable(state) {
    return state === 'Draft' || state === 'Reopened';
  }

  function monthStateLocksEditing(state) {
    return state === 'In Review' || state === 'Finalized';
  }

  function attendanceScopeRecordKey(record) {
    return `${String(record?.eventId ?? '')}::${String(record?.memberId ?? '')}::${String(record?.attendanceGroup || activeGroup())}::${String(record?.rosterModeAtEdit || 'Current')}`;
  }

  function recordMutationTime(record) {
    return Math.max(Date.parse(record?.updatedAt || '') || 0, Date.parse(record?.createdAt || '') || 0);
  }

  function recordBelongsToMonthScope(record, eventIds, group = activeGroup(), mode = activeMode()) {
    return eventIds.has(String(record?.eventId ?? '')) &&
      String(record?.attendanceGroup || group) === String(group) &&
      String(record?.rosterModeAtEdit || 'Current') === String(mode);
  }

  function prepareMonthAttendance(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode()) {
    const events = scopedMonthEvents(month, semester, group);
    const eventIds = new Set(events.map((event) => String(event.id ?? '')));
    const current = getAttendance().map((record) => ({ ...record }));
    const indexesByKey = new Map();
    current.forEach((record, index) => {
      if (!recordBelongsToMonthScope(record, eventIds, group, mode)) return;
      const key = attendanceScopeRecordKey(record);
      if (!indexesByKey.has(key)) indexesByKey.set(key, []);
      indexesByKey.get(key).push(index);
    });

    const removeIndexes = new Set();
    const updateByIndex = new Map();
    let duplicateCount = 0;
    indexesByKey.forEach((indexes) => {
      if (indexes.length <= 1) return;
      const sorted = [...indexes].sort((a, b) => recordMutationTime(current[b]) - recordMutationTime(current[a]) || b - a);
      sorted.slice(1).forEach((index) => removeIndexes.add(index));
      duplicateCount += sorted.length - 1;
      indexesByKey.set(attendanceScopeRecordKey(current[sorted[0]]), [sorted[0]]);
    });

    const now = new Date().toISOString();
    const actor = periodActor();
    let loaCorrectionCount = 0;
    events.forEach((event) => {
      rosterMembersForEvent(event, group).forEach((member) => {
        if (!memberOnLeaveForDate(member, event.date)) return;
        const key = `${String(event.id ?? '')}::${String(member.id ?? '')}::${String(group)}::${String(mode)}`;
        const keptIndex = (indexesByKey.get(key) || []).find((index) => !removeIndexes.has(index));
        const existing = keptIndex == null ? null : (updateByIndex.get(keptIndex) || current[keptIndex]);
        if (existing?.status === 'Excused' && existing?.loaAutoExcused) return;
        const next = {
          ...(existing || {}), eventId: event.id, memberId: member.id,
          attendanceGroup: group, rosterModeAtEdit: mode,
          status: 'Excused', loaAutoExcused: true,
          remarks: 'Automatically marked Excused because the member was on approved LOA for this attendance date.',
          createdAt: existing?.createdAt || now, updatedAt: now, updatedBy: actor
        };
        if (keptIndex == null) {
          current.push(next);
          indexesByKey.set(key, [current.length - 1]);
        } else updateByIndex.set(keptIndex, next);
        loaCorrectionCount += 1;
      });
    });

    // Apply updates before removing duplicates so update indexes continue to
    // refer to the original array positions. Filtering first would shift the
    // indexes and could apply an LOA correction to the wrong member record.
    const attendance = current
      .map((record, index) => updateByIndex.get(index) || record)
      .filter((_, index) => !removeIndexes.has(index));
    return { attendance, events, duplicateCount, loaCorrectionCount, changed: duplicateCount > 0 || loaCorrectionCount > 0 };
  }

  function buildMonthValidation(month = activeMonth(), semester = activeSemester(), group = activeGroup(), mode = activeMode(), attendanceOverride = null) {
    const cacheKey = attendanceOverride ? '' : validationScopeCacheKey(month, semester, group, mode);
    if (cacheKey && validationCache.has(cacheKey)) return validationCache.get(cacheKey);
    const events = scopedMonthEvents(month, semester, group);
    const eventIds = new Set(events.map((event) => String(event.id ?? '')));
    const records = (attendanceOverride || getAttendance()).filter((record) => recordBelongsToMonthScope(record, eventIds, group, mode));
    const recordsByKey = new Map();
    records.forEach((record) => {
      const key = attendanceScopeRecordKey(record);
      if (!recordsByKey.has(key)) recordsByKey.set(key, []);
      recordsByKey.get(key).push(record);
    });
    let missingCount = 0;
    let invalidCount = 0;
    let duplicateCount = 0;
    let loaMismatchCount = 0;
    let expectedRecordCount = 0;
    let excusedCount = 0;
    const validStatuses = new Set(['Present', 'Late', 'Absent', 'Excused', 'Not Required']);
    recordsByKey.forEach((items) => { if (items.length > 1) duplicateCount += items.length - 1; });

    events.forEach((event) => {
      rosterMembersForEvent(event, group).forEach((member) => {
        expectedRecordCount += 1;
        const key = `${String(event.id ?? '')}::${String(member.id ?? '')}::${String(group)}::${String(mode)}`;
        const items = recordsByKey.get(key) || [];
        const record = [...items].sort((a, b) => recordMutationTime(b) - recordMutationTime(a))[0] || null;
        const onLeave = memberOnLeaveForDate(member, event.date);
        if (onLeave) {
          if (!record || record.status !== 'Excused') loaMismatchCount += 1;
          else excusedCount += 1;
          return;
        }
        if (!record || !record.status) { missingCount += 1; return; }
        if (!validStatuses.has(record.status)) invalidCount += 1;
      });
    });

    const snapshot = calculateMonthSnapshot(month, semester, group, mode, attendanceOverride || getAttendance());
    const ratedCount = Number(snapshot?.counts?.Present || 0) + Number(snapshot?.counts?.Late || 0) + Number(snapshot?.counts?.Absent || 0);
    const checks = [
      { id: 'activities', label: 'Completed activities available', value: events.length, ready: events.length > 0, helper: events.length ? `${events.length} activit${events.length === 1 ? 'y' : 'ies'} in this month` : 'Create or select at least one completed activity.' },
      { id: 'roster', label: 'All roster entries recorded', value: missingCount, ready: missingCount === 0, helper: missingCount ? `${missingCount} attendance entr${missingCount === 1 ? 'y is' : 'ies are'} still missing.` : `${expectedRecordCount} expected roster entries are complete.` },
      { id: 'statuses', label: 'All attendance statuses are valid', value: invalidCount, ready: invalidCount === 0, helper: invalidCount ? `${invalidCount} attendance entr${invalidCount === 1 ? 'y has' : 'ies have'} an unsupported status.` : 'Present, Late, Absent, Excused, and Not Required statuses are valid.' },
      { id: 'loa', label: 'LOA records verified as Excused', value: loaMismatchCount, ready: loaMismatchCount === 0, helper: loaMismatchCount ? `${loaMismatchCount} LOA entr${loaMismatchCount === 1 ? 'y needs' : 'ies need'} correction.` : `${excusedCount} Excused entr${excusedCount === 1 ? 'y' : 'ies'} verified.` },
      { id: 'duplicates', label: 'No duplicate attendance records', value: duplicateCount, ready: duplicateCount === 0, helper: duplicateCount ? `${duplicateCount} duplicate entr${duplicateCount === 1 ? 'y' : 'ies'} detected.` : 'No duplicate event/member records detected.' },
      { id: 'rating', label: 'Monthly rating can be computed', value: snapshot.groupRate, ready: ratedCount > 0 || (expectedRecordCount > 0 && excusedCount === expectedRecordCount), helper: ratedCount > 0 ? `Working rating: ${snapshot.groupRate ?? '—'}%` : (excusedCount === expectedRecordCount && expectedRecordCount > 0 ? 'All records are Excused; no numeric rating will be assigned.' : 'No rated attendance records are available yet.') }
    ];
    const result = {
      month, semester, attendanceGroup: group, rosterMode: mode,
      ready: checks.every((check) => check.ready), checks,
      eventCount: events.length, expectedRecordCount, missingCount, invalidCount, duplicateCount, loaMismatchCount,
      excusedCount, ratedCount, groupRate: snapshot.groupRate, snapshot, checkedAt: new Date().toISOString()
    };
    if (cacheKey) validationCache.set(cacheKey, result);
    return result;
  }

  function reviewMonth() {
    if (activeMode() !== 'Current') return window.LSOApp?.showToast?.('Return to Current Attendance to review a month.', true);
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Your role is not assigned to review and finalize attendance.', true);
    const month = activeMonth();
    const current = monthState(month);
    if (current.state === 'Finalized') return window.LSOApp?.showToast?.('This month is already finalized. Reopen it before making a revision.', true);
    if (current.state === 'In Review') return window.LSOApp?.showToast?.('This month is already in review and ready for finalization.');
    const prepared = prepareMonthAttendance(month);
    if (prepared.changed && window.LSOOperations?.replaceAttendance?.(prepared.attendance) === false) {
      return window.LSOApp?.showToast?.('Attendance corrections required for review could not be saved.', true);
    }
    if (prepared.changed) markValidationDirty();
    const validation = buildMonthValidation(month, activeSemester(), activeGroup(), activeMode(), prepared.attendance);
    if (!validation.ready) {
      window.LSOApp?.showToast?.(`Month review found ${validation.missingCount + validation.invalidCount + validation.loaMismatchCount + validation.duplicateCount} item(s) that require correction.`, true);
      scheduleRender(0, true);
      return;
    }
    const now = new Date().toISOString();
    const actor = periodActor();
    const data = loadPeriodGovernance(true);
    const key = monthScopeKey(month);
    data.monthFinalizations[key] = {
      ...current, state: 'In Review', reviewedAt: now, reviewedBy: actor,
      validation: { ...validation, snapshot: undefined }, snapshot: null,
      history: [periodAudit('Monthly attendance reviewed', `${validation.eventCount} activities and ${validation.expectedRecordCount} roster entries validated.`), ...current.history].slice(0, 100)
    };
    if (!savePeriodGovernance(data, { source: 'attendance-month-reviewed' })) return window.LSOApp?.showToast?.('The monthly review state could not be saved.', true);
    window.LSOOperations?.logActivity?.('Reviewed monthly attendance', 'Attendance Audit', `${month} • ${activeSemester()} • ${activeGroup()}`);
    window.LSOApp?.showToast?.('Monthly attendance passed validation and is ready to finalize.');
    scheduleRender(0, true);
  }

  function returnMonthToCorrections() {
    if (!canUnlockAttendance()) return window.LSOApp?.showToast?.('Only an authorized Administrator can return a reviewed month for corrections.', true);
    const month = activeMonth();
    const current = monthState(month);
    if (current.state !== 'In Review') return;
    const nextState = current.revision > 0 ? 'Reopened' : 'Draft';
    const data = loadPeriodGovernance(true);
    const key = monthScopeKey(month);
    data.monthFinalizations[key] = {
      ...current, state: nextState, reviewedAt: '', reviewedBy: '', validation: null,
      history: [periodAudit('Monthly review returned for corrections', `${month} returned to ${nextState}.`), ...current.history].slice(0, 100)
    };
    if (!savePeriodGovernance(data, { source: 'attendance-month-returned' })) return window.LSOApp?.showToast?.('The month could not be returned for corrections.', true);
    window.LSOApp?.showToast?.('Monthly attendance is editable again.');
    scheduleRender(0, true);
  }


  function finalizeMonth() {
    if (activeMode() !== 'Current') return window.LSOApp?.showToast?.('Finalized archive copies are view-only. Return to Current Attendance to finalize a month.', true);
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Your role is not assigned to finalize a monthly attendance period.', true);
    if (window.LSOCloud?.getSessionToken?.() && window.LSOCloud?.canWrite?.('settings') === false) {
      return window.LSOApp?.showToast?.('This role cannot save finalized attendance archives. Assign System Settings data access in Role Management before finalizing.', true);
    }
    const month = activeMonth();
    const current = monthState(month);
    if (current.state === 'Finalized') return window.LSOApp?.showToast?.('This monthly attendance period is already finalized.', true);
    if (current.state !== 'In Review') return window.LSOApp?.showToast?.('Review and validate the selected month before finalizing it.', true);
    const prepared = prepareMonthAttendance(month);
    if (prepared.changed) markValidationDirty();
    const validation = buildMonthValidation(month, activeSemester(), activeGroup(), activeMode(), prepared.attendance);
    if (!validation.ready) {
      return window.LSOApp?.showToast?.('The month changed after review. Return it for corrections, resolve the validation items, and review it again.', true);
    }
    const events = prepared.events;
    if (!events.length) return window.LSOApp?.showToast?.('There are no completed activities in this calendar month to finalize.', true);
    if (!window.confirm(`Finalize the validated ${month} attendance for ${activeGroup()}? This creates a locked archive copy and uses it for the semester rating.`)) return;
    if (prepared.changed && window.LSOOperations?.replaceAttendance?.(prepared.attendance) === false) {
      return window.LSOApp?.showToast?.('The validated attendance records could not be saved. No archive was created.', true);
    }
    const nextAttendance = prepared.attendance;
    const now = new Date().toISOString();
    const actor = periodActor();
    // The month lifecycle is the single source of truth. Avoid writing every
    // event during finalization; this prevents a burst of cloud saves and keeps
    // the validated archive transaction stable across slower devices.
    const data = loadPeriodGovernance(true);
    const key = monthScopeKey(month);
    const frozenSnapshot = calculateMonthSnapshot(month, activeSemester(), activeGroup(), activeMode(), nextAttendance);
    const archivedEventIds = new Set(events.map((event) => String(event.id)));
    const originalRecords = nextAttendance
      .filter((record) => archivedEventIds.has(String(record.eventId)) && (record.attendanceGroup || activeGroup()) === activeGroup() && (record.rosterModeAtEdit || 'Current') === activeMode())
      .map((record) => {
        const event = events.find((item) => String(item.id) === String(record.eventId)) || {};
        return { ...clone(record), memberName: memberName(record.memberId), eventTitle: event.title || event.name || 'Attendance activity', eventDate: event.date || '' };
      })
      .sort((a, b) => String(a.eventDate).localeCompare(String(b.eventDate)) || String(a.memberName).localeCompare(String(b.memberName)));
    const highestArchivedRevision = data.archives
      .filter((entry) => archiveScopeKey(entry) === key)
      .reduce((max, entry) => Math.max(max, Number(entry?.revision) || 0), 0);
    const nextRevision = Math.max(current.revision, highestArchivedRevision) + 1;
    data.monthFinalizations[key] = {
      ...current, state: 'Finalized', revision: nextRevision, finalizedAt: now, finalizedBy: actor,
      reviewedAt: current.reviewedAt || now, reviewedBy: current.reviewedBy || actor,
      reopenedAt: current.reopenedAt || '', reopenedBy: current.reopenedBy || '',
      validation: { ...validation, snapshot: undefined }, snapshot: frozenSnapshot,
      history: [periodAudit('Validated monthly attendance finalized', `${events.length} activit${events.length === 1 ? 'y' : 'ies'} and ${originalRecords.length} records locked and archived.`), ...current.history].slice(0, 100)
    };
    data.archives = data.archives
      .filter((entry) => !(archiveScopeKey(entry) === key && Number(entry?.revision || 1) === nextRevision))
      .map((entry) => archiveScopeKey(entry) === key ? { ...entry, isCurrentFinalizedCopy: false } : entry);
    const finalizedArchive = {
      id: archiveId(), scopeKey: key, month, semester: activeSemester(), attendanceGroup: activeGroup(), rosterMode: 'Current',
      revision: nextRevision, finalizedAt: now, finalizedBy: actor, reviewedAt: current.reviewedAt || now, reviewedBy: current.reviewedBy || actor,
      snapshot: compactArchiveSnapshot(frozenSnapshot, events, originalRecords), locked: true,
      source: 'validated-month-workflow', isCurrentFinalizedCopy: true, integrityStatus: 'verified'
    };
    data.archives.unshift(finalizedArchive);
    data.archives = data.archives.slice(0, 240);
    const semesterKey = periodScopeKey();
    if (data.semesterFinalizations[semesterKey]?.state === 'Finalized') data.semesterFinalizations[semesterKey] = {
      ...data.semesterFinalizations[semesterKey], state: 'Draft', reopenedAt: now, reopenedBy: actor, updatedAt: now,
      stateVersion: Math.max(Number(data.semesterFinalizations[semesterKey]?.stateVersion) || 0, Number(data.semesterFinalizations[semesterKey]?.revision) || 0) + 1,
      mutationId: uid('semester-invalidated'), snapshot: null,
      history: [periodAudit('Semester snapshot invalidated', `Validated month ${month} was finalized or revised.`), ...(data.semesterFinalizations[semesterKey].history || [])].slice(0, 100)
    };
    if (!savePeriodGovernance(data, { source: 'attendance-month-finalized' })) {
      return window.LSOApp?.showToast?.('Attendance records were prepared, but the finalized archive could not be stored. Check System Settings access and try again.', true);
    }
    window.LSOOperations?.logActivity?.('Finalized validated monthly attendance', 'Attendance Audit', `${month} • ${activeSemester()} • ${activeGroup()} • ${events.length} activities • ${originalRecords.length} archived records`);
    selectArchiveId(finalizedArchive.id);
    window.LSOOperations?.setAttendanceRosterMode?.('Archive');
    window.LSOAttendanceWorkspace?.setTab?.('archive', { preserveSelection: true });
    window.LSOApp?.showToast?.('Validated month finalized and added to Monthly Archive.');
    setTimeout(() => {
      window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request', { detail: { source: 'attendance-month-finalized', archiveId: finalizedArchive.id } }));
      render();
      el('attendanceFinalizedArchiveBlock')?.scrollIntoView({ block: 'start', behavior: 'auto' });
    }, 90);
  }

  function reopenMonth() {
    if (!canUnlockAttendance()) return window.LSOApp?.showToast?.('Only an authorized Administrator can reopen a finalized month.', true);
    const month = activeMonth(); const current = monthState(month);
    if (current.state !== 'Finalized') return;
    const reason = window.prompt('Enter the reason for reopening this finalized month:');
    if (reason === null) return;
    if (reason.trim().length < 3) return window.LSOApp?.showToast?.('A clear correction reason is required.', true);
    const now = new Date().toISOString(); const actor = periodActor();
    // Reopening the month changes one governed state instead of rewriting
    // every activity. workflowState() releases any legacy event lock while the
    // monthly state is Reopened.
    const data = loadPeriodGovernance(true); const key = monthScopeKey(month);
    data.monthFinalizations[key] = {
      ...current, state: 'Reopened', reopenedAt: now, reopenedBy: actor, reopenReason: reason.trim(),
      reviewedAt: '', reviewedBy: '', validation: null, snapshot: null,
      history: [periodAudit('Monthly attendance reopened', `${month} reopened for correction.`, reason.trim()), ...current.history].slice(0, 100)
    };
    data.archives = data.archives.map((entry) => archiveScopeKey(entry) === key && entry?.isCurrentFinalizedCopy
      ? { ...entry, isCurrentFinalizedCopy: false, liveMonthReopenedAt: now, liveMonthReopenedBy: actor }
      : entry);
    const semesterKey = periodScopeKey();
    if (data.semesterFinalizations[semesterKey]) data.semesterFinalizations[semesterKey] = {
      ...data.semesterFinalizations[semesterKey], state: 'Draft', snapshot: null, reopenedAt: now, reopenedBy: actor, updatedAt: now,
      stateVersion: Math.max(Number(data.semesterFinalizations[semesterKey]?.stateVersion) || 0, Number(data.semesterFinalizations[semesterKey]?.revision) || 0) + 1,
      mutationId: uid('semester-invalidated'),
      history: [periodAudit('Semester snapshot invalidated', `Month ${month} was reopened.`, reason.trim()), ...(data.semesterFinalizations[semesterKey].history || [])].slice(0, 100)
    };
    if (!savePeriodGovernance(data, { source: 'attendance-month-reopened' })) return window.LSOApp?.showToast?.('The finalized month could not be reopened.', true);
    window.LSOOperations?.setAttendanceRosterMode?.('Current');
    window.LSOAttendanceWorkspace?.setTab?.('current');
    window.LSOOperations?.logActivity?.('Reopened monthly attendance', 'Attendance Audit', `${month} • ${activeGroup()} • ${reason.trim()}`);
    window.LSOApp?.showToast?.('Monthly attendance reopened. Correct the records, review the month again, then create a new finalized revision.');
    setTimeout(() => { window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request')); render(); }, 80);
  }

  function saveSemesterEndDate() {
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can set the semester completion date.', true);
    const scope = scopeIdentity();
    const current = semesterState(scope.semester, scope.group, scope.mode);
    if (current.state === 'Finalized') return window.LSOApp?.showToast?.('Reopen the finalized semester before changing its completion date.', true);
    const input = el('attendanceSemesterEndDate');
    const value = input?.value || '';
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return window.LSOApp?.showToast?.('Enter a valid semester completion date.', true);
    const data = loadPeriodGovernance(true);
    const now = new Date().toISOString();
    data.semesterEndDates[scope.semester] = value;
    data.semesterEndDateUpdates[scope.semester] = { value, updatedAt: now, updatedBy: periodActor(), mutationId: uid('semester-end-date') };
    if (!savePeriodGovernance(data)) return window.LSOApp?.showToast?.('The semester completion date could not be saved. Please reload and try again.', true);
    window.LSOApp?.showToast?.(`${scope.semester} completion date saved.`);
    scheduleRender(0, true);
  }

  function finalizeSemester() {
    if (!canFinalizeAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can finalize a semester rating.', true);
    const scope = scopeIdentity();
    if (semesterTransaction) return window.LSOApp?.showToast?.('A semester attendance update is already being saved. Please wait.', true);
    const data = loadPeriodGovernance(true);
    const endDate = data.semesterEndDates[scope.semester] || '';
    if (!endDate) return window.LSOApp?.showToast?.('Enter and save the semester completion date first.', true);
    if (endDate > today()) return window.LSOApp?.showToast?.('The semester cannot be finalized before its completion date.', true);
    const eventMonths = [...new Set(getEvents().filter((event) =>
      (event.semester || 'First Semester') === scope.semester &&
      eventBelongsToActiveGroup(event, scope.group) &&
      event.date && event.date <= endDate
    ).map((event) => String(event.date).slice(0, 7)))].sort();
    if (!eventMonths.length) return window.LSOApp?.showToast?.('No attendance activities are available for this semester.', true);
    const unfinished = eventMonths.filter((month) => monthState(month, scope.semester, scope.group, scope.mode).state !== 'Finalized');
    if (unfinished.length) return window.LSOApp?.showToast?.(`Finalize these monthly attendance periods first: ${unfinished.join(', ')}.`, true);
    const snapshot = calculateSemesterSnapshot(scope.semester, scope.group, scope.mode, endDate);
    if (!snapshot.monthCount) return window.LSOApp?.showToast?.('No finalized monthly ratings are available for the semester.', true);
    if (!window.confirm(`Finalize ${scope.semester} for ${scope.group} using ${snapshot.monthCount} finalized monthly rating${snapshot.monthCount === 1 ? '' : 's'}?`)) return;

    setSemesterTransaction('finalize', scope, 'Finalized');
    scheduleRender(0, true);
    const current = semesterState(scope.semester, scope.group, scope.mode);
    const now = new Date().toISOString();
    const nextRevision = current.revision + 1;
    data.semesterFinalizations[scope.key] = {
      state: 'Finalized', revision: nextRevision, stateVersion: Math.max(current.stateVersion, current.revision) + 1,
      finalizedAt: now, finalizedBy: periodActor(), reopenedAt: '', reopenedBy: '', endDate, snapshot,
      updatedAt: now, mutationId: uid('semester-finalize'),
      history: [periodAudit('Semester attendance finalized', `${snapshot.monthCount} finalized monthly ratings • ${snapshot.groupRate ?? 'No'}% overall.`), ...current.history].slice(0, 100)
    };
    if (!savePeriodGovernance(data)) {
      clearSemesterTransaction(scope.key);
      scheduleRender(0, true);
      return window.LSOApp?.showToast?.('The semester rating could not be finalized. No workflow state was changed.', true);
    }
    const persisted = semesterState(scope.semester, scope.group, scope.mode);
    if (persisted.state !== 'Finalized' || persisted.revision < nextRevision) {
      clearSemesterTransaction(scope.key);
      scheduleRender(0, true);
      return window.LSOApp?.showToast?.('The semester finalization was not confirmed by browser storage. Please reload before trying again.', true);
    }
    window.LSOOperations?.logActivity?.('Finalized semester attendance', 'Attendance Audit', `${scope.semester} • ${scope.group} • ${snapshot.monthCount} months • ${snapshot.groupRate ?? '—'}%`);
    window.LSOApp?.showToast?.('Semester attendance rating finalized and locked.');
    clearSemesterTransaction(scope.key);
    scheduleRender(0, true);
  }

  function reopenSemester() {
    if (!canUnlockAttendance()) return window.LSOApp?.showToast?.('Only the Administrator can reopen a semester rating.', true);
    const scope = scopeIdentity();
    if (semesterTransaction) return window.LSOApp?.showToast?.('A semester attendance update is already being saved. Please wait.', true);
    const current = semesterState(scope.semester, scope.group, scope.mode);
    if (current.state !== 'Finalized') return;
    const reason = window.prompt('Enter the reason for reopening the finalized semester rating:');
    if (reason === null) return;
    if (reason.trim().length < 3) return window.LSOApp?.showToast?.('A clear correction reason is required.', true);

    setSemesterTransaction('reopen', scope, 'Draft');
    scheduleRender(0, true);
    const data = loadPeriodGovernance(true);
    const now = new Date().toISOString();
    data.semesterFinalizations[scope.key] = {
      ...current, state: 'Draft', snapshot: null, reopenedAt: now, reopenedBy: periodActor(),
      updatedAt: now, stateVersion: Math.max(current.stateVersion, current.revision) + 1, mutationId: uid('semester-reopen'),
      history: [periodAudit('Semester attendance reopened', 'Semester rating reopened for recalculation.', reason.trim()), ...current.history].slice(0, 100)
    };
    if (!savePeriodGovernance(data)) {
      clearSemesterTransaction(scope.key);
      scheduleRender(0, true);
      return window.LSOApp?.showToast?.('The semester could not be reopened. Its finalized state was preserved.', true);
    }
    const persisted = semesterState(scope.semester, scope.group, scope.mode);
    if (persisted.state !== 'Draft') {
      clearSemesterTransaction(scope.key);
      scheduleRender(0, true);
      return window.LSOApp?.showToast?.('The reopened semester state was not confirmed. Please reload before trying again.', true);
    }
    window.LSOApp?.showToast?.('Semester attendance rating reopened for correction.');
    clearSemesterTransaction(scope.key);
    scheduleRender(0, true);
  }

  function attendanceArchives() {
    return loadPeriodGovernance().archives
      .filter((entry) => entry && entry.snapshot)
      .sort((a, b) => String(b.finalizedAt || '').localeCompare(String(a.finalizedAt || '')));
  }

  function visibleAttendanceArchives() {
    return attendanceArchives().filter((entry) =>
      String(entry.semester || 'First Semester') === String(activeSemester()) &&
      String(entry.attendanceGroup || 'Official Members') === String(activeGroup()) &&
      String(entry.rosterMode || 'Current') === 'Current'
    );
  }

  function selectArchiveId(id = '') {
    selectedArchiveId = String(id || '');
    window.LSOSelectedAttendanceArchiveId = selectedArchiveId;
    return selectedArchiveId;
  }

  function selectedAttendanceArchive() {
    const visible = visibleAttendanceArchives();
    if (!visible.length) {
      selectArchiveId('');
      return null;
    }
    const explicit = visible.find((entry) => String(entry.id) === String(selectedArchiveId));
    if (explicit) return explicit;
    const currentMonth = visible.find((entry) => String(entry.month) === String(activeMonth()) && entry.isCurrentFinalizedCopy);
    const latest = currentMonth || visible.find((entry) => entry.isCurrentFinalizedCopy) || visible[0];
    selectArchiveId(latest?.id || '');
    return latest || null;
  }

  const ARCHIVE_PAGE_SIZE = 75;

  function renderArchiveRecordDetails(entry) {
    const count = archiveRecordCount(entry);
    if (!count) return '<small class="attendance-archive-legacy-note">This legacy archive contains a rating snapshot only. Record-level frozen copies are retained for newer finalizations.</small>';
    return `<details class="attendance-archive-original" data-attendance-archive-details="${safeText(entry.id)}"><summary>View Original Finalized Records (${safeText(count)})</summary><div class="attendance-archive-lazy-body" data-attendance-archive-body="${safeText(entry.id)}"><p class="attendance-archive-loading-note">Open this section to load the archived records.</p></div></details>`;
  }

  function renderArchiveRecordPage(id, page = 1) {
    const entry = attendanceArchives().find((item) => String(item.id) === String(id));
    const body = [...document.querySelectorAll('[data-attendance-archive-body]')].find((node) => String(node.dataset.attendanceArchiveBody) === String(id));
    if (!entry || !body) return;
    const rows = archiveSnapshotRows(entry);
    if (!rows.length) {
      body.innerHTML = '<small class="attendance-archive-legacy-note">No record-level rows are available for this archive.</small>';
      return;
    }
    const pages = Math.max(1, Math.ceil(rows.length / ARCHIVE_PAGE_SIZE));
    const currentPage = Math.max(1, Math.min(pages, Number(page) || 1));
    const start = (currentPage - 1) * ARCHIVE_PAGE_SIZE;
    const visible = rows.slice(start, start + ARCHIVE_PAGE_SIZE);
    const controls = pages > 1 ? `<div class="attendance-archive-page-controls"><button class="button button-secondary" type="button" data-attendance-archive-page="${safeText(id)}" data-page="${currentPage - 1}" ${currentPage <= 1 ? 'disabled' : ''}>Previous</button><span>Rows ${safeText(start + 1)}–${safeText(Math.min(rows.length, start + visible.length))} of ${safeText(rows.length)} • Page ${safeText(currentPage)} of ${safeText(pages)}</span><button class="button button-secondary" type="button" data-attendance-archive-page="${safeText(id)}" data-page="${currentPage + 1}" ${currentPage >= pages ? 'disabled' : ''}>Next</button></div>` : '';
    body.innerHTML = `${controls}<div class="table-wrap attendance-archive-record-table"><table><thead><tr><th>Date</th><th>Activity</th><th>Member</th><th>Status</th><th>Remarks</th></tr></thead><tbody>${visible.map((record) => `<tr><td>${safeText(dateLabel(record.eventDate))}</td><td>${safeText(record.eventTitle || 'Activity')}</td><td>${safeText(record.memberName || record.memberId)}</td><td><span class="badge ${record.status === 'Excused' ? 'badge-blue' : record.status === 'Absent' ? 'badge-red' : 'badge-green'}">${safeText(record.status || '—')}</span></td><td>${safeText(record.remarks || '—')}</td></tr>`).join('')}</tbody></table></div>${controls}`;
  }

  function renderArchiveMetrics(entry, compact = false) {
    const snapshot = entry?.snapshot || {};
    const counts = snapshot.counts || {};
    const recordCount = archiveRecordCount(entry);
    const groupRate = snapshot.groupRate == null ? 'No rated attendance' : `${snapshot.groupRate}%`;
    return `<div class="attendance-archive-metrics${compact ? ' is-compact' : ''}"><span><b>${safeText(snapshot.eventCount || 0)}</b> activities</span><span><b>${safeText(recordCount)}</b> records</span><span><b>${safeText(groupRate)}</b> ${compact ? 'rating' : 'verified rating'}</span><span><b>${safeText(counts.Excused || 0)}</b> excused</span></div>`;
  }

  function archiveActionButtons(entry, { compact = false } = {}) {
    const selectLabel = String(entry.id) === String(selectedArchiveId) ? 'Selected Validated Copy' : 'View Validated Copy';
    const deleteButton = isAdmin() || canUnlockAttendance()
      ? `<button class="button button-danger" data-attendance-archive-delete="${safeText(entry.id)}" type="button">Delete Archive</button>`
      : '';
    return `<div class="attendance-archive-actions${compact ? ' is-compact' : ''}"><button class="button button-primary" data-attendance-archive-select="${safeText(entry.id)}" type="button">${safeText(selectLabel)}</button><button class="button button-secondary" data-attendance-archive-open="${safeText(entry.id)}" type="button">Open Live Month</button>${deleteButton}</div>`;
  }

  function renderAttendanceArchive() {
    const container = el('attendanceFinalizedArchiveList');
    if (!container) return;
    const groups = groupedAttendanceArchives();
    const selected = selectedAttendanceArchive();
    container.innerHTML = groups.length ? groups.map((group) => {
      const entry = group.primary;
      const isSelected = String(entry.id) === String(selected?.id);
      const statusLabel = archiveStatusLabel(entry, group);
      const previous = group.previous.length ? `<details class="attendance-archive-revisions"><summary>Previous finalized revisions (${safeText(group.previous.length)})</summary><div class="attendance-archive-revision-list">${group.previous.map((revision) => `<article class="attendance-archive-revision${String(revision.id) === String(selected?.id) ? ' is-selected' : ''}"><div><strong>Revision ${safeText(revision.revision || 1)}</strong><small>Finalized ${safeText(dateLabel(revision.finalizedAt, true))} by ${safeText(revision.finalizedBy || 'Administrator')}</small></div>${renderArchiveMetrics(revision, true)}${archiveActionButtons(revision, { compact: true })}${renderArchiveRecordDetails(revision)}</article>`).join('')}</div></details>` : '';
      return `<article class="attendance-archive-card is-verified${isSelected ? ' is-selected' : ''}" data-attendance-archive-card="${safeText(entry.id)}"><div class="attendance-archive-card-copy"><span>${safeText(entry.month || 'Unknown month')}</span><strong>${safeText(entry.attendanceGroup || 'Attendance')} • ${safeText(entry.semester || 'Semester')}</strong><small>Finalized ${safeText(dateLabel(entry.finalizedAt, true))} by ${safeText(entry.finalizedBy || 'Administrator')} • Revision ${safeText(entry.revision || 1)}</small><em>${safeText(isSelected ? 'Selected Validated Copy' : statusLabel)}</em></div>${renderArchiveMetrics(entry)}${archiveActionButtons(entry)}${renderArchiveRecordDetails(entry)}${previous}</article>`;
    }).join('') : '<div class="empty-state compact-empty"><h4>No validated attendance archives</h4><p>Finalize a Current Roster month for this attendance group. The computed and frozen copy will appear here automatically.</p></div>';
  }

  function selectAttendanceArchive(id, options = {}) {
    const entry = attendanceArchives().find((item) => String(item.id) === String(id));
    if (!entry) return null;
    selectArchiveId(entry.id);
    window.LSOOperations?.setAttendanceSemester?.(entry.semester || 'First Semester');
    window.LSOOperations?.setAttendanceGroup?.(entry.attendanceGroup || 'Official Members');
    window.LSOOperations?.setAttendanceMonth?.(entry.month || activeMonth());
    if (options.keepMode !== true) window.LSOOperations?.setAttendanceRosterMode?.('Archive');
    window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request', { detail: { source: 'attendance-archive-select', archiveId: entry.id } }));
    if (!options.silent) window.LSOApp?.showToast?.(`${entry.month} ${entry.attendanceGroup} validated archive selected.`);
    return entry;
  }

  function openAttendanceArchive(id) {
    const entry = attendanceArchives().find((item) => String(item.id) === String(id));
    if (!entry) return;
    selectArchiveId(entry.id);
    window.LSOOperations?.setAttendanceSemester?.(entry.semester);
    window.LSOOperations?.setAttendanceGroup?.(entry.attendanceGroup);
    window.LSOOperations?.setAttendanceRosterMode?.('Current');
    window.LSOOperations?.setAttendanceMonth?.(entry.month);
    window.LSOApp?.showToast?.(`${entry.month} ${entry.attendanceGroup} live month opened.`);
    setTimeout(() => el('attendancePeriodFinalizationCenter')?.scrollIntoView({ block: 'start', behavior: 'auto' }), 80);
  }

  function deleteAttendanceArchive(id) {
    if (!(isAdmin() || canUnlockAttendance())) return window.LSOApp?.showToast?.('Only an authorized Administrator can delete a finalized attendance archive.', true);
    const data = loadPeriodGovernance(true);
    const index = data.archives.findIndex((entry) => String(entry.id) === String(id));
    if (index < 0) return window.LSOApp?.showToast?.('The selected attendance archive could not be found.', true);
    const entry = data.archives[index];
    const scopeKey = archiveScopeKey(entry);
    const live = data.monthFinalizations[scopeKey] || {};
    const deletesValidatedLiveCopy = live.state === 'Finalized' && (entry.isCurrentFinalizedCopy || Number(entry.revision || 0) === Number(live.revision || 0));
    const warning = deletesValidatedLiveCopy
      ? `Delete the validated ${entry.month} archive? The connected live month will return to Draft so it can be corrected and finalized again.`
      : `Delete this archived revision for ${entry.month}? The connected current finalized copy will remain unchanged.`;
    if (!window.confirm(warning)) return;
    const reason = window.prompt('Enter the reason for deleting this attendance archive:');
    if (reason === null) return;
    if (reason.trim().length < 3) return window.LSOApp?.showToast?.('A clear deletion reason is required.', true);

    const now = new Date().toISOString();
    const actor = periodActor();
    data.archives.splice(index, 1);
    if (deletesValidatedLiveCopy) {
      data.monthFinalizations[scopeKey] = {
        ...live,
        state: 'Draft',
        snapshot: null,
        finalizedAt: '',
        finalizedBy: '',
        reviewedAt: '',
        reviewedBy: '',
        validation: null,
        reopenedAt: '',
        reopenedBy: '',
        reopenReason: '',
        history: [periodAudit('Validated attendance archive deleted', `${entry.month} was returned to Draft.`, reason.trim()), ...(live.history || [])].slice(0, 100)
      };
      // The governed monthly state is authoritative. Do not rewrite every
      // activity here; that created a burst of duplicate saves and could race
      // with shared-database synchronization on slower devices.
      const semesterKey = periodScopeKey(entry.semester, entry.attendanceGroup, entry.rosterMode || 'Current');
      if (data.semesterFinalizations[semesterKey]?.state === 'Finalized') {
        data.semesterFinalizations[semesterKey] = {
          ...data.semesterFinalizations[semesterKey],
          state: 'Draft', snapshot: null, reopenedAt: now, reopenedBy: actor,
          history: [periodAudit('Semester snapshot invalidated', `Validated monthly archive ${entry.month} was deleted.`, reason.trim()), ...(data.semesterFinalizations[semesterKey].history || [])].slice(0, 100)
        };
      }
    }
    if (!savePeriodGovernance(data, { source: 'attendance-archive-delete' })) return;
    window.LSOOperations?.logActivity?.('Deleted attendance archive', 'Attendance Archive', `${entry.month} • ${entry.attendanceGroup} • Revision ${entry.revision || 1} • ${reason.trim()}`);
    if (String(selectedArchiveId) === String(id)) selectArchiveId('');
    if (deletesValidatedLiveCopy) {
      window.LSOOperations?.setAttendanceSemester?.(entry.semester);
      window.LSOOperations?.setAttendanceGroup?.(entry.attendanceGroup);
      window.LSOOperations?.setAttendanceMonth?.(entry.month);
      window.LSOOperations?.setAttendanceRosterMode?.('Current');
      window.LSOApp?.showToast?.('Validated archive deleted. The connected live month is now Draft.');
    } else {
      window.LSOApp?.showToast?.('Archived revision deleted.');
    }
    window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request', { detail: { source: 'attendance-archive-delete' } }));
    scheduleRender(0, true);
  }

  function renderReviewChecklist(validation, state) {
    const container = el('attendanceMonthReviewChecklist');
    const badge = el('attendanceMonthReviewBadge');
    const summary = el('attendanceMonthReviewSummary');
    if (!container) return;
    container.innerHTML = validation.checks.map((check) => `
      <div class="attendance-review-check ${check.ready ? 'is-ready' : 'needs-action'}">
        <span aria-hidden="true">${check.ready ? '✓' : '!'}</span>
        <div><strong>${safeText(check.label)}</strong><small>${safeText(check.helper)}</small></div>
      </div>`).join('');
    if (badge) {
      const label = state === 'Finalized' ? 'Finalized' : state === 'In Review' ? 'Ready to finalize' : validation.ready ? 'Ready for review' : 'Needs attention';
      badge.textContent = label;
      badge.className = `badge ${state === 'Finalized' ? 'badge-green' : state === 'In Review' || validation.ready ? 'badge-blue' : 'badge-gold'}`;
    }
    if (summary) {
      summary.textContent = state === 'Finalized'
        ? 'This validation was frozen with the current finalized archive copy.'
        : state === 'In Review'
          ? `Reviewed by ${monthState().reviewedBy || 'Administrator'} on ${dateLabel(monthState().reviewedAt, true)}. Return for corrections or finalize the validated month.`
          : validation.ready
            ? 'All validation checks currently pass. Select Review Month to lock the month for final verification.'
            : 'Resolve every item marked for attention before moving the month into Review.';
    }
  }

  function renderPeriodCenter() {
    const panel = el('attendancePeriodFinalizationCenter'); if (!panel) return;
    renderAttendanceArchive();
    const archiveMode = activeMode() === 'Archive';
    panel.classList.toggle('hidden', archiveMode);
    if (archiveMode) return;
    const month = monthState();
    const data = loadPeriodGovernance();
    const semester = semesterState();
    const preview = semester.state === 'Finalized' && semester.snapshot ? semester.snapshot : calculateSemesterSnapshot(activeSemester(), activeGroup(), activeMode(), data.semesterEndDates[activeSemester()] || '');
    const monthSnapshot = month.state === 'Finalized' && month.snapshot ? month.snapshot : calculateMonthSnapshot();
    const validation = buildMonthValidation();
    const monthBadge = el('attendanceMonthFinalizationBadge');
    if (monthBadge) {
      monthBadge.textContent = month.state;
      monthBadge.className = `badge ${month.state === 'Finalized' ? 'badge-green' : month.state === 'In Review' ? 'badge-blue' : month.state === 'Reopened' ? 'badge-red' : 'badge-gold'}`;
    }
    if (el('attendanceMonthFinalizationTitle')) el('attendanceMonthFinalizationTitle').textContent = `${activeMonth()} • ${activeGroup()}`;
    if (el('attendanceMonthFinalizationMeta')) {
      const rateText = monthSnapshot.groupRate == null ? 'No rated attendance' : `${monthSnapshot.groupRate}%`;
      el('attendanceMonthFinalizationMeta').textContent = month.state === 'Finalized'
        ? `Verified rating ${rateText} • ${monthSnapshot.eventCount} activities • Revision ${month.revision}`
        : month.state === 'In Review'
          ? `Validation passed • ${validation.eventCount} activities • Working rating ${rateText}`
          : month.state === 'Reopened'
            ? `Reopened for correction • Revision ${month.revision} preserved in archive • Working rating ${rateText}`
            : `${monthSnapshot.eventCount} activities • Working monthly rating ${rateText}`;
    }
    setStateOwnedVisibility(el('reviewAttendanceMonthButton'), monthStateIsEditable(month.state) && canFinalizeAttendance());
    setStateOwnedVisibility(el('returnAttendanceMonthToDraftButton'), month.state === 'In Review' && canUnlockAttendance());
    setStateOwnedVisibility(el('finalizeAttendanceMonthButton'), month.state === 'In Review' && canFinalizeAttendance());
    setStateOwnedVisibility(el('reopenAttendanceMonthButton'), month.state === 'Finalized' && canUnlockAttendance());
    renderReviewChecklist(month.state === 'Finalized' && month.validation ? { ...validation, ...month.validation, checks: validation.checks } : validation, month.state);

    document.querySelectorAll('[data-attendance-stage]').forEach((node) => {
      const stage = node.dataset.attendanceStage;
      const active = stage === month.state || (month.state === 'Reopened' && stage === 'Draft');
      const complete = month.state === 'Finalized' || (month.state === 'In Review' && stage === 'Draft');
      node.classList.toggle('active', active);
      node.classList.toggle('complete', complete && !active);
    });

    const endDate = data.semesterEndDates[activeSemester()] || '';
    const endDateInput = el('attendanceSemesterEndDate');
    if (endDateInput) {
      endDateInput.value = endDate;
      endDateInput.disabled = semester.state === 'Finalized' || Boolean(semesterTransaction);
      endDateInput.title = semester.state === 'Finalized' ? 'Reopen the semester before changing its completion date.' : '';
    }
    const activeScopeKey = periodScopeKey();
    const pending = semesterTransaction?.scope?.key === activeScopeKey ? semesterTransaction : null;
    const visibleState = pending?.expectedState || semester.state;
    const badge = el('attendanceSemesterFinalizationBadge');
    if (badge) {
      badge.textContent = pending ? (pending.action === 'finalize' ? 'Saving…' : 'Reopening…') : visibleState;
      badge.className = `badge ${pending ? 'badge-blue' : visibleState === 'Finalized' ? 'badge-green' : 'badge-gold'}`;
    }
    if (el('attendanceSemesterRatingValue')) el('attendanceSemesterRatingValue').textContent = preview.groupRate == null ? '—' : `${preview.groupRate}%`;
    if (el('attendanceSemesterRatingMeta')) {
      const audit = semester.state === 'Finalized' && semester.finalizedAt ? ` • Finalized ${dateLabel(semester.finalizedAt, true)} • Revision ${semester.revision}` : '';
      el('attendanceSemesterRatingMeta').textContent = `${preview.monthCount || 0} finalized month${preview.monthCount === 1 ? '' : 's'} • Average of monthly ratings${endDate ? ` • Ends ${dateLabel(endDate)}` : ' • End date not set'}${audit}`;
    }
    const saveDateButton = el('saveAttendanceSemesterEndDate');
    if (saveDateButton) {
      setStateOwnedVisibility(saveDateButton, semester.state !== 'Finalized' && canFinalizeAttendance());
      saveDateButton.disabled = Boolean(pending) || !canFinalizeAttendance();
    }
    const finalizeSemesterButton = el('finalizeAttendanceSemesterButton');
    const reopenSemesterButton = el('reopenAttendanceSemesterButton');
    setStateOwnedVisibility(finalizeSemesterButton, !pending && semester.state !== 'Finalized' && canFinalizeAttendance());
    setStateOwnedVisibility(reopenSemesterButton, !pending && semester.state === 'Finalized' && canUnlockAttendance());
    if (pending) {
      const pendingButton = pending.action === 'finalize' ? finalizeSemesterButton : reopenSemesterButton;
      setStateOwnedVisibility(pendingButton, true);
      pendingButton.disabled = true;
      pendingButton.textContent = pending.action === 'finalize' ? 'Finalizing Semester…' : 'Reopening Semester…';
    } else {
      if (finalizeSemesterButton) { finalizeSemesterButton.disabled = false; finalizeSemesterButton.textContent = 'Finalize Semester Rating'; }
      if (reopenSemesterButton) { reopenSemesterButton.disabled = false; reopenSemesterButton.textContent = 'Reopen Semester'; }
    }
    const table = el('attendanceSemesterMonthlyRatesBody');
    if (table) table.innerHTML = preview.months?.length ? preview.months.map((item) => `<tr><td>${safeText(item.month)}</td><td>${safeText(item.eventCount)}</td><td><span class="badge ${item.groupRate == null ? 'badge-gray' : item.groupRate >= 80 ? 'badge-green' : item.groupRate >= 60 ? 'badge-gold' : 'badge-red'}">${item.groupRate == null ? 'No rated attendance' : `${item.groupRate}%`}</span></td><td>Finalized</td></tr>`).join('') : '<tr><td colspan="4"><div class="empty-state compact-empty"><h4>No finalized monthly ratings</h4><p>Review and finalize each calendar month before completing the semester.</p></div></td></tr>';
  }

  function renderGovernance() {
    const event = selectedEvent();
    const container = el('attendanceGovernancePanel');
    if (!container) return;
    container.classList.toggle('hidden', !event);
    if (!event) return;

    const workflow = getWorkflow(event);
    const eventMonth = String(event.date || '').slice(0, 7);
    const monthlyState = Boolean(eventMonth) ? monthState(eventMonth, event.semester || activeSemester(), activeGroup(), activeMode()) : { state: 'Draft' };
    const monthlyLocked = monthStateLocksEditing(monthlyState.state);
    const effectiveWorkflowState = workflowState(event, activeGroup(), activeMode());
    const finalized = effectiveWorkflowState === 'Finalized';
    const badge = el('attendanceWorkflowStatusBadge');
    if (badge) {
      badge.textContent = monthlyLocked ? monthlyState.state : workflow.state;
      badge.className = `badge ${monthlyState.state === 'Finalized' || finalized ? 'badge-green' : monthlyState.state === 'In Review' ? 'badge-blue' : monthlyState.state === 'Reopened' ? 'badge-red' : 'badge-gold'}`;
    }
    if (el('attendanceWorkflowStatusTitle')) {
      el('attendanceWorkflowStatusTitle').textContent = monthlyState.state === 'In Review' ? 'This month is in Review and editing is paused' : monthlyState.state === 'Finalized' ? 'This entire attendance month is finalized and archived' : finalized ? 'This activity is finalized and locked' : 'Activity attendance is editable';
    }
    if (el('attendanceWorkflowStatusMeta')) {
      el('attendanceWorkflowStatusMeta').textContent = monthlyState.state === 'In Review'
        ? `Monthly validation passed for ${eventMonth}. Return the month for corrections before editing this activity.`
        : monthlyState.state === 'Finalized'
        ? `Monthly rating finalized for ${eventMonth}. Reopen the whole month to create a corrected revision.`
        : finalized
          ? `Finalized by ${workflow.finalizedBy || 'Administrator'} on ${dateLabel(workflow.finalizedAt, true)} • Revision ${workflow.revision}`
          : workflow.unlockedAt
          ? `Unlocked by ${workflow.unlockedBy || 'Administrator'} on ${dateLabel(workflow.unlockedAt, true)} • Save corrections and finalize again.`
          : 'Save this activity roster, then complete the monthly Review and Finalize workflow.';
    }

    const finalizeButton = el('finalizeAttendanceButton');
    const unlockButton = el('unlockAttendanceButton');
    if (finalizeButton) finalizeButton.classList.toggle('hidden', finalized || monthlyLocked || !canFinalizeAttendance());
    if (unlockButton) unlockButton.classList.toggle('hidden', !finalized || monthlyLocked || !canUnlockAttendance());

    ['markAllPresent', 'saveAttendanceButton'].forEach((id) => {
      const button = el(id);
      if (!button) return;
      button.disabled = monthlyLocked || finalized;
      button.setAttribute('aria-disabled', monthlyLocked || finalized ? 'true' : 'false');
      button.title = monthlyState.state === 'In Review' ? 'Return the reviewed month for corrections before editing.' : finalized ? 'Reopen the finalized month before editing.' : '';
    });
    document.querySelectorAll('.attendance-status, .attendance-remarks').forEach((control) => {
      const loaLocked = control.closest('[data-loa-excused="true"]') !== null;
      const workflowLocked = monthlyLocked || finalized || !canSaveDraftAttendance();
      control.disabled = loaLocked || workflowLocked;
      if (control.matches('.attendance-remarks')) control.readOnly = loaLocked || workflowLocked;
      control.classList.toggle('attendance-locked-control', loaLocked || workflowLocked);
      control.title = loaLocked
        ? 'Approved LOA is automatically Excused and excluded from attendance computation.'
        : monthlyState.state === 'In Review'
          ? 'The month is in Review. Return it for corrections to edit.'
          : finalized
            ? 'Finalized attendance is locked. Reopen the month for corrections.'
            : '';
    });
    // Activity creation belongs to the currently selected calendar month, not to
    // whichever activity happened to be selected previously. Keeping these scopes
    // separate prevents a finalized old activity from disabling + New Activity in
    // a different Draft/Reopened month.
    const activeMonthWorkflow = monthState(activeMonth(), activeSemester(), activeGroup(), activeMode());
    const createLocked = activeMode() !== 'Current' || monthStateLocksEditing(activeMonthWorkflow.state);
    ['addEventButton', 'createEventOnSelectedDate'].forEach((id) => {
      const control = el(id);
      if (!control) return;
      control.disabled = createLocked;
      control.setAttribute('aria-disabled', createLocked ? 'true' : 'false');
      control.title = activeMode() !== 'Current'
        ? 'Return to Current Attendance to create an activity.'
        : activeMonthWorkflow.state === 'In Review'
          ? 'Return the selected month for corrections before creating an activity.'
          : activeMonthWorkflow.state === 'Finalized'
            ? 'Reopen the selected month before creating an activity.'
            : '';
    });
    ['editEventButton', 'deleteEventButton'].forEach((id) => {
      const control = el(id);
      if (!control) return;
      control.disabled = monthlyLocked;
      control.setAttribute('aria-disabled', monthlyLocked ? 'true' : 'false');
      control.title = monthlyState.state === 'In Review' ? 'Return the activity month for corrections before changing it.' : monthlyState.state === 'Finalized' ? 'Reopen the activity month before changing it.' : '';
    });
    const recordingState = el('attendanceRecordingState');
    if (recordingState) {
      recordingState.className = `attendance-recording-state state-${String(monthlyState.state).toLowerCase().replace(/\s+/g, '-')}`;
      recordingState.innerHTML = monthlyState.state === 'In Review'
        ? '<span>Month in Review</span><small>Activity records are read-only while monthly validation is being confirmed.</small>'
        : monthlyState.state === 'Finalized'
          ? '<span>Finalized and archived</span><small>Reopen the month to make a corrected revision.</small>'
          : monthlyState.state === 'Reopened'
            ? '<span>Reopened revision</span><small>Save corrections, then review the whole month again.</small>'
            : '<span>Draft activity</span><small>Changes are saved only when you select Save Attendance.</small>';
    }

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
    const eventMap = new Map(getEvents().map((event) => [String(event.id ?? ''), event]));
    const records = getAttendance()
      .filter((record) => String(record.memberId ?? '') === String(memberId ?? ''))
      .filter((record) => (record.attendanceGroup || activeGroup()) === activeGroup())
      .filter((record) => (record.rosterModeAtEdit || 'Current') === activeMode())
      .map((record) => ({ record, event: eventMap.get(String(record.eventId ?? '')) }))
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
    if (activeMode() === 'Archive') {
      const entry = selectedAttendanceArchive();
      const snapshot = entry?.snapshot || {};
      const records = entry ? archiveSnapshotRows(entry) : [];
      container.innerHTML = [
        ['Archive Status', entry ? 'Validated' : '—', entry ? `Revision ${entry.revision || 1}` : 'No archive selected'],
        ['Frozen Activities', snapshot.eventCount || 0, entry?.month || activeMonth()],
        ['Frozen Records', records.length || snapshot.recordCount || 0, 'Original finalized copy'],
        ['Verification Coverage', entry ? '100%' : '—', entry ? 'Computed at finalization' : 'Finalize a Current Roster month']
      ].map(([label, value, helper]) => `<div class="attendance-kpi"><span>${safeText(label)}</span><strong>${safeText(value)}</strong><small>${safeText(helper)}</small></div>`).join('');
      return;
    }
    const events = scopedMonthEvents(activeMonth(), activeSemester(), activeGroup());
    const relevant = events.filter((event) => {
      const records = getAttendance().filter((record) => String(record.eventId ?? '') === String(event.id ?? ''));
      return records.some((record) => (record.attendanceGroup || activeGroup()) === activeGroup() && (record.rosterModeAtEdit || 'Current') === activeMode());
    });
    const finalized = relevant.filter((event) => workflowState(event) === 'Finalized').length;
    const drafts = relevant.length - finalized;
    const records = relevant.flatMap((event) => getAttendance().filter((record) =>
      String(record.eventId ?? '') === String(event.id ?? '') &&
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
    if (activeMode() === 'Archive') {
      container.innerHTML = '';
      container.classList.add('hidden');
      return;
    }
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
      const records = getAttendance().filter((record) => String(record.eventId ?? '') === String(event.id ?? '') && record.status);
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
      const drafts = pairs.filter(({ group, mode }) => {
        const eventMonth = String(event.date || '').slice(0, 7);
        const monthlyState = eventMonth ? monthState(eventMonth, event.semester || activeSemester(), group, mode).state : 'Draft';
        // Once a month is under review or finalized, its event-level draft state is
        // represented by the monthly workflow and must not create duplicate alerts.
        if (monthlyState === 'In Review' || monthlyState === 'Finalized') return false;
        return workflowState(event, group, mode) !== 'Finalized';
      });
      if (drafts.length) {
        const workflows = drafts.map(({ group, mode }) => getWorkflow(event, group, mode));
        const reopened = workflows.some((workflow) => workflow.unlockedAt && workflow.history[0]?.action === 'Unlocked for editing');
        const draftLabels = drafts.map(({ group, mode }) => `${group}${mode === 'Archive' ? ' Archive' : ''}`);
        alerts.push({
          type: 'attendance', severity: reopened || ageDays >= 7 ? 'high' : 'medium',
          title: reopened ? `${event.title} was reopened and needs monthly review` : `${event.title} attendance remains Draft`,
          detail: `${dateLabel(event.date)} • ${draftLabels.join(', ')}${reopened ? ' • Corrections are still open.' : ' • Complete the roster, review the month, then finalize.'}`,
          eventId: event.id
        });
      }
    });
    const selectedMonthState = monthState();
    const selectedValidation = buildMonthValidation();
    if (selectedMonthState.state === 'In Review') alerts.push({
      type: 'attendance', severity: 'medium', title: `${activeMonth()} attendance is ready to finalize`,
      detail: `${activeGroup()} • Monthly validation passed. Finalize to create the locked archive copy.`,
      action: 'attendance-month-review', attendanceGroup: activeGroup(), semester: activeSemester(), month: activeMonth()
    });
    else if (selectedMonthState.state === 'Reopened') alerts.push({
      type: 'attendance', severity: 'high', title: `${activeMonth()} attendance was reopened`,
      detail: `${activeGroup()} • Correct the records and review the month again before finalization.`,
      action: 'attendance-month-review', attendanceGroup: activeGroup(), semester: activeSemester(), month: activeMonth()
    });
    else if (selectedMonthState.state === 'Draft' && selectedValidation.eventCount > 0 && selectedValidation.ready) alerts.push({
      type: 'attendance', severity: 'low', title: `${activeMonth()} attendance is ready for review`,
      detail: `${activeGroup()} • All current validation checks pass.`,
      action: 'attendance-month-review', attendanceGroup: activeGroup(), semester: activeSemester(), month: activeMonth()
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

    // Creating a new activity is governed by the active month even when there is
    // no selected activity yet (or the previously selected activity is finalized).
    const createControl = target.closest?.('#addEventButton, #createEventOnSelectedDate');
    if (createControl) {
      const current = monthState(activeMonth(), activeSemester(), activeGroup(), activeMode());
      const createLocked = activeMode() !== 'Current' || monthStateLocksEditing(current.state);
      if (!createLocked) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      window.LSOApp?.showToast?.(
        activeMode() !== 'Current'
          ? 'Return to Current Attendance to create an activity.'
          : current.state === 'In Review'
            ? 'This month is in Review. Return it for corrections before creating an activity.'
            : 'This month is finalized. Reopen it before creating a corrected revision.',
        true
      );
      return;
    }

    const eventRecord = selectedEvent();
    if (!eventRecord) return;
    const eventMonth = String(eventRecord.date || '').slice(0, 7);
    const monthly = monthState(eventMonth, eventRecord.semester || activeSemester(), activeGroup(), activeMode());
    const locked = monthStateLocksEditing(monthly.state) || workflowState(eventRecord) === 'Finalized';
    if (!locked) return;
    const blocked = target.closest?.('#saveAttendanceButton, #markAllPresent, .attendance-status, .attendance-remarks, #editEventButton, #deleteEventButton');
    if (!blocked) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    window.LSOApp?.showToast?.(monthly.state === 'In Review' ? 'This month is in Review. Return it for corrections before editing.' : 'This month is finalized. Reopen it before making a corrected revision.', true);
  }

  let renderTimer = 0;
  let renderFrame = 0;
  let archiveSyncTimer = 0;
  let archiveSyncIdleHandle = 0;
  let archiveSyncQueued = false;
  let archiveSyncRunning = false;
  let archiveDirtyVersion = 1;
  let archiveProcessedVersion = 0;
  let reconcileQueueVersion = 0;
  let reconcileScopeQueue = [];

  function markArchiveDirty() {
    archiveDirtyVersion += 1;
    reconcileScopeQueue = [];
  }

  function runWhenIdle(callback, timeout = 1400) {
    if (typeof window.requestIdleCallback === 'function') {
      archiveSyncIdleHandle = window.requestIdleCallback(() => callback(), { timeout });
      return;
    }
    archiveSyncIdleHandle = window.setTimeout(callback, Math.min(180, timeout));
  }

  function attendanceViewActive() {
    const view = el('attendanceView');
    return Boolean(view && !view.classList.contains('hidden') && view.classList.contains('active'));
  }

  function scheduleRender(delay = 35, force = false) {
    clearTimeout(renderTimer);
    renderTimer = window.setTimeout(() => {
      if (!force && !attendanceViewActive()) return;
      if (renderFrame) window.cancelAnimationFrame(renderFrame);
      renderFrame = window.requestAnimationFrame(() => {
        renderFrame = 0;
        render();
      });
    }, delay);
  }

  function monthSnapshotSignature(snapshot) {
    if (!snapshot) return '';
    const members = Object.entries(snapshot.members || {}).map(([memberId, item]) => ({
      memberId: String(memberId), rate: item?.rate ?? null, eventCount: Number(item?.eventCount || 0),
      counts: item?.counts || {}
    })).sort((a, b) => a.memberId.localeCompare(b.memberId));
    return JSON.stringify({
      month: snapshot.month || '', semester: snapshot.semester || '', attendanceGroup: snapshot.attendanceGroup || '',
      rosterMode: snapshot.rosterMode || 'Current', eventIds: (snapshot.eventIds || []).map(String).sort(),
      eventCount: Number(snapshot.eventCount || 0), recordCount: Number(snapshot.recordCount || 0),
      counts: snapshot.counts || {}, pooledRate: snapshot.pooledRate ?? null, groupRate: snapshot.groupRate ?? null, members
    });
  }

  function scheduleFinalizedArchiveSync(delay = 260, options = {}) {
    const force = Boolean(options.force);
    archiveSyncQueued = true;
    clearTimeout(archiveSyncTimer);
    if (archiveSyncIdleHandle) {
      if (typeof window.cancelIdleCallback === 'function') window.cancelIdleCallback(archiveSyncIdleHandle);
      else clearTimeout(archiveSyncIdleHandle);
      archiveSyncIdleHandle = 0;
    }
    archiveSyncTimer = window.setTimeout(() => {
      runWhenIdle(() => {
        archiveSyncIdleHandle = 0;
        archiveSyncQueued = false;
        if (archiveSyncRunning) {
          archiveSyncQueued = true;
          return;
        }
        if (!force && archiveProcessedVersion === archiveDirtyVersion) return;
        archiveSyncRunning = true;
        const processingVersion = archiveDirtyVersion;
        try {
          const changed = reconcileFinalizedLoaRecords();
          if (!reconcileScopeQueue.length) archiveProcessedVersion = processingVersion;
          else archiveSyncQueued = true;
          if (changed) scheduleRender(20, true);
        } finally {
          archiveSyncRunning = false;
          if (archiveSyncQueued || archiveProcessedVersion !== archiveDirtyVersion) scheduleFinalizedArchiveSync(500);
        }
      });
    }, delay);
  }

  function wireEvents() {
    el('finalizeAttendanceButton')?.addEventListener('click', finalizeAttendance);
    el('unlockAttendanceButton')?.addEventListener('click', unlockAttendance);
    el('exportAttendanceAuditCsv')?.addEventListener('click', exportAuditHistory);
    el('exportAttendanceAnalyticsCsv')?.addEventListener('click', exportOverallAnalytics);
    el('exportIndividualAttendanceCsv')?.addEventListener('click', exportIndividualAnalytics);

    el('reviewAttendanceMonthButton')?.addEventListener('click', reviewMonth);
    el('returnAttendanceMonthToDraftButton')?.addEventListener('click', returnMonthToCorrections);
    el('finalizeAttendanceMonthButton')?.addEventListener('click', finalizeMonth);
    el('reopenAttendanceMonthButton')?.addEventListener('click', reopenMonth);
    el('refreshAttendanceArchiveButton')?.addEventListener('click', () => {
      scheduleFinalizedArchiveSync(0, { force: true });
      scheduleRender(30, true);
    });
    el('attendanceFinalizedArchiveList')?.addEventListener('click', (event) => {
      const selectButton = event.target.closest('[data-attendance-archive-select]');
      if (selectButton) { selectAttendanceArchive(selectButton.dataset.attendanceArchiveSelect); return; }
      const deleteButton = event.target.closest('[data-attendance-archive-delete]');
      if (deleteButton) { deleteAttendanceArchive(deleteButton.dataset.attendanceArchiveDelete); return; }
      const openButton = event.target.closest('[data-attendance-archive-open]');
      if (openButton) { openAttendanceArchive(openButton.dataset.attendanceArchiveOpen); return; }
      const pageButton = event.target.closest('[data-attendance-archive-page]');
      if (pageButton && !pageButton.disabled) renderArchiveRecordPage(pageButton.dataset.attendanceArchivePage, pageButton.dataset.page);
      const summary = event.target.closest('summary');
      const details = summary?.closest('[data-attendance-archive-details]');
      if (details) setTimeout(() => { if (details.open) renderArchiveRecordPage(details.dataset.attendanceArchiveDetails, 1); }, 0);
    });
    el('saveAttendanceSemesterEndDate')?.addEventListener('click', saveSemesterEndDate);
    el('finalizeAttendanceSemesterButton')?.addEventListener('click', finalizeSemester);
    el('reopenAttendanceSemesterButton')?.addEventListener('click', reopenSemester);

    document.addEventListener('click', interceptLockedEdits, true);
    document.addEventListener('change', interceptLockedEdits, true);

    document.addEventListener('click', (event) => {
      const button = event.target.closest?.('#saveAttendanceButton');
      if (!button) return;
      const eventRecord = selectedEvent();
      if (!eventRecord || workflowState(eventRecord) === 'Finalized' || monthState(String(eventRecord.date || '').slice(0, 7), eventRecord.semester || activeSemester(), activeGroup(), activeMode()).state === 'In Review') return;
      beforeSaveSnapshot = clone(scopedAttendanceRecords());
      clearTimeout(saveAuditTimer);
      saveAuditTimer = setTimeout(() => {
        appendDraftSaveAudit(beforeSaveSnapshot);
        beforeSaveSnapshot = null;
        scheduleRender(0, true);
      }, 140);
    }, true);

    el('attendanceIndividualSelect')?.addEventListener('change', () => scheduleRender(15, true));
    el('eventList')?.addEventListener('click', (event) => {
      if (event.target.closest?.('[data-event-id]')) scheduleRender(20, true);
    });
    el('attendanceMemberSearch')?.addEventListener('input', () => {
      clearTimeout(renderTimer);
      renderTimer = window.setTimeout(renderGovernance, 70);
    });

    const reactiveEvents = ['lso:operations-changed', 'lso:members-changed', 'lso:attendance-semester-changed', 'lso:attendance-group-changed',
      'lso:attendance-roster-mode-changed', 'lso:attendance-month-changed', 'lso:attendance-period-changed', 'lso:cloud-state-changed', 'lso:auth-changed'];
    reactiveEvents.forEach((name) => window.addEventListener(name, (event) => {
      scheduleRender(45);
      const source = event?.detail?.source || '';
      if (source === 'attendance-period-governance' || source === 'attendance-archive-integrity') return;
      if (name === 'lso:operations-changed') {
        const key = event?.detail?.key || '';
        if (![EVENTS_KEY, ATTENDANCE_KEY, MONTHLY_KEY].includes(key)) return;
      }
      if (name === 'lso:cloud-state-changed') {
        const keys = Array.isArray(event?.detail?.keys) ? event.detail.keys : [event?.detail?.key].filter(Boolean);
        if (keys.length && !keys.some((key) => [EVENTS_KEY, ATTENDANCE_KEY, MONTHLY_KEY, SETTINGS_KEY].includes(key))) return;
      }
      if (['lso:operations-changed', 'lso:members-changed', 'lso:cloud-state-changed'].includes(name)) {
        markArchiveDirty();
        markValidationDirty();
        scheduleFinalizedArchiveSync(name === 'lso:cloud-state-changed' ? 900 : 420);
      }
    }));
    window.addEventListener('lso:cloud-saved', () => {
      if (!semesterTransaction) return;
      const { scope, expectedState } = semesterTransaction;
      const current = semesterState(scope.semester, scope.group, scope.mode);
      if (current.state === expectedState) clearSemesterTransaction(scope.key);
      scheduleRender(0, true);
    });
    window.addEventListener('lso:storage-error', () => {
      if (!semesterTransaction) return;
      clearSemesterTransaction(semesterTransaction.scope.key);
      scheduleRender(0, true);
    });

    window.addEventListener('lso:monthly-report-changed', () => {
      monthlyReportsCacheRaw = null;
      markValidationDirty();
      markArchiveDirty();
      scheduleFinalizedArchiveSync(420);
      scheduleRender(260);
    });
    document.querySelectorAll('[data-view="attendanceView"]').forEach((button) => button.addEventListener('click', () => {
      scheduleFinalizedArchiveSync(120);
      scheduleRender(140, true);
    }));
  }

  let loaReconciliationRunning = false;
  function reconcileFinalizedLoaRecords() {
    if (loaReconciliationRunning) {
      archiveSyncQueued = true;
      return false;
    }
    const governance = loadPeriodGovernance(true);
    const finalized = Object.entries(governance.monthFinalizations).filter(([, value]) => value?.state === 'Finalized');
    if (!finalized.length) { reconcileScopeQueue = []; return false; }
    if (reconcileQueueVersion !== archiveDirtyVersion || !reconcileScopeQueue.length) {
      reconcileQueueVersion = archiveDirtyVersion;
      reconcileScopeQueue = finalized.map(([scopeKey]) => scopeKey);
    }
    const batchSize = window.LSORuntimeStability?.constrained ? 2 : 5;
    const scopeBatch = new Set(reconcileScopeQueue.splice(0, batchSize));
    const finalizedBatch = finalized.filter(([scopeKey]) => scopeBatch.has(scopeKey));
    const monthlyReports = loadMonthlyReports().reports || {};
    loaReconciliationRunning = true;
    try {
      let attendance = getAttendance().map((record) => ({ ...record }));
      let attendanceChanged = false;
      let governanceChanged = false;
      const allEvents = getEvents();
      finalizedBatch.forEach(([scopeKey, value]) => {
        const parts = scopeKey.split('::');
        if (parts.length < 4) return;
        const [semester, group, mode, month] = parts;
        const events = allEvents.filter((event) =>
          String(event.semester || 'First Semester') === String(semester) &&
          eventBelongsToActiveGroup(event, group) &&
          String(event.date || '').slice(0, 7) === month &&
          (!event.date || event.date <= today())
        );
        let scopeAttendanceChanged = false;
        const canApplyLoa = Object.keys(monthlyReports).length || getMembers().some((member) => normalizeText(member.memberStatus) === 'loa');
        if (canApplyLoa) {
          events.forEach((event) => {
            rosterMembersForEvent(event, group).filter((member) => memberOnLeaveForDate(member, event.date)).forEach((member) => {
              const index = attendance.findIndex((record) =>
                String(record.eventId ?? '') === String(event.id ?? '') &&
                String(record.memberId ?? '') === String(member.id ?? '') &&
                String(record.attendanceGroup || group) === String(group) &&
                String(record.rosterModeAtEdit || 'Current') === String(mode)
              );
              const existing = index >= 0 ? attendance[index] : {};
              if (existing.status === 'Excused' && existing.loaAutoExcused) return;
              const next = { ...existing, eventId: event.id, memberId: member.id, status: 'Excused', remarks: 'Corrected to Excused under the approved LOA attendance policy.', attendanceGroup: group, rosterModeAtEdit: mode, loaAutoExcused: true, createdAt: existing.createdAt || value.finalizedAt || new Date().toISOString(), updatedAt: new Date().toISOString(), updatedBy: 'LOA policy reconciliation' };
              if (index >= 0) attendance[index] = next; else attendance.push(next);
              scopeAttendanceChanged = true;
              attendanceChanged = true;
            });
          });
        }

        const snapshot = calculateMonthSnapshot(month, semester, group, mode, attendance);
        if (monthSnapshotSignature(value.snapshot) !== monthSnapshotSignature(snapshot)) {
          value.snapshot = snapshot;
          governanceChanged = true;
        }
        const scopeEntries = governance.archives.filter((entry) => archiveScopeKey(entry) === scopeKey);
        const highestRevision = scopeEntries.reduce((max, entry) => Math.max(max, Number(entry?.revision) || 0), 0);
        const newestArchivedAt = scopeEntries.reduce((latest, entry) => String(entry?.finalizedAt || '') > latest ? String(entry.finalizedAt) : latest, '');
        let revision = Math.max(1, Number(value.revision) || 1);
        if (String(value.finalizedAt || '') > newestArchivedAt && revision <= highestRevision) {
          revision = highestRevision + 1;
          value.revision = revision;
          governanceChanged = true;
        }
        const eventIds = new Set(events.map((event) => String(event.id ?? '')));
        const originalRecords = attendance
          .filter((record) =>
            eventIds.has(String(record.eventId ?? '')) &&
            String(record.attendanceGroup || group) === String(group) &&
            String(record.rosterModeAtEdit || 'Current') === String(mode) &&
            Boolean(record.status)
          )
          .map((record) => {
            const event = events.find((item) => String(item.id ?? '') === String(record.eventId ?? '')) || {};
            return { ...clone(record), memberName: memberName(record.memberId), eventTitle: event.title || event.name || 'Attendance activity', eventDate: event.date || '' };
          })
          .sort((a, b) => String(a.eventDate).localeCompare(String(b.eventDate)) || String(a.memberName).localeCompare(String(b.memberName)));
        let archiveIndex = governance.archives.findIndex((entry) => archiveScopeKey(entry) === scopeKey && entry?.isCurrentFinalizedCopy && String(entry.finalizedAt || '') === String(value.finalizedAt || ''));
        if (archiveIndex < 0) archiveIndex = governance.archives.findIndex((entry) => archiveScopeKey(entry) === scopeKey && String(entry.finalizedAt || '') === String(value.finalizedAt || ''));
        if (archiveIndex < 0) archiveIndex = governance.archives.findIndex((entry) => archiveScopeKey(entry) === scopeKey && Number(entry.revision || 1) === revision);
        const existingArchive = archiveIndex >= 0 ? governance.archives[archiveIndex] : null;
        const recordSignature = (records) => JSON.stringify((records || []).map((record) => ({
          eventId: String(record.eventId || ''), memberId: String(record.memberId || ''), status: record.status || '', remarks: record.remarks || '', loaAutoExcused: Boolean(record.loaAutoExcused)
        })).sort((a, b) => `${a.eventId}:${a.memberId}`.localeCompare(`${b.eventId}:${b.memberId}`)));
        const archiveNeedsUpdate = !existingArchive || scopeAttendanceChanged ||
          recordSignature(archiveSnapshotRows(existingArchive)) !== recordSignature(originalRecords) ||
          monthSnapshotSignature(existingArchive.snapshot) !== monthSnapshotSignature(snapshot);
        if (archiveNeedsUpdate || !existingArchive?.isCurrentFinalizedCopy) {
          governance.archives = governance.archives.map((entry, index) => archiveScopeKey(entry) === scopeKey && index !== archiveIndex
            ? { ...entry, isCurrentFinalizedCopy: false }
            : entry);
          const correctedArchive = {
            ...(existingArchive || {}),
            id: existingArchive?.id || archiveId('attendance-month-synchronized'),
            scopeKey, month, semester, attendanceGroup: group, rosterMode: mode, revision,
            finalizedAt: value.finalizedAt || existingArchive?.finalizedAt || new Date().toISOString(),
            finalizedBy: value.finalizedBy || existingArchive?.finalizedBy || 'Administrator',
            snapshot: compactArchiveSnapshot(snapshot, events, originalRecords),
            locked: true,
            source: existingArchive?.source || 'synchronized-live-finalized-month',
            isCurrentFinalizedCopy: true,
            integrityStatus: 'verified',
            migratedFromFinalizedMonth: !existingArchive || Boolean(existingArchive.migratedFromFinalizedMonth),
            liveArchiveSyncedAt: new Date().toISOString(),
            loaPolicyCorrection: 'Approved LOA dates are stored as Excused and excluded from ratings and absence streaks.'
          };
          if (archiveIndex >= 0) governance.archives[archiveIndex] = correctedArchive;
          else governance.archives.push(correctedArchive);
          governanceChanged = true;
        }
      });
      governance.archives = governance.archives.sort((a, b) => String(b.finalizedAt || '').localeCompare(String(a.finalizedAt || ''))).slice(0, 240);
      if (attendanceChanged) {
        governance.loaPolicyVersion = Math.max(3, Number(governance.loaPolicyVersion) || 0);
        const attendanceSaved = window.LSOOperations?.replaceAttendance?.(attendance, { source: 'attendance-archive-integrity' });
        if (attendanceSaved === false) return false;
        window.LSOOperations?.logActivity?.('Reconciled finalized attendance archive', 'Attendance Governance', 'Live finalized attendance and archived originals were synchronized. Approved LOA dates were stored as Excused.');
      }
      if ((governanceChanged || attendanceChanged) && !savePeriodGovernance(governance, { source: 'attendance-archive-integrity' })) return false;
      return governanceChanged || attendanceChanged;
    } finally {
      loaReconciliationRunning = false;
      if (archiveSyncQueued) {
        archiveSyncQueued = false;
        scheduleFinalizedArchiveSync(320);
      }
    }
  }

  function compactLegacyArchiveStorage() {
    if (!isAdmin()) return false;
    if (window.LSOCloud?.getSessionToken?.() && window.LSOCloud?.canWrite?.('settings') === false) return false;
    const data = loadPeriodGovernance(true);
    let changed = false;
    data.archives = data.archives.map((entry) => {
      const snapshot = entry?.snapshot || {};
      if (!Array.isArray(snapshot.records) && !Array.isArray(snapshot.events)) return entry;
      changed = true;
      return { ...entry, snapshot: compactArchiveSnapshot(snapshot, snapshot.events || [], snapshot.records || []), compactedAt: new Date().toISOString() };
    });
    if (!changed) return false;
    return savePeriodGovernance(data, { source: 'attendance-archive-compaction' });
  }

  function initialize() {
    wireEvents();
    render();
    window.LSOOperations?.refreshAll?.();
    const compactAndRepair = () => {
      compactLegacyArchiveStorage();
      markArchiveDirty();
      scheduleFinalizedArchiveSync(700, { force: true });
    };
    if (typeof window.requestIdleCallback === 'function') window.requestIdleCallback(compactAndRepair, { timeout: 2400 });
    else window.setTimeout(compactAndRepair, 1200);
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
    reviewMonth,
    returnMonthToCorrections,
    finalizeMonth,
    getMonthValidation: buildMonthValidation,
    getMonthlyArchives: () => clone(attendanceArchives()),
    getVisibleMonthlyArchives: () => clone(visibleAttendanceArchives()),
    getSelectedArchive: () => clone(selectedAttendanceArchive()),
    selectArchive: (id, options) => selectAttendanceArchive(id, options),
    deleteArchive: deleteAttendanceArchive,
    getArchiveRows: (id) => clone(archiveSnapshotRows(attendanceArchives().find((entry) => String(entry.id) === String(id)) || {})),
    renderMonthlyArchives: renderAttendanceArchive,
    reopenMonth,
    finalizeSemester,
    reopenSemester,
    saveSemesterEndDate,
    getMonthState: monthState,
    getSemesterState: semesterState,
    getMonthSnapshot: (month, semester, group, mode) => monthState(month, semester, group, mode).snapshot || calculateMonthSnapshot(month, semester, group, mode),
    getSemesterSnapshot: (semester, group, mode) => semesterState(semester, group, mode).snapshot || calculateSemesterSnapshot(semester, group, mode),
    calculateMonthSnapshot,
    calculateSemesterSnapshot,
    isMemberOnLeaveForDate: (member, date) => memberOnLeaveForDate(member, date),
    synchronizeFinalizedArchives: () => reconcileFinalizedLoaRecords()
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
