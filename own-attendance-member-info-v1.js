/* ============================================================================
   LASALLIAN SYMPHONY ORCHESTRA — V84 "MY ATTENDANCE" (SELF-SERVICE, READ-ONLY)

   Purpose
     Gives a signed-in Trainee/Probationary member a section that shows ONLY
     their own attendance record, in read-only form. The account is linked to
     exactly one member (account.memberId); every row rendered here is filtered
     by that member id and nothing else.

   Read-only guarantee (by construction)
     - This module never calls a write path. It does not use
       LSOOperations.replaceAttendance, the attendance roster save, any form
       submission, or any shared-state column write.
     - The view contains no inputs, no selects that change data, and no edit
       controls. The only interactive controls are the month filter (a local
       read-only filter) and the print action.
     - There is no "edit attendance" permission to grant. The permission is a
       module (view) grant only; the V82 write-column derivation is untouched,
       so a role with only this module receives zero shared-database write
       columns from it.

   Data sources (all read-only)
     - window.LSOApp.getMembers()            -> member directory (own record)
     - window.LSOOperations.getEvents()      -> attendance activities
     - window.LSOOperations.getAttendance()  -> attendance records
     - window.LSOBrand.printHeader()         -> branded printable header
   ============================================================================ */
(() => {
  'use strict';

  const VIEW_ID = 'ownAttendanceView';
  const TRAINEE_ROLE = 'Trainee/Probationary';
  const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const PH_TIME_ZONE = 'Asia/Manila';

  const el = (id) => document.getElementById(id);
  const safe = (value) => String(value ?? '').replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
  const sameId = (left, right) => String(left ?? '') !== '' && String(left ?? '') === String(right ?? '');
  const text = (value) => String(value ?? '').trim();

  let renderFrame = 0;
  let renderSignature = '';
  let selectedMonth = '';

  // --------------------------------------------------------------------------
  // Identity — the viewer is resolved from the session only. No URL parameter,
  // query string, or on-screen selector can widen or change this scope.
  // --------------------------------------------------------------------------
  function account() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function role() {
    return window.LSORoleAccess?.role?.(account()) || account()?.role || '';
  }

  function isTraineeAccount() {
    return role() === TRAINEE_ROLE;
  }

  function canOpenView() {
    if (!isTraineeAccount()) return false;
    return window.LSORoleAccess?.canAccessView?.(VIEW_ID, account()) ?? true;
  }

  function linkedMemberId() {
    const value = account()?.memberId;
    if (value === undefined || value === null) return '';
    return String(value).trim();
  }

  function linkedMember() {
    const memberId = linkedMemberId();
    if (!memberId) return null;
    return (window.LSOApp?.getMembers?.() || []).find((member) => sameId(member.id, memberId)) || null;
  }

  // --------------------------------------------------------------------------
  // Presentation helpers
  // --------------------------------------------------------------------------
  function phToday() {
    try {
      return new Intl.DateTimeFormat('en-CA', { timeZone: PH_TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
    } catch {
      return new Date().toISOString().slice(0, 10);
    }
  }

  function dateLabel(value) {
    const iso = text(value);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso || '—';
    const [year, month, day] = iso.split('-');
    return `${MONTH_NAMES[Number(month) - 1]?.slice(0, 3) || month} ${Number(day)}, ${year}`;
  }

  function monthKeyOf(value) {
    const iso = text(value);
    return /^\d{4}-\d{2}/.test(iso) ? iso.slice(0, 7) : '';
  }

  function monthLabel(key) {
    const value = text(key);
    if (!/^\d{4}-\d{2}$/.test(value)) return 'Undated activity';
    const [year, month] = value.split('-');
    return `${MONTH_NAMES[Number(month) - 1] || month} ${year}`;
  }

  function nowLabel() {
    try {
      return new Intl.DateTimeFormat('en-PH', { timeZone: PH_TIME_ZONE, dateStyle: 'medium', timeStyle: 'short' }).format(new Date());
    } catch {
      return new Date().toISOString();
    }
  }

  function normalizeStatus(value) {
    const status = text(value);
    return status || 'Not Recorded';
  }

  function statusClass(status) {
    const key = text(status).toLowerCase().replace(/\s+/g, '-');
    return `own-attendance-status is-${key || 'unknown'}`;
  }

  function rateLabel(rate) {
    return rate === null ? 'Not rated' : `${rate}%`;
  }

  // --------------------------------------------------------------------------
  // Read-only data assembly — every row is the linked member's own record.
  // --------------------------------------------------------------------------
  function buildRows() {
    const memberId = linkedMemberId();
    if (!memberId) return [];
    const events = new Map((window.LSOOperations?.getEvents?.() || []).map((event) => [String(event?.id ?? ''), event]));
    return (window.LSOOperations?.getAttendance?.() || [])
      .filter((record) => sameId(record?.memberId, memberId))
      .map((record) => {
        const event = events.get(String(record?.eventId ?? '')) || null;
        const date = text(event?.date);
        return {
          eventId: String(record?.eventId ?? ''),
          date,
          monthKey: monthKeyOf(date),
          title: text(event?.title) || 'Activity no longer listed',
          type: text(event?.type) || '—',
          venue: text(event?.venue),
          group: text(record?.attendanceGroup),
          status: normalizeStatus(record?.status),
          remarks: text(record?.remarks),
          loa: record?.loaAutoExcused === true
        };
      })
      .sort((left, right) => (right.date || '').localeCompare(left.date || '') || left.title.localeCompare(right.title));
  }

  function summarize(rows) {
    const counts = { Present: 0, Late: 0, Absent: 0, Excused: 0, 'Not Required': 0 };
    let other = 0;
    rows.forEach((row) => {
      if (Object.prototype.hasOwnProperty.call(counts, row.status)) counts[row.status] += 1;
      else other += 1;
    });
    // Identical denominator to the official Attendance rating:
    // (Present + Late) over (Present + Late + Absent). Excused, Not Required,
    // and LOA rows are excluded from the rating, never counted as absences.
    const rated = counts.Present + counts.Late + counts.Absent;
    const rate = rated > 0 ? Math.round(((counts.Present + counts.Late) / rated) * 100) : null;
    return { counts, other, rated, rate, total: rows.length };
  }

  function visibleRows(allRows) {
    if (!selectedMonth) return allRows;
    return allRows.filter((row) => row.monthKey === selectedMonth);
  }

  function monthsIn(rows) {
    return [...new Set(rows.map((row) => row.monthKey).filter(Boolean))].sort().reverse();
  }

  // --------------------------------------------------------------------------
  // Rendering
  // --------------------------------------------------------------------------
  function summaryCard(label, value, helper = '') {
    return `<article class="own-attendance-metric"><p>${safe(label)}</p><strong>${safe(value)}</strong>${helper ? `<small>${safe(helper)}</small>` : ''}</article>`;
  }

  function renderIdentity(member) {
    const nameNode = el('ownAttendanceMemberName');
    const metaNode = el('ownAttendanceMemberMeta');
    if (nameNode) nameNode.textContent = member?.fullName || account()?.displayName || account()?.username || 'Linked member';
    if (metaNode) {
      const parts = [
        text(member?.membershipId),
        text(member?.membershipStage) || text(member?.periodGroup),
        text(member?.orchestraSection),
        text(member?.primaryInstrument)
      ].filter(Boolean);
      metaNode.textContent = parts.join(' • ') || 'Member record';
    }
  }

  function renderMonthFilter(rows) {
    const select = el('ownAttendanceMonthFilter');
    if (!select) return;
    const months = monthsIn(rows);
    if (selectedMonth && !months.includes(selectedMonth)) selectedMonth = '';
    const signature = `${months.join('|')}#${selectedMonth}`;
    if (select.dataset.signature !== signature) {
      select.dataset.signature = signature;
      select.innerHTML = [`<option value="">All recorded months (${rows.length} session${rows.length === 1 ? '' : 's'})</option>`]
        .concat(months.map((month) => {
          const count = rows.filter((row) => row.monthKey === month).length;
          return `<option value="${safe(month)}">${safe(monthLabel(month))} (${count})</option>`;
        }))
        .join('');
      select.value = selectedMonth;
    }
    select.disabled = months.length === 0;
  }

  function renderSummary(rows) {
    const container = el('ownAttendanceSummary');
    if (!container) return;
    const summary = summarize(rows);
    container.innerHTML = [
      summaryCard('Recorded sessions', String(summary.total), summary.total === 0 ? 'No attendance record yet' : 'Logged in the shared database'),
      summaryCard('Present', String(summary.counts.Present)),
      summaryCard('Late', String(summary.counts.Late)),
      summaryCard('Absent', String(summary.counts.Absent)),
      summaryCard('Excused', String(summary.counts.Excused), 'LOA and approved excuses'),
      summaryCard('Not required', String(summary.counts['Not Required'])),
      summaryCard('Attendance rate', rateLabel(summary.rate), summary.rated ? `${summary.rated} rated session${summary.rated === 1 ? '' : 's'}` : 'No rated session yet')
    ].join('');
  }

  function renderTable(rows) {
    const body = el('ownAttendanceTableBody');
    const empty = el('ownAttendanceEmpty');
    const wrapper = el('ownAttendanceTableWrap');
    if (body) {
      body.innerHTML = rows.map((row) => `<tr>
        <td>${safe(dateLabel(row.date))}</td>
        <td><strong>${safe(row.title)}</strong>${row.venue ? `<br><small>${safe(row.venue)}</small>` : ''}</td>
        <td>${safe(row.type)}</td>
        <td><span class="${statusClass(row.status)}">${safe(row.status)}</span></td>
        <td>${safe(row.remarks) || '—'}${row.loa ? ' <small>(Approved LOA)</small>' : ''}</td>
      </tr>`).join('');
    }
    if (empty) empty.classList.toggle('hidden', rows.length > 0);
    if (wrapper) wrapper.classList.toggle('hidden', rows.length === 0);
  }

  function renderStatus(rows) {
    const node = el('ownAttendanceStatus');
    if (!node) return;
    if (!linkedMemberId()) {
      node.textContent = 'This account is not linked to a member record yet. Ask the Administrator to link the account before attendance can be shown.';
      return;
    }
    if (!rows.length) {
      node.textContent = `No attendance record has been filed for this member yet. Checked ${nowLabel()} (Philippine time).`;
      return;
    }
    node.textContent = `Read-only copy of your own attendance, checked ${nowLabel()} (Philippine time). Only records linked to this account's member are shown — editing is not available in this section.`;
  }

  function render({ force = false } = {}) {
    const view = el(VIEW_ID);
    if (!view) return;
    // Never render (or reveal) this section for an account that is not an
    // eligible, permission-granted Trainee/Probationary member. The section is
    // hidden outright if the current account is not eligible, so a revoked
    // permission can never leave the surface reachable.
    if (!canOpenView()) {
      renderSignature = '';
      view.classList.add('hidden');
      return;
    }
    view.classList.remove('hidden');
    const member = linkedMember();
    const allRows = buildRows();
    const rows = visibleRows(allRows);
    const signature = JSON.stringify({
      month: selectedMonth,
      member: linkedMemberId(),
      rows: allRows.map((row) => [row.eventId, row.status, row.remarks, row.date, row.title])
    });
    if (!force && signature === renderSignature) return;
    renderSignature = signature;
    renderIdentity(member);
    renderMonthFilter(allRows);
    renderSummary(rows);
    renderTable(rows);
    renderStatus(allRows);
  }

  function scheduleRender() {
    if (renderFrame) return;
    renderFrame = window.requestAnimationFrame(() => {
      renderFrame = 0;
      render();
    });
  }

  function isViewActive() {
    return document.querySelector(`.view.active:not(.hidden)`)?.id === VIEW_ID;
  }

  // --------------------------------------------------------------------------
  // Printable copy (read-only report). Uses the same rows that are on screen.
  // --------------------------------------------------------------------------
  function printStyles() {
    return `
      * { box-sizing: border-box; }
      body { font-family: "Segoe UI", Arial, sans-serif; color: #14231d; margin: 26px; }
      h1 { font-size: 19px; margin: 0 0 4px; }
      p { margin: 0 0 6px; }
      .meta { color: #4c5b55; font-size: 12px; }
      .summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin: 16px 0 18px; }
      .summary div { border: 1px solid #d6ded9; border-radius: 10px; padding: 9px 11px; }
      .summary span { display: block; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #5d6c66; }
      .summary strong { font-size: 17px; }
      table { width: 100%; border-collapse: collapse; font-size: 12px; }
      th, td { border: 1px solid #d6ded9; padding: 7px 8px; text-align: left; vertical-align: top; }
      th { background: #f1f6f3; font-size: 11px; text-transform: uppercase; letter-spacing: .05em; }
      .footer { margin-top: 16px; font-size: 11px; color: #5d6c66; }
      .notice { margin-top: 14px; border: 1px solid #d6ded9; border-radius: 10px; padding: 10px 12px; font-size: 11px; color: #4c5b55; }
    `;
  }

  function printReport() {
    if (!canOpenView()) return;
    const member = linkedMember();
    const allRows = buildRows();
    const rows = visibleRows(allRows);
    const summary = summarize(rows);
    const scope = selectedMonth ? monthLabel(selectedMonth) : 'All recorded months';
    const brandHeader = window.LSOBrand?.printHeader
      ? window.LSOBrand.printHeader({
        title: 'Individual Attendance Report',
        subtitle: `${member?.fullName || account()?.displayName || 'Member'} • ${scope}`,
        meta: `Generated ${nowLabel()} (Philippine time)`
      })
      : '<h1>Individual Attendance Report</h1>';
    const html = `<!doctype html><html><head><meta charset="utf-8"><title>${safe(member?.fullName || 'Attendance')} — My Attendance</title><style>${printStyles()}</style></head><body>
      ${brandHeader}
      <p class="meta">${safe([text(member?.membershipId), text(member?.membershipStage) || text(member?.periodGroup), text(member?.orchestraSection)].filter(Boolean).join(' • '))}</p>
      <div class="summary">
        <div><span>Recorded sessions</span><strong>${summary.total}</strong></div>
        <div><span>Present</span><strong>${summary.counts.Present}</strong></div>
        <div><span>Late</span><strong>${summary.counts.Late}</strong></div>
        <div><span>Absent</span><strong>${summary.counts.Absent}</strong></div>
        <div><span>Excused</span><strong>${summary.counts.Excused}</strong></div>
        <div><span>Not required</span><strong>${summary.counts['Not Required']}</strong></div>
        <div><span>Attendance rate</span><strong>${rateLabel(summary.rate)}</strong></div>
        <div><span>Rated sessions</span><strong>${summary.rated}</strong></div>
      </div>
      <table><thead><tr><th>Date</th><th>Activity</th><th>Type</th><th>Status</th><th>Remarks</th></tr></thead><tbody>
      ${rows.length ? rows.map((row) => `<tr><td>${safe(dateLabel(row.date))}</td><td>${safe(row.title)}</td><td>${safe(row.type)}</td><td>${safe(row.status)}</td><td>${safe(row.remarks) || '—'}</td></tr>`).join('') : '<tr><td colspan="5">No attendance record has been filed for this member yet.</td></tr>'}
      </tbody></table>
      <div class="notice">Read-only copy generated from the shared LSO database. Attendance rating counts Present and Late over rated Present/Late/Absent sessions; Excused, Not Required, and approved LOA records are excluded from the rating.</div>
      <div class="footer">Lasallian Symphony Orchestra • Orchestra Management System</div>
      </body></html>`;
    const popup = window.open('', '_blank', 'width=1100,height=800');
    if (!popup) {
      window.LSOApp?.showToast?.('Allow pop-ups to generate the printable attendance report.', true);
      return;
    }
    popup.document.write(html);
    popup.document.close();
  }

  // --------------------------------------------------------------------------
  // Wiring
  // --------------------------------------------------------------------------
  function wire() {
    el('ownAttendanceMonthFilter')?.addEventListener('change', (event) => {
      selectedMonth = text(event.target.value);
      render({ force: true });
    });
    el('ownAttendancePrintButton')?.addEventListener('click', printReport);
    el('ownAttendanceRefreshButton')?.addEventListener('click', () => render({ force: true }));

    // The shell reveals views on navigation click; render on the next frame so
    // the section always reflects the shared database when it becomes visible.
    document.addEventListener('click', (event) => {
      if (event.target?.closest?.(`.nav-item[data-view="${VIEW_ID}"]`)) window.setTimeout(scheduleRender, 0);
    });

    ['lso:cloud-state-changed', 'lso:attendance-changed', 'lso:attendance-governance-changed', 'lso:permissions-changed', 'lso:auth-changed']
      .forEach((name) => window.addEventListener(name, () => {
        if (name === 'lso:auth-changed') { renderSignature = ''; selectedMonth = ''; }
        if (isViewActive() || name === 'lso:auth-changed') scheduleRender();
      }));
  }

  function initialize() {
    wire();
    render({ force: true });
    // Shared-database values may still be loading at first paint; refresh once
    // more after the initial synchronization settles.
    window.setTimeout(scheduleRender, 900);
  }

  window.LSOOwnAttendance = {
    viewId: VIEW_ID,
    refresh: () => render({ force: true }),
    // Diagnostics only — returns the linked member id resolved from the session.
    getScope: () => linkedMemberId(),
    getRows: () => visibleRows(buildRows())
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
