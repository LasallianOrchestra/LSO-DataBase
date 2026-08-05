(() => {
  'use strict';

  const KEYS = Object.freeze({
    members: 'lso_member_database_v1',
    events: 'lso_events_v2',
    attendance: 'lso_attendance_v2',
    duty: 'lso_duty_hours_v1',
    monthly: 'lso_monthly_reports_v1'
  });
  const el = (id) => document.getElementById(id);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];
  let activeTab = 'overview';
  let selectedId = '';
  let renderTimer = null;

  function safeText(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[character]));
  }

  function normalize(value) {
    return String(value ?? '').trim().toLowerCase();
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value ?? null));
  }

  function read(key, fallback) {
    try {
      const parsed = JSON.parse(window.LSOStorage?.getItem(key) || '');
      return parsed === null || parsed === undefined ? clone(fallback) : parsed;
    } catch {
      return clone(fallback);
    }
  }

  function write(key, value, eventName = '') {
    const saved = window.LSOStorage?.setItem(key, JSON.stringify(value));
    if (saved === false) return false;
    if (eventName) window.dispatchEvent(new CustomEvent(eventName, { detail: { key, source: 'members-overall-record' } }));
    window.dispatchEvent(new CustomEvent('lso:cloud-state-changed', { detail: { key, source: 'members-overall-record' } }));
    return true;
  }

  function toast(message, error = false) {
    window.LSOApp?.showToast?.(message, error);
  }

  function currentAccount() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function isAdmin() {
    return currentAccount()?.role === 'Administrator';
  }

  function can(action) {
    return window.LSORoleAccess?.can?.(action, currentAccount()) ?? isAdmin();
  }

  function log(action, category, details) {
    window.LSOOperations?.logActivity?.(action, category, details);
  }

  function today() {
    return window.LSOApp?.getToday?.() || new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
  }

  function uid(prefix = 'record') {
    return window.crypto?.randomUUID ? window.crypto.randomUUID() : `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }

  function dateLabel(value, short = true) {
    if (!value) return 'Not recorded';
    const raw = String(value);
    const date = new Date(raw.length === 10 ? `${raw}T00:00:00` : raw);
    if (Number.isNaN(date.getTime())) return raw;
    return new Intl.DateTimeFormat('en-PH', short
      ? { month: 'short', day: 'numeric', year: 'numeric' }
      : { month: 'long', day: 'numeric', year: 'numeric' }).format(date);
  }

  function monthLabel(value) {
    if (!/^\d{4}-\d{2}$/.test(String(value || ''))) return String(value || 'Unknown month');
    const [year, month] = value.split('-').map(Number);
    return new Intl.DateTimeFormat('en-PH', { month: 'long', year: 'numeric' }).format(new Date(year, month - 1, 1));
  }

  function timeLabel(value) {
    if (!value) return '—';
    const [hour, minute] = String(value).split(':').map(Number);
    if (!Number.isFinite(hour)) return String(value);
    const date = new Date();
    date.setHours(hour, Number.isFinite(minute) ? minute : 0, 0, 0);
    return new Intl.DateTimeFormat('en-PH', { hour: 'numeric', minute: '2-digit' }).format(date);
  }

  function minutesLabel(value, signed = false) {
    const total = Number(value) || 0;
    const absolute = Math.abs(total);
    const hours = Math.floor(absolute / 60);
    const minutes = absolute % 60;
    const parts = [];
    if (hours) parts.push(`${hours} hr${hours === 1 ? '' : 's'}`);
    if (minutes || !parts.length) parts.push(`${minutes} min`);
    const prefix = signed ? (total > 0 ? '+' : total < 0 ? '-' : '') : total < 0 ? '-' : '';
    return `${prefix}${parts.join(' ')}`;
  }

  function members() {
    return window.LSOApp?.getMembers?.() || read(KEYS.members, []);
  }

  function selectedMember() {
    const current = window.LSOApp?.getSelectedMemberId?.() || selectedId;
    return members().find((member) => String(member.id) === String(current)) || null;
  }

  function phaseAt(member, value) {
    const date = String(value || today()).slice(0, 10);
    if (member.regularMemberDate && date >= member.regularMemberDate) return 'Official';
    if (!member.probationarySkipped && member.probationaryStartDate && date >= member.probationaryStartDate) return 'Probationary';
    return 'Trainee';
  }

  function attendanceGroupFor(member, value) {
    const phase = phaseAt(member, value);
    return phase === 'Official' ? 'Official Members' : phase === 'Probationary' ? 'Probationary Members' : 'Trainee Members';
  }

  function phaseClass(phase) {
    return normalize(phase).includes('official') ? 'official' : normalize(phase).includes('probationary') ? 'probationary' : 'trainee';
  }

  function statusClass(status) {
    const value = normalize(status);
    if (value.includes('approved') || value.includes('finalized') || value === 'present') return value === 'present' ? 'present' : value.includes('final') ? 'finalized' : 'approved';
    if (value.includes('pending') || value.includes('draft') || value === 'late') return value === 'late' ? 'late' : value.includes('draft') ? 'draft' : 'pending';
    if (value.includes('reject') || value === 'absent') return value === 'absent' ? 'absent' : 'rejected';
    if (value.includes('active') || value === 'excused') return value === 'excused' ? 'excused' : 'active';
    return 'neutral';
  }

  function setCount(id, value) {
    if (el(id)) el(id).textContent = String(value);
  }

  function recordData(member) {
    const eventList = read(KEYS.events, []);
    const eventMap = new Map(eventList.map((event) => [String(event.id), event]));
    const attendanceRecords = read(KEYS.attendance, []).filter((record) => String(record.memberId) === String(member.id));
    const duty = read(KEYS.duty, { commitments: {}, entries: [] });
    const dutyEntries = (Array.isArray(duty.entries) ? duty.entries : []).filter((entry) => String(entry.memberId) === String(member.id));
    const monthly = read(KEYS.monthly, { reports: {}, civilStatusByMember: {} });
    const contracts = Array.isArray(member.contractRecords) ? member.contractRecords : [];
    return { eventList, eventMap, attendanceRecords, duty, dutyEntries, monthly, contracts };
  }

  function updateSearchCount() {
    const buttons = qsa('[data-lookup-id]', el('lookupResults'));
    if (el('overallSearchCount')) el('overallSearchCount').textContent = `${buttons.length}${buttons.length === 100 ? '+' : ''} record${buttons.length === 1 ? '' : 's'}`;
  }

  function renderMetrics(member, data) {
    const attendanceCount = data.attendanceRecords.length;
    const dutyApproved = data.dutyEntries.filter((entry) => entry.approvalStatus === 'Approved').reduce((sum, entry) => sum + Number(entry.minutes || 0), 0);
    const monthlyCount = monthlyRowsForMember(member, data.monthly).length;
    const currentPhase = phaseAt(member, today());
    const metrics = [
      ['Current Phase', currentPhase, member.memberStatus || 'Status not set'],
      ['Contracts', data.contracts.length, data.contracts.length ? 'Tracked generated PDFs' : 'No tracked contract'],
      ['Monthly Filings', monthlyCount, 'Report months on record'],
      ['Attendance', attendanceCount, `${attendanceRate(data.attendanceRecords)} recorded rate`],
      ['Duty Credited', minutesLabel(dutyApproved, true), `${data.dutyEntries.length} ledger entr${data.dutyEntries.length === 1 ? 'y' : 'ies'}`]
    ];
    el('overallRecordMetrics').innerHTML = metrics.map(([label, value, detail]) => `<div class="overall-record-metric"><span>${safeText(label)}</span><strong>${safeText(value)}</strong><small>${safeText(detail)}</small></div>`).join('');
    setCount('overallContractCount', data.contracts.length);
    setCount('overallMonthlyCount', monthlyCount);
    setCount('overallAttendanceCount', attendanceCount);
    setCount('overallDutyCount', data.dutyEntries.length);
  }

  function attendanceRate(records) {
    const counted = records.filter((record) => ['Present', 'Late', 'Absent', 'Excused'].includes(record.status));
    if (!counted.length) return 'No rate';
    const earned = counted.reduce((sum, record) => sum + (record.status === 'Present' ? 1 : record.status === 'Late' ? 0.75 : record.status === 'Excused' ? 1 : 0), 0);
    return `${Math.round((earned / counted.length) * 100)}%`;
  }

  function renderLifecycle(member) {
    const current = phaseAt(member, today());
    const steps = [
      ['1', 'Trainee Period', member.traineeStartDate ? `Started ${dateLabel(member.traineeStartDate)}` : 'Start date not recorded', current === 'Trainee'],
      ['2', 'Probationary Period', member.probationarySkipped ? 'Skipped by approved transition' : member.probationaryStartDate ? `Started ${dateLabel(member.probationaryStartDate)}` : 'Not started', current === 'Probationary'],
      ['3', 'Membership Period', member.regularMemberDate ? `Started ${dateLabel(member.regularMemberDate)}` : 'Not started', current === 'Official']
    ];
    el('overallLifecycle').innerHTML = steps.map(([step, title, detail, active]) => `<div class="overall-lifecycle-step ${active ? 'current' : ''}" data-step="${step}"><strong>${safeText(title)}</strong><small>${safeText(detail)}</small></div>`).join('');
  }

  function renderContracts(member, contracts) {
    const root = el('overallContractsList');
    if (!root) return;
    const canGenerate = can('generateContract') && phaseAt(member, today()) === 'Official';
    el('overallOpenContractCenter')?.classList.toggle('hidden', !canGenerate);
    if (!contracts.length) {
      root.innerHTML = `<div class="overall-empty"><strong>No tracked generated contract</strong><p>${phaseAt(member, today()) === 'Official' ? 'Use Open Contract Center to create a PDF. Contracts generated after V49 will appear here automatically.' : 'Contract generation becomes available when the person reaches the Membership Period.'}</p></div>`;
      return;
    }
    root.innerHTML = [...contracts].sort((a, b) => String(b.generatedAt || '').localeCompare(String(a.generatedAt || ''))).map((record) => `
      <article class="overall-record-card" data-contract-record="${safeText(record.id)}">
        <div class="overall-record-card-header"><div class="overall-record-card-title"><strong>${safeText(record.filename || 'LSO Membership Contract.pdf')}</strong><small>Generated ${safeText(dateLabel(record.generatedAt, false))}</small></div><div class="overall-record-card-actions"><span class="overall-status-badge approved">Generated</span>${canGenerate ? '<button class="overall-small-button" data-overall-contract-open type="button">Regenerate</button>' : ''}${isAdmin() ? `<button class="overall-small-button danger" data-overall-contract-remove="${safeText(record.id)}" type="button">Remove Log</button>` : ''}</div></div>
        <div class="overall-record-card-body"><div class="overall-record-detail-grid">
          ${detail('Contract Date', dateLabel(record.contractDate))}${detail('Semester', record.semester || 'Not recorded')}${detail('Academic Year', record.academicYear || 'Not recorded')}${detail('Authorized Officer', record.officer || 'Not recorded')}
        </div><div class="overall-contract-note">The downloaded PDF itself is stored on the user’s device. This live history stores the generation details without placing large PDF files in the shared database.</div></div>
      </article>`).join('');
  }

  function detail(label, value) {
    return `<div class="overall-record-detail"><span>${safeText(label)}</span><strong>${safeText(value || '—')}</strong></div>`;
  }

  function reportDate(report, key) {
    return report.asOfDate || `${key}-01`;
  }

  function matchesMember(row, member) {
    return String(row?.memberId || '') === String(member.id) || (!!row?.name && normalize(row.name) === normalize(member.fullName));
  }

  function monthlyRowsForMember(member, monthlyState) {
    const reports = monthlyState?.reports && typeof monthlyState.reports === 'object' ? monthlyState.reports : {};
    const rows = [];
    Object.entries(reports).forEach(([key, reportValue]) => {
      const report = reportValue && typeof reportValue === 'object' ? reportValue : {};
      const asOf = reportDate(report, key);
      if (member.dateRegistered && asOf < member.dateRegistered) return;
      const items = [];
      (report.loaRows || []).filter((row) => matchesMember(row, member)).forEach((row) => items.push({ collection: 'loaRows', type: 'Leave', row }));
      (report.ojtRows || []).filter((row) => matchesMember(row, member)).forEach((row) => items.push({ collection: 'ojtRows', type: 'OJT', row }));
      (report.traineeRows || []).filter((row) => matchesMember(row, member)).forEach((row) => items.push({ collection: 'traineeRows', type: 'Trainee/Probationary Filing', row }));
      (report.quittedRows || []).filter((row) => matchesMember(row, member)).forEach((row) => items.push({ collection: 'quittedRows', type: 'Quitted/Removed', row }));
      (report.manualRemainingRows || []).filter((row) => matchesMember(row, member)).forEach((row) => items.push({ collection: 'manualRemainingRows', type: 'Remaining Trainee', row }));
      if (report.remainingMode !== 'manual') {
        const trainee = (report.traineeRows || []).find((row) => matchesMember(row, member));
        const removed = (report.quittedRows || []).some((row) => matchesMember(row, member));
        if (trainee && !removed) items.push({ collection: '', type: 'Remaining Trainee (Automatic)', row: trainee, automatic: true });
      }
      rows.push({ key, report, phase: phaseAt(member, asOf), items, civilStatus: monthlyState?.civilStatusByMember?.[member.id] || '' });
    });
    return rows.sort((a, b) => String(b.key).localeCompare(String(a.key)));
  }

  function monthlyEditor(key, item, canEdit, finalized) {
    if (!item.collection || item.automatic) return '';
    const row = item.row || {};
    const disabled = !canEdit || finalized;
    const common = `data-monthly-key="${safeText(key)}" data-monthly-collection="${safeText(item.collection)}" data-monthly-row="${safeText(row.id)}"`;
    let fields = '';
    if (item.collection === 'loaRows') fields = `<label><span class="sr-only">Purpose</span><textarea data-overall-monthly-field="purpose" ${disabled ? 'disabled' : ''}>${safeText(row.purpose || '')}</textarea></label><label><span class="sr-only">Leave until</span><input data-overall-monthly-field="until" value="${safeText(row.until || '')}" placeholder="Leave until" ${disabled ? 'disabled' : ''}/></label>`;
    if (item.collection === 'ojtRows') fields = `<label><span class="sr-only">OJT until</span><input data-overall-monthly-field="until" value="${safeText(row.until || '')}" placeholder="OJT until" ${disabled ? 'disabled' : ''}/></label>`;
    if (item.collection === 'traineeRows') fields = `<label><span class="sr-only">Name</span><input data-overall-monthly-field="name" value="${safeText(row.name || '')}" placeholder="Name" ${disabled ? 'disabled' : ''}/></label><label><span class="sr-only">Course</span><input data-overall-monthly-field="course" value="${safeText(row.course || '')}" placeholder="Course" ${disabled ? 'disabled' : ''}/></label><label><span class="sr-only">Year</span><input data-overall-monthly-field="year" value="${safeText(row.year || '')}" placeholder="Year" ${disabled ? 'disabled' : ''}/></label><label><span class="sr-only">Original entry date</span><input data-overall-monthly-field="date" type="date" value="${safeText(row.date || '')}" ${disabled ? 'disabled' : ''}/></label>`;
    if (item.collection === 'quittedRows') fields = `<label><span class="sr-only">Reason</span><input data-overall-monthly-field="reason" value="${safeText(row.reason || '')}" placeholder="Reason" ${disabled ? 'disabled' : ''}/></label><label><span class="sr-only">Remarks</span><textarea data-overall-monthly-field="remarks" ${disabled ? 'disabled' : ''}>${safeText(row.remarks || '')}</textarea></label>`;
    if (item.collection === 'manualRemainingRows') fields = `<label><span class="sr-only">Name</span><input data-overall-monthly-field="name" value="${safeText(row.name || '')}" placeholder="Name" ${disabled ? 'disabled' : ''}/></label><label><span class="sr-only">Course</span><input data-overall-monthly-field="course" value="${safeText(row.course || '')}" placeholder="Course" ${disabled ? 'disabled' : ''}/></label>`;
    return `<div class="overall-record-edit-grid" ${common}>${fields}${!disabled ? `<div class="overall-record-card-actions span-4"><button class="overall-small-button primary" data-overall-monthly-save type="button">Save Revision</button><button class="overall-small-button danger" data-overall-monthly-remove type="button">Remove Entry</button></div>` : `<div class="overall-inline-message span-4">${finalized ? 'This monthly report is finalized. Reopen it before changing member-specific rows.' : 'Your role has read-only access to monthly reports.'}</div>`}</div>`;
  }

  function renderMonthlyAdd(member, monthlyState) {
    const root = el('overallMonthlyAdd');
    if (!root) return;
    const reports = monthlyState?.reports && typeof monthlyState.reports === 'object' ? monthlyState.reports : {};
    const keys = Object.keys(reports).sort((a, b) => b.localeCompare(a));
    if (!can('editMonthlyReport') || !keys.length) { root.innerHTML = ''; return; }
    const options = keys.map((key) => `<option value="${safeText(key)}">${safeText(monthLabel(key))} - ${safeText(reports[key]?.workflowStatus || 'Draft')}</option>`).join('');
    root.innerHTML = `<button class="overall-editor-toggle" type="button">Add a member-specific monthly filing entry</button><div class="overall-editor-body"><div class="overall-editor-grid"><label class="field"><span>Report Month</span><select id="overallMonthlyAddKey">${options}</select></label><label class="field"><span>Entry Type</span><select id="overallMonthlyAddType"><option value="loaRows">Leave</option><option value="ojtRows">OJT</option><option value="traineeRows">Trainee/Probationary Filing</option><option value="quittedRows">Quitted/Removed</option><option value="manualRemainingRows">Remaining Trainee</option></select></label><label class="field span-2"><span>Purpose / Reason / Course</span><input id="overallMonthlyAddPrimary" placeholder="Enter the main filing detail"/></label><label class="field"><span>Until / Original Entry Date</span><input id="overallMonthlyAddSecondary" placeholder="Text or YYYY-MM-DD"/></label><label class="field span-2"><span>Remarks</span><input id="overallMonthlyAddRemarks" placeholder="Optional remarks"/></label></div><div class="overall-inline-message">The selected report must remain in Draft status. This entry will be saved into the same monthly report tables used by the full report module.</div><div class="overall-editor-actions"><button class="button button-primary" data-overall-monthly-add type="button">Add Monthly Entry</button></div></div>`;
  }

  function renderMonthly(member, monthlyState) {
    const root = el('overallMonthlyList');
    renderMonthlyAdd(member, monthlyState);
    const rows = monthlyRowsForMember(member, monthlyState);
    if (!rows.length) {
      root.innerHTML = '<div class="overall-empty"><strong>No monthly report history</strong><p>Monthly report months will appear here when filings are created.</p></div>';
      return;
    }
    const canEdit = can('editMonthlyReport');
    root.innerHTML = rows.map(({ key, report, phase, items, civilStatus }) => {
      const finalized = report.workflowStatus === 'Finalized';
      const itemHtml = items.length ? items.map((item) => `<div class="overall-record-card-body"><div class="overall-record-card-header" style="padding:0 0 10px;background:transparent;border:0"><div class="overall-record-card-title"><strong>${safeText(item.type)}</strong><small>${item.automatic ? 'Calculated automatically from the monthly filing' : 'Member-specific monthly row'}</small></div></div>${monthlyEditor(key, item, canEdit, finalized)}</div>`).join('') : '<div class="overall-record-card-body"><div class="overall-inline-message">No special Leave, OJT, Trainee/Probationary, Quitted, or Remaining row for this person. The phase shown above is calculated from the membership timeline as of the report date.</div></div>';
      return `<article class="overall-record-card">
        <div class="overall-record-card-header"><div class="overall-record-card-title"><strong>${safeText(monthLabel(key))}</strong><small>${safeText(report.semester || 'Semester not set')} • Academic Year ${safeText(report.academicYear || 'Not set')} • As of ${safeText(dateLabel(reportDate(report, key)))}</small></div><div class="overall-record-card-actions"><span class="overall-phase-badge ${phaseClass(phase)}">${safeText(phase)}</span><span class="overall-status-badge ${statusClass(report.workflowStatus || 'Draft')}">${safeText(report.workflowStatus || 'Draft')}</span><button class="overall-small-button" data-overall-open-month="${safeText(key)}" type="button">Open Full Report</button></div></div>
        <div class="overall-record-card-body"><div class="overall-record-detail-grid">${detail('Phase in Filing', phase)}${detail('Civil Status', civilStatus || 'Not entered')}${detail('Revision', report.revision || 0)}${detail('Updated', dateLabel(report.updatedAt || report.asOfDate))}</div></div>${itemHtml}
      </article>`;
    }).join('');
  }

  function eventFinalized(event, group, mode = 'Current') {
    try { return Boolean(window.LSOAttendanceGovernance?.isFinalized?.(event, group, mode)); } catch { return false; }
  }

  function renderAttendanceAdd(member, data) {
    const root = el('overallAttendanceAdd');
    const allowedGroups = ['Official Members', 'Trainee Members', 'Probationary Members'].filter((group) => window.LSORoleAccess?.canUseAttendanceGroup?.(group, currentAccount()) ?? isAdmin());
    if (!can('saveDraftAttendance') || !allowedGroups.length || !data.eventList.length) { root.innerHTML = ''; return; }
    const options = [...data.eventList].sort((a, b) => String(b.date || '').localeCompare(String(a.date || ''))).filter((event) => (!member.dateRegistered || !event.date || event.date >= member.dateRegistered) && allowedGroups.includes(attendanceGroupFor(member, event.date))).map((event) => `<option value="${safeText(event.id)}">${safeText(dateLabel(event.date))} - ${safeText(event.title || event.name || 'Activity')} (${safeText(attendanceGroupFor(member, event.date))})</option>`).join('');
    if (!options) { root.innerHTML = ''; return; }
    root.innerHTML = `<button class="overall-editor-toggle" type="button">Add or fill an attendance record</button><div class="overall-editor-body"><div class="overall-editor-grid"><label class="field span-2"><span>Activity</span><select id="overallAttendanceEvent">${options}</select></label><label class="field"><span>Status</span><select id="overallAttendanceStatus"><option>Present</option><option>Late</option><option>Absent</option><option>Excused</option></select></label><label class="field"><span>Remarks</span><input id="overallAttendanceRemarks" placeholder="Optional remarks"/></label></div><div class="overall-editor-actions"><button class="button button-primary" data-overall-attendance-add type="button">Save Attendance Record</button></div></div>`;
  }

  function renderAttendance(member, data) {
    const root = el('overallAttendanceList');
    renderAttendanceAdd(member, data);
    const records = data.attendanceRecords.map((record) => ({ record, event: data.eventMap.get(String(record.eventId)) || {} })).sort((a, b) => String(b.event.date || b.record.updatedAt || '').localeCompare(String(a.event.date || a.record.updatedAt || '')));
    if (!records.length) {
      root.innerHTML = '<div class="overall-empty"><strong>No attendance records</strong><p>Use the form above to add an entry, or record attendance from the Attendance module.</p></div>';
      return;
    }
    root.innerHTML = records.map(({ record, event }) => {
      const group = record.attendanceGroup || attendanceGroupFor(member, event.date);
      const locked = eventFinalized(event, group, record.rosterModeAtEdit || 'Current');
      const editable = can('saveDraftAttendance') && (window.LSORoleAccess?.canUseAttendanceGroup?.(group, currentAccount()) ?? isAdmin()) && !locked;
      return `<article class="overall-record-card ${locked ? 'overall-row-locked' : ''}" data-attendance-record="${safeText(record.eventId)}">
        <div class="overall-record-card-header"><div class="overall-record-card-title"><strong>${safeText(event.title || event.name || 'Attendance Activity')}</strong><small>${safeText(dateLabel(event.date))} • ${safeText(group)} • ${safeText(event.semester || 'Semester not recorded')}</small></div><div class="overall-record-card-actions"><span class="overall-status-badge ${statusClass(record.status)}">${safeText(record.status || 'No status')}</span>${locked ? '<span class="overall-status-badge finalized">Locked</span>' : ''}<button class="overall-small-button" data-overall-attendance-open="${safeText(record.eventId)}" type="button">Open Attendance</button>${isAdmin() && !locked ? `<button class="overall-small-button danger" data-overall-attendance-remove="${safeText(record.eventId)}" type="button">Remove</button>` : ''}</div></div>
        <div class="overall-record-card-body">${editable ? `<div class="overall-record-edit-grid"><label><span class="sr-only">Attendance status</span><select data-overall-attendance-field="status"><option ${record.status === 'Present' ? 'selected' : ''}>Present</option><option ${record.status === 'Late' ? 'selected' : ''}>Late</option><option ${record.status === 'Absent' ? 'selected' : ''}>Absent</option><option ${record.status === 'Excused' ? 'selected' : ''}>Excused</option></select></label><label class="span-2"><span class="sr-only">Remarks</span><input data-overall-attendance-field="remarks" value="${safeText(record.remarks || '')}" placeholder="Remarks"/></label><div class="overall-record-card-actions"><button class="overall-small-button primary" data-overall-attendance-save="${safeText(record.eventId)}" type="button">Save Revision</button></div></div>` : `<div class="overall-record-detail-grid">${detail('Status', record.status || 'Not marked')}${detail('Remarks', record.remarks || 'None')}${detail('Updated By', record.updatedBy || 'Not recorded')}${detail('Last Updated', dateLabel(record.updatedAt || record.createdAt))}</div>${locked ? '<div class="overall-inline-message">This roster is finalized. Reopen the event or month in Attendance before revising it.</div>' : ''}`}</div>
      </article>`;
    }).join('');
  }

  function dutySummary(data, memberId) {
    const result = window.LSODutyHours?.calculateMember?.(memberId);
    if (result) return result;
    const entries = (data.entries || []).filter((entry) => String(entry.memberId) === String(memberId) && entry.approvalStatus === 'Approved');
    const combined = entries.reduce((sum, entry) => sum + Number(entry.minutes || 0), 0);
    return { first: { combined: { credited: combined, committed: 0, balance: -combined } }, second: { combined: { credited: 0, committed: 0, balance: 0 } }, academicYear: { credited: combined, committed: 0, balance: -combined } };
  }

  function renderDutyAdd(member) {
    const root = el('overallDutyAdd');
    if (!can('manageDutyHours')) { root.innerHTML = ''; return; }
    root.innerHTML = `<button class="overall-editor-toggle" type="button">Add a manual duty or incentive record</button><div class="overall-editor-body"><div class="overall-editor-grid"><label class="field"><span>Semester</span><select id="overallDutySemester"><option>First Semester</option><option>Second Semester</option></select></label><label class="field"><span>Period</span><select id="overallDutyPeriod"><option>Trainee Period</option><option>Probationary Period</option></select></label><label class="field"><span>Entry Type</span><select id="overallDutyType"><option value="Duty">Rendered Duty</option><option value="Incentive">Incentive Adjustment</option></select></label><label class="field"><span>Date</span><input id="overallDutyDate" type="date" value="${safeText(today())}"/></label><label class="field duty-time-field"><span>Time In</span><input id="overallDutyTimeIn" type="time"/></label><label class="field duty-time-field"><span>Time Out</span><input id="overallDutyTimeOut" type="time"/></label><label class="field incentive-minute-field hidden"><span>Minutes (+/-)</span><input id="overallDutyMinutes" type="number" step="1" value="0"/></label><label class="field span-2"><span>Description / reason</span><input id="overallDutyDescription" placeholder="Required explanation"/></label></div><div class="overall-editor-actions"><button class="button button-primary" data-overall-duty-add type="button">Save Duty Record</button></div></div>`;
  }

  function renderDuty(member, data) {
    const root = el('overallDutyList');
    renderDutyAdd(member);
    const summary = dutySummary(data.duty, member.id);
    const first = summary?.first?.combined || {};
    const second = summary?.second?.combined || {};
    const total = summary?.academicYear || {};
    el('overallDutySummary').innerHTML = `<div class="overall-duty-summary-grid"><div class="overall-duty-summary-card"><span>First Semester</span><strong>${safeText(minutesLabel(first.credited || 0))}</strong></div><div class="overall-duty-summary-card"><span>Second Semester</span><strong>${safeText(minutesLabel(second.credited || 0))}</strong></div><div class="overall-duty-summary-card"><span>Total Credited</span><strong>${safeText(minutesLabel(total.credited || 0))}</strong></div><div class="overall-duty-summary-card"><span>Outstanding</span><strong>${safeText(minutesLabel(Math.max(0, total.balance || 0)))}</strong></div></div>`;
    const entries = [...data.dutyEntries].sort((a, b) => String(b.date || b.createdAt || '').localeCompare(String(a.date || a.createdAt || '')));
    if (!entries.length) {
      root.innerHTML = '<div class="overall-empty"><strong>No duty-hour records</strong><p>Duty records are normally required during the Trainee and Probationary periods, and may also be retained for an Official Member when applicable.</p></div>';
      return;
    }
    const manageable = can('manageDutyHours');
    root.innerHTML = entries.map((entry) => {
      const workflowLocked = entry.approvalStatus !== 'Approved' || (entry.entryType === 'Duty' && (entry.timeInApprovalStatus === 'Pending' || entry.timeOutApprovalStatus === 'Pending'));
      const editable = manageable && !workflowLocked;
      const clock = entry.entryType === 'Duty' ? `${timeLabel(entry.timeIn)} - ${timeLabel(entry.timeOut)}` : 'Incentive adjustment';
      return `<article class="overall-record-card ${workflowLocked ? 'overall-row-locked' : ''}" data-duty-record="${safeText(entry.id)}">
        <div class="overall-record-card-header"><div class="overall-record-card-title"><strong>${safeText(entry.entryType === 'Duty' ? 'Rendered Duty' : 'Incentive Adjustment')} - ${safeText(dateLabel(entry.date))}</strong><small>${safeText(entry.semester || 'Semester')} • ${safeText(entry.period || 'Period')} • ${safeText(clock)}</small></div><div class="overall-record-card-actions"><span class="overall-status-badge ${statusClass(entry.approvalStatus)}">${safeText(entry.approvalStatus || 'Approved')}</span><button class="overall-small-button" data-overall-duty-open="${safeText(entry.id)}" type="button">Open Duty Hours</button>${isAdmin() ? `<button class="overall-small-button danger" data-overall-duty-remove="${safeText(entry.id)}" type="button">Remove</button>` : ''}</div></div>
        <div class="overall-record-card-body">${editable ? `<div class="overall-record-edit-grid"><label><span class="sr-only">Date</span><input data-overall-duty-field="date" type="date" value="${safeText(entry.date || '')}"/></label>${entry.entryType === 'Duty' ? `<label><span class="sr-only">Time In</span><input data-overall-duty-field="timeIn" type="time" value="${safeText(entry.timeIn || '')}"/></label><label><span class="sr-only">Time Out</span><input data-overall-duty-field="timeOut" type="time" value="${safeText(entry.timeOut || '')}"/></label>` : `<label><span class="sr-only">Minutes</span><input data-overall-duty-field="minutes" type="number" value="${safeText(entry.minutes || 0)}"/></label>`}<label class="span-2"><span class="sr-only">Description</span><input data-overall-duty-field="description" value="${safeText(entry.description || '')}" placeholder="Description"/></label><div class="overall-record-card-actions"><button class="overall-small-button primary" data-overall-duty-save="${safeText(entry.id)}" type="button">Save Revision</button></div></div>` : `<div class="overall-record-detail-grid">${detail('Duration', entry.approvalStatus === 'Active' ? 'In progress' : minutesLabel(entry.minutes, entry.entryType === 'Incentive'))}${detail('Description', entry.description || 'None')}${detail('Submitted By', entry.submittedByUsername || entry.createdBy || 'System')}${detail('Approver', entry.memberApprovers || entry.approvedBy || 'Not recorded')}</div>${workflowLocked ? '<div class="overall-inline-message">This is an active, pending, or rejected punch workflow. Use Duty Hours to approve, reject, or correct it without bypassing its audit trail.</div>' : ''}`}</div>
      </article>`;
    }).join('');
  }

  function renderAll() {
    clearTimeout(renderTimer);
    const member = selectedMember();
    updateSearchCount();
    if (!member || !el('memberRecord') || el('memberRecord').classList.contains('hidden')) return;
    selectedId = String(member.id);
    const data = recordData(member);
    renderMetrics(member, data);
    renderLifecycle(member);
    renderContracts(member, data.contracts);
    renderMonthly(member, data.monthly);
    renderAttendance(member, data);
    renderDuty(member, data);
    setActiveTab(activeTab);
  }

  function scheduleRender(delay = 40) {
    clearTimeout(renderTimer);
    renderTimer = setTimeout(() => {
      if (!window.LSORuntimeStability?.isViewActive?.('lookupView')) return;
      renderAll();
    }, Math.max(delay, window.LSORuntimeStability?.constrained ? 100 : delay));
  }

  function setActiveTab(tab) {
    activeTab = ['overview', 'contracts', 'monthly', 'attendance', 'duty'].includes(tab) ? tab : 'overview';
    qsa('[data-overall-tab]').forEach((button) => {
      const active = button.dataset.overallTab === activeTab;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', String(active));
    });
    qsa('[data-overall-panel]').forEach((panel) => panel.classList.toggle('active', panel.dataset.overallPanel === activeTab));
  }

  function openContract(member) {
    if (!can('generateContract')) return toast('Your role is not assigned to generate contracts.', true);
    if (phaseAt(member, today()) !== 'Official') return toast('Contracts are available only for Official Members.', true);
    window.LSOApp?.setView?.('contractView');
    setTimeout(() => window.LSOContractMaker?.selectMember?.(member.id), 60);
  }

  function removeContract(member, recordId) {
    if (!isAdmin()) return;
    const reason = window.prompt('Enter the reason for removing this contract history entry:');
    if (reason === null) return;
    if (reason.trim().length < 3) return toast('A clear removal reason is required.', true);
    const all = read(KEYS.members, []);
    const index = all.findIndex((item) => String(item.id) === String(member.id));
    if (index < 0) return;
    all[index].contractRecords = (Array.isArray(all[index].contractRecords) ? all[index].contractRecords : []).filter((record) => String(record.id) !== String(recordId));
    all[index].updatedAt = new Date().toISOString();
    if (!write(KEYS.members, all, 'lso:members-changed')) return;
    log('Removed contract history', 'Contracts', `${member.fullName} • Reason: ${reason.trim()}`);
    toast('Contract history entry removed.');
    scheduleRender();
  }

  function addMonthlyRow(member) {
    if (!can('editMonthlyReport')) return toast('Your role cannot edit monthly reports.', true);
    const key = el('overallMonthlyAddKey')?.value;
    const collection = el('overallMonthlyAddType')?.value;
    const primary = el('overallMonthlyAddPrimary')?.value.trim() || '';
    const secondary = el('overallMonthlyAddSecondary')?.value.trim() || '';
    const remarks = el('overallMonthlyAddRemarks')?.value.trim() || '';
    const state = read(KEYS.monthly, { reports: {} });
    const report = state.reports?.[key];
    if (!report) return toast('Choose an existing monthly report.', true);
    if (report.workflowStatus === 'Finalized') return toast('This monthly report is finalized. Reopen it before adding entries.', true);
    if (!['loaRows', 'ojtRows', 'traineeRows', 'quittedRows', 'manualRemainingRows'].includes(collection)) return toast('Choose a valid monthly entry type.', true);
    if (collection === 'loaRows' && primary.length < 2) return toast('Enter the leave purpose.', true);
    if (collection === 'ojtRows' && !(secondary || primary)) return toast('Enter the OJT end date or filing detail.', true);
    if (collection === 'quittedRows' && primary.length < 2) return toast('Enter the reason for the removal or resignation.', true);
    report[collection] = Array.isArray(report[collection]) ? report[collection] : [];
    const alreadyExists = report[collection].some((row) => matchesMember(row, member));
    if (alreadyExists) return toast('This member already has that entry type for the selected month. Revise the existing row instead.', true);
    if (collection === 'loaRows') report[collection].push({ id: uid('loa'), memberId: member.id, name: member.fullName || '', purpose: primary, until: secondary });
    if (collection === 'ojtRows') report[collection].push({ id: uid('ojt'), memberId: member.id, name: member.fullName || '', until: secondary || primary });
    if (collection === 'traineeRows') {
      report[collection].push({ id: uid('trainee-row'), memberId: member.id, name: member.fullName || '', course: primary || member.course || member.college || '', year: member.yearLevel || '', date: secondary || '' });
      report.traineeExcludedMemberIds = (Array.isArray(report.traineeExcludedMemberIds) ? report.traineeExcludedMemberIds : []).filter((id) => String(id) !== String(member.id));
    }
    if (collection === 'quittedRows') report[collection].push({ id: uid('quitted'), memberId: member.id, name: member.fullName || '', reason: primary, remarks });
    if (collection === 'manualRemainingRows') {
      report.remainingMode = 'manual';
      report[collection].push({ id: uid('remaining'), memberId: member.id, name: member.fullName || '', course: primary || member.course || member.college || '' });
    }
    report.updatedAt = new Date().toISOString();
    if (!write(KEYS.monthly, state, 'lso:monthly-report-changed')) return;
    log('Added member monthly filing from overall record', 'Monthly Report', `${member.fullName} • ${monthLabel(key)} • ${collection}`);
    toast('Monthly filing entry added.');
    window.LSOMonthlyReport?.refresh?.();
    scheduleRender();
  }

  function openMonthly(key) {
    window.LSOApp?.setView?.('monthlyReportView');
    setTimeout(() => window.LSOMonthlyReport?.openReport?.(key, 'setup'), 50);
  }

  function saveMonthlyRow(container) {
    if (!can('editMonthlyReport')) return toast('Your role cannot edit monthly reports.', true);
    const key = container.dataset.monthlyKey;
    const collection = container.dataset.monthlyCollection;
    const rowId = container.dataset.monthlyRow;
    const state = read(KEYS.monthly, { reports: {} });
    const report = state.reports?.[key];
    if (!report || report.workflowStatus === 'Finalized') return toast('This monthly report is finalized. Reopen it before editing.', true);
    const rows = Array.isArray(report[collection]) ? report[collection] : [];
    const row = rows.find((item) => String(item.id) === String(rowId));
    if (!row) return toast('The monthly row no longer exists. Refresh the record.', true);
    qsa('[data-overall-monthly-field]', container).forEach((input) => { row[input.dataset.overallMonthlyField] = input.value.trim(); });
    report.updatedAt = new Date().toISOString();
    if (!write(KEYS.monthly, state, 'lso:monthly-report-changed')) return;
    log('Revised member monthly filing', 'Monthly Report', `${selectedMember()?.fullName || 'Member'} • ${monthLabel(key)} • ${collection}`);
    toast('Monthly filing revision saved.');
    window.LSOMonthlyReport?.refresh?.();
    scheduleRender();
  }

  function removeMonthlyRow(container) {
    if (!can('editMonthlyReport')) return toast('Your role cannot edit monthly reports.', true);
    const key = container.dataset.monthlyKey;
    const collection = container.dataset.monthlyCollection;
    const rowId = container.dataset.monthlyRow;
    const state = read(KEYS.monthly, { reports: {} });
    const report = state.reports?.[key];
    if (!report || report.workflowStatus === 'Finalized') return toast('This monthly report is finalized. Reopen it before removing rows.', true);
    const reason = window.prompt('Enter the reason for removing this member-specific monthly row:');
    if (reason === null) return;
    if (reason.trim().length < 3) return toast('A clear removal reason is required.', true);
    const existingRows = Array.isArray(report[collection]) ? report[collection] : [];
    const removedRow = existingRows.find((row) => String(row.id) === String(rowId));
    report[collection] = existingRows.filter((row) => String(row.id) !== String(rowId));
    if (collection === 'traineeRows' && removedRow?.memberId) {
      report.traineeExcludedMemberIds = Array.isArray(report.traineeExcludedMemberIds) ? report.traineeExcludedMemberIds : [];
      if (!report.traineeExcludedMemberIds.includes(removedRow.memberId)) report.traineeExcludedMemberIds.push(removedRow.memberId);
    }
    report.updatedAt = new Date().toISOString();
    if (!write(KEYS.monthly, state, 'lso:monthly-report-changed')) return;
    log('Removed member monthly filing row', 'Monthly Report', `${selectedMember()?.fullName || 'Member'} • ${monthLabel(key)} • ${collection} • Reason: ${reason.trim()}`);
    toast('Monthly filing row removed.');
    window.LSOMonthlyReport?.refresh?.();
    scheduleRender();
  }

  function openAttendance(eventId, member) {
    const events = read(KEYS.events, []);
    const event = events.find((item) => String(item.id) === String(eventId));
    if (!event) return toast('The attendance activity no longer exists.', true);
    const group = attendanceGroupFor(member, event.date);
    window.LSOApp?.setView?.('attendanceView');
    window.LSOOperations?.setAttendanceSemester?.(event.semester || 'First Semester');
    window.LSOOperations?.setAttendanceGroup?.(group);
    window.LSOOperations?.setAttendanceMonth?.(String(event.date || '').slice(0, 7));
    setTimeout(() => {
      window.LSOOperations?.setSelectedEventId?.(event.id);
      const select = el('attendanceIndividualSelect');
      if (select && [...select.options].some((option) => String(option.value) === String(member.id))) {
        select.value = member.id;
        select.dispatchEvent(new Event('change', { bubbles: true }));
      }
    }, 90);
  }

  function saveAttendance(eventId, card, member) {
    const attendance = read(KEYS.attendance, []);
    const events = read(KEYS.events, []);
    const event = events.find((item) => String(item.id) === String(eventId));
    const record = attendance.find((item) => String(item.eventId) === String(eventId) && String(item.memberId) === String(member.id));
    if (!event || !record) return toast('The attendance record no longer exists.', true);
    const group = record.attendanceGroup || attendanceGroupFor(member, event.date);
    if (!can('saveDraftAttendance') || !(window.LSORoleAccess?.canUseAttendanceGroup?.(group, currentAccount()) ?? isAdmin())) return toast('Your role cannot edit this attendance group.', true);
    if (eventFinalized(event, group, record.rosterModeAtEdit || 'Current')) return toast('This attendance roster is finalized.', true);
    record.status = card.querySelector('[data-overall-attendance-field="status"]')?.value || '';
    record.remarks = card.querySelector('[data-overall-attendance-field="remarks"]')?.value.trim() || '';
    record.updatedAt = new Date().toISOString();
    record.updatedBy = currentAccount()?.displayName || currentAccount()?.username || 'Authorized user';
    if (!write(KEYS.attendance, attendance, 'lso:operations-changed')) return;
    log('Revised attendance from overall record', 'Attendance', `${member.fullName} • ${event.title || 'Activity'} • ${record.status}`);
    toast('Attendance revision saved.');
    window.LSOOperations?.refreshAll?.();
    scheduleRender();
  }

  function addAttendance(member) {
    const eventId = el('overallAttendanceEvent')?.value;
    const status = el('overallAttendanceStatus')?.value || 'Present';
    const remarks = el('overallAttendanceRemarks')?.value.trim() || '';
    const events = read(KEYS.events, []);
    const event = events.find((item) => String(item.id) === String(eventId));
    if (!event) return toast('Choose an attendance activity.', true);
    const group = attendanceGroupFor(member, event.date);
    if (!can('saveDraftAttendance') || !(window.LSORoleAccess?.canUseAttendanceGroup?.(group, currentAccount()) ?? isAdmin())) return toast('Your role cannot edit this attendance group.', true);
    if (eventFinalized(event, group, 'Current')) return toast('This attendance roster is finalized.', true);
    const attendance = read(KEYS.attendance, []);
    const index = attendance.findIndex((item) => String(item.eventId) === String(event.id) && String(item.memberId) === String(member.id) && String(item.attendanceGroup || group) === String(group));
    const now = new Date().toISOString();
    const next = { ...(index >= 0 ? attendance[index] : {}), eventId: event.id, memberId: member.id, status, remarks, attendanceGroup: group, rosterModeAtEdit: 'Current', createdAt: index >= 0 ? attendance[index].createdAt || now : now, updatedAt: now, updatedBy: currentAccount()?.displayName || currentAccount()?.username || 'Authorized user' };
    if (index >= 0) attendance[index] = next; else attendance.push(next);
    if (!write(KEYS.attendance, attendance, 'lso:operations-changed')) return;
    log(index >= 0 ? 'Updated attendance from overall record' : 'Added attendance from overall record', 'Attendance', `${member.fullName} • ${event.title || 'Activity'} • ${status}`);
    toast(index >= 0 ? 'Existing attendance record updated.' : 'Attendance record added.');
    window.LSOOperations?.refreshAll?.();
    scheduleRender();
  }

  function removeAttendance(eventId, member) {
    if (!isAdmin()) return;
    const events = read(KEYS.events, []);
    const event = events.find((item) => String(item.id) === String(eventId));
    const attendance = read(KEYS.attendance, []);
    const record = attendance.find((item) => String(item.eventId) === String(eventId) && String(item.memberId) === String(member.id));
    if (!record) return;
    const group = record.attendanceGroup || attendanceGroupFor(member, event?.date);
    if (event && eventFinalized(event, group, record.rosterModeAtEdit || 'Current')) return toast('This attendance roster is finalized.', true);
    const reason = window.prompt('Enter the reason for removing this attendance record:');
    if (reason === null) return;
    if (reason.trim().length < 3) return toast('A clear removal reason is required.', true);
    const next = attendance.filter((item) => !(String(item.eventId) === String(eventId) && String(item.memberId) === String(member.id)));
    if (!write(KEYS.attendance, next, 'lso:operations-changed')) return;
    log('Removed attendance from overall record', 'Attendance', `${member.fullName} • ${event?.title || eventId} • Reason: ${reason.trim()}`);
    toast('Attendance record removed.');
    window.LSOOperations?.refreshAll?.();
    scheduleRender();
  }

  function clockMinutes(timeIn, timeOut) {
    if (!timeIn || !timeOut) return 0;
    const [ih, im] = timeIn.split(':').map(Number);
    const [oh, om] = timeOut.split(':').map(Number);
    if (![ih, im, oh, om].every(Number.isFinite)) return 0;
    let result = oh * 60 + om - (ih * 60 + im);
    if (result < 0) result += 1440;
    return result;
  }

  function overlapsDutyEntries(entries, memberId, date, timeIn, timeOut, excludeId = '') {
    const start = clockMinutes('00:00', timeIn);
    let end = clockMinutes('00:00', timeOut);
    if (end <= start) end += 1440;
    return (Array.isArray(entries) ? entries : []).some((item) => {
      if (String(item.id) === String(excludeId) || String(item.memberId) !== String(memberId) || item.entryType !== 'Duty' || String(item.date || '') !== String(date || '')) return false;
      const otherStart = clockMinutes('00:00', item.timeIn);
      let otherEnd = clockMinutes('00:00', item.timeOut);
      if (otherEnd <= otherStart) otherEnd += 1440;
      return start < otherEnd && end > otherStart;
    });
  }

  function addDuty(member) {
    if (!can('manageDutyHours')) return toast('Your role cannot manage duty-hour records.', true);
    const type = el('overallDutyType')?.value || 'Duty';
    const date = el('overallDutyDate')?.value;
    const semester = el('overallDutySemester')?.value || 'First Semester';
    const period = el('overallDutyPeriod')?.value || 'Trainee Period';
    const description = el('overallDutyDescription')?.value.trim() || '';
    if (!date || description.length < 3) return toast('Enter a date and a clear description.', true);
    const data = read(KEYS.duty, { version: 8, commitments: {}, entries: [], archiveExclusions: {} });
    data.entries = Array.isArray(data.entries) ? data.entries : [];
    let timeIn = '', timeOut = '', minutes = 0;
    if (type === 'Duty') {
      timeIn = el('overallDutyTimeIn')?.value || '';
      timeOut = el('overallDutyTimeOut')?.value || '';
      minutes = clockMinutes(timeIn, timeOut);
      if (!timeIn || !timeOut || minutes <= 0) return toast('Enter a valid Time In and Time Out.', true);
      if (overlapsDutyEntries(data.entries, member.id, date, timeIn, timeOut)) return toast('This time overlaps an existing duty entry.', true);
    } else {
      minutes = Number(el('overallDutyMinutes')?.value || 0);
      if (!Number.isFinite(minutes) || minutes === 0) return toast('Enter non-zero incentive minutes.', true);
    }
    const account = currentAccount();
    data.entries.push({ id: uid('duty-entry'), memberId: member.id, semester, period, entryType: type, date, minutes, timeIn, timeOut, description, category: type === 'Duty' ? 'Manual Rendered Duty' : 'Manual Incentive', manualReason: description, correctionReason: '', memberApprovers: account?.displayName || account?.username || 'Authorized user', clockInAt: '', clockOutAt: '', timeSource: 'Manual Overall Record', approvalStatus: 'Approved', timeInApprovalStatus: type === 'Duty' ? 'Approved' : 'Not Submitted', timeOutApprovalStatus: type === 'Duty' ? 'Approved' : 'Not Submitted', punchAudit: [], approvedAt: new Date().toISOString(), approvedBy: account?.username || 'Authorized user', submittedAt: new Date().toISOString(), createdAt: new Date().toISOString(), createdBy: account?.displayName || account?.username || 'Authorized user', createdByUsername: account?.username || '' });
    window.LSODutyHours?.persistData?.(data, { action: 'Added duty record from overall record', details: `${member.fullName} • ${semester} • ${period} • ${minutesLabel(minutes, type === 'Incentive')}` });
    toast('Duty-hour record added.');
    scheduleRender(80);
  }

  function saveDuty(entryId, card, member) {
    if (!can('manageDutyHours')) return toast('Your role cannot manage duty-hour records.', true);
    const data = read(KEYS.duty, { version: 8, commitments: {}, entries: [] });
    const entry = (data.entries || []).find((item) => String(item.id) === String(entryId));
    if (!entry) return toast('The duty record no longer exists.', true);
    if (entry.approvalStatus !== 'Approved') return toast('Use Duty Hours to revise active, pending, or rejected punch workflows.', true);
    const date = card.querySelector('[data-overall-duty-field="date"]')?.value || entry.date;
    const description = card.querySelector('[data-overall-duty-field="description"]')?.value.trim() || '';
    if (!date || description.length < 3) return toast('Enter a date and a clear description.', true);
    if (entry.entryType === 'Duty') {
      const timeIn = card.querySelector('[data-overall-duty-field="timeIn"]')?.value || '';
      const timeOut = card.querySelector('[data-overall-duty-field="timeOut"]')?.value || '';
      const minutes = clockMinutes(timeIn, timeOut);
      if (!timeIn || !timeOut || minutes <= 0) return toast('Enter a valid Time In and Time Out.', true);
      if (overlapsDutyEntries(data.entries, member.id, date, timeIn, timeOut, entry.id)) return toast('This revised time overlaps another duty entry.', true);
      entry.timeIn = timeIn; entry.timeOut = timeOut; entry.minutes = minutes;
    } else {
      const minutes = Number(card.querySelector('[data-overall-duty-field="minutes"]')?.value || 0);
      if (!Number.isFinite(minutes) || minutes === 0) return toast('Enter non-zero incentive minutes.', true);
      entry.minutes = minutes;
    }
    entry.date = date;
    entry.description = description;
    entry.correctionReason = `Revised from Members Overall Record by ${currentAccount()?.username || 'authorized user'} on ${new Date().toISOString()}`;
    window.LSODutyHours?.persistData?.(data, { action: 'Revised duty record from overall record', details: `${member.fullName} • ${entry.semester} • ${entry.period} • ${entry.date}` });
    toast('Duty-hour revision saved.');
    scheduleRender(80);
  }

  function openDuty(entryId, member) {
    const data = read(KEYS.duty, { entries: [] });
    const entry = (data.entries || []).find((item) => String(item.id) === String(entryId));
    if (!entry) return toast('The duty record no longer exists.', true);
    window.LSOApp?.setView?.('dutyHoursView');
    setTimeout(() => window.LSODutyHours?.openRecord?.(member.id, entry.period, entry.semester, entryId), 70);
  }

  function removeDuty(entryId, member) {
    if (!isAdmin()) return;
    const reason = window.prompt('Enter the reason for deleting this duty-hour ledger entry:');
    if (reason === null) return;
    if (reason.trim().length < 3) return toast('A clear deletion reason is required.', true);
    const data = read(KEYS.duty, { version: 8, commitments: {}, entries: [] });
    const entry = (data.entries || []).find((item) => String(item.id) === String(entryId));
    if (!entry) return;
    data.entries = data.entries.filter((item) => String(item.id) !== String(entryId));
    window.LSODutyHours?.persistData?.(data, { action: 'Deleted duty record from overall record', details: `${member.fullName} • ${entry.semester} • ${entry.period} • Reason: ${reason.trim()}` });
    toast('Duty-hour record removed.');
    scheduleRender(80);
  }

  function pdfSafe(value) {
    return String(value ?? '—').replace(/[\u2010-\u2015]/g, '-').replace(/[\u2022]/g, '-').replace(/[^\x20-\x7E\n]/g, '');
  }

  async function downloadPdf(member) {
    if (!window.PDFLib?.PDFDocument) return toast('The PDF library is not available.', true);
    const button = el('printRecordButton');
    const original = button?.textContent || 'Download PDF Overview';
    if (button) { button.disabled = true; button.textContent = 'Preparing PDF...'; }
    try {
      const data = recordData(member);
      const PDF = window.PDFLib;
      const doc = await PDF.PDFDocument.create();
      doc.setTitle(`${member.fullName} - Members Overall Record`);
      doc.setAuthor('Lasallian Symphony Orchestra');
      doc.setSubject('Unified member profile, contract, monthly report, attendance, and duty-hour overview');
      const regular = await doc.embedFont(PDF.StandardFonts.Helvetica);
      const bold = await doc.embedFont(PDF.StandardFonts.HelveticaBold);
      function loadOfficialAsset(filename) {
        const base64 = window.LSO_OFFICIAL_PDF_ASSETS?.[filename];
        if (!base64) throw new Error(`The embedded official LSO PDF asset is unavailable: ${filename}`);
        try {
          const binary = window.atob(base64);
          const bytes = new Uint8Array(binary.length);
          for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
          return bytes;
        } catch {
          throw new Error(`The official LSO PDF asset could not be decoded: ${filename}`);
        }
      }
      const [officialHeaderBytes, officialFooterBytes] = await Promise.all([
        loadOfficialAsset('lso-official-header.png'),
        loadOfficialAsset('lso-official-footer.png')
      ]);
      const officialHeader = await doc.embedPng(officialHeaderBytes);
      const officialFooter = await doc.embedPng(officialFooterBytes);
      const pageSize = [595.28, 841.89];
      const margin = 42;
      const width = pageSize[0] - margin * 2;
      const officialHeaderHeight = pageSize[0] * (officialHeader.height / officialHeader.width);
      const officialFooterHeight = pageSize[0] * (officialFooter.height / officialFooter.width);
      const contentBottom = officialFooterHeight + 28;
      const green = PDF.rgb(18 / 255, 63 / 255, 51 / 255);
      const emerald = PDF.rgb(22 / 255, 122 / 255, 91 / 255);
      const ink = PDF.rgb(31 / 255, 41 / 255, 51 / 255);
      const muted = PDF.rgb(102 / 255, 112 / 255, 133 / 255);
      const light = PDF.rgb(244 / 255, 246 / 255, 248 / 255);
      let page;
      let y;
      const pages = [];
      function newPage(title = 'Members Overall Record') {
        page = doc.addPage(pageSize); pages.push(page);
        page.drawImage(officialHeader, { x: 0, y: pageSize[1] - officialHeaderHeight, width: pageSize[0], height: officialHeaderHeight });
        page.drawImage(officialFooter, { x: 0, y: 0, width: pageSize[0], height: officialFooterHeight });
        const titleTop = pageSize[1] - officialHeaderHeight - 24;
        page.drawText(pdfSafe(title), { x: margin, y: titleTop, size: 15, font: bold, color: green });
        page.drawLine({ start: { x: margin, y: titleTop - 9 }, end: { x: margin + width, y: titleTop - 9 }, thickness: 1.2, color: emerald });
        y = titleTop - 31;
      }
      function ensure(height = 35, title) { if (y - height < contentBottom) newPage(title); }
      function heading(text) { ensure(32); page.drawText(pdfSafe(text), { x: margin, y, size: 12, font: bold, color: green }); y -= 18; page.drawLine({ start: { x: margin, y: y + 4 }, end: { x: margin + width, y: y + 4 }, thickness: 1, color: emerald }); y -= 9; }
      function wrap(text, size, maxWidth, font = regular) {
        const words = pdfSafe(text).split(/\s+/); const lines = []; let line = '';
        words.forEach((word) => { const next = line ? `${line} ${word}` : word; if (font.widthOfTextAtSize(next, size) <= maxWidth) line = next; else { if (line) lines.push(line); line = word; } });
        if (line) lines.push(line); return lines.length ? lines : ['—'];
      }
      function textBlock(label, value) {
        const lines = wrap(value || '—', 8.4, width - 132);
        ensure(Math.max(22, lines.length * 11 + 8));
        page.drawText(pdfSafe(label), { x: margin, y, size: 8, font: bold, color: muted });
        lines.forEach((line, index) => page.drawText(line, { x: margin + 126, y: y - index * 11, size: 8.4, font: regular, color: ink }));
        y -= Math.max(22, lines.length * 11 + 7);
      }
      function table(headers, rows, widths) {
        const rowHeight = 22;
        const headerHeight = 24;
        ensure(headerHeight + rowHeight * Math.min(rows.length, 2) + 12);
        let x = margin;
        page.drawRectangle({ x: margin, y: y - headerHeight + 5, width, height: headerHeight, color: green });
        headers.forEach((header, index) => { page.drawText(pdfSafe(header), { x: x + 5, y: y - 11, size: 7.2, font: bold, color: PDF.rgb(1,1,1) }); x += widths[index]; });
        y -= headerHeight;
        rows.forEach((row) => {
          if (y - rowHeight < contentBottom) { newPage(); x = margin; page.drawRectangle({ x: margin, y: y - headerHeight + 5, width, height: headerHeight, color: green }); headers.forEach((header, index) => { page.drawText(pdfSafe(header), { x: x + 5, y: y - 11, size: 7.2, font: bold, color: PDF.rgb(1,1,1) }); x += widths[index]; }); y -= headerHeight; }
          page.drawRectangle({ x: margin, y: y - rowHeight + 5, width, height: rowHeight, color: light, borderColor: PDF.rgb(.82,.85,.84), borderWidth: .5 });
          x = margin;
          row.forEach((cell, index) => { const lines = wrap(cell, 6.8, widths[index] - 9).slice(0, 2); lines.forEach((line, lineIndex) => page.drawText(line, { x: x + 5, y: y - 8 - lineIndex * 8, size: 6.8, font: regular, color: ink })); x += widths[index]; });
          y -= rowHeight;
        });
        y -= 10;
      }

      newPage();
      page.drawText(pdfSafe(member.fullName), { x: margin, y, size: 20, font: bold, color: green }); y -= 23;
      page.drawText(pdfSafe(`${member.membershipId || 'No Membership ID'} | Student No. ${member.studentNumber || 'Not recorded'} | ${phaseAt(member, today())}`), { x: margin, y, size: 9, font: regular, color: muted }); y -= 24;
      heading('Profile and Membership Lifecycle');
      [['Membership Status', member.memberStatus], ['Current Phase', phaseAt(member, today())], ['Orchestra Section', member.orchestraSection], ['Primary Instrument', member.primaryInstrument], ['College / Course', [member.college, member.course].filter(Boolean).join(' - ')], ['Year / Section', [member.yearLevel, member.section].filter(Boolean).join(' - ')], ['Home Address', member.homeAddress], ['DLSUD Outlook', member.outlook], ['Trainee Start', dateLabel(member.traineeStartDate)], ['Probationary Start', member.probationarySkipped ? 'Skipped' : dateLabel(member.probationaryStartDate)], ['Membership Start', dateLabel(member.regularMemberDate)], ['Remarks', [member.stageNotes, member.remarks].filter(Boolean).join(' | ') || 'None']].forEach(([label, value]) => textBlock(label, value));

      heading('Generated Contract History');
      const contracts = [...data.contracts].sort((a,b) => String(b.generatedAt || '').localeCompare(String(a.generatedAt || '')));
      if (contracts.length) table(['Generated', 'Contract Date', 'Semester / AY', 'Officer'], contracts.map((record) => [dateLabel(record.generatedAt), dateLabel(record.contractDate), `${record.semester || '—'} / ${record.academicYear || '—'}`, record.officer || '—']), [105, 100, 145, width - 350]); else textBlock('Status', 'No tracked generated contracts. Older PDFs generated before V49 were not historically logged.');

      heading('Monthly Report Participation');
      const monthRows = monthlyRowsForMember(member, data.monthly);
      if (monthRows.length) table(['Month', 'Phase', 'Report', 'Member-specific entries'], monthRows.map((item) => [monthLabel(item.key), item.phase, item.report.workflowStatus || 'Draft', item.items.map((entry) => entry.type).join(', ') || 'Phase snapshot only']), [115, 80, 70, width - 265]); else textBlock('Status', 'No monthly report history.');

      heading('Complete Attendance');
      const attendanceRows = data.attendanceRecords.map((record) => ({ record, event: data.eventMap.get(String(record.eventId)) || {} })).sort((a,b) => String(b.event.date || '').localeCompare(String(a.event.date || '')));
      if (attendanceRows.length) table(['Date', 'Activity', 'Group', 'Status', 'Remarks'], attendanceRows.map(({ record, event }) => [dateLabel(event.date), event.title || event.name || 'Activity', record.attendanceGroup || attendanceGroupFor(member, event.date), record.status || '—', record.remarks || '—']), [75, 150, 105, 55, width - 385]); else textBlock('Status', 'No attendance records.');

      heading('Duty-Hour Ledger');
      const dutyRows = [...data.dutyEntries].sort((a,b) => String(b.date || '').localeCompare(String(a.date || '')));
      if (dutyRows.length) table(['Date', 'Semester / Period', 'Type', 'Duration', 'Status', 'Description'], dutyRows.map((entry) => [dateLabel(entry.date), `${entry.semester || '—'} / ${entry.period || '—'}`, entry.entryType || 'Duty', minutesLabel(entry.minutes, entry.entryType === 'Incentive'), entry.approvalStatus || '—', entry.description || '—']), [70, 125, 65, 70, 60, width - 390]); else textBlock('Status', 'No duty-hour records.');

      pages.forEach((item, index) => {
        const metaY = officialFooterHeight + 9;
        item.drawLine({ start: { x: margin, y: metaY + 11 }, end: { x: margin + width, y: metaY + 11 }, thickness: .55, color: PDF.rgb(.82,.85,.84) });
        item.drawText(pdfSafe(`Generated ${dateLabel(new Date().toISOString(), false)} | Official LSO Members Overall Record`), { x: margin, y: metaY, size: 6.5, font: regular, color: muted });
        const label = `Page ${index + 1} of ${pages.length}`;
        item.drawText(label, { x: pageSize[0] - margin - regular.widthOfTextAtSize(label, 6.5), y: metaY, size: 6.5, font: regular, color: muted });
      });
      const bytes = await doc.save();
      const blob = new Blob([bytes], { type: 'application/pdf' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = `LSO_Members_Overall_Record_${String(member.fullName || 'Member').replace(/[^a-z0-9]+/gi, '_')}.pdf`;
      document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1500);
      log('Downloaded members overall record PDF', 'Members', `${member.fullName} • ${data.attendanceRecords.length} attendance • ${data.dutyEntries.length} duty entries`);
      toast('Members Overall Record PDF downloaded.');
    } catch (error) {
      console.error('Overall record PDF failed:', error);
      toast(error.message || 'Unable to generate the PDF overview.', true);
    } finally {
      if (button) { button.disabled = false; button.textContent = original; }
    }
  }

  function handleClick(event) {
    const member = selectedMember();
    const tab = event.target.closest('[data-overall-tab]');
    if (tab) return setActiveTab(tab.dataset.overallTab);
    const toggle = event.target.closest('.overall-editor-toggle');
    if (toggle) return toggle.closest('.overall-inline-editor')?.classList.toggle('open');
    if (!member) return;
    if (event.target.closest('#overallOpenContractCenter') || event.target.closest('[data-overall-contract-open]')) return openContract(member);
    const contractRemove = event.target.closest('[data-overall-contract-remove]');
    if (contractRemove) return removeContract(member, contractRemove.dataset.overallContractRemove);
    if (event.target.closest('[data-overall-monthly-add]')) return addMonthlyRow(member);
    const monthOpen = event.target.closest('[data-overall-open-month]');
    if (monthOpen) return openMonthly(monthOpen.dataset.overallOpenMonth);
    const monthlySave = event.target.closest('[data-overall-monthly-save]');
    if (monthlySave) return saveMonthlyRow(monthlySave.closest('[data-monthly-row]'));
    const monthlyRemove = event.target.closest('[data-overall-monthly-remove]');
    if (monthlyRemove) return removeMonthlyRow(monthlyRemove.closest('[data-monthly-row]'));
    const attendanceOpen = event.target.closest('[data-overall-attendance-open]');
    if (attendanceOpen) return openAttendance(attendanceOpen.dataset.overallAttendanceOpen, member);
    const attendanceSave = event.target.closest('[data-overall-attendance-save]');
    if (attendanceSave) return saveAttendance(attendanceSave.dataset.overallAttendanceSave, attendanceSave.closest('.overall-record-card'), member);
    const attendanceRemove = event.target.closest('[data-overall-attendance-remove]');
    if (attendanceRemove) return removeAttendance(attendanceRemove.dataset.overallAttendanceRemove, member);
    if (event.target.closest('[data-overall-attendance-add]')) return addAttendance(member);
    const dutyOpen = event.target.closest('[data-overall-duty-open]');
    if (dutyOpen) return openDuty(dutyOpen.dataset.overallDutyOpen, member);
    const dutySave = event.target.closest('[data-overall-duty-save]');
    if (dutySave) return saveDuty(dutySave.dataset.overallDutySave, dutySave.closest('.overall-record-card'), member);
    const dutyRemove = event.target.closest('[data-overall-duty-remove]');
    if (dutyRemove) return removeDuty(dutyRemove.dataset.overallDutyRemove, member);
    if (event.target.closest('[data-overall-duty-add]')) return addDuty(member);
  }

  function handleChange(event) {
    if (event.target.id === 'overallDutyType') {
      const incentive = event.target.value === 'Incentive';
      qsa('.duty-time-field', el('overallDutyAdd')).forEach((node) => node.classList.toggle('hidden', incentive));
      qsa('.incentive-minute-field', el('overallDutyAdd')).forEach((node) => node.classList.toggle('hidden', !incentive));
    }
  }

  function initialize() {
    const lookup = el('lookupView');
    if (!lookup) return;
    lookup.addEventListener('click', handleClick);
    lookup.addEventListener('change', handleChange);
    el('lookupResults')?.addEventListener('click', () => scheduleRender(30));
    el('lookupSearch')?.addEventListener('input', () => scheduleRender(30));
    el('printRecordButton')?.addEventListener('click', (event) => {
      event.preventDefault(); event.stopImmediatePropagation();
      const member = selectedMember();
      if (member) downloadPdf(member); else toast('Select a member first.', true);
    }, true);
    const observer = new MutationObserver(() => scheduleRender(10));
    if (el('recordName')) observer.observe(el('recordName'), { childList: true, characterData: true, subtree: true });
    if (el('lookupResults')) observer.observe(el('lookupResults'), { childList: true, subtree: true });
    ['lso:members-changed', 'lso:operations-changed', 'lso:monthly-report-changed', 'lso:duty-hours-changed', 'lso:cloud-state-changed', 'lso:auth-changed']
      .forEach((name) => window.addEventListener(name, () => scheduleRender(60)));
    document.querySelector('[data-view="lookupView"]')?.addEventListener('click', () => scheduleRender(80));
    scheduleRender(120);
  }

  window.LSOMemberOverall = { refresh: renderAll, downloadPdf: () => { const member = selectedMember(); if (member) return downloadPdf(member); }, openTab: setActiveTab };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
