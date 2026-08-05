(() => {
  'use strict';
  window.__LSO_ATTENDANCE_WORKFLOW_VERSION__ = 'v8-attendance-lifecycle-workflow';

  const el = (id) => document.getElementById(id);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];
  const normalize = (value) => String(value ?? '').trim().toLowerCase();
  const safeText = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  }[char]));

  let calendarCursor = new Date();
  calendarCursor.setDate(1);
  let selectedCalendarDate = localISO(new Date());
  window.LSOAttendanceMonth = /^\d{4}-\d{2}$/.test(String(window.LSOAttendanceMonth || ''))
    ? String(window.LSOAttendanceMonth)
    : `${calendarCursor.getFullYear()}-${String(calendarCursor.getMonth() + 1).padStart(2, '0')}`;
  window.LSOAttendanceSelectedDate = selectedCalendarDate;
  let selectedAttendanceMemberId = '';
  const SEMESTERS = ['First Semester', 'Second Semester'];
  const ATTENDANCE_GROUPS = ['Official Members', 'Trainee Members', 'Probationary Members'];
  const ATTENDANCE_ROSTER_MODES = ['Current', 'Archive'];
  window.LSOAttendanceSemester = SEMESTERS.includes(window.LSOAttendanceSemester) ? window.LSOAttendanceSemester : 'First Semester';
  window.LSOAttendanceGroup = ATTENDANCE_GROUPS.includes(window.LSOAttendanceGroup) ? window.LSOAttendanceGroup : 'Official Members';
  window.LSOAttendanceRosterMode = ATTENDANCE_ROSTER_MODES.includes(window.LSOAttendanceRosterMode) ? window.LSOAttendanceRosterMode : 'Current';

  const CALENDAR_STATE_KEY = 'lso_attendance_calendar_state_v1';

  function loadCalendarStates() {
    try {
      const parsed = JSON.parse(localStorage.getItem(CALENDAR_STATE_KEY) || '{}');
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch { return {}; }
  }

  function calendarStateKey(group = activeAttendanceGroup(), semester = activeSemester()) {
    return `${semester}::${group}`;
  }

  function saveCalendarState() {
    const states = loadCalendarStates();
    states[calendarStateKey()] = { month: calendarMonthKey(), selectedDate: selectedCalendarDate };
    try { localStorage.setItem(CALENDAR_STATE_KEY, JSON.stringify(states)); } catch { /* device storage can be unavailable */ }
  }

  function restoreCalendarState(group = activeAttendanceGroup(), semester = activeSemester()) {
    const state = loadCalendarStates()[calendarStateKey(group, semester)] || {};
    const month = /^\d{4}-\d{2}$/.test(String(state.month || '')) ? state.month : today().slice(0, 7);
    const selected = /^\d{4}-\d{2}-\d{2}$/.test(String(state.selectedDate || '')) && String(state.selectedDate).slice(0, 7) === month ? state.selectedDate : `${month}-01`;
    calendarCursor = new Date(`${month}-01T00:00:00`);
    selectedCalendarDate = selected;
    window.LSOAttendanceMonth = month;
    window.LSOAttendanceSelectedDate = selected;
  }

  function localISO(date) {
    const offset = date.getTimezoneOffset();
    return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 10);
  }

  function today() {
    return localISO(new Date());
  }

  function addDays(value, amount) {
    const date = new Date(`${value}T00:00:00`);
    if (Number.isNaN(date.getTime())) return value;
    date.setDate(date.getDate() + amount);
    return localISO(date);
  }

  function dateLabel(value, options = {}) {
    if (!value) return '—';
    const date = new Date(String(value).length === 10 ? `${value}T00:00:00` : value);
    if (Number.isNaN(date.getTime())) return String(value);
    return new Intl.DateTimeFormat('en-PH', {
      year: options.year === false ? undefined : 'numeric',
      month: options.short ? 'short' : 'long',
      day: 'numeric',
      weekday: options.weekday ? 'long' : undefined
    }).format(date);
  }

  function getMembers() {
    return window.LSOApp?.getMembers?.() || [];
  }

  function getEvents() {
    return window.LSOOperations?.getEvents?.() || [];
  }

  function getAttendance() {
    return window.LSOOperations?.getAttendance?.() || [];
  }

  function normalizeSemester(value) {
    return SEMESTERS.includes(value) ? value : 'First Semester';
  }

  function activeSemester() {
    return normalizeSemester(window.LSOAttendanceSemester);
  }

  function normalizeAttendanceGroup(value) {
    return ATTENDANCE_GROUPS.includes(value) ? value : 'Official Members';
  }

  function activeAttendanceGroup() {
    const selected = normalizeAttendanceGroup(window.LSOAttendanceGroup);
    if (window.LSORoleAccess?.canUseAttendanceGroup && !window.LSORoleAccess.canUseAttendanceGroup(selected)) {
      const fallback = window.LSORoleAccess.defaultAttendanceGroup?.() || 'Trainee Members';
      window.LSOAttendanceGroup = fallback;
      return normalizeAttendanceGroup(fallback);
    }
    return selected;
  }

  function normalizeAttendanceRosterMode(value) {
    return ATTENDANCE_ROSTER_MODES.includes(value) ? value : 'Current';
  }

  function activeAttendanceRosterMode() {
    return normalizeAttendanceRosterMode(window.LSOAttendanceRosterMode);
  }

  function attendanceGroupShortLabel(group = activeAttendanceGroup()) {
    return ({
      'Official Members': 'Official Members',
      'Trainee Members': 'Trainees',
      'Probationary Members': 'Probationary Members'
    })[normalizeAttendanceGroup(group)];
  }

  function attendanceRosterModeLabel(mode = activeAttendanceRosterMode()) {
    return normalizeAttendanceRosterMode(mode) === 'Archive' ? 'Attendance Archive' : 'Current Roster';
  }

  function archiveModeActive() {
    return activeAttendanceRosterMode() === 'Archive';
  }

  function selectedValidatedArchive() {
    return window.LSOAttendanceGovernance?.getSelectedArchive?.() || null;
  }

  function selectedArchiveRows() {
    const entry = selectedValidatedArchive();
    return entry ? (window.LSOAttendanceGovernance?.getArchiveRows?.(entry.id) || []) : [];
  }

  function currentMemberAttendanceGroup(member) {
    if (!member) return 'Official Members';
    const period = normalize(member.periodGroup);
    const stage = normalize(member.membershipStage);

    // The calculated periodGroup is authoritative. membershipStage is only a
    // fallback for older records that do not yet have a periodGroup value.
    if (period === 'trainee period') return 'Trainee Members';
    if (period === 'probationary period') return 'Probationary Members';
    if (period === 'membership period') return 'Official Members';
    if (stage === 'trainee') return 'Trainee Members';
    if (stage === 'probationary') return 'Probationary Members';
    if (stage === 'regular member') return 'Official Members';

    // Fallback for older/imported profiles whose calculated period label is missing.
    const referenceDate = today();
    const membershipStart = String(member.regularMemberDate || '').slice(0, 10);
    const probationaryStart = String(member.probationaryStartDate || '').slice(0, 10);
    if (membershipStart && referenceDate >= membershipStart) return 'Official Members';
    if (!member.probationarySkipped && probationaryStart && referenceDate >= probationaryStart) return 'Probationary Members';
    return 'Trainee Members';
  }

  function memberIsCurrentlyActive(member) {
    const status = normalize(member?.memberStatus);
    // Older/imported records sometimes have no status. Treat them as active unless
    // they are explicitly marked Nonactive or LOA.
    return !['nonactive', 'loa'].includes(status);
  }

  function memberAttendanceGroupOnDate(member, dateValue) {
    if (!member) return '';
    const date = String(dateValue || today()).slice(0, 10);
    const traineeStart = String(member.traineeStartDate || member.dateRegistered || '').slice(0, 10);
    const probationaryStart = String(member.probationaryStartDate || '').slice(0, 10);
    const membershipStart = String(member.regularMemberDate || '').slice(0, 10);
    const skipped = Boolean(member.probationarySkipped);
    const currentGroup = currentMemberAttendanceGroup(member);

    if (membershipStart && date >= membershipStart) return 'Official Members';
    if (!membershipStart && currentGroup === 'Official Members') return 'Official Members';
    if (!skipped && probationaryStart && date >= probationaryStart) return 'Probationary Members';
    if (!probationaryStart && currentGroup === 'Probationary Members') return 'Probationary Members';
    if (!traineeStart || date >= traineeStart) return 'Trainee Members';
    return currentMemberAttendanceGroup(member);
  }

  function memberHasAttendanceGroupHistory(member, group = activeAttendanceGroup()) {
    const normalizedGroup = normalizeAttendanceGroup(group);
    const currentGroup = currentMemberAttendanceGroup(member);
    if (normalizedGroup === 'Trainee Members') {
      return currentGroup !== 'Trainee Members' && Boolean(member?.traineeStartDate || member?.dateRegistered);
    }
    if (normalizedGroup === 'Probationary Members') {
      return currentGroup === 'Official Members' && Boolean(member?.probationaryStartDate || member?.probationarySkipped);
    }
    return currentGroup === 'Official Members' && !memberIsCurrentlyActive(member);
  }

  function memberMatchesAttendanceRosterMode(member, group = activeAttendanceGroup(), mode = activeAttendanceRosterMode()) {
    if (!member) return false;
    const normalizedGroup = normalizeAttendanceGroup(group);
    if (normalizeAttendanceRosterMode(mode) === 'Current') {
      return memberIsCurrentlyActive(member) && currentMemberAttendanceGroup(member) === normalizedGroup;
    }
    return memberHasAttendanceGroupHistory(member, normalizedGroup);
  }

  function attendanceRecordGroup(record, event, member) {
    if (ATTENDANCE_GROUPS.includes(record?.attendanceGroup)) return record.attendanceGroup;
    return memberAttendanceGroupOnDate(member, event?.date);
  }

  function memberEligibleForAttendanceEvent(member, event) {
    if (!memberMatchesAttendanceRosterMode(member) || !event) return false;

    // Current rosters must always show every person who is currently assigned to
    // the selected membership group. The event date must not hide their name.
    // The saved attendanceGroup field keeps Official, Trainee, and Probationary
    // attendance completely separate even when they use the same event.
    if (activeAttendanceRosterMode() === 'Current') return true;

    // Archive mode remains historical: show a former-stage member when the event
    // occurred during that stage or when a stored record already exists.
    const hasStoredRecord = getAttendance().some((record) =>
      record.eventId === event.id &&
      record.memberId === member.id &&
      attendanceRecordGroup(record, event, member) === activeAttendanceGroup()
    );
    return hasStoredRecord || memberAttendanceGroupOnDate(member, event.date) === activeAttendanceGroup();
  }

  function memberEventsForActiveGroup(member, events) {
    return events.filter((event) => {
      if (memberAttendanceGroupOnDate(member, event.date) === activeAttendanceGroup()) return true;
      return getAttendance().some((record) =>
        record.eventId === event.id &&
        record.memberId === member.id &&
        attendanceRecordGroup(record, event, member) === activeAttendanceGroup()
      );
    });
  }

  function membersForAttendanceGroup() {
    return getMembers()
      .filter((member) => memberMatchesAttendanceRosterMode(member))
      .sort((a, b) => String(a.fullName).localeCompare(String(b.fullName)));
  }

  function groupRecordsForEvents(events) {
    const eventMap = new Map(events.map((event) => [event.id, event]));
    const memberMap = new Map(getMembers().map((member) => [member.id, member]));
    return getAttendance().filter((record) => {
      const event = eventMap.get(record.eventId);
      const member = memberMap.get(record.memberId);
      return Boolean(
        record.status &&
        event &&
        member &&
        memberMatchesAttendanceRosterMode(member) &&
        attendanceRecordGroup(record, event, member) === activeAttendanceGroup()
      );
    });
  }

  function eventSemester(event) {
    return normalizeSemester(event?.semester);
  }

  function eventBelongsToActiveGroup(event, group = activeAttendanceGroup()) {
    if (window.LSOOperations?.eventBelongsToAttendanceGroup) return window.LSOOperations.eventBelongsToAttendanceGroup(event, group);
    const explicit = Array.isArray(event?.attendanceGroups) ? event.attendanceGroups : [event?.attendanceGroup || 'Official Members'];
    return explicit.includes(group);
  }

  function semesterEvents(semester = activeSemester()) {
    return getEvents().filter((event) => eventSemester(event) === normalizeSemester(semester) && eventBelongsToActiveGroup(event));
  }

  function eventIsPastOrToday(event) {
    return !event.date || event.date <= today();
  }

  function rehearsalEvents(semester = activeSemester()) {
    return semesterEvents(semester)
      .filter((event) => normalize(event.type) === 'rehearsal' && eventIsPastOrToday(event))
      .sort((a, b) => String(a.date).localeCompare(String(b.date)));
  }

  function activityEvents(semester = activeSemester()) {
    return semesterEvents(semester)
      .filter(eventIsPastOrToday)
      .sort((a, b) => String(a.date).localeCompare(String(b.date)));
  }


  function monthlyActivityEvents(semester = activeSemester()) {
    return eventsInCalendarMonth(activityEvents(semester));
  }

  function monthlyRehearsalEvents(semester = activeSemester()) {
    return eventsInCalendarMonth(rehearsalEvents(semester));
  }

  function calendarMonthKey() {
    return `${calendarCursor.getFullYear()}-${String(calendarCursor.getMonth() + 1).padStart(2, '0')}`;
  }

  function calendarMonthLabel() {
    return new Intl.DateTimeFormat('en-PH', { month: 'long', year: 'numeric' }).format(calendarCursor);
  }

  function eventsInCalendarMonth(events) {
    const month = calendarMonthKey();
    return events.filter((event) => String(event.date || '').slice(0, 7) === month);
  }

  function setMonthWorkspace(monthDate, { resetDate = true } = {}) {
    calendarCursor = new Date(monthDate.getFullYear(), monthDate.getMonth(), 1);
    if (resetDate) selectedCalendarDate = localISO(calendarCursor);
    window.LSOAttendanceSelectedDate = selectedCalendarDate;
    const month = calendarMonthKey();
    const changed = window.LSOAttendanceMonth !== month;
    window.LSOAttendanceMonth = month;
    saveCalendarState();
    if (changed) {
      if (!window.LSOOperations?.setAttendanceMonth?.(month)) {
        window.dispatchEvent(new CustomEvent('lso:attendance-month-changed', { detail: { month, label: calendarMonthLabel() } }));
      }
    }
  }

  function moveCalendarMonth(amount) {
    const next = new Date(calendarCursor.getFullYear(), calendarCursor.getMonth() + amount, 1);
    setMonthWorkspace(next, { resetDate: true });
    renderEverything();
  }

  function renderMonthWorkspaceSummary(monthlyEvents) {
    const container = el('attendanceMonthWorkspaceSummary');
    if (!container) return;
    const eventIds = new Set(monthlyEvents.map((event) => event.id));
    const records = groupRecordsForEvents(monthlyEvents);
    const finalized = monthlyEvents.filter((event) => eventWorkflowState(event) === 'Finalized').length;
    const draft = Math.max(0, monthlyEvents.length - finalized);
    container.innerHTML = `<div class="month-workspace-copy"><span>Selected month workspace</span><strong>${safeText(calendarMonthLabel())}</strong><small>Only this month’s activities appear in the activity list and attendance workspace. Other months remain stored separately.</small></div>
      <div class="month-workspace-metric"><span>Activities</span><strong>${monthlyEvents.length}</strong><small>Selected semester</small></div>
      <div class="month-workspace-metric"><span>Finalized</span><strong>${finalized}</strong><small>Locked rosters</small></div>
      <div class="month-workspace-metric"><span>Draft</span><strong>${draft}</strong><small>Still editable</small></div>
      <div class="month-workspace-metric"><span>Attendance Marks</span><strong>${records.filter((record) => eventIds.has(record.eventId) && record.status).length}</strong><small>${safeText(attendanceGroupShortLabel())}</small></div>`;
  }

  function statusCounts(records) {
    const statuses = ['Present', 'Late', 'Absent', 'Excused', 'Not Required'];
    return Object.fromEntries(statuses.map((status) => [status, records.filter((record) => record.status === status).length]));
  }

  function rateFromCounts(counts) {
    const denominator = counts.Present + counts.Late + counts.Absent;
    return denominator ? Math.round(((counts.Present + counts.Late) / denominator) * 100) : null;
  }

  function eventWorkflowState(event, group = activeAttendanceGroup(), mode = activeAttendanceRosterMode()) {
    if (window.LSOAttendanceGovernance?.workflowState) return window.LSOAttendanceGovernance.workflowState(event, group, mode);
    const key = `${group}::${mode}`;
    return event?.attendanceWorkflows?.[key]?.state === 'Finalized' ? 'Finalized' : 'Draft';
  }

  function memberSummaryForEvents(memberId, events) {
    const attendance = getAttendance();
    const member = getMembers().find((item) => item.id === memberId);
    const scopedEvents = member ? memberEventsForActiveGroup(member, events) : [];
    const eventMap = new Map(scopedEvents.map((event) => [event.id, event]));
    const records = attendance.filter((record) => {
      const event = eventMap.get(record.eventId);
      return record.memberId === memberId && event && attendanceRecordGroup(record, event, member) === activeAttendanceGroup();
    });
    const counts = statusCounts(records);
    return {
      events: scopedEvents,
      records,
      counts,
      totalEvents: scopedEvents.length,
      totalRehearsals: scopedEvents.length,
      recorded: records.filter((record) => record.status).length,
      rate: rateFromCounts(counts)
    };
  }

  function memberRehearsalSummary(memberId) {
    return memberSummaryForEvents(memberId, monthlyRehearsalEvents());
  }

  function metricMarkup(label, value, helper = '') {
    return `<div class="attendance-kpi"><span>${safeText(label)}</span><strong>${safeText(value)}</strong><small>${safeText(helper)}</small></div>`;
  }

  function renderValidatedArchiveOverall(metrics, tableBody) {
    const entry = selectedValidatedArchive();
    if (!entry) {
      metrics.innerHTML = metricMarkup('Validated Archives', 0, `${attendanceGroupShortLabel()} • ${activeSemester()}`);
      tableBody.innerHTML = '<tr><td colspan="7"><div class="empty-state compact-empty"><h4>No validated archive selected</h4><p>Finalize a Current Roster month or select a finalized copy from Attendance Archive.</p></div></td></tr>';
      if (el('overallAttendanceCaption')) el('overallAttendanceCaption').textContent = `No validated ${attendanceGroupShortLabel().toLowerCase()} archive is available for ${activeSemester()}.`;
      if (el('attendanceGroupHeading')) el('attendanceGroupHeading').textContent = `Validated Archive — ${attendanceGroupShortLabel()}`;
      return;
    }
    const snapshot = entry.snapshot || {};
    const counts = snapshot.counts || {};
    const members = Object.entries(snapshot.members || {}).map(([id, item]) => ({ id, ...(item || {}) })).sort((a, b) => String(a.memberName || '').localeCompare(String(b.memberName || '')));
    const recordCount = Number(snapshot.recordCount) || selectedArchiveRows().length;
    metrics.innerHTML = [
      metricMarkup('Validated Month', entry.month || '—', `Revision ${entry.revision || 1}`),
      metricMarkup('Archived Members', members.length, attendanceGroupShortLabel()),
      metricMarkup('Activities', snapshot.eventCount || 0, `${recordCount} frozen records`),
      metricMarkup('Present', counts.Present || 0),
      metricMarkup('Excused', counts.Excused || 0, 'Excluded from rating'),
      metricMarkup('Verified Rating', snapshot.groupRate == null ? '—' : `${snapshot.groupRate}%`, 'Computed at finalization')
    ].join('');
    if (el('overallAttendanceCaption')) el('overallAttendanceCaption').textContent = `${entry.month} • ${entry.semester} • Finalized ${dateLabel(entry.finalizedAt, { short: true })} • Revision ${entry.revision || 1} • ${recordCount} frozen records`;
    if (el('attendanceGroupHeading')) el('attendanceGroupHeading').textContent = `Validated Archive — ${attendanceGroupShortLabel()}`;
    tableBody.innerHTML = members.length ? members.map((member) => {
      const memberCounts = member.counts || {};
      return `<tr><td><strong>${safeText(member.memberName || member.id)}</strong><small class="table-subtext">Validated ${safeText(entry.month)} • Revision ${safeText(entry.revision || 1)}</small></td><td>${safeText(member.eventCount || 0)}</td><td>${safeText(memberCounts.Present || 0)}</td><td>${safeText(memberCounts.Late || 0)}</td><td>${safeText(memberCounts.Absent || 0)}</td><td>${safeText(memberCounts.Excused || 0)}</td><td><span class="badge ${member.rate == null ? 'badge-gray' : member.rate >= 80 ? 'badge-green' : member.rate >= 60 ? 'badge-gold' : 'badge-red'}">${member.rate == null ? 'No rated attendance' : `${safeText(member.rate)}%`}</span></td></tr>`;
    }).join('') : '<tr><td colspan="7"><div class="empty-state compact-empty"><h4>No member records in this archive</h4><p>The selected finalized copy contains no rated member rows.</p></div></td></tr>';
  }

  function renderOverallAttendance() {
    const metrics = el('overallAttendanceMetrics');
    const tableBody = el('attendanceOverallTableBody');
    if (!metrics || !tableBody) return;
    if (archiveModeActive()) {
      renderValidatedArchiveOverall(metrics, tableBody);
      return;
    }

    const allEvents = monthlyActivityEvents();
    const members = membersForAttendanceGroup(monthlyRehearsalEvents());
    const memberIds = new Set(members.map((member) => member.id));
    const events = allEvents.filter((event) => members.some((member) => memberEligibleForAttendanceEvent(member, event)));
    const records = groupRecordsForEvents(events).filter((record) => memberIds.has(record.memberId));
    const counts = statusCounts(records);
    const marked = records.length;
    const overallRate = rateFromCounts(counts);
    const percent = (count) => marked ? `${Math.round((count / marked) * 100)}%` : '0%';

    metrics.innerHTML = [
      metricMarkup('Group Members', members.length, attendanceGroupShortLabel()),
      metricMarkup('Recorded Activities', events.length, `${marked} attendance marks`),
      metricMarkup('Present', counts.Present, percent(counts.Present)),
      metricMarkup('Late', counts.Late, percent(counts.Late)),
      metricMarkup('Absent', counts.Absent, percent(counts.Absent)),
      metricMarkup('Overall Rate', overallRate === null ? '—' : `${overallRate}%`, 'Present + Late ÷ counted')
    ].join('');

    if (el('overallAttendanceCaption')) {
      el('overallAttendanceCaption').textContent = events.length
        ? `${attendanceRosterModeLabel()} • ${attendanceGroupShortLabel()} • ${calendarMonthLabel()} • ${events.length} completed activit${events.length === 1 ? 'y' : 'ies'} • ${marked} recorded statuses`
        : `No completed ${attendanceRosterModeLabel().toLowerCase()} ${attendanceGroupShortLabel().toLowerCase()} attendance activities in ${calendarMonthLabel()}.`;
    }
    if (el('attendanceGroupHeading')) el('attendanceGroupHeading').textContent = `${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()}`;

    tableBody.innerHTML = members.length ? members.map((member) => {
      const summary = memberRehearsalSummary(member.id);
      return `<tr>
        <td><strong>${safeText(member.fullName)}</strong><small class="table-subtext">${safeText(member.membershipId)} • ${safeText(member.periodGroup)}</small></td>
        <td>${summary.totalRehearsals}</td>
        <td>${summary.counts.Present}</td>
        <td>${summary.counts.Late}</td>
        <td>${summary.counts.Absent}</td>
        <td>${summary.counts.Excused}</td>
        <td><span class="badge ${summary.rate === null ? 'badge-gray' : summary.rate >= 80 ? 'badge-green' : summary.rate >= 60 ? 'badge-gold' : 'badge-red'}">${summary.rate === null ? 'No data' : `${summary.rate}%`}</span></td>
      </tr>`;
    }).join('') : `<tr><td colspan="7"><div class="empty-state compact-empty"><h4>No ${safeText(attendanceGroupShortLabel())} records</h4><p>Members assigned to this attendance group will appear here.</p></div></td></tr>`;
  }

  function populateIndividualSelect() {
    const select = el('attendanceIndividualSelect');
    if (!select) return;
    const current = selectedAttendanceMemberId || select.value;
    if (archiveModeActive()) {
      const entry = selectedValidatedArchive();
      const members = Object.entries(entry?.snapshot?.members || {}).map(([id, item]) => ({ id, name: item?.memberName || id })).sort((a, b) => a.name.localeCompare(b.name));
      select.innerHTML = '<option value="">Choose an archived member…</option>' + members.map((member) => `<option value="${safeText(member.id)}">${safeText(member.name)} — ${safeText(entry?.month || 'Validated archive')}</option>`).join('');
      if (members.some((member) => String(member.id) === String(current))) select.value = current;
      else selectedAttendanceMemberId = '';
      return;
    }
    const members = membersForAttendanceGroup(monthlyRehearsalEvents());
    select.innerHTML = '<option value="">Choose a member…</option>' + members.map((member) =>
      `<option value="${safeText(member.id)}">${safeText(member.fullName)} — ${safeText(member.periodGroup)}</option>`
    ).join('');
    if (members.some((member) => member.id === current)) select.value = current;
  }

  function renderIndividualAttendance() {
    const container = el('individualAttendanceSummary');
    const history = el('individualAttendanceHistory');
    const actions = el('individualReportActions');
    if (!container || !history || !actions) return;

    if (archiveModeActive()) {
      const entry = selectedValidatedArchive();
      const member = entry?.snapshot?.members?.[selectedAttendanceMemberId];
      if (!entry || !member) {
        container.innerHTML = '<div class="dashboard-empty-state"><span>⌕</span><strong>Select an archived member</strong><small>The validated monthly totals and frozen attendance rows will appear here.</small></div>';
        history.innerHTML = '';
        actions.classList.add('hidden');
        return;
      }
      const counts = member.counts || {};
      const name = member.memberName || selectedAttendanceMemberId;
      container.innerHTML = `<div class="individual-member-heading"><div class="member-avatar">${safeText(String(name).split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toUpperCase())}</div><div><strong>${safeText(name)}</strong><small>Validated ${safeText(entry.month)} • ${safeText(entry.attendanceGroup)} • Revision ${safeText(entry.revision || 1)}</small></div></div><div class="individual-stat-grid">${metricMarkup('Archived Activities', member.eventCount || 0, entry.month)}${metricMarkup('Present', counts.Present || 0)}${metricMarkup('Late', counts.Late || 0)}${metricMarkup('Absent', counts.Absent || 0)}${metricMarkup('Excused', counts.Excused || 0)}${metricMarkup('Verified Rating', member.rate == null ? '—' : `${member.rate}%`, 'Excused excluded')}</div>`;
      const rows = selectedArchiveRows().filter((record) => String(record.memberId) === String(selectedAttendanceMemberId));
      history.innerHTML = rows.length ? `<div class="individual-history-header"><strong>${safeText(entry.month)} Validated Attendance</strong><span>${rows.length} frozen records</span></div>${rows.map((record) => { const badge = record.status === 'Present' ? 'badge-green' : record.status === 'Absent' ? 'badge-red' : record.status === 'Excused' || record.status === 'Late' ? 'badge-gold' : 'badge-gray'; return `<div class="attendance-history-row"><div><strong>${safeText(record.eventTitle || 'Attendance activity')}</strong><small>${safeText(dateLabel(record.eventDate, { short: true }))}</small></div><span class="badge ${badge}">${safeText(record.status || '—')}</span><span class="badge badge-green">Validated</span><small>${safeText(record.remarks || '')}</small></div>`; }).join('')}` : '<div class="dashboard-empty-state"><span>□</span><strong>No frozen attendance rows</strong><small>This archive contains a rating snapshot without record-level rows.</small></div>';
      actions.classList.add('hidden');
      return;
    }

    const member = membersForAttendanceGroup(monthlyRehearsalEvents()).find((item) => item.id === selectedAttendanceMemberId);
    if (!member) {
      container.innerHTML = '<div class="dashboard-empty-state"><span>⌕</span><strong>Select a member</strong><small>Their rehearsal totals and printable history will appear here.</small></div>';
      history.innerHTML = '';
      actions.classList.add('hidden');
      return;
    }

    const summary = memberRehearsalSummary(member.id);
    container.innerHTML = `<div class="individual-member-heading"><div class="member-avatar">${safeText(String(member.fullName || 'M').split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toUpperCase())}</div><div><strong>${safeText(member.fullName)}</strong><small>${safeText(member.membershipId)} • ${safeText(member.periodGroup)}</small></div></div>
      <div class="individual-stat-grid">
        ${metricMarkup('Monthly Rehearsals', summary.totalRehearsals, calendarMonthLabel())}
        ${metricMarkup('Present', summary.counts.Present)}
        ${metricMarkup('Late', summary.counts.Late)}
        ${metricMarkup('Absent', summary.counts.Absent)}
        ${metricMarkup('Excused', summary.counts.Excused)}
        ${metricMarkup('Attendance Rate', summary.rate === null ? '—' : `${summary.rate}%`, 'Excused excluded')}
      </div>`;

    const attendanceByEvent = new Map(summary.records.map((record) => [record.eventId, record]));
    history.innerHTML = summary.events.length ? `<div class="individual-history-header"><strong>${safeText(calendarMonthLabel())} Rehearsal History</strong><span>${summary.recorded} of ${summary.totalRehearsals} marked</span></div>${summary.events.map((event) => {
      const record = attendanceByEvent.get(event.id) || {};
      const status = record.status || 'Not marked';
      const badge = status === 'Present' ? 'badge-green' : status === 'Late' || status === 'Excused' ? 'badge-gold' : status === 'Absent' ? 'badge-red' : 'badge-gray';
      const workflow = eventWorkflowState(event, record.attendanceGroup || activeAttendanceGroup(), record.rosterModeAtEdit || activeAttendanceRosterMode());
      return `<div class="attendance-history-row"><div><strong>${safeText(event.title)}</strong><small>${safeText(dateLabel(event.date, { short: true }))}${event.venue ? ` • ${safeText(event.venue)}` : ''}</small></div><span class="badge ${badge}">${safeText(status)}</span><span class="badge ${workflow === 'Finalized' ? 'badge-green' : 'badge-gold'}">${safeText(workflow)}</span><small>${safeText(record.remarks || '')}</small></div>`;
    }).join('')}` : '<div class="dashboard-empty-state"><span>□</span><strong>No completed rehearsals</strong><small>Create rehearsal events in the attendance calendar.</small></div>';
    actions.classList.remove('hidden');
  }

  function renderCalendar() {
    const grid = el('attendanceCalendarGrid');
    if (!grid || archiveModeActive()) return;
    const year = calendarCursor.getFullYear();
    const month = calendarCursor.getMonth();
    const monthStart = new Date(year, month, 1);
    const gridStart = new Date(year, month, 1 - monthStart.getDay());
    const monthlyEvents = eventsInCalendarMonth(semesterEvents());
    const eventsByDate = new Map();
    monthlyEvents.forEach((event) => {
      if (!eventsByDate.has(event.date)) eventsByDate.set(event.date, []);
      eventsByDate.get(event.date).push(event);
    });
    renderMonthWorkspaceSummary(monthlyEvents);

    el('attendanceCalendarMonth').textContent = `${new Intl.DateTimeFormat('en-PH', { month: 'long', year: 'numeric' }).format(monthStart)} — ${activeSemester()} — ${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()}`;
    const cells = [];
    for (let index = 0; index < 42; index += 1) {
      const date = new Date(gridStart);
      date.setDate(gridStart.getDate() + index);
      const iso = localISO(date);
      const outside = date.getMonth() !== month;
      const dayEvents = outside ? [] : (eventsByDate.get(iso) || []);
      const selected = !outside && iso === selectedCalendarDate;
      const isToday = !outside && iso === today();
      cells.push(`<button class="attendance-calendar-day${outside ? ' outside-month' : ''}${selected ? ' selected' : ''}${isToday ? ' today' : ''}" ${outside ? 'disabled aria-hidden="true" tabindex="-1"' : `data-calendar-date="${iso}"`} type="button">
        <span class="calendar-day-number">${date.getDate()}</span>
        <span class="calendar-day-events">${dayEvents.slice(0, 3).map((event) => `<em class="calendar-event-pill ${normalize(event.type) === 'rehearsal' ? 'rehearsal' : ''}">${safeText(event.title)}</em>`).join('')}${dayEvents.length > 3 ? `<em class="calendar-more">+${dayEvents.length - 3} more</em>` : ''}</span>
      </button>`);
    }
    grid.innerHTML = cells.join('');
    renderSelectedCalendarDate();
  }

  function renderSelectedCalendarDate() {
    const events = semesterEvents().filter((event) => event.date === selectedCalendarDate);
    if (el('calendarSelectedDateLabel')) el('calendarSelectedDateLabel').textContent = dateLabel(selectedCalendarDate, { weekday: true });
    if (el('calendarSelectedDateMeta')) el('calendarSelectedDateMeta').textContent = events.length
      ? `${events.length} scheduled event${events.length === 1 ? '' : 's'} • click the date again to open the first one`
      : 'No event scheduled. Create a rehearsal for this date.';
  }

  function selectCalendarDate(value, openEvent = true) {
    selectedCalendarDate = value;
    window.LSOAttendanceSelectedDate = value;
    saveCalendarState();
    const selectedDate = new Date(`${value}T00:00:00`);
    if (!Number.isNaN(selectedDate.getTime())) {
      setMonthWorkspace(selectedDate, { resetDate: false });
    }
    renderCalendar();
    const event = semesterEvents().find((item) => item.date === value);
    if (event && openEvent) {
      if (el('eventSearch')) el('eventSearch').value = '';
      window.LSOOperations?.refreshAll?.();
      setTimeout(() => document.querySelector(`[data-event-id="${cssEscape(event.id)}"]`)?.click(), 20);
    }
  }

  function cssEscape(value) {
    return window.CSS?.escape ? window.CSS.escape(String(value)) : String(value).replace(/["\\]/g, '\\$&');
  }

  function createEventOnSelectedDate() {
    el('addEventButton')?.click();
    setTimeout(() => {
      if (el('eventDate')) el('eventDate').value = selectedCalendarDate || today();
      if (el('eventType')) el('eventType').value = 'Rehearsal';
      if (el('eventSemester')) el('eventSemester').value = activeSemester();
      if (el('eventAttendanceGroup')) el('eventAttendanceGroup').value = activeAttendanceGroup();
      if (el('eventTitle') && !el('eventTitle').value) el('eventTitle').value = 'Full Orchestra Rehearsal';
      el('eventTitle')?.focus();
    }, 20);
  }

  function printableDocument({ title, subtitle, summaryHtml, tableHtml, footer = '' }) {
    return `<!doctype html><html><head><title>${safeText(title)}</title><style>
      @page{size:A4 portrait;margin:0}*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#17211d;margin:0}.summary{display:grid}.report-section{margin:18px 0 8px}.sign{display:grid;grid-template-columns:1fr 1fr}.footer{font-size:9px;text-align:center}${window.LSOBrand?.printCss || ''}</style></head><body class="lso-print-portrait">
      ${window.LSOBrand.printHeader({ title, subtitle, meta: `Generated ${dateLabel(today())}` })}
      ${summaryHtml}${tableHtml}<div class="sign"><div>Prepared by</div><div>Authorized Officer</div></div><div class="footer">${safeText(footer || 'Generated from the LSO Orchestra Management System.')}</div>${window.LSOBrand.printRuntimeScript}</body></html>`;
  }

  function openPrintDocument(html) {
    const popup = window.open('', '_blank', 'width=1100,height=800');
    if (!popup) {
      window.LSOApp?.showToast?.('Allow pop-ups to generate the printable report.', true);
      return;
    }
    popup.document.write(html);
    popup.document.close();
  }

  function printIndividualAttendance() {
    const member = getMembers().find((item) => item.id === selectedAttendanceMemberId);
    if (!member) return;
    const snapshot = window.LSOAttendanceGovernance?.getSemesterSnapshot?.(activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode()) || { members: {}, months: [], groupRate: null, endDate: '' };
    const item = snapshot.members?.[member.id] || { monthlyRates: [], rate: null, monthsCounted: 0 };
    const rows = (item.monthlyRates || []).map((entry) => `<tr><td>${safeText(entry.month)}</td><td>${entry.rate == null ? '—' : `${entry.rate}%`}</td><td>Finalized monthly rating</td></tr>`).join('');
    const summaryHtml = `<div class="summary">${[
      ['Member', member.fullName], ['Attendance Group', attendanceGroupShortLabel()], ['Semester', activeSemester()], ['Months Counted', item.monthsCounted || 0], ['Semester Rate', item.rate == null ? '—' : `${item.rate}%`], ['Completion Date', snapshot.endDate ? dateLabel(snapshot.endDate) : 'Not set']
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    openPrintDocument(printableDocument({
      title: `${member.fullName} — ${attendanceGroupShortLabel()} Semestral Attendance`,
      subtitle: `${activeSemester()} • ${member.membershipId || 'No membership ID'} • average of finalized monthly ratings`,
      summaryHtml,
      tableHtml: `<table><thead><tr><th>Month</th><th>Final Rating</th><th>Basis</th></tr></thead><tbody>${rows || '<tr><td colspan="3">No finalized monthly ratings for this member.</td></tr>'}</tbody></table>`
    }));
  }

  function eventDetailReportTable(events) {
    const attendance = getAttendance();
    const rows = events.map((event) => {
      const memberMap = new Map(getMembers().map((member) => [member.id, member]));
      const records = attendance.filter((record) => {
        const member = memberMap.get(record.memberId);
        return record.eventId === event.id && record.status && member && memberMatchesAttendanceRosterMode(member) && attendanceRecordGroup(record, event, member) === activeAttendanceGroup();
      });
      const workflow = eventWorkflowState(event);
      return `<tr><td>${safeText(dateLabel(event.date, { short: true }))}</td><td>${safeText(event.title)}</td><td>${safeText(event.type || 'Activity')}</td><td>${safeText(event.venue || '—')}</td><td>${safeText(workflow)}</td><td>${records.length}</td></tr>`;
    }).join('');
    return `<h2 class="report-section">Activity Breakdown</h2><p class="report-note">Each row lists one completed activity, its verification state, and the number of recorded attendance entries.</p><table><thead><tr><th>Date</th><th>Activity</th><th>Type</th><th>Venue</th><th>Verification</th><th>Recorded</th></tr></thead><tbody>${rows || '<tr><td colspan="6">No completed activities in this report period.</td></tr>'}</tbody></table>`;
  }

  function printCurrentAttendanceGroupRoster() {
    const members = membersForAttendanceGroup();
    const rehearsals = monthlyRehearsalEvents();
    const records = groupRecordsForEvents(rehearsals);
    const modeLabel = attendanceRosterModeLabel();
    const summaryHtml = `<div class="summary">${[
      [modeLabel, members.length],
      ['Month', calendarMonthLabel()],
      ['Recorded Entries', records.length]
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    const rows = members.map((member) => {
      const summary = memberRehearsalSummary(member.id);
      const recordStatus = activeAttendanceRosterMode() === 'Archive' ? 'Archived Attendance Record' : 'Current';
      return `<tr><td>${safeText(member.fullName)}</td><td>${safeText(member.membershipId || '—')}</td><td>${safeText(member.orchestraSection || '—')}</td><td>${safeText(member.primaryInstrument || '—')}</td><td>${safeText(recordStatus)}</td><td>${summary.rate === null ? '—' : `${summary.rate}%`}</td></tr>`;
    }).join('');
    openPrintDocument(printableDocument({
      title: `${modeLabel} — ${attendanceGroupShortLabel()} Attendance`,
      subtitle: `${calendarMonthLabel()} • ${activeSemester()} • ${activeAttendanceRosterMode() === 'Archive' ? 'Completed-stage records only' : 'Current active roster only'}`,
      summaryHtml,
      tableHtml: `<table><thead><tr><th>Member</th><th>Membership ID</th><th>Section</th><th>Instrument</th><th>Record Status</th><th>Attendance Rate</th></tr></thead><tbody>${rows || '<tr><td colspan="6">No members in this attendance roster.</td></tr>'}</tbody></table>`
    }));
  }

  function printOverallAttendance() {
    const semesterState = window.LSOAttendanceGovernance?.getSemesterState?.(activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode());
    if (!semesterState || semesterState.state !== 'Finalized') {
      return window.LSOApp?.showToast?.('Finalize the semestral attendance rating before printing the official semester report.', true);
    }
    const snapshot = window.LSOAttendanceGovernance?.getSemesterSnapshot?.(activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode()) || { monthCount: 0, months: [], members: {}, groupRate: null, endDate: '' };
    const membersById = new Map(getMembers().map((member) => [member.id, member]));
    const memberRows = Object.entries(snapshot.members || {}).map(([memberId, item]) => {
      const member = membersById.get(memberId) || { fullName: item.memberName || memberId, membershipId: '' };
      const monthlyRates = (item.monthlyRates || []).map((entry) => `${entry.month}: ${entry.rate == null ? '—' : `${entry.rate}%`}`).join(' • ');
      return `<tr><td>${safeText(member.fullName)}</td><td>${safeText(member.membershipId || '—')}</td><td>${safeText(item.monthsCounted || 0)}</td><td>${item.rate == null ? '—' : `${item.rate}%`}</td><td>${safeText(monthlyRates || 'No finalized monthly rating')}</td></tr>`;
    }).join('');
    const monthRows = (snapshot.months || []).map((item) => `<tr><td>${safeText(item.month)}</td><td>${safeText(item.eventCount || 0)}</td><td>${item.groupRate == null ? '—' : `${item.groupRate}%`}</td><td>Finalized</td></tr>`).join('');
    const summaryHtml = `<div class="summary">${[
      ['Attendance Group', attendanceGroupShortLabel()], ['Semester', activeSemester()], ['Completion Date', snapshot.endDate ? dateLabel(snapshot.endDate) : 'Not set'], ['Finalized Months', snapshot.monthCount || 0], ['Semester Rate', snapshot.groupRate == null ? '—' : `${snapshot.groupRate}%`], ['Method', 'Average of monthly ratings']
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    openPrintDocument(printableDocument({
      title: `${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()} — ${activeSemester()} Semestral Attendance`,
      subtitle: `The semester rating is the arithmetic mean of finalized monthly attendance ratings.`,
      summaryHtml,
      tableHtml: `<h2 class="report-section">Finalized Monthly Ratings</h2><table><thead><tr><th>Month</th><th>Activities</th><th>Final Rating</th><th>Status</th></tr></thead><tbody>${monthRows || '<tr><td colspan="4">No finalized monthly ratings.</td></tr>'}</tbody></table><h2 class="report-section">Member Semestral Ratings</h2><table><thead><tr><th>Member</th><th>Membership ID</th><th>Months Counted</th><th>Semester Rate</th><th>Monthly Ratings</th></tr></thead><tbody>${memberRows || '<tr><td colspan="5">No finalized member ratings.</td></tr>'}</tbody></table>`,
      footer: `${attendanceGroupShortLabel()} semestral report • ${activeSemester()} • monthly ratings are not pooled across calendar months.`
    }));
  }

  function printMonthlyAttendance() {
    const monthlyState = window.LSOAttendanceGovernance?.getMonthState?.(calendarMonthKey(), activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode());
    if (!monthlyState || monthlyState.state !== 'Finalized') {
      return window.LSOApp?.showToast?.('Finalize the selected attendance month before printing its official monthly rating.', true);
    }
    const monthLabel = calendarMonthLabel();
    const monthEvents = eventsInCalendarMonth(activityEvents());
    const members = membersForAttendanceGroup(monthEvents.filter((event) => normalize(event.type) === 'rehearsal'));
    const memberIds = new Set(members.map((member) => member.id));
    const events = monthEvents.filter((event) => members.some((member) => memberEligibleForAttendanceEvent(member, event)));
    const records = groupRecordsForEvents(events).filter((record) => memberIds.has(record.memberId));
    const counts = statusCounts(records);
    const monthlySnapshot = window.LSOAttendanceGovernance?.getMonthSnapshot?.(calendarMonthKey(), activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode());
    const rate = monthlySnapshot?.groupRate ?? rateFromCounts(counts);
    const summaryHtml = `<div class="summary">${[
      ['Members', members.length], ['Activities', events.length], ['Present', counts.Present], ['Late', counts.Late], ['Absent', counts.Absent], ['Overall Rate', rate === null ? '—' : `${rate}%`]
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    const rows = members.map((member) => {
      const summary = memberSummaryForEvents(member.id, events);
      const finalRate = monthlySnapshot?.members?.[member.id]?.rate ?? summary.rate;
      return `<tr><td>${safeText(member.fullName)}</td><td>${finalRate === null || finalRate === undefined ? '—' : `${finalRate}%`}</td></tr>`;
    }).join('');
    openPrintDocument(printableDocument({
      title: `${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()} — ${monthLabel} Attendance Report`,
      subtitle: `${activeSemester()} • ${members.length} members • ${events.length} completed activities • ${records.length} recorded statuses`,
      summaryHtml,
      tableHtml: `${eventDetailReportTable(events)}<h2 class="report-section">${safeText(attendanceGroupShortLabel())} Monthly Summary</h2><p class="report-note">This monthly report is isolated from the other attendance groups.</p><table><thead><tr><th>Member</th><th>Attendance Rate</th></tr></thead><tbody>${rows || '<tr><td colspan="2">No member records.</td></tr>'}</tbody></table>`,
      footer: `${attendanceGroupShortLabel()} monthly attendance report for ${monthLabel}, ${activeSemester()}.`
    }));
  }

  function printIndividualMonthlyAttendance() {
    const monthlyState = window.LSOAttendanceGovernance?.getMonthState?.(calendarMonthKey(), activeSemester(), activeAttendanceGroup(), activeAttendanceRosterMode());
    if (!monthlyState || monthlyState.state !== 'Finalized') {
      return window.LSOApp?.showToast?.('Finalize the selected attendance month before printing an official member monthly report.', true);
    }
    const member = membersForAttendanceGroup(rehearsalEvents()).find((item) => item.id === selectedAttendanceMemberId);
    if (!member) return;
    const monthLabel = calendarMonthLabel();
    const events = eventsInCalendarMonth(rehearsalEvents());
    const summary = memberSummaryForEvents(member.id, events);
    const recordMap = new Map(summary.records.map((record) => [record.eventId, record]));
    const summaryHtml = `<div class="summary">${[
      ['Rehearsals', summary.totalEvents], ['Present', summary.counts.Present], ['Late', summary.counts.Late],
      ['Absent', summary.counts.Absent], ['Excused', summary.counts.Excused], ['Attendance Rate', summary.rate === null ? '—' : `${summary.rate}%`]
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    const rows = summary.events.map((event) => {
      const record = recordMap.get(event.id) || {};
      const workflow = eventWorkflowState(event, record.attendanceGroup || activeAttendanceGroup(), record.rosterModeAtEdit || activeAttendanceRosterMode());
      return `<tr><td>${safeText(dateLabel(event.date, { short: true }))}</td><td>${safeText(event.venue || '—')}</td><td>${safeText(workflow)}</td><td>${safeText(record.status || 'Not marked')}</td><td>${safeText(record.remarks || '')}</td></tr>`;
    }).join('');
    openPrintDocument(printableDocument({
      title: `${member.fullName} — ${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()} — ${monthLabel}`, 
      subtitle: `${activeSemester()} • ${attendanceGroupShortLabel()} • ${member.membershipId} • ${member.periodGroup} • ${member.primaryInstrument || 'No instrument recorded'}`,
      summaryHtml,
      tableHtml: `<table><thead><tr><th>Date</th><th>Venue</th><th>Verification</th><th>Status</th><th>Remarks</th></tr></thead><tbody>${rows || '<tr><td colspan="5">No completed rehearsal records for this month.</td></tr>'}</tbody></table>`,
      footer: `Individual monthly attendance report for ${monthLabel}, ${activeSemester()}.`
    }));
  }

  function printSelectedEventAttendance() {
    const active = document.querySelector('.event-card.active');
    const event = getEvents().find((item) => item.id === active?.dataset.eventId);
    if (!event) return;
    const members = getMembers()
      .filter((member) => memberEligibleForAttendanceEvent(member, event))
      .sort((a, b) => String(a.fullName).localeCompare(String(b.fullName)));
    const memberIds = new Set(members.map((member) => member.id));
    const memberMap = new Map(members.map((member) => [member.id, member]));
    const records = getAttendance().filter((record) => {
      const member = memberMap.get(record.memberId);
      return record.eventId === event.id && memberIds.has(record.memberId) && attendanceRecordGroup(record, event, member) === activeAttendanceGroup();
    });
    const map = new Map(records.map((record) => [record.memberId, record]));
    const counts = statusCounts(records);
    const workflow = eventWorkflowState(event);
    const summaryHtml = `<div class="summary">${[
      ['Roster', members.length], ['Verification', workflow], ['Present', counts.Present], ['Late', counts.Late], ['Absent', counts.Absent], ['Recorded', records.filter((r) => r.status).length]
    ].map(([label, value]) => `<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>`;
    const rows = members.map((member) => {
      const record = map.get(member.id) || {};
      return `<tr><td>${safeText(member.fullName)}</td><td>${safeText(member.orchestraSection || '—')}</td><td>${safeText(record.status || 'Not marked')}</td><td>${safeText(record.remarks || '')}</td></tr>`;
    }).join('');
    openPrintDocument(printableDocument({
      title: `${event.title} — ${attendanceRosterModeLabel()} — ${attendanceGroupShortLabel()}`, 
      subtitle: `${eventSemester(event)} • ${dateLabel(event.date)} • ${event.venue || 'Venue not recorded'} • ${event.type || 'Activity'} • ${workflow}`,
      summaryHtml,
      tableHtml: `<table><thead><tr><th>Member</th><th>Section</th><th>Status</th><th>Remarks</th></tr></thead><tbody>${rows || '<tr><td colspan="4">No members in this attendance group.</td></tr>'}</tbody></table>`
    }));
  }

  function renderMembershipFlow() {
    const container = el('dashboardMembershipFlow');
    if (!container) return;
    const members = getMembers();
    const groups = [
      ['Trainee Period', 'Training', 'Foundation and onboarding'],
      ['Probationary Period', 'Evaluation', 'Performance monitoring'],
      ['Membership Period', 'Official', 'Full member directory']
    ];
    const total = members.length || 1;
    container.innerHTML = `<div class="membership-flow-track">${groups.map(([stage, label, helper], index) => {
      const count = members.filter((member) => member.periodGroup === stage).length;
      const percent = Math.round((count / total) * 100);
      return `<button class="membership-flow-node" data-dashboard-stage="${safeText(stage)}" type="button"><span class="flow-index">0${index + 1}</span><div><small>${safeText(label)}</small><strong>${count}</strong><em>${safeText(helper)}</em></div><span class="flow-percent">${members.length ? percent : 0}%</span></button>`;
    }).join('<span class="flow-connector">→</span>')}</div>`;
    if (el('dashboardMembershipFlowSummary')) el('dashboardMembershipFlowSummary').textContent = members.length
      ? `${members.length} total profiles moving through three automatic periods`
      : 'No membership profiles have been registered yet.';
  }

  function semesterAttendanceSignal(semester) {
    const snapshot = window.LSOAttendanceGovernance?.getSemesterSnapshot?.(semester, 'Official Members', 'Current');
    const events = getEvents().filter((event) => eventSemester(event) === semester && eventBelongsToActiveGroup(event, 'Official Members'));
    const eventMap = new Map(events.map((event) => [event.id, event]));
    const memberMap = new Map(getMembers().map((member) => [member.id, member]));
    const records = getAttendance().filter((record) => {
      const event = eventMap.get(record.eventId);
      const member = memberMap.get(record.memberId);
      return Boolean(record.status && event && member && attendanceRecordGroup(record, event, member) === 'Official Members');
    });
    const counts = statusCounts(records);
    return { semester, events, records, counts, rate: snapshot?.groupRate ?? rateFromCounts(counts) };
  }

  function renderDutyDashboard() {
    const container = el('dashboardDutyOverview');
    const caption = el('dashboardDutySummary');
    if (!container || !caption) return;
    const api = window.LSODutyHours;
    if (!api?.getDashboardSummary) {
      container.innerHTML = '<div class="dashboard-empty-state"><span>◷</span><strong>Duty Hours is ready</strong><small>Open the module to set commitments and rendered time.</small></div>';
      caption.textContent = 'Waiting for duty-hour records';
      return;
    }
    const first = api.getDashboardSummary('First Semester');
    const second = api.getDashboardSummary('Second Semester');
    caption.textContent = `${first.tracked + second.tracked} semester roster records • exact hour-and-minute accounting`;
    container.innerHTML = `<div class="dashboard-semester-signal-grid">${[first, second].map((item) => `<button class="dashboard-semester-signal" data-dashboard-duty-semester="${safeText(item.semester)}" type="button"><span>${safeText(item.semester.replace(' Semester', ''))}</span><strong>${safeText(item.remainingLabel)}</strong><small>${item.tracked} tracked • ${item.completed} complete</small><div class="mini-progress"><i style="width:${item.progress}%"></i></div></button>`).join('')}</div>`;
  }

  function renderFuturisticDashboardSignals() {
    const members = getMembers();
    const events = getEvents();
    const first = semesterAttendanceSignal('First Semester');
    const second = semesterAttendanceSignal('Second Semester');
    const upcoming = events.filter((event) => event.date >= today()).length;
    const membership = members.filter((member) => member.periodGroup === 'Membership Period').length;
    if (el('dashboardHeroStatus')) {
      el('dashboardHeroStatus').innerHTML = [
        ['1st Sem Official Attendance', first.rate === null ? 'No data' : `${first.rate}%`],
        ['2nd Sem Official Attendance', second.rate === null ? 'No data' : `${second.rate}%`],
        ['Upcoming Schedule', `${upcoming} event${upcoming === 1 ? '' : 's'}`],
        ['Official Members', membership]
      ].map(([label, value]) => `<div class="hero-status-chip"><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('');
    }
    if (el('dashboardAttendanceSummary')) {
      el('dashboardAttendanceSummary').textContent = `Official-member semester signals • 1st: ${first.rate === null ? 'No data' : `${first.rate}%`} • 2nd: ${second.rate === null ? 'No data' : `${second.rate}%`}`;
    }
    if (el('dashboardGreetingMeta')) {
      el('dashboardGreetingMeta').textContent = 'Semester-separated attendance, exact duty-hour compliance, membership progression, and printable operational records in one live workspace.';
    }
    renderMembershipFlow();
    renderDutyDashboard();
  }

  function setEntryStage(stage) {
    const dateRegistered = el('dateRegistered')?.value || today();
    const skipControl = el('probationarySkipped');
    if (stage === 'Trainee Period') {
      if (skipControl) skipControl.checked = false;
      el('traineeStartDate').value = el('traineeStartDate').value || dateRegistered;
      el('probationaryStartDate').disabled = false;
      el('probationaryStartDate').value = '';
      el('regularMemberDate').value = '';
    } else if (stage === 'Probationary Period') {
      if (skipControl) skipControl.checked = false;
      const probationary = today();
      el('traineeStartDate').value = el('traineeStartDate').value && el('traineeStartDate').value < probationary ? el('traineeStartDate').value : addDays(probationary, -1);
      el('probationaryStartDate').disabled = false;
      el('probationaryStartDate').value = probationary;
      el('regularMemberDate').value = '';
    } else {
      const membership = today();
      const skipped = Boolean(skipControl?.checked);
      el('traineeStartDate').value = el('traineeStartDate').value && el('traineeStartDate').value < membership ? el('traineeStartDate').value : addDays(membership, skipped ? -1 : -2);
      el('probationaryStartDate').disabled = skipped;
      el('probationaryStartDate').value = skipped ? '' : (el('probationaryStartDate').value && el('probationaryStartDate').value < membership ? el('probationaryStartDate').value : addDays(membership, -1));
      el('regularMemberDate').value = membership;
    }
    if (skipControl) skipControl.dispatchEvent(new Event('change', { bubbles: true }));
    ['traineeStartDate', 'probationaryStartDate', 'regularMemberDate'].forEach((id) => el(id)?.dispatchEvent(new Event('change', { bubbles: true })));
  }

  function syncAttendanceSemesterControls() {
    if (el('attendanceSemesterLabel')) el('attendanceSemesterLabel').textContent = activeSemester();
    qsa('[data-attendance-semester]', el('attendanceSemesterToggle')).forEach((button) => {
      button.classList.toggle('active', button.dataset.attendanceSemester === activeSemester());
    });
  }

  function syncAttendanceGroupControls() {
    qsa('[data-attendance-group]', el('attendanceGroupToggle')).forEach((button) => {
      const allowed = window.LSORoleAccess?.canUseAttendanceGroup?.(button.dataset.attendanceGroup) ?? true;
      button.classList.toggle('active', allowed && button.dataset.attendanceGroup === activeAttendanceGroup());
      button.classList.toggle('role-hidden', !allowed);
      button.disabled = !allowed;
      button.setAttribute('aria-hidden', String(!allowed));
    });
    qsa('[data-attendance-roster-mode]', el('attendanceRosterModeToggle')).forEach((button) => {
      button.classList.toggle('active', button.dataset.attendanceRosterMode === activeAttendanceRosterMode());
    });
    const modeLabel = attendanceRosterModeLabel();
    if (el('attendanceRosterModeLabel')) el('attendanceRosterModeLabel').textContent = activeAttendanceRosterMode() === 'Archive' ? 'Validated finalized months' : 'Current roster';
    if (el('attendanceGroupLabel')) el('attendanceGroupLabel').textContent = attendanceGroupShortLabel();
    const archiveMode = activeAttendanceRosterMode() === 'Archive';
    if (el('attendanceGroupPrintButton')) {
      el('attendanceGroupPrintButton').textContent = 'Print Current Roster';
      el('attendanceGroupPrintButton').classList.toggle('hidden', archiveMode);
    }
    if (el('printOverallAttendance')) el('printOverallAttendance').classList.toggle('hidden', archiveMode);
    if (el('printMonthlyAttendance')) el('printMonthlyAttendance').classList.toggle('hidden', archiveMode);
    if (el('addEventButton')) el('addEventButton').classList.toggle('hidden', archiveMode);
    if (el('attendanceRosterGroupLabel')) el('attendanceRosterGroupLabel').textContent = `${modeLabel}: ${attendanceGroupShortLabel()}`;
    if (el('attendanceArchiveNotice')) el('attendanceArchiveNotice').classList.toggle('hidden', !archiveMode);
    if (el('attendanceFinalizedArchiveBlock')) el('attendanceFinalizedArchiveBlock').classList.toggle('hidden', !archiveMode);
    if (el('attendancePeriodFinalizationCenter')) el('attendancePeriodFinalizationCenter').classList.toggle('hidden', archiveMode);
    document.querySelector('.attendance-calendar-panel')?.classList.toggle('hidden', archiveMode);
    document.querySelector('.attendance-management-layout')?.classList.toggle('hidden', archiveMode);
    el('attendanceView')?.classList.toggle('attendance-archive-mode', archiveMode);
  }

  let renderEverythingTimer = 0;
  let renderEverythingFrame = 0;
  let attendanceRenderPending = false;

  function attendanceViewActive() {
    const view = el('attendanceView');
    return Boolean(view && !view.classList.contains('hidden') && view.classList.contains('active'));
  }

  function scheduleRenderEverything(delay = 35, force = false) {
    clearTimeout(renderEverythingTimer);
    renderEverythingTimer = window.setTimeout(() => {
      if (!force && !attendanceViewActive()) {
        attendanceRenderPending = true;
        return;
      }
      attendanceRenderPending = false;
      if (renderEverythingFrame) window.cancelAnimationFrame(renderEverythingFrame);
      renderEverythingFrame = window.requestAnimationFrame(() => {
        renderEverythingFrame = 0;
        renderEverything();
      });
    }, delay);
  }

  function renderEverything() {
    const calendarPanel = document.querySelector('.attendance-calendar-panel');
    if (calendarPanel) calendarPanel.dataset.attendanceCalendar = activeAttendanceGroup();
    syncAttendanceSemesterControls();
    syncAttendanceGroupControls();
    populateIndividualSelect();
    renderOverallAttendance();
    renderIndividualAttendance();
    renderCalendar();
    renderFuturisticDashboardSignals();
    window.LSOAttendanceWorkspace?.refresh?.();
  }

  function removeRetiredInventoryFromUI() {
    document.querySelector('[data-view="instrumentsView"]')?.remove();
    el('instrumentsView')?.classList.add('hidden');
    el('instrumentModal')?.classList.add('hidden');
    qsa('[data-dashboard-action="inventory"], [data-dashboard-action="add-instrument"]').forEach((node) => node.remove());
  }

  function wireEvents() {
    el('attendanceIndividualSelect')?.addEventListener('change', (event) => {
      selectedAttendanceMemberId = event.target.value;
      renderIndividualAttendance();
    });
    el('printIndividualAttendance')?.addEventListener('click', printIndividualAttendance);
    el('printIndividualMonthlyAttendance')?.addEventListener('click', printIndividualMonthlyAttendance);
    el('printOverallAttendance')?.addEventListener('click', printOverallAttendance);
    el('printMonthlyAttendance')?.addEventListener('click', printMonthlyAttendance);
    el('printCalendarMonthlyAttendance')?.addEventListener('click', printMonthlyAttendance);
    el('printEventAttendance')?.addEventListener('click', printSelectedEventAttendance);
    el('attendanceSemesterToggle')?.addEventListener('click', (event) => {
      const button = event.target.closest('[data-attendance-semester]');
      if (!button) return;
      saveCalendarState();
      window.LSOAttendanceSemester = normalizeSemester(button.dataset.attendanceSemester);
      restoreCalendarState(activeAttendanceGroup(), window.LSOAttendanceSemester);
      qsa('[data-attendance-semester]', el('attendanceSemesterToggle')).forEach((item) => item.classList.toggle('active', item === button));
      if (el('attendanceSemesterLabel')) el('attendanceSemesterLabel').textContent = window.LSOAttendanceSemester;
      window.LSOOperations?.setAttendanceSemester?.(window.LSOAttendanceSemester);
      renderEverything();
    });
    el('attendanceGroupToggle')?.addEventListener('click', (event) => {
      const button = event.target.closest('[data-attendance-group]');
      if (!button) return;
      const requestedGroup = normalizeAttendanceGroup(button.dataset.attendanceGroup);
      if (window.LSORoleAccess?.canUseAttendanceGroup && !window.LSORoleAccess.canUseAttendanceGroup(requestedGroup)) {
        window.LSOApp?.showToast?.(window.LSORoleAccess.deniedMessage('attendanceGroup'), true);
        return;
      }
      saveCalendarState();
      window.LSOAttendanceGroup = requestedGroup;
      restoreCalendarState(requestedGroup, activeSemester());
      selectedAttendanceMemberId = '';
      if (el('attendanceIndividualSelect')) el('attendanceIndividualSelect').value = '';
      window.LSOOperations?.setAttendanceGroup?.(window.LSOAttendanceGroup);
      window.LSOOperations?.setAttendanceMonth?.(window.LSOAttendanceMonth);
      renderEverything();
    });
    el('attendanceRosterModeToggle')?.addEventListener('click', (event) => {
      const button = event.target.closest('[data-attendance-roster-mode]');
      if (!button) return;
      window.LSOAttendanceRosterMode = normalizeAttendanceRosterMode(button.dataset.attendanceRosterMode);
      selectedAttendanceMemberId = '';
      if (el('attendanceIndividualSelect')) el('attendanceIndividualSelect').value = '';
      window.LSOOperations?.setAttendanceRosterMode?.(window.LSOAttendanceRosterMode);
      if (window.LSOAttendanceRosterMode === 'Archive') window.LSOAttendanceGovernance?.getSelectedArchive?.();
      window.LSOAttendanceGovernance?.renderMonthlyArchives?.();
      renderEverything();
    });
    el('attendanceGroupPrintButton')?.addEventListener('click', printCurrentAttendanceGroupRoster);
    el('calendarPreviousMonth')?.addEventListener('click', () => moveCalendarMonth(-1));
    el('calendarNextMonth')?.addEventListener('click', () => moveCalendarMonth(1));
    el('calendarToday')?.addEventListener('click', () => selectCalendarDate(today(), false));
    el('createEventOnSelectedDate')?.addEventListener('click', createEventOnSelectedDate);
    el('attendanceCalendarGrid')?.addEventListener('click', (event) => {
      const day = event.target.closest('[data-calendar-date]');
      if (day) selectCalendarDate(day.dataset.calendarDate, true);
    });
    el('stageEntryToggle')?.addEventListener('click', (event) => {
      const button = event.target.closest('[data-entry-stage]');
      if (button) setEntryStage(button.dataset.entryStage);
    });

    document.addEventListener('click', (event) => {
      const stage = event.target.closest('[data-dashboard-stage]');
      if (stage) {
        window.LSOApp?.setView?.('membersView');
        window.LSOApp?.setMembershipDirectory?.(stage.dataset.dashboardStage);
      }
      const action = event.target.closest('[data-dashboard-action="member-lookup"]');
      if (action) window.LSOApp?.setView?.('lookupView');
      const membersAction = event.target.closest('[data-dashboard-action="members"]');
      if (membersAction) window.LSOApp?.setView?.('membersView');
      const dutyAction = event.target.closest('[data-dashboard-action="duty-hours"]');
      if (dutyAction) window.LSOApp?.setView?.('dutyHoursView');
      const dutySemester = event.target.closest('[data-dashboard-duty-semester]');
      if (dutySemester) {
        window.LSOApp?.setView?.('dutyHoursView');
        window.LSODutyHours?.setSemester?.(dutySemester.dataset.dashboardDutySemester);
      }
    }, true);

    ['lso:members-changed', 'lso:operations-changed', 'lso:duty-hours-changed', 'lso:attendance-semester-changed', 'lso:attendance-month-changed', 'lso:attendance-group-changed', 'lso:attendance-roster-mode-changed', 'lso:attendance-period-changed', 'lso:cloud-state-changed', 'lso:auth-changed'].forEach((name) => {
      window.addEventListener(name, () => scheduleRenderEverything(name === 'lso:cloud-state-changed' ? 70 : 35));
    });
    document.querySelectorAll('[data-view="attendanceView"]').forEach((button) => button.addEventListener('click', () => {
      scheduleRenderEverything(attendanceRenderPending ? 90 : 55, true);
    }));

    // The existing attendance manager saves first, then this refresh updates analytics and calendar.
    el('saveAttendanceButton')?.addEventListener('click', () => scheduleRenderEverything(85, true));
    el('eventForm')?.addEventListener('submit', () => setTimeout(() => {
      selectedCalendarDate = el('eventDate')?.value || selectedCalendarDate;
      window.LSOAttendanceSelectedDate = selectedCalendarDate;
      const savedDate = new Date(`${selectedCalendarDate}T00:00:00`);
      if (!Number.isNaN(savedDate.getTime())) setMonthWorkspace(savedDate, { resetDate: false });
      renderEverything();
    }, 100));
  }

  window.addEventListener('lso:auth-changed', () => { activeAttendanceGroup(); scheduleRenderEverything(20); });
  window.addEventListener('lso:attendance-refresh-request', () => scheduleRenderEverything(0, true));

  window.LSOAttendanceMonthWorkspace = Object.freeze({
    refresh: () => scheduleRenderEverything(0, true),
    getMonth: () => String(window.LSOAttendanceMonth || ''),
    getSelectedDate: () => String(window.LSOAttendanceSelectedDate || ''),
    getGroupCalendarState: () => ({ group: activeAttendanceGroup(), semester: activeSemester(), month: calendarMonthKey(), selectedDate: selectedCalendarDate })
  });

  function initialize() {
    if (el('attendanceSemesterLabel')) el('attendanceSemesterLabel').textContent = activeSemester();
    qsa('[data-attendance-semester]', el('attendanceSemesterToggle')).forEach((button) => button.classList.toggle('active', button.dataset.attendanceSemester === activeSemester()));
    syncAttendanceGroupControls();
    restoreCalendarState(activeAttendanceGroup(), activeSemester());
    setMonthWorkspace(calendarCursor, { resetDate: false });
    removeRetiredInventoryFromUI();
    wireEvents();
    renderEverything();
    window.setInterval(() => {
      if (!document.hidden && !el('appShell')?.classList.contains('hidden') && attendanceViewActive()) scheduleRenderEverything(0, true);
    }, 60_000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
