(() => {
  'use strict';

  const STORAGE_KEY = 'lso_attendance_workspace_tab_v58';
  const TABS = ['current', 'archive', 'semester'];
  const el = (id) => document.getElementById(id);
  let activeTab = 'current';
  let applying = false;
  let applyTimer = 0;

  function safeTab(value) {
    return TABS.includes(value) ? value : 'current';
  }

  function attendanceViewActive() {
    const view = el('attendanceView');
    return Boolean(view && view.classList.contains('active') && !view.classList.contains('hidden'));
  }

  function setHidden(node, hidden) {
    if (!node) return;
    node.classList.toggle('hidden', Boolean(hidden));
    node.setAttribute('aria-hidden', hidden ? 'true' : 'false');
  }

  function setModeForTab(tab) {
    const expected = tab === 'archive' ? 'Archive' : 'Current';
    if (String(window.LSOOperations?.getAttendanceRosterMode?.() || window.LSOAttendanceRosterMode || 'Current') === expected) return;
    window.LSOAttendanceRosterMode = expected;
    window.LSOOperations?.setAttendanceRosterMode?.(expected);
  }

  function updateContext(tab) {
    const context = el('attendanceWorkspaceContext');
    if (!context) return;
    const copy = {
      current: ['Current Attendance', 'Draft → Review → Finalize', 'Create activities, complete the selected roster, review the month, and finalize one validated output.'],
      archive: ['Monthly Archive', 'Validated finalized copies', 'Review frozen monthly records, ratings, revisions, and archive actions without changing live attendance.'],
      semester: ['Semester Summary', 'Finalized months only', 'Set the end date, review finalized monthly ratings, and lock the semestral computation.']
    }[tab];
    context.innerHTML = `<span>${copy[0]}</span><strong>${copy[1]}</strong><small>${copy[2]}</small>`;
  }

  function updateHeaderActions(tab) {
    setHidden(el('addEventButton'), tab !== 'current');
    setHidden(el('printMonthlyAttendance'), tab !== 'current');
    setHidden(el('printOverallAttendance'), tab !== 'semester');
    setHidden(el('exportAttendanceAnalyticsCsv'), tab === 'archive');
    setHidden(el('attendanceGroupPrintButton'), tab !== 'current');
  }

  function updatePanelVisibility(tab) {
    const periodCenter = el('attendancePeriodFinalizationCenter');
    const monthProgress = el('attendanceMonthProgress');
    const archiveNotice = el('attendanceArchiveNotice');
    const archiveBlock = el('attendanceFinalizedArchiveBlock');
    const overview = el('attendanceOverviewGrid');
    const calendar = el('attendanceCalendarPanel');
    const management = el('attendanceManagementLayout');

    setHidden(archiveNotice, tab !== 'archive');
    setHidden(archiveBlock, tab !== 'archive');
    setHidden(periodCenter, tab === 'archive');
    setHidden(monthProgress, tab !== 'current');
    setHidden(overview, tab === 'semester');
    setHidden(calendar, tab !== 'current');
    setHidden(management, tab !== 'current');

    document.querySelectorAll('[data-attendance-workspace-panel="current"]').forEach((node) => setHidden(node, tab !== 'current'));
    document.querySelectorAll('[data-attendance-workspace-panel="semester"]').forEach((node) => setHidden(node, tab !== 'semester'));

    const centerTitle = el('attendancePeriodCenterTitle');
    const centerSubtitle = centerTitle?.closest('.panel-header')?.querySelector('.panel-subtitle');
    if (centerTitle) centerTitle.textContent = tab === 'semester' ? 'Semester Computation & Finalization' : 'Monthly Attendance Lifecycle';
    if (centerSubtitle) centerSubtitle.textContent = tab === 'semester'
      ? 'The semester rating uses only validated finalized monthly copies up to the saved semester end date.'
      : 'Complete the selected month through Draft, Review, and Finalized stages. Finalization automatically creates its archive copy.';
  }

  function updateTabButtons(tab) {
    const buttons = [...document.querySelectorAll('[data-attendance-workspace-tab]')];
    buttons.forEach((button) => {
      const active = button.dataset.attendanceWorkspaceTab === tab;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.tabIndex = active ? 0 : -1;
    });
  }

  function updateTabMetrics() {
    const archives = window.LSOAttendanceGovernance?.getVisibleMonthlyArchives?.() || [];
    const month = window.LSOAttendanceGovernance?.getMonthState?.();
    const semester = window.LSOAttendanceGovernance?.getSemesterState?.();
    document.querySelectorAll('[data-attendance-workspace-tab]').forEach((button) => {
      const small = button.querySelector('small');
      if (!small) return;
      const tab = button.dataset.attendanceWorkspaceTab;
      if (tab === 'current') small.textContent = `${month?.state || 'Draft'} selected month`;
      if (tab === 'archive') small.textContent = `${archives.length} validated cop${archives.length === 1 ? 'y' : 'ies'}`;
      if (tab === 'semester') small.textContent = `${semester?.state || 'Draft'} semester`;
    });
  }

  function applyWorkspace(tab = activeTab, options = {}) {
    if (applying) return;
    applying = true;
    try {
      activeTab = safeTab(tab);
      const view = el('attendanceView');
      if (view) {
        view.dataset.attendanceWorkspaceActive = activeTab;
        TABS.forEach((item) => view.classList.toggle(`attendance-workspace-${item}`, item === activeTab));
      }
      if (options.updateMode !== false) setModeForTab(activeTab);
      updateTabButtons(activeTab);
      updateContext(activeTab);
      updateHeaderActions(activeTab);
      updatePanelVisibility(activeTab);
      updateTabMetrics();
      try { localStorage.setItem(STORAGE_KEY, activeTab); } catch { /* device storage can be blocked */ }
    } finally {
      applying = false;
    }
  }

  function scheduleApply(delay = 20) {
    clearTimeout(applyTimer);
    applyTimer = window.setTimeout(() => applyWorkspace(activeTab, { updateMode: false }), delay);
  }

  function setTab(tab, options = {}) {
    const next = safeTab(tab);
    activeTab = next;
    applyWorkspace(next, { updateMode: true });
    if (!options.silent) window.dispatchEvent(new CustomEvent('lso:attendance-workspace-tab-changed', { detail: { tab: next } }));
    if (!options.preserveScroll && attendanceViewActive()) el('attendanceWorkspaceTabs')?.scrollIntoView({ block: 'nearest', behavior: 'auto' });
    window.LSOAttendanceGovernance?.render?.();
    window.LSOAttendanceMonthWorkspace?.refresh?.();
  }

  function syncFromRosterMode() {
    const mode = String(window.LSOOperations?.getAttendanceRosterMode?.() || window.LSOAttendanceRosterMode || 'Current');
    if (mode === 'Archive' && activeTab !== 'archive') activeTab = 'archive';
    if (mode === 'Current' && activeTab === 'archive') activeTab = 'current';
    scheduleApply(10);
  }

  function wire() {
    el('attendanceWorkspaceTabs')?.addEventListener('click', (event) => {
      const button = event.target.closest('[data-attendance-workspace-tab]');
      if (button) setTab(button.dataset.attendanceWorkspaceTab);
    });
    el('attendanceWorkspaceTabs')?.addEventListener('keydown', (event) => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      const buttons = [...document.querySelectorAll('[data-attendance-workspace-tab]')];
      const index = buttons.findIndex((button) => button.classList.contains('active'));
      let next = index;
      if (event.key === 'ArrowLeft') next = (index - 1 + buttons.length) % buttons.length;
      if (event.key === 'ArrowRight') next = (index + 1) % buttons.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = buttons.length - 1;
      event.preventDefault();
      setTab(buttons[next].dataset.attendanceWorkspaceTab);
      buttons[next].focus();
    });

    ['lso:attendance-period-changed', 'lso:attendance-refresh-request', 'lso:operations-changed', 'lso:cloud-state-changed', 'lso:auth-changed'].forEach((name) => {
      window.addEventListener(name, () => scheduleApply(name === 'lso:cloud-state-changed' ? 80 : 25));
    });
    window.addEventListener('lso:attendance-roster-mode-changed', syncFromRosterMode);
    document.querySelectorAll('[data-view="attendanceView"]').forEach((button) => button.addEventListener('click', () => scheduleApply(40)));
  }

  function initialize() {
    let stored = '';
    try { stored = localStorage.getItem(STORAGE_KEY) || ''; } catch { /* ignore */ }
    const mode = String(window.LSOOperations?.getAttendanceRosterMode?.() || window.LSOAttendanceRosterMode || 'Current');
    activeTab = mode === 'Archive' ? 'archive' : safeTab(stored || 'current');
    wire();
    applyWorkspace(activeTab, { updateMode: true });
  }

  window.LSOAttendanceWorkspace = Object.freeze({
    setTab,
    getTab: () => activeTab,
    refresh: () => applyWorkspace(activeTab, { updateMode: false })
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
