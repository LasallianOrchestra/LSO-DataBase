(() => {
  'use strict';

  const CORE = window.LSOSystemCore || {};
  const VERSION = CORE.VERSION || { app: '3.0.2', build: '2026.07.25-enterprise.3', schemaTarget: '006_enterprise_operations', cache: 'lso-enterprise-v25' };
  const SETTINGS_KEY = 'lso_system_settings_v2';
  const DUTY_KEY = 'lso_duty_hours_v1';
  const MONTHLY_KEY = 'lso_monthly_reports_v1';
  const ERROR_KEY = 'lso_local_error_log_v1';
  const ACCESSIBILITY_KEY = 'lso_accessibility_preferences_v1';
  const DAILY_RECOVERY_KEY = 'lso_daily_recovery_v1';
  const el = (id) => document.getElementById(id);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];
  let lastHealth = null;
  let recoveryPoints = [];
  let loggingServerError = false;
  let lastShownErrorSignature = '';
  let lastShownErrorAt = 0;
  let activeHealthPanel = 'overview';

  function safeText(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
  }

  function csvEscape(value) {
    const text = String(value ?? '');
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  }

  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function uid(prefix = 'enterprise') { return window.crypto?.randomUUID?.() || `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`; }
  function currentAccount() { return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null; }
  function role() { return window.LSORoleAccess?.role?.(currentAccount()) || currentAccount()?.role || 'Staff Account'; }
  function isAdmin() { return role() === 'Administrator'; }
  function can(action) { return window.LSORoleAccess?.can?.(action, currentAccount()) ?? isAdmin(); }
  function toast(message, error = false) { window.LSOApp?.showToast?.(message, error); }
  function storageGet(key, fallback) {
    try { const parsed = JSON.parse(window.LSOStorage?.getItem(key) || ''); return parsed ?? fallback; } catch { return fallback; }
  }
  function storageSet(key, value) { return window.LSOStorage?.setItem(key, JSON.stringify(value)); }
  function todayPH() {
    try {
      const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
      const map = Object.fromEntries(parts.map((item) => [item.type, item.value]));
      return `${map.year}-${map.month}-${map.day}`;
    } catch { return new Date().toISOString().slice(0, 10); }
  }
  function dateTimeLabel(value) {
    if (!value) return 'Not available';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return String(value);
    return new Intl.DateTimeFormat('en-PH', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Manila' }).format(date);
  }
  function durationLabel(minutes) {
    const total = Math.max(0, Math.round(Number(minutes) || 0));
    const hours = Math.floor(total / 60); const mins = total % 60;
    return `${hours} hr${hours === 1 ? '' : 's'}${mins ? ` ${mins} min` : ''}`;
  }
  function download(name, text, type = 'text/plain') {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const link = document.createElement('a'); link.href = url; link.download = name; document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function setView(viewId) {
    window.LSOApp?.setView?.(viewId);
    requestAnimationFrame(() => el(viewId)?.scrollIntoView({ block: 'start' }));
  }

  // ---------------------------------------------------------------------------
  // Friendly error reporting
  // ---------------------------------------------------------------------------
  function localErrors() {
    const value = storageGet(ERROR_KEY, []);
    return Array.isArray(value) ? value : [];
  }
  function saveLocalErrors(records) {
    try { localStorage.setItem(ERROR_KEY, JSON.stringify((Array.isArray(records) ? records : []).slice(0, 100))); } catch { /* no-op */ }
  }
  function saveLocalError(record) { saveLocalErrors([record, ...localErrors()]); }
  function classifyError(detail = {}) {
    const technical = String(detail.technicalMessage || detail.message || detail.reason?.message || detail.reason || 'Unknown error');
    const publicMessage = String(detail.publicMessage || detail.message || 'The requested action could not be completed.');
    let errorCode = detail.errorCode || CORE.ERROR_CODES?.UNKNOWN || 'SYS-UNEXPECTED-999';
    let module = detail.module || 'System';
    if (/failed to fetch|network|offline|load failed/i.test(technical)) errorCode = CORE.ERROR_CODES?.NETWORK || 'NET-CONNECTION-001';
    else if (/session|expired token|invalid token/i.test(technical)) errorCode = CORE.ERROR_CODES?.SESSION || 'AUTH-SESSION-002';
    else if (/schema|column .*does not exist|function .*does not exist|migration|schema cache/i.test(technical)) errorCode = CORE.ERROR_CODES?.MIGRATION || 'DB-MIGRATION-004';
    else if (/permission|access is required|not allowed|42501/i.test(technical)) errorCode = CORE.ERROR_CODES?.PERMISSION || 'AUTH-PERMISSION-005';
    return { errorCode, module, publicMessage, technicalMessage: technical, severity: detail.severity || 'error', context: detail.context || {}, rpc: detail.rpc || '' };
  }
  function showErrorDialog(record) {
    const signature = `${record.errorCode}:${record.publicMessage}`;
    if (signature === lastShownErrorSignature && Date.now() - lastShownErrorAt < 1500) return;
    lastShownErrorSignature = signature; lastShownErrorAt = Date.now();
    if (el('systemErrorTitle')) el('systemErrorTitle').textContent = record.module === 'System' ? 'The requested action could not be completed' : `${record.module} needs attention`;
    if (el('systemErrorMessage')) el('systemErrorMessage').textContent = record.publicMessage;
    if (el('systemErrorCode')) el('systemErrorCode').textContent = record.errorCode;
    if (el('systemErrorTechnicalText')) el('systemErrorTechnicalText').textContent = `${record.technicalMessage}\n\nBuild: ${VERSION.build}\nBrowser: ${navigator.userAgent}`;
    el('systemErrorTechnicalDetails')?.toggleAttribute('open', false);
    el('systemErrorDialog')?.classList.remove('hidden');
  }
  async function reportError(detail = {}, { show = true } = {}) {
    const normalized = classifyError(detail);
    const record = {
      id: uid('error'), ...normalized, createdAt: new Date().toISOString(), appVersion: VERSION.build,
      browserInfo: navigator.userAgent, username: currentAccount()?.username || ''
    };
    saveLocalError(record);
    if (show) showErrorDialog(record);
    if (window.LSOCloud?.logSystemError && window.LSOCloud?.getSessionToken?.() && !loggingServerError && detail.rpc !== 'lso_log_system_error') {
      loggingServerError = true;
      try { await window.LSOCloud.logSystemError({
        errorCode: record.errorCode, severity: record.severity, module: record.module,
        publicMessage: record.publicMessage, technicalMessage: record.technicalMessage,
        context: { ...record.context, rpc: record.rpc }, appVersion: VERSION.build, browserInfo: navigator.userAgent
      }); } catch { /* The local record remains available. */ } finally { loggingServerError = false; }
    }
    return record;
  }
  function closeErrorDialog() { el('systemErrorDialog')?.classList.add('hidden'); }
  function copyErrorDetails() {
    const text = `Error Code: ${el('systemErrorCode')?.textContent || ''}\n${el('systemErrorMessage')?.textContent || ''}\n${el('systemErrorTechnicalText')?.textContent || ''}`;
    navigator.clipboard?.writeText(text).then(() => toast('Error details copied.')).catch(() => window.prompt('Copy the error details:', text));
  }

  // ---------------------------------------------------------------------------
  // Accessibility and display controls
  // ---------------------------------------------------------------------------
  const defaultAccessibility = { theme: 'light', textSize: 'normal', contrast: 'standard', motion: 'system', density: 'comfortable', tables: 'auto', focus: true };
  function loadAccessibility() {
    try { return { ...defaultAccessibility, ...JSON.parse(localStorage.getItem(ACCESSIBILITY_KEY) || '{}') }; } catch { return { ...defaultAccessibility }; }
  }
  function applyAccessibility(prefs = loadAccessibility()) {
    const root = document.documentElement;
    const theme = prefs.theme === 'night' ? 'night' : 'light';
    root.dataset.lsoTheme = theme;
    root.style.colorScheme = theme === 'night' ? 'dark' : 'light';
    const themeMeta = document.querySelector('meta[name="theme-color"]');
    if (themeMeta) themeMeta.setAttribute('content', theme === 'night' ? '#091712' : '#0B3D2E');
    root.dataset.lsoTextSize = prefs.textSize;
    root.dataset.lsoDensity = prefs.density;
    root.dataset.lsoTableMode = prefs.tables;
    root.dataset.lsoHighContrast = String(prefs.contrast === 'high');
    const deviceReduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    root.dataset.lsoReducedMotion = String(prefs.motion === 'reduced' || (prefs.motion === 'system' && deviceReduced));
    root.dataset.lsoFocus = String(Boolean(prefs.focus));
    qsa('[data-theme-choice]').forEach((button) => {
      const active = button.dataset.themeChoice === theme;
      button.classList.toggle('active', active);
      button.setAttribute('aria-pressed', String(active));
    });
    return { ...prefs, theme };
  }
  function populateAccessibility() {
    const prefs = applyAccessibility(loadAccessibility());
    if (el('accessibilityTheme')) el('accessibilityTheme').value = prefs.theme;
    if (el('accessibilityTextSize')) el('accessibilityTextSize').value = prefs.textSize;
    if (el('accessibilityContrast')) el('accessibilityContrast').value = prefs.contrast;
    if (el('accessibilityMotion')) el('accessibilityMotion').value = prefs.motion;
    if (el('accessibilityDensity')) el('accessibilityDensity').value = prefs.density;
    if (el('accessibilityTables')) el('accessibilityTables').value = prefs.tables;
    if (el('accessibilityFocus')) el('accessibilityFocus').checked = Boolean(prefs.focus);
  }
  function openAccessibility() { populateAccessibility(); el('accessibilityDrawer')?.classList.remove('hidden'); el('accessibilityOverlay')?.classList.remove('hidden'); el('accessibilityDrawer')?.setAttribute('aria-hidden', 'false'); setTimeout(() => el('closeAccessibilityButton')?.focus(), 20); }
  function closeAccessibility() { el('accessibilityDrawer')?.classList.add('hidden'); el('accessibilityOverlay')?.classList.add('hidden'); el('accessibilityDrawer')?.setAttribute('aria-hidden', 'true'); }
  function saveAccessibility() {
    const prefs = {
      theme: el('accessibilityTheme')?.value === 'night' ? 'night' : 'light',
      textSize: el('accessibilityTextSize')?.value || 'normal', contrast: el('accessibilityContrast')?.value || 'standard',
      motion: el('accessibilityMotion')?.value || 'system', density: el('accessibilityDensity')?.value || 'comfortable',
      tables: el('accessibilityTables')?.value || 'auto', focus: Boolean(el('accessibilityFocus')?.checked)
    };
    localStorage.setItem(ACCESSIBILITY_KEY, JSON.stringify(prefs)); applyAccessibility(prefs); closeAccessibility(); toast('Accessibility and display settings applied.');
  }
  function resetAccessibility() { localStorage.removeItem(ACCESSIBILITY_KEY); applyAccessibility(defaultAccessibility); populateAccessibility(); }

  // ---------------------------------------------------------------------------
  // System Administration and diagnostics
  // ---------------------------------------------------------------------------
  function setHealthPanel(panelName = 'overview') {
    const available = ['overview', 'access', 'diagnostics'];
    activeHealthPanel = available.includes(panelName) ? panelName : 'overview';
    qsa('[data-health-panel]').forEach((button) => {
      const active = button.dataset.healthPanel === activeHealthPanel;
      button.classList.toggle('active', active);
      button.setAttribute('aria-current', active ? 'step' : 'false');
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
    });
    qsa('[data-health-workflow-panel]').forEach((panel) => {
      const active = panel.dataset.healthWorkflowPanel === activeHealthPanel;
      panel.classList.toggle('active', active);
      panel.hidden = !active;
    });
    requestAnimationFrame(() => el('systemHealthNavigation')?.scrollIntoView({ block: 'nearest' }));
  }
  function renderHealthWorkflowSummary(health = lastHealth) {
    const summary = el('healthWorkflowSummary');
    if (!summary) return;
    if (!health) {
      summary.textContent = navigator.onLine ? 'System status has not been verified in this session.' : 'Offline: reconnect before running a complete diagnostics check.';
      summary.dataset.state = 'pending';
      return;
    }
    const failed = (health.checks || []).filter((check) => !check.ok).length;
    if (!failed) {
      summary.textContent = 'All verified compatibility and connection checks passed.';
      summary.dataset.state = 'healthy';
    } else {
      summary.textContent = `${failed} compatibility check${failed === 1 ? '' : 's'} need attention.`;
      summary.dataset.state = 'attention';
    }
    const diagnosticsButton = document.querySelector('[data-health-panel="diagnostics"]');
    if (diagnosticsButton) diagnosticsButton.classList.toggle('has-attention', failed > 0);
  }
  function renderHealthVersions(health = null) {
    const container = el('healthVersionGrid'); if (!container) return;
    const migrationCount = health?.migrations?.length || 0;
    const schemaOk = health?.databaseVersion === VERSION.schemaTarget;
    const cards = [
      ['Website', `v${VERSION.app}`, VERSION.build, ''],
      ['Database Schema', health?.databaseVersion || 'Not verified', schemaOk ? 'Matches website target' : 'Run the master installer', schemaOk ? '' : 'is-warning'],
      ['Migration History', migrationCount, `Target migration 6`, migrationCount >= 6 ? '' : 'is-warning'],
      ['PWA Cache', VERSION.cache, navigator.onLine ? 'Online validation enabled' : 'Offline mode', '']
    ];
    container.innerHTML = cards.map(([label, value, note, className]) => `<article class="health-version-card ${className}"><span>${safeText(label)}</span><strong>${safeText(value)}</strong><small>${safeText(note)}</small></article>`).join('');
  }
  function renderHealthChecks(health = null) {
    const container = el('systemHealthChecks'); if (!container) return;
    const localChecks = [
      { id: 'javascript', label: 'Website modules loaded', ok: Boolean(window.LSOApp && window.LSOCloud && window.LSORoleAccess), detail: 'Core application, cloud connector, and centralized permissions.' },
      { id: 'auth-gate', label: 'Authentication gate', ok: Boolean(el('appShell')?.hasAttribute('inert') || currentAccount()), detail: 'System content stays locked until authentication succeeds.' },
      { id: 'service-worker', label: 'PWA service worker support', ok: 'serviceWorker' in navigator, detail: 'Installability and cache updates.' },
      { id: 'online', label: 'Internet connection', ok: navigator.onLine, detail: navigator.onLine ? 'Browser reports an active network.' : 'Database actions require reconnection.' }
    ];
    const checks = [...localChecks, ...(Array.isArray(health?.checks) ? health.checks.map((item) => ({ ...item, detail: item.ok ? 'Available and compatible.' : 'Missing or incompatible. Run the master migration installer.' })) : [])];
    container.innerHTML = checks.map((check) => `<div class="health-check-item ${check.ok ? '' : 'is-failed'}"><span class="health-check-icon">${check.ok ? '✓' : '!'}</span><span class="health-check-copy"><strong>${safeText(check.label)}</strong><small>${safeText(check.detail || '')}</small></span><span class="health-check-status">${check.ok ? 'Passed' : 'Action required'}</span></div>`).join('');
  }
  function renderMigrations(health = null) {
    const body = el('migrationHistoryBody'); if (!body) return;
    const rows = Array.isArray(health?.migrations) ? health.migrations : [];
    body.innerHTML = rows.length ? rows.map((item) => `<tr><td><strong>${safeText(item.version)}</strong></td><td>${safeText(item.title)}<br><small>${safeText(item.key)}</small></td><td>${safeText(dateTimeLabel(item.appliedAt))}</td><td><code>${safeText(item.checksum)}</code></td></tr>`).join('') : '<tr><td colspan="4">Migration history is unavailable. Run LSO_MASTER_MIGRATION_INSTALLER.sql.</td></tr>';
  }
  function renderHealthCounts(health = null) {
    const container = el('healthCountGrid'); if (!container) return;
    const c = health?.counts || {};
    const items = [['Members', c.members || 0], ['Activities', c.events || 0], ['Attendance Marks', c.attendance || 0], ['Duty Entries', c.dutyEntries || 0], ['Accounts', c.accounts || 0], ['Recovery Points', c.recoveryPoints || 0], ['State Updated', health?.stateUpdatedAt ? dateTimeLabel(health.stateUpdatedAt) : '—']];
    container.innerHTML = items.map(([label, value]) => `<div class="health-count-card"><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('');
    renderHealthWorkflowSummary(health);
  }
  const permissionLabels = {
    manageAccounts:'Manage accounts',manageMembers:'Manage member records',generateContract:'Generate contracts',editMonthlyReport:'Edit Monthly Reports',finalizeMonthlyReport:'Finalize Monthly Reports',reopenMonthlyReport:'Reopen Monthly Reports',manageEvents:'Create/edit activities',deleteEvents:'Delete activities',saveDraftAttendance:'Save draft attendance',finalizeAttendance:'Finalize attendance',unlockAttendance:'Unlock attendance',reviewDutyPunches:'Approve/reject Duty punches',manageDutyHours:'Manually manage Duty Hours',manageDutyRequirements:'Set Duty requirements',certifyDutyHours:'Generate Duty certification',manageSettings:'Manage system settings',manageInventory:'Manage inventory',manageData:'Import/export/clear data',manageRecovery:'Manage recovery points',viewSystemHealth:'View System Administration',writeActivityLog:'Write audit activity',selfDutyPunch:'Submit personal Duty punches',manageAccessibility:'Use accessibility controls'
  };
  function renderPermissionMatrix() {
    const head = el('permissionMatrixHead'); const body = el('permissionMatrixBody'); if (!head || !body) return;
    const roles = Object.values(CORE.ROLES || {}); const manifest = window.LSORoleAccess?.permissionManifest?.() || CORE.PERMISSIONS || { actions:{}, views:{} };
    head.innerHTML = `<tr><th scope="col">Permission</th>${roles.map((roleName)=>`<th scope="col">${safeText(roleName)}</th>`).join('')}</tr>`;
    const rows=[];
    rows.push(`<tr class="permission-category-row"><th colspan="${roles.length+1}">Module access</th></tr>`);
    const viewLabels={dashboardView:'Dashboard',membersView:'Members',contractView:'Contract',monthlyReportView:'Monthly Report',attendanceView:'Attendance',dutyHoursView:'Duty Hours',accountsView:'Accounts',systemHealthView:'System Administration',dataView:'Data & Recovery'};
    const allViews=[...new Set(Object.values(manifest.views||{}).flat())];
    allViews.forEach((viewId)=>rows.push(`<tr><th scope="row">${safeText(viewLabels[viewId]||viewId)}</th>${roles.map((roleName)=>{const granted=(manifest.views?.[roleName]||[]).includes(viewId);return `<td><span class="${granted?'permission-granted':'permission-denied'}" aria-label="${granted?'Allowed':'Not allowed'}">${granted?'Yes':'—'}</span></td>`;}).join('')}</tr>`));
    rows.push(`<tr class="permission-category-row"><th colspan="${roles.length+1}">Action permissions</th></tr>`);
    Object.entries(manifest.actions||{}).forEach(([action,allowedRoles])=>rows.push(`<tr><th scope="row">${safeText(permissionLabels[action]||action)}</th>${roles.map((roleName)=>{const granted=(allowedRoles||[]).includes(roleName);return `<td><span class="${granted?'permission-granted':'permission-denied'}" aria-label="${granted?'Allowed':'Not allowed'}">${granted?'Yes':'—'}</span></td>`;}).join('')}</tr>`));
    body.innerHTML=rows.join('');
  }
  function exportPermissionMatrix() {
    const roles=Object.values(CORE.ROLES||{});const manifest=window.LSORoleAccess?.permissionManifest?.()||CORE.PERMISSIONS||{actions:{},views:{}};const rows=[['Category','Permission',...roles]];
    const viewLabels={dashboardView:'Dashboard',membersView:'Members',contractView:'Contract',monthlyReportView:'Monthly Report',attendanceView:'Attendance',dutyHoursView:'Duty Hours',accountsView:'Accounts',systemHealthView:'System Administration',dataView:'Data & Recovery'};
    [...new Set(Object.values(manifest.views||{}).flat())].forEach((viewId)=>rows.push(['Module',viewLabels[viewId]||viewId,...roles.map((roleName)=>(manifest.views?.[roleName]||[]).includes(viewId)?'Allowed':'Not allowed')]));
    Object.entries(manifest.actions||{}).forEach(([action,allowedRoles])=>rows.push(['Action',permissionLabels[action]||action,...roles.map((roleName)=>(allowedRoles||[]).includes(roleName)?'Allowed':'Not allowed')]));
    download(`LSO_Role_Permission_Matrix_${todayPH()}.csv`,rows.map((row)=>row.map(csvEscape).join(',')).join('\n'),'text/csv');
  }
  async function refreshSystemHealth({ quiet = false } = {}) {
    if (!isAdmin()) return;
    renderHealthVersions(lastHealth); renderHealthChecks(lastHealth); renderMigrations(lastHealth); renderHealthCounts(lastHealth);
    const button = el('refreshSystemHealthButton'); if (button) { button.disabled = true; button.textContent = 'Checking…'; }
    try {
      if (!window.LSOCloud?.getSystemHealth) throw new Error('The website health connector is unavailable. Upload the complete enterprise package.');
      lastHealth = await window.LSOCloud.getSystemHealth();
      renderHealthVersions(lastHealth); renderHealthChecks(lastHealth); renderMigrations(lastHealth); renderHealthCounts(lastHealth); renderHealthWorkflowSummary(lastHealth);
      window.dispatchEvent(new CustomEvent('lso:system-health-changed', { detail: clone(lastHealth) }));
      if (!quiet) toast('System diagnostics completed.');
    } catch (error) {
      lastHealth = null; renderHealthVersions(); renderHealthChecks(); renderMigrations(); renderHealthCounts(); renderHealthWorkflowSummary();
      reportError({ module: 'System Administration', publicMessage: 'System diagnostics could not verify the shared database compatibility. Check the migration status and connection, then try again.', technicalMessage: error.message, errorCode: CORE.ERROR_CODES?.MIGRATION || 'DB-MIGRATION-004' }, { show: !quiet });
    } finally { if (button) { button.disabled = false; button.textContent = 'Run Diagnostics'; } }
  }
  function copyHealthReport() {
    const report = { website: VERSION, database: lastHealth || null, generatedAt: new Date().toISOString(), browser: navigator.userAgent, online: navigator.onLine };
    const text = JSON.stringify(report, null, 2);
    navigator.clipboard?.writeText(text).then(() => toast('Diagnostics report copied.')).catch(() => download(`LSO_System_Diagnostics_${todayPH()}.json`, text, 'application/json'));
  }

  // ---------------------------------------------------------------------------
  // Automated backup and recovery
  // ---------------------------------------------------------------------------
  async function createRecoveryPoint(label = 'Manual recovery point', reason = '', metadata = {}) {
    if (!isAdmin()) throw new Error('Administrator access is required.');
    if (!window.LSOCloud?.createRecoveryPoint) throw new Error('The Recovery Center database migration is not installed.');
    const result = await window.LSOCloud.createRecoveryPoint({ label, reason, metadata });
    await refreshRecoveryPoints({ quiet: true });
    window.LSOOperations?.logActivity?.('Created recovery point', 'Backup & Recovery', `${label}${reason ? ` • ${reason}` : ''}`);
    return result;
  }
  function recoverySummary(points = recoveryPoints) {
    const latest = points[0];
    return { count: points.length, latest: latest?.createdAt || '', lastCreator: latest?.createdBy || '—' };
  }
  function renderRecoveryPoints() {
    const container = el('recoveryPointList'); if (!container) return;
    const summary = recoverySummary();
    const kpis = el('recoveryKpis'); if (kpis) kpis.innerHTML = [['Available Points', summary.count], ['Latest Protection', summary.latest ? dateTimeLabel(summary.latest) : 'None'], ['Created By', summary.lastCreator]].map(([label,value]) => `<div class="recovery-kpi"><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('');
    container.innerHTML = recoveryPoints.length ? recoveryPoints.map((point) => `<article class="recovery-point-card"><div class="recovery-point-header"><div><h4>${safeText(point.label)}</h4><div class="recovery-point-meta"><span>${safeText(dateTimeLabel(point.createdAt))}</span><span>${safeText(point.createdBy || 'Administrator')}</span>${point.restoredAt ? `<span>Restored ${safeText(dateTimeLabel(point.restoredAt))}</span>` : ''}</div></div><span class="badge badge-green">Protected</span></div><p class="recovery-point-reason">${safeText(point.reason || 'No additional reason provided.')}</p><div class="recovery-point-summary">${Object.entries(point.summary || {}).map(([key,value]) => `<div><span>${safeText(key.replace(/([A-Z])/g,' $1'))}</span><strong>${safeText(value)}</strong></div>`).join('')}</div><div class="recovery-point-actions"><button class="button button-primary" data-restore-recovery="${safeText(point.id)}" type="button">Restore This Point</button><button class="button button-secondary" data-delete-recovery="${safeText(point.id)}" type="button">Delete</button></div></article>`).join('') : '<div class="recovery-empty"><strong>No server recovery points yet</strong><p>Create one now or sign in again after installing the master database migration.</p></div>';
  }
  async function refreshRecoveryPoints({ quiet = false } = {}) {
    if (!isAdmin()) return;
    try { recoveryPoints = await window.LSOCloud?.listRecoveryPoints?.() || []; renderRecoveryPoints(); if (!quiet) toast('Recovery history refreshed.'); }
    catch (error) { recoveryPoints = []; renderRecoveryPoints(); renderRecoveryWorkspaceStatus(); if (!quiet) toast('Server recovery points are unavailable. Complete portable backup remains available.', true); }
  }
  async function restoreRecovery(id) {
    const point = recoveryPoints.find((item) => String(item.id) === String(id)); if (!point) return;
    if (!window.confirm(`Restore “${point.label}”?\n\nThe system will create another recovery point before replacing current shared records.`)) return;
    try { await window.LSOCloud.restoreRecoveryPoint(id); await window.LSOCloud.loadSharedState({ quiet: true }); window.LSOApp?.refresh?.(); await refreshRecoveryPoints({ quiet: true }); window.LSOOperations?.logActivity?.('Restored recovery point', 'Backup & Recovery', `${point.label} • ${id}`); toast('Recovery point restored.'); }
    catch (error) { reportError({ module: 'Backup & Recovery', publicMessage: 'The selected recovery point could not be restored.', technicalMessage: error.message, errorCode: CORE.ERROR_CODES?.RESTORE || 'DATA-RESTORE-007' }); }
  }
  async function deleteRecovery(id) {
    if (!window.confirm('Delete this recovery point? This cannot be undone.')) return;
    try { await window.LSOCloud.deleteRecoveryPoint(id); await refreshRecoveryPoints({ quiet: true }); window.LSOOperations?.logActivity?.('Deleted recovery point', 'Backup & Recovery', id); toast('Recovery point deleted.'); }
    catch (error) { reportError({ module: 'Backup & Recovery', publicMessage: 'The recovery point could not be deleted.', technicalMessage: error.message }); }
  }
  async function ensureDailyRecovery() {
    if (!isAdmin() || !window.LSOCloud?.getSessionToken?.()) return;
    const marker = localStorage.getItem(DAILY_RECOVERY_KEY);
    if (marker === todayPH()) return;
    try { await createRecoveryPoint(`Daily automatic recovery • ${todayPH()}`, 'Created automatically after Administrator sign-in.', { type: 'daily', appVersion: VERSION.build }); localStorage.setItem(DAILY_RECOVERY_KEY, todayPH()); if (el('automaticRecoveryStatus')) el('automaticRecoveryStatus').textContent = `Daily recovery protection is active • ${todayPH()}`; }
    catch (error) { if (el('automaticRecoveryStatus')) el('automaticRecoveryStatus').textContent = 'Daily recovery is waiting for the master database migration.'; }
  }
  function validateBackupObject(backup) {
    const issues = [];
    if (!backup || typeof backup !== 'object' || Array.isArray(backup)) issues.push('The file does not contain a JSON object.');
    if (!Array.isArray(backup?.members)) issues.push('Members array is missing.');
    if (!Array.isArray(backup?.events)) issues.push('Events array is missing.');
    if (!Array.isArray(backup?.attendance)) issues.push('Attendance array is missing.');
    if (backup?.dutyHours && typeof backup.dutyHours !== 'object') issues.push('Duty Hours data is invalid.');
    if (backup?.monthlyReports && typeof backup.monthlyReports !== 'object') issues.push('Monthly Reports data is invalid.');
    return { valid: issues.length === 0, issues, summary: { members: backup?.members?.length || 0, events: backup?.events?.length || 0, attendance: backup?.attendance?.length || 0, dutyEntries: backup?.dutyHours?.entries?.length || 0 } };
  }
  async function validateBackupFile(file, target = el('backupValidationResult')) {
    if (!file) return null;
    try { const backup = JSON.parse(await file.text()); const result = validateBackupObject(backup); if (target) { target.className = `backup-validation-result ${result.valid ? 'is-valid' : 'is-invalid'}`; target.innerHTML = result.valid ? `<strong>Backup passed validation</strong><p>${result.summary.members} members • ${result.summary.events} activities • ${result.summary.attendance} attendance marks • ${result.summary.dutyEntries} Duty Hours entries</p>` : `<strong>Backup cannot be restored safely</strong><ul>${result.issues.map((issue) => `<li>${safeText(issue)}</li>`).join('')}</ul>`; } return result; }
    catch (error) { if (target) { target.className = 'backup-validation-result is-invalid'; target.innerHTML = `<strong>Invalid JSON backup</strong><p>${safeText(error.message)}</p>`; } return { valid: false, issues: [error.message] }; }
  }
  async function prepareRiskyOperation(element, event, label, reason) {
    if (element.dataset.enterpriseRecoveryPrepared === 'true') { delete element.dataset.enterpriseRecoveryPrepared; return true; }
    event.preventDefault(); event.stopImmediatePropagation();
    try {
      if (element.files?.[0]) { const validation = await validateBackupFile(element.files[0], null); if (label.includes('restore') && !validation?.valid) throw new Error(`The selected backup failed validation: ${(validation?.issues || []).join(' ')}`); }
      await createRecoveryPoint(label, reason, { type: 'automatic-pre-operation', elementId: element.id, appVersion: VERSION.build });
      element.dataset.enterpriseRecoveryPrepared = 'true';
      if (event.type === 'click') element.click(); else element.dispatchEvent(new Event(event.type, { bubbles: true }));
      return true;
    } catch (error) { setView('dataView'); setRecoveryPanel('backup'); toast('The operation was paused because server recovery protection is unavailable. Download a Complete System Backup, then retry.', true); setTimeout(()=>el('backupCompleteSystem')?.focus(),80); return false; }
  }

  // ---------------------------------------------------------------------------
  // Duty Hours enhancements
  // ---------------------------------------------------------------------------
  function dutyData() { return window.LSODutyHours?.getData?.() || storageGet(DUTY_KEY, { version: 7, commitments: {}, entries: [] }); }
  function settings() { const value = storageGet(SETTINGS_KEY, {}); return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
  function injectDutySettings() {
    const grid = document.querySelector('#dataView .settings-grid'); if (!grid || el('settingDefaultTraineeDutyHours')) return;
    grid.insertAdjacentHTML('beforeend', `<label class="field"><span>Default Trainee Duty Hours</span><input id="settingDefaultTraineeDutyHours" min="0" type="number" step="1" placeholder="30"/></label><label class="field"><span>Default Probationary Duty Hours</span><input id="settingDefaultProbationaryDutyHours" min="0" type="number" step="1" placeholder="30"/></label><label class="field"><span>Duty Completion Alert (%)</span><input id="settingDutyCompletionAlert" min="50" max="100" type="number" step="1" placeholder="100"/></label>`);
    renderDutySettings();
  }
  function renderDutySettings() {
    const s = settings();
    if (el('settingDefaultTraineeDutyHours')) el('settingDefaultTraineeDutyHours').value = Number.isFinite(Number(s.defaultTraineeDutyMinutes)) ? Number(s.defaultTraineeDutyMinutes) / 60 : 30;
    if (el('settingDefaultProbationaryDutyHours')) el('settingDefaultProbationaryDutyHours').value = Number.isFinite(Number(s.defaultProbationaryDutyMinutes)) ? Number(s.defaultProbationaryDutyMinutes) / 60 : 30;
    if (el('settingDutyCompletionAlert')) el('settingDutyCompletionAlert').value = Number(s.dutyCompletionAlertPercent) || 100;
  }
  function dutyMemberIds(period) { return window.LSODutyHours?.getRosterMembers?.(period, 'Active') || []; }
  function calculateDutyPeriod(data, memberId, semester, period) {
    const key = period === 'Probationary Period' ? 'probationary' : 'trainee';
    const committed = Math.max(0, Number(data.commitments?.[memberId]?.[semester]?.[key]) || 0);
    const entries = (data.entries || []).filter((entry) => entry.memberId === memberId && entry.semester === semester && entry.period === period);
    const approved = entries.filter((entry) => entry.approvalStatus === 'Approved');
    const rendered = approved.filter((entry) => entry.entryType === 'Duty').reduce((sum, entry) => sum + Math.max(0, Number(entry.minutes) || 0), 0);
    const incentives = approved.filter((entry) => entry.entryType === 'Incentive').reduce((sum, entry) => sum + (Number(entry.minutes) || 0), 0);
    const credited = rendered + incentives;
    return { committed, rendered, incentives, credited, remaining: Math.max(0, committed - credited), percent: committed ? Math.min(100, Math.round(credited / committed * 100)) : 0, entries };
  }
  function renderDutyEnhancements() {
    const metrics = el('dutyEnhancementMetrics'); const alerts = el('dutyCompletionAlerts'); if (!metrics || !alerts) return;
    const data = dutyData(); const entries = data.entries || [];
    const pendingIn = entries.filter((entry) => entry.timeInApprovalStatus === 'Pending').length;
    const pendingOut = entries.filter((entry) => entry.timeOutApprovalStatus === 'Pending').length;
    const approved = entries.filter((entry) => entry.approvalStatus === 'Approved').length;
    const rejected = entries.filter((entry) => entry.approvalStatus === 'Rejected').length;
    const selectedSemester = window.LSODutyHours?.getActiveSemester?.() || 'First Semester';
    const all = [...dutyMemberIds('Trainee Period').map((id) => [id,'Trainee Period']), ...dutyMemberIds('Probationary Period').map((id) => [id,'Probationary Period'])];
    const completed = all.filter(([id,period]) => { const calc = calculateDutyPeriod(data,id,selectedSemester,period); return calc.committed > 0 && calc.credited >= calc.committed; });
    metrics.innerHTML = [['Pending Time In',pendingIn],['Pending Time Out',pendingOut],['Approved Sessions',approved],['Rejected Sessions',rejected],['Completed Members',completed.length]].map(([label,value]) => `<div class="duty-enhancement-metric"><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('');
    const members = window.LSOApp?.getMembers?.() || [];
    alerts.innerHTML = completed.length ? completed.slice(0,10).map(([id,period]) => { const member=members.find((m)=>m.id===id); const calc=calculateDutyPeriod(data,id,selectedSemester,period); return `<div class="duty-completion-item"><div><strong>${safeText(member?.fullName || id)}</strong><small>${safeText(period)} • ${safeText(durationLabel(calc.credited))} credited of ${safeText(durationLabel(calc.committed))}</small></div><div class="duty-completion-bar" aria-label="${calc.percent}% complete"><span style="width:${calc.percent}%"></span></div></div>`; }).join('') : '<div class="system-error-empty"><strong>No completed requirements detected</strong><p>Apply default requirements or set commitments for the selected semester.</p></div>';
    const cert = el('printDutyCertification'); if (cert) cert.disabled = !window.LSODutyHours?.getSelectedMemberId?.();
  }
  function applyDefaultDutyRequirements() {
    if (!can('manageDutyRequirements')) return toast('Administrator or Membership access is required.', true);
    const s = settings(); const trainee = Math.max(0, Number(s.defaultTraineeDutyMinutes) || 1800); const probationary = Math.max(0, Number(s.defaultProbationaryDutyMinutes) || 1800);
    const data = dutyData(); const semester = window.LSODutyHours?.getActiveSemester?.() || 'First Semester'; let changed = 0;
    [['Trainee Period',trainee],['Probationary Period',probationary]].forEach(([period,minutes]) => dutyMemberIds(period).forEach((memberId) => {
      data.commitments[memberId] = data.commitments[memberId] || {}; data.commitments[memberId][semester] = data.commitments[memberId][semester] || { trainee:0, probationary:0 };
      const key = period === 'Probationary Period' ? 'probationary' : 'trainee'; if (!Number(data.commitments[memberId][semester][key])) { data.commitments[memberId][semester][key] = minutes; changed += 1; }
    }));
    window.LSODutyHours?.persistData?.(data,{ action:'Applied default Duty Hours requirements', details:`${semester} • ${changed} member records` }); window.LSODutyHours?.refresh?.(); renderDutyEnhancements(); toast(`${changed} Duty Hours requirement${changed===1?'':'s'} applied.`);
  }
  function printDutyCertification() {
    if (!can('certifyDutyHours')) return toast('Administrator or Membership access is required.', true);
    const member = window.LSODutyHours?.getSelectedMember?.(); if (!member) return toast('Select a Trainee or Probationary member first.', true);
    const period = window.LSODutyHours.getSelectedPeriod(); const semester = window.LSODutyHours.getActiveSemester(); const calc = calculateDutyPeriod(dutyData(), member.id, semester, period);
    const popup = window.open('', '_blank', 'width=900,height=720'); if (!popup) return toast('Allow pop-ups to generate the certification.', true);
    popup.document.write(`<!doctype html><html><head><title>Duty Hours Certification</title><style>
      @page{size:A4 portrait;margin:0}*{box-sizing:border-box}body{font-family:Arial,Helvetica,sans-serif;color:#17211d;margin:0}.summary{display:grid}.statement{font-size:10px;line-height:1.75;text-align:justify;margin:5mm 0;padding:4mm;border:1px solid #8aa89b;border-left:4px solid #d4a017;background:#fbfcfb}.sign{display:grid;grid-template-columns:1fr 1fr}${window.LSOBrand?.printCss || ''}
      </style></head><body>
      ${window.LSOBrand.printHeader({ title: 'Duty Hours Certification', subtitle: `${semester} • ${period}`, meta: `Generated ${dateTimeLabel(new Date().toISOString())}`, badge: 'Verified approved entries only' })}
      <p class="statement">This certifies that <strong>${safeText(member.fullName)}</strong> (${safeText(member.membershipId || member.studentNumber || 'member record')}) has a verified Duty Hours record for the period stated above. Only approved entries are included in the credited total.</p>
      <div class="summary">${[
        ['Required',durationLabel(calc.committed)],['Credited',durationLabel(calc.credited)],['Remaining',durationLabel(calc.remaining)],['Completion',`${calc.percent}%`]
      ].map(([label,value])=>`<div><span>${safeText(label)}</span><strong>${safeText(value)}</strong></div>`).join('')}</div>
      <div class="sign"><div>Member Signature</div><div>Authorized Officer</div></div>${window.LSOBrand.printRuntimeScript}</body></html>`); popup.document.close();
  }

  // ---------------------------------------------------------------------------
  // Monthly Report workflow
  // ---------------------------------------------------------------------------
  function monthlyState() { const value=storageGet(MONTHLY_KEY,{}); return value&&typeof value==='object'&&!Array.isArray(value)?value:{version:1,reports:{}}; }
  function activeReportKey() { return window.LSOMonthlyReport?.getActiveReportKey?.() || el('monthlyReportMonth')?.value || todayPH().slice(0,7); }
  function monthlyReport() { const state=monthlyState(); return state.reports?.[activeReportKey()] || null; }
  function monthlyActor() { const account=currentAccount()||{}; return account.displayName||account.username||'Administrator'; }
  function monthlyAudit(action, details='', reason='') { return { id:uid('monthly-audit'), timestamp:new Date().toISOString(), action, details, reason, account:monthlyActor(), username:currentAccount()?.username||'' }; }
  function saveMonthlyState(state) { storageSet(MONTHLY_KEY,state); window.dispatchEvent(new CustomEvent('lso:monthly-report-changed',{detail:{key:activeReportKey(),source:'enterprise-workflow'}})); window.LSOMonthlyReport?.refresh?.(); }
  function monthlyMissing(report) {
    const missing=[]; if(!report) return ['Report record'];
    if(!report.asOfDate) missing.push('As-of Date'); if(!report.academicYear) missing.push('Academic Year'); if(!report.preparedBy) missing.push('Prepared By'); if(!report.notedBy) missing.push('Noted By');
    (report.traineeRows||[]).forEach((row,index)=>{ if(!row.date) missing.push(`Table 5 Original Entry Date, row ${index+1}`); });
    return missing;
  }
  function renderMonthlyWorkflow() {
    const report=monthlyReport(); if(!report) return;
    const finalized=report.workflowStatus==='Finalized'; const view=el('monthlyReportView'); view?.classList.toggle('report-finalized',finalized);
    const badge=el('monthlyReportWorkflowBadge'); if(badge){badge.textContent=finalized?`Finalized • Rev ${report.revision||1}`:'Draft';badge.className=`badge ${finalized?'badge-green':'badge-gold'}`;}
    el('monthlyReportFinalizeButton')?.classList.toggle('hidden',finalized||!can('finalizeMonthlyReport'));
    el('monthlyReportReopenButton')?.classList.toggle('hidden',!finalized||!can('reopenMonthlyReport'));
    qsa('#monthlyReportView [data-monthly-edit], #monthlyReportView [data-monthly-write]').forEach((node)=>{ if(node.id==='monthlyReportMonth') return; node.disabled=finalized; node.setAttribute('aria-disabled',String(finalized)); node.title=finalized?'Finalized report is locked. An Administrator must reopen it.':''; });
    if(finalized && !el('monthlyReportFinalizedBanner')){ const banner=document.createElement('div');banner.id='monthlyReportFinalizedBanner';banner.className='monthly-report-finalized-banner';banner.innerHTML=`<div><strong>Finalized report</strong><small>Locked by ${safeText(report.finalizedBy||'Administrator')} on ${safeText(dateTimeLabel(report.finalizedAt))} • Revision ${safeText(report.revision||1)}</small></div><span class="badge badge-green">Verified</span>`;document.querySelector('#monthlyReportView .monthly-report-toolbar')?.insertAdjacentElement('afterend',banner); }
    if(!finalized) el('monthlyReportFinalizedBanner')?.remove();
  }
  function finalizeMonthlyReport() {
    if(!can('finalizeMonthlyReport')) return toast('Only an Administrator can finalize a Monthly Report.',true);
    const state=monthlyState();const key=activeReportKey();const report=state.reports?.[key];const missing=monthlyMissing(report);if(missing.length)return toast(`Complete these fields before finalizing: ${missing.join(', ')}.`,true);
    if(!window.confirm('Finalize and lock this Monthly Report? It can be reopened only by an Administrator with a correction reason.'))return;
    report.workflowStatus='Finalized';report.revision=Math.max(0,Number(report.revision)||0)+1;report.finalizedAt=new Date().toISOString();report.finalizedBy=monthlyActor();report.reopenedAt='';report.reopenedBy='';report.workflowHistory=Array.isArray(report.workflowHistory)?report.workflowHistory:[];report.workflowHistory.unshift(monthlyAudit('Monthly Report finalized',`Revision ${report.revision}`));report.workflowHistory=report.workflowHistory.slice(0,100);report.updatedAt=new Date().toISOString();saveMonthlyState(state);window.LSOOperations?.logActivity?.('Finalized Monthly Report','Monthly Reports',`${key} • Revision ${report.revision}`);renderMonthlyWorkflow();setTimeout(()=>window.LSOMonthlyReport?.archiveCurrent?.('Finalized report'),40);toast('Monthly Report finalized, locked, and added to the archive.');
  }
  function reopenMonthlyReport() {
    if(!can('reopenMonthlyReport')) return toast('Only an Administrator can reopen a Monthly Report.',true);
    const reason=window.prompt('Enter the reason for reopening this finalized report:');if(reason===null)return;if(reason.trim().length<3)return toast('A correction reason with at least 3 characters is required.',true);
    const state=monthlyState();const reportKey=activeReportKey();const report=state.reports?.[reportKey];if(!report)return;report.workflowStatus='Draft';report.reopenedAt=new Date().toISOString();report.reopenedBy=monthlyActor();report.workflowHistory=Array.isArray(report.workflowHistory)?report.workflowHistory:[];report.workflowHistory.unshift(monthlyAudit('Monthly Report reopened','Finalized report reopened for correction.',reason.trim()));report.workflowHistory=report.workflowHistory.slice(0,100);saveMonthlyState(state);window.LSOOperations?.logActivity?.('Reopened Monthly Report','Monthly Reports',`${reportKey} • ${reason.trim()}`);renderMonthlyWorkflow();toast('Monthly Report reopened for correction.');
  }
  function showMonthlyAudit() {
    const report=monthlyReport();const history=Array.isArray(report?.workflowHistory)?report.workflowHistory:[];let overlay=el('monthlyReportAuditPanel');if(!overlay){overlay=document.createElement('div');overlay.id='monthlyReportAuditPanel';overlay.className='monthly-report-audit-panel';document.body.appendChild(overlay);}overlay.innerHTML=`<section class="monthly-report-audit-card"><div class="panel-header"><div><p class="eyebrow">Revision History</p><h3>${safeText(activeReportKey())} Monthly Report</h3><p class="panel-subtitle">Finalization and correction events are preserved.</p></div><button class="icon-button" data-close-monthly-audit type="button">×</button></div><div class="monthly-report-audit-list">${history.length?history.map((item)=>`<div class="monthly-report-audit-item"><strong>${safeText(item.action)}</strong><small>${safeText(dateTimeLabel(item.timestamp))} • ${safeText(item.account||'Administrator')}</small>${item.reason?`<p>${safeText(item.reason)}</p>`:''}</div>`).join(''):'<div class="system-error-empty"><strong>No workflow history yet</strong><p>Save, finalize, or reopen the report to begin its revision history.</p></div>'}</div></section>`;overlay.classList.remove('hidden');
  }
  function closeMonthlyAudit(){el('monthlyReportAuditPanel')?.classList.add('hidden');}

  // ---------------------------------------------------------------------------
  // Notification contributions
  // ---------------------------------------------------------------------------
  function enterpriseNotifications() {
    const notifications=[];const account=currentAccount();const accountRole=role();const data=dutyData();
    const dutyTarget=(entry,punchType)=>`${entry.id}::${punchType}`;

    // Reviewer-facing pending punch alerts are generated by the notification workflow so
    // the notification center and Duty Hours review use one permission-aware source.
    // This block adds private status updates only for the submitting trainee account.
    if(accountRole==='Trainee/Probationary'){
      const ownerEntries=(data.entries||[]).filter((entry)=>entry.memberId===account?.memberId||entry.submittedByAccountId===account?.id||entry.submittedByUsername===account?.username);
      ownerEntries.forEach((entry)=>{
        [['TimeIn','Time In',entry.timeInApprovalStatus,entry.timeInRequestedAt,entry.timeInReviewedAt],['TimeOut','Time Out',entry.timeOutApprovalStatus,entry.timeOutRequestedAt,entry.timeOutReviewedAt]].forEach(([punchType,label,statusValue,requestedAt,reviewedAt])=>{
          if(statusValue==='Pending'){
            notifications.push({id:`enterprise-duty-pending:${entry.id}:${punchType}`,category:'Duty Hours Update',severity:'medium',title:`Your ${label} is awaiting review`,detail:`${entry.date||'Duty session'} • Open the exact session record.`,timestamp:requestedAt||entry.createdAt||'',actionType:'duty-session',targetId:dutyTarget(entry,punchType),icon:'◷'});
            return;
          }
          if(!['Approved','Rejected'].includes(statusValue)||!reviewedAt)return;
          notifications.push({id:`enterprise-duty-result:${entry.id}:${punchType}:${statusValue}:${reviewedAt}`,category:'Duty Hours Update',severity:statusValue==='Approved'?'low':'high',title:`Your ${label} was ${statusValue.toLowerCase()}`,detail:`${entry.date||'Duty session'} • Open the exact session record.`,timestamp:reviewedAt,actionType:'duty-session',targetId:dutyTarget(entry,punchType),icon:statusValue==='Approved'?'✓':'!'});
        });
      });
    }

    const failedHealthChecks=(lastHealth?.checks||[]).filter((check)=>!check.ok).length;if(isAdmin()&&lastHealth&&failedHealthChecks>0)notifications.push({id:'enterprise-system-administration',category:'System Administration',severity:'high',title:'System diagnostics need attention',detail:`${failedHealthChecks} compatibility check${failedHealthChecks===1?'':'s'} require review.`,timestamp:lastHealth.stateUpdatedAt||lastHealth.checkedAt||'',actionType:'system-health',targetId:'diagnostics',icon:'!'});
    return notifications;
  }

  // ---------------------------------------------------------------------------
  // Data & Recovery workspace
  // ---------------------------------------------------------------------------
  let activeRecoveryPanel = 'backup';
  const LAST_PORTABLE_BACKUP_KEY = 'lso_last_portable_backup_v73';
  function setRecoveryPanel(panelName = 'backup') {
    const available = ['backup', 'recovery', 'transfer', 'governance'];
    activeRecoveryPanel = available.includes(panelName) ? panelName : 'backup';
    qsa('[data-recovery-panel]').forEach((button) => {
      const active = button.dataset.recoveryPanel === activeRecoveryPanel;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', String(active));
      button.tabIndex = active ? 0 : -1;
    });
    qsa('[data-recovery-workflow-panel]').forEach((panel) => {
      const active = panel.dataset.recoveryWorkflowPanel === activeRecoveryPanel;
      panel.classList.toggle('active', active);
      panel.hidden = !active;
    });
    renderRecoveryWorkspaceStatus();
  }
  function renderRecoveryWorkspaceStatus() {
    const host = el('v73RecoveryStatusCards');
    if (!host) return;
    const lastPortable = localStorage.getItem(LAST_PORTABLE_BACKUP_KEY) || '';
    const sharedStatus = window.LSOCloud?.isOnline?.() === false || !navigator.onLine ? 'Offline' : 'Connected';
    const recoveryStatus = window.LSOCloud?.createRecoveryPoint ? 'Available' : 'Portable backup only';
    const cards = [
      { icon: 'DB', label: 'Shared Database', value: sharedStatus, note: sharedStatus === 'Connected' ? 'Cloud operations are available.' : 'Reconnect before shared recovery actions.', tone: sharedStatus === 'Connected' ? 'success' : 'warning' },
      { icon: 'BK', label: 'Portable Backup', value: lastPortable ? dateTimeLabel(lastPortable) : 'Not created yet', note: lastPortable ? 'Latest complete-system download on this browser.' : 'Create a complete-system backup before major changes.', tone: lastPortable ? 'success' : 'neutral' },
      { icon: 'RP', label: 'Server Recovery', value: recoveryStatus, note: recoveryPoints.length ? `${recoveryPoints.length} recovery point${recoveryPoints.length===1?'':'s'} available.` : 'Refresh Recovery Points to verify server history.', tone: recoveryStatus === 'Available' ? 'success' : 'neutral' },
      { icon: 'V', label: 'System Version', value: `v${VERSION.app}`, note: VERSION.build, tone: 'info' }
    ];
    host.innerHTML = cards.map((card) => `<article class="data-recovery-status-card is-${safeText(card.tone)}"><span class="data-recovery-status-icon">${safeText(card.icon)}</span><div><span>${safeText(card.label)}</span><strong>${safeText(card.value)}</strong><small>${safeText(card.note)}</small></div></article>`).join('');
    if (el('v73LastPortableBackup')) el('v73LastPortableBackup').textContent = lastPortable ? `Last complete backup: ${dateTimeLabel(lastPortable)}` : 'No complete portable backup has been recorded on this browser yet.';
  }
  function recordPortableBackup() {
    const now = new Date().toISOString();
    try { localStorage.setItem(LAST_PORTABLE_BACKUP_KEY, now); } catch { /* no-op */ }
    renderRecoveryWorkspaceStatus();
  }
  // ---------------------------------------------------------------------------
  // Event wiring
  // ---------------------------------------------------------------------------
  function wireRiskProtection() {
    document.addEventListener('click',(event)=>{const target=event.target.closest?.('#clearDatabase');if(target)prepareRiskyOperation(target,event,'Automatic point before clearing members','Created before clearing the shared member database.');},true);
    document.addEventListener('change',(event)=>{const target=event.target;if(!target?.matches?.('#restoreCompleteSystem, #jsonRestore, #csvImport'))return;const labels={restoreCompleteSystem:['Automatic point before complete restore','Created before restoring a complete system backup.'],jsonRestore:['Automatic point before JSON restore','Created before restoring member JSON records.'],csvImport:['Automatic point before CSV import','Created before importing member records.']};prepareRiskyOperation(target,event,...labels[target.id]);},true);
  }
  function wireEvents() {
    el('accessibilityButton')?.addEventListener('click',openAccessibility);el('closeAccessibilityButton')?.addEventListener('click',closeAccessibility);el('accessibilityOverlay')?.addEventListener('click',closeAccessibility);el('saveAccessibilityButton')?.addEventListener('click',saveAccessibility);el('resetAccessibilityButton')?.addEventListener('click',resetAccessibility);
    qsa('[data-theme-choice]').forEach((button)=>button.addEventListener('click',()=>{const theme=button.dataset.themeChoice==='night'?'night':'light';if(el('accessibilityTheme'))el('accessibilityTheme').value=theme;applyAccessibility({...loadAccessibility(),theme});}));
    el('dismissSystemErrorButton')?.addEventListener('click',closeErrorDialog);el('copySystemErrorButton')?.addEventListener('click',copyErrorDetails);el('openHealthFromErrorButton')?.addEventListener('click',()=>{closeErrorDialog();setView('systemHealthView');setHealthPanel('diagnostics');setTimeout(()=>refreshSystemHealth(),50);});
    el('refreshSystemHealthButton')?.addEventListener('click',()=>refreshSystemHealth());el('copyHealthReportButton')?.addEventListener('click',copyHealthReport);el('exportPermissionMatrixButton')?.addEventListener('click',exportPermissionMatrix);
    const healthButtons=qsa('[data-health-panel]');
    healthButtons.forEach((button,index)=>{
      button.addEventListener('click',()=>setHealthPanel(button.dataset.healthPanel));
      button.addEventListener('keydown',(event)=>{
        if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
        event.preventDefault();
        const nextIndex=event.key==='Home'?0:event.key==='End'?healthButtons.length-1:(index+(event.key==='ArrowRight'?1:-1)+healthButtons.length)%healthButtons.length;
        const next=healthButtons[nextIndex];
        setHealthPanel(next.dataset.healthPanel);
        next.focus();
      });
    });
    const recoveryButtons=qsa('[data-recovery-panel]');
    recoveryButtons.forEach((button,index)=>{button.addEventListener('click',()=>setRecoveryPanel(button.dataset.recoveryPanel));button.addEventListener('keydown',(event)=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const nextIndex=event.key==='Home'?0:event.key==='End'?recoveryButtons.length-1:(index+(event.key==='ArrowRight'?1:-1)+recoveryButtons.length)%recoveryButtons.length;const next=recoveryButtons[nextIndex];setRecoveryPanel(next.dataset.recoveryPanel);next.focus();});});
    el('createRecoveryPointButton')?.addEventListener('click',async()=>{const label=window.prompt('Recovery point label:','Manual recovery point');if(label===null)return;const reason=window.prompt('Reason or note (optional):','');try{await createRecoveryPoint(label,reason||'',{type:'manual'});renderRecoveryWorkspaceStatus();toast('Recovery point created.');}catch(error){setRecoveryPanel('backup');toast('Server recovery is unavailable. Create a Complete System Backup instead.',true);el('backupCompleteSystem')?.focus();}});
    el('refreshRecoveryPointsButton')?.addEventListener('click',()=>refreshRecoveryPoints());el('recoveryPointList')?.addEventListener('click',(event)=>{const restore=event.target.closest('[data-restore-recovery]');const remove=event.target.closest('[data-delete-recovery]');if(restore)restoreRecovery(restore.dataset.restoreRecovery);if(remove)deleteRecovery(remove.dataset.deleteRecovery);});
    el('validateBackupFile')?.addEventListener('change',(event)=>validateBackupFile(event.target.files?.[0]));
    el('applyDefaultDutyRequirements')?.addEventListener('click',applyDefaultDutyRequirements);el('printDutyCertification')?.addEventListener('click',printDutyCertification);
    el('monthlyReportFinalizeButton')?.addEventListener('click',finalizeMonthlyReport);el('monthlyReportReopenButton')?.addEventListener('click',reopenMonthlyReport);el('monthlyReportAuditButton')?.addEventListener('click',showMonthlyAudit);
    document.addEventListener('click',(event)=>{if(event.target.closest?.('[data-close-monthly-audit]')||event.target.id==='monthlyReportAuditPanel')closeMonthlyAudit();});
    document.addEventListener('click',(event)=>{const target=event.target.closest?.('#monthlyReportView [data-monthly-write]');if(target&&monthlyReport()?.workflowStatus==='Finalized'){event.preventDefault();event.stopImmediatePropagation();toast('This Monthly Report is finalized. An Administrator must reopen it before editing.',true);}},true);
    document.addEventListener('input',(event)=>{if(event.target.closest?.('#monthlyReportView')&&event.target.matches?.('[data-monthly-edit]')&&monthlyReport()?.workflowStatus==='Finalized'){event.preventDefault();event.stopImmediatePropagation();window.LSOMonthlyReport?.refresh?.();toast('This Monthly Report is finalized and locked.',true);}},true);
    document.querySelector('[data-view="systemHealthView"]')?.addEventListener('click',()=>setTimeout(()=>refreshSystemHealth({quiet:true}),50));
    document.querySelector('[data-view="dataView"]')?.addEventListener('click',()=>setTimeout(()=>{setRecoveryPanel(activeRecoveryPanel);refreshRecoveryPoints({quiet:true});renderRecoveryWorkspaceStatus();},50));
    ['lso:duty-hours-changed','lso:cloud-state-changed','lso:members-changed'].forEach((name)=>window.addEventListener(name,()=>window.LSORuntimeStability?.schedule?.('system-duty-enhancements',renderDutyEnhancements,120,{viewId:'dutyHoursView'})));
    ['lso:monthly-report-changed','lso:cloud-state-changed'].forEach((name)=>window.addEventListener(name,()=>window.LSORuntimeStability?.schedule?.('system-monthly-workflow',renderMonthlyWorkflow,120,{viewId:'monthlyReportView'})));
    window.addEventListener('lso:system-error',(event)=>{
      if(loggingServerError&&event.detail?.rpc==='lso_log_system_error')return;
      const detail=event.detail||{};
      const technical=String(detail.technicalMessage||detail.message||detail.publicMessage||'');
      // An expired login session is expected authentication lifecycle behavior. It should
      // return the user to Login, not be presented as a Shared Database malfunction.
      if(detail.errorCode==='AUTH-SESSION-002'||/invalid or expired session|session expired|invalid session|expired token/i.test(technical)){
        closeErrorDialog();
        return;
      }
      reportError(detail);
    });
    window.addEventListener('lso:session-invalid',()=>closeErrorDialog());
    window.addEventListener('lso:auth-session-recovered',()=>closeErrorDialog());
    window.addEventListener('error',(event)=>{if(!event.error&&!event.message)return;const technical=String(event.error?.stack||event.message||'Unknown JavaScript error');if(/renderAll is not defined/i.test(technical)&&/workflow-attendance-month-v2\.js/i.test(technical)){event.preventDefault?.();window.LSORenderCompatibility?.refreshAttendance?.();window.renderAll?.();closeErrorDialog();console.warn('Obsolete attendance cache recovered without blocking the website.');return;}reportError({module:'Website',publicMessage:'A website component stopped unexpectedly. Your shared records were not intentionally changed.',technicalMessage:technical}, {show:true});});
    window.addEventListener('unhandledrejection',(event)=>{const reason=event.reason;reportError({module:'Website',publicMessage:'A background operation could not be completed.',technicalMessage:reason?.stack||reason?.message||String(reason||'Unknown promise rejection')},{show:true});});
    window.addEventListener('lso:auth-changed',()=>setTimeout(()=>{if(isAdmin()){ensureDailyRecovery();refreshSystemHealth({quiet:true});refreshRecoveryPoints({quiet:true});}renderDutyEnhancements();renderMonthlyWorkflow();},300));
    wireRiskProtection();
  }
  function initialize() {
    if (el('systemVersionFooter')) el('systemVersionFooter').textContent = `LSO System v${VERSION.app} • Database target ${String(VERSION.schemaTarget || '').split('_')[0] || '—'}`;
    applyAccessibility();injectDutySettings();renderDutySettings();renderHealthVersions();renderHealthChecks();renderMigrations();renderHealthCounts();renderPermissionMatrix();renderRecoveryPoints();renderDutyEnhancements();renderMonthlyWorkflow();wireEvents();setHealthPanel(activeHealthPanel);setRecoveryPanel(activeRecoveryPanel);renderHealthWorkflowSummary();renderRecoveryWorkspaceStatus();
    window.dispatchEvent(new CustomEvent('lso:enterprise-ready', { detail: { version: VERSION } }));
    if(isAdmin()){setTimeout(()=>{ensureDailyRecovery();refreshSystemHealth({quiet:true});refreshRecoveryPoints({quiet:true});},900);}
  }

  window.LSOEnterprise = { VERSION, reportError, getNotifications: enterpriseNotifications, refreshHealth: refreshSystemHealth, refreshRecovery: refreshRecoveryPoints, applyAccessibility, validateBackupObject, renderDutyEnhancements, renderMonthlyWorkflow, setRecoveryPanel, renderRecoveryWorkspaceStatus };
  window.addEventListener('lso:permissions-changed',()=>setTimeout(()=>{renderPermissionMatrix();window.LSORolePermissionCenter?.render?.();},20));
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',initialize,{once:true});else initialize();
})();
