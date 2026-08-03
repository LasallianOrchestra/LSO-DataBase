(() => {
  'use strict';

  const el = (id) => document.getElementById(id);
  const safe = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[char]));
  const clone = (value) => JSON.parse(JSON.stringify(value || {}));
  const ADMIN = 'Administrator';
  const ROLES = ['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary'];
  const VIEW_DEFS = [
    ['dashboardView','Dashboard','Summary, alerts, analytics, and operational overview.'],
    ['membersView','Members','Member directory, records, and stage monitoring.'],
    ['lookupView','Member Lookup','Focused member search and record review.'],
    ['contractView','Contract','Membership contract preparation and printing.'],
    ['monthlyReportView','Monthly Report','Monthly filing, report review, and PDF generation.'],
    ['attendanceView','Attendance','Activities, calendars, rosters, ratings, and reports.'],
    ['dutyHoursView','Duty Hours','Trainee/Probationary hours, approvals, and progress.'],
    ['alertsView','Action Center','System-generated operational notices and follow-up items.'],
    ['accountsView','Accounts','Protected Administrator-only account management.'],
    ['systemHealthView','System Health','Protected diagnostics, permissions, migrations, and errors.'],
    ['dataView','Data & Recovery','Protected backups, imports, restores, and settings.']
  ];
  const ACTION_DEFS = [
    ['manageMembers','Manage member records','Add, edit, and update member profiles.'],
    ['generateContract','Generate contracts','Prepare, preview, and print membership contracts.'],
    ['editMonthlyReport','Edit Monthly Reports','Create and update monthly report content.'],
    ['finalizeMonthlyReport','Finalize Monthly Reports','Lock a verified Monthly Report.'],
    ['reopenMonthlyReport','Reopen Monthly Reports','Reopen a finalized report for correction.'],
    ['manageEvents','Create/edit activities','Create or modify Attendance activities.'],
    ['deleteEvents','Delete activities','Permanently remove activities.'],
    ['saveDraftAttendance','Save draft attendance','Mark and save Attendance rosters.'],
    ['finalizeAttendance','Finalize attendance','Finalize activity, month, and semester ratings.'],
    ['unlockAttendance','Unlock attendance','Reopen finalized Attendance records.'],
    ['reviewDutyPunches','Approve/reject Duty punches','Review separate Time In and Time Out requests.'],
    ['manageDutyHours','Manually manage Duty Hours','Add, edit, delete, and adjust Duty Hours records.'],
    ['manageDutyRequirements','Set Duty requirements','Configure required Trainee/Probationary hours.'],
    ['certifyDutyHours','Generate Duty certification','Prepare official Duty Hours certification.'],
    ['writeActivityLog','Write audit activity','Record changes in the system activity log.'],
    ['manageAccessibility','Use accessibility controls','Use text, contrast, motion, density, and table settings.'],
    ['selfDutyPunch','Submit personal Duty punches','Use Time In and Time Out for the linked member account.'],
    ['manageAccounts','Manage accounts','Protected Administrator-only function.'],
    ['manageSettings','Manage system settings','Protected Administrator-only function.'],
    ['manageInventory','Manage inventory','Protected Administrator-only function.'],
    ['manageData','Import/export/clear data','Protected Administrator-only function.'],
    ['manageRecovery','Manage recovery points','Protected Administrator-only function.'],
    ['viewSystemHealth','View System Health','Protected Administrator-only function.'],
    ['manageSystemErrors','Resolve system errors','Protected Administrator-only function.']
  ];
  const GROUP_DEFS = [
    ['Official Members','Official Members Calendar'],
    ['Trainee Members','Trainee Members Calendar'],
    ['Probationary Members','Probationary Members Calendar']
  ];
  const PROTECTED_VIEWS = new Set(['accountsView','systemHealthView','dataView']);
  const PROTECTED_ACTIONS = new Set(['manageAccounts','manageSettings','manageInventory','manageData','manageRecovery','viewSystemHealth','manageSystemErrors']);
  const ROLE_RESTRICTED_ACTIONS = {
    reviewDutyPunches: new Set(['Membership','Staff Account']),
    selfDutyPunch: new Set(['Trainee/Probationary'])
  };

  let payload = null;
  let activeRole = 'Membership';
  let busy = false;
  let loadPromise = null;
  let suppressPermissionEventRender = false;
  let renderFrame = 0;
  let matrixSignature = '';
  let responsiveSectionsInitialized = false;

  function isAdmin() { return (window.LSOCurrentAccount?.role || '') === ADMIN; }
  function roleRow(roleName = activeRole) { return (payload?.roles || []).find((row) => row.roleName === roleName) || null; }
  function checked(selector) { return [...document.querySelectorAll(selector)].filter((input) => input.checked).map((input) => input.value); }
  function viewLabel(id) { return VIEW_DEFS.find(([key]) => key === id)?.[1] || id; }
  function status(message = '', type = '') {
    const node = el('permissionEditorStatus'); if (!node) return;
    node.textContent = message; node.className = `permission-editor-status${type ? ` is-${type}` : ''}`;
  }
  function setBusy(value) {
    busy = Boolean(value);
    ['permissionRoleSelect','permissionLandingViewSelect','saveRolePermissionsButton','resetRolePermissionsButton'].forEach((id) => { if (el(id)) el(id).disabled = busy; });
    el('rolePermissionEditor')?.setAttribute('aria-busy', String(busy));
  }

  function replaceHtml(node, html) {
    if (node && node.innerHTML !== html) node.innerHTML = html;
  }

  function applyPayload(nextPayload) {
    payload = nextPayload;
    suppressPermissionEventRender = true;
    try { window.LSORoleAccess?.applyServerPayload?.(nextPayload); }
    finally { suppressPermissionEventRender = false; }
  }

  function scheduleRender({ editor = true, matrix = true } = {}) {
    if (renderFrame) cancelAnimationFrame(renderFrame);
    renderFrame = requestAnimationFrame(() => {
      renderFrame = 0;
      if (editor) renderEditor();
      if (matrix) renderMatrix();
    });
  }

  function configureResponsiveSections() {
    if (responsiveSectionsInitialized || !window.matchMedia?.('(max-width: 820px)').matches) return;
    const sections = [...document.querySelectorAll('#rolePermissionEditor details.permission-editor-section')];
    sections.forEach((section, index) => { section.open = index === 0; });
    responsiveSectionsInitialized = true;
  }

  function protectedFor(roleName, type, key) {
    if (roleName === ADMIN) return true;
    if (type === 'view' && PROTECTED_VIEWS.has(key)) return true;
    if (type === 'action' && PROTECTED_ACTIONS.has(key)) return true;
    if (type === 'action' && ['manageAccessibility','selfDutyPunch'].includes(key)) return true;
    const compatible = ROLE_RESTRICTED_ACTIONS[key];
    return Boolean(type === 'action' && compatible && !compatible.has(roleName));
  }

  function renderRoleOptions() {
    const select = el('permissionRoleSelect'); if (!select) return;
    if (select.options.length !== ROLES.length) {
      select.innerHTML = ROLES.map((roleName) => `<option value="${safe(roleName)}">${safe(roleName)}${roleName === ADMIN ? ' (protected)' : ''}</option>`).join('');
    }
    if (!ROLES.includes(activeRole)) activeRole = 'Membership';
    select.value = activeRole;
  }

  function toggleCard(type, key, label, description, granted, roleName) {
    const locked = protectedFor(roleName, type, key);
    return `<label class="permission-toggle-card${locked ? ' is-protected' : ''}">
      <input type="checkbox" data-permission-kind="${safe(type)}" value="${safe(key)}" ${granted ? 'checked' : ''} ${locked ? 'disabled' : ''}/>
      <span class="permission-toggle-copy"><strong>${safe(label)}</strong><small>${safe(description)}${locked ? ' This option is protected or unsupported for the selected role.' : ''}</small></span>
    </label>`;
  }

  function renderEditor() {
    const row = roleRow();
    const roleName = activeRole;
    const editable = isAdmin() && roleName !== ADMIN;
    const views = new Set(row?.views || []);
    const actions = new Set(row?.actions || []);
    const groups = new Set(row?.attendanceGroups || []);

    renderRoleOptions();
    const landing = el('permissionLandingViewSelect');
    if (landing) {
      const allowedViews = VIEW_DEFS.filter(([key]) => views.has(key));
      landing.innerHTML = allowedViews.length
        ? allowedViews.map(([key,label]) => `<option value="${safe(key)}">${safe(label)}</option>`).join('')
        : '<option value="">Select at least one module first</option>';
      landing.value = allowedViews.some(([key]) => key === row?.landingView) ? row.landingView : (allowedViews[0]?.[0] || '');
      landing.disabled = !editable || !allowedViews.length;
    }

    replaceHtml(el('permissionModuleOptions'), VIEW_DEFS.map(([key,label,description]) => toggleCard('view',key,label,description,views.has(key),roleName)).join(''));
    replaceHtml(el('permissionActionOptions'), ACTION_DEFS.map(([key,label,description]) => toggleCard('action',key,label,description,actions.has(key),roleName)).join(''));
    replaceHtml(el('permissionAttendanceOptions'), GROUP_DEFS.map(([key,label]) => toggleCard('attendance',key,label,'Allow this Attendance calendar and its records.',groups.has(key),roleName)).join(''));
    configureResponsiveSections();

    document.querySelectorAll('#rolePermissionEditor input[type="checkbox"]').forEach((input) => {
      if (!editable) input.disabled = true;
    });
    if (el('saveRolePermissionsButton')) el('saveRolePermissionsButton').disabled = !editable || busy;
    if (el('resetRolePermissionsButton')) el('resetRolePermissionsButton').disabled = !editable || busy;
    if (el('permissionEditorProtectionNote')) {
      el('permissionEditorProtectionNote').innerHTML = roleName === ADMIN
        ? '<strong>Administrator is protected.</strong> Full access and Dashboard landing cannot be removed, preventing system lockout.'
        : '<strong>Safety controls:</strong> Accounts, System Health, Data & Recovery, database administration, and unsupported workflow actions remain Administrator-only.';
    }
    updateSummary();
  }

  function updateLandingOptions() {
    const landing = el('permissionLandingViewSelect'); if (!landing) return;
    const previous = landing.value;
    const views = checked('#permissionModuleOptions input:not(:disabled)');
    const protectedChecked = [...document.querySelectorAll('#permissionModuleOptions input:disabled:checked')].map((input) => input.value);
    const selected = [...new Set([...views, ...protectedChecked])];
    landing.innerHTML = VIEW_DEFS.filter(([key]) => selected.includes(key)).map(([key,label]) => `<option value="${safe(key)}">${safe(label)}</option>`).join('') || '<option value="">Select at least one module first</option>';
    landing.value = selected.includes(previous) ? previous : (selected[0] || '');
    updateSummary();
  }

  function updateSummary() {
    const container = el('permissionRoleSummary'); if (!container) return;
    const views = checked('#permissionModuleOptions input:checked');
    const actions = checked('#permissionActionOptions input:checked');
    const landing = el('permissionLandingViewSelect')?.value || '';
    replaceHtml(container, `<span>${views.length} module${views.length === 1 ? '' : 's'}</span><span>${actions.length} action permission${actions.length === 1 ? '' : 's'}</span><span>Landing: ${safe(viewLabel(landing) || 'Not selected')}</span>`);
  }

  function setActiveMatrixColumn() {
    const table = document.querySelector('.permission-matrix-table');
    if (!table) return;
    table.dataset.activeRole = activeRole;
    table.querySelectorAll('.permission-role-column').forEach((cell) => {
      cell.classList.toggle('is-active-role-column', cell.dataset.role === activeRole);
    });
  }

  function renderMatrix() {
    const head = el('permissionMatrixHead'); const body = el('permissionMatrixBody'); if (!head || !body) return;
    const manifest = window.LSORoleAccess?.permissionManifest?.() || {};
    const landings = window.LSORoleAccess?.landingManifest?.() || {};
    const signature = JSON.stringify({ manifest, landings });
    if (signature === matrixSignature && head.children.length && body.children.length) {
      setActiveMatrixColumn();
      return;
    }
    matrixSignature = signature;
    head.innerHTML = `<tr><th scope="col">Permission</th>${ROLES.map((roleName) => `<th scope="col" class="permission-role-column${roleName === activeRole ? ' is-active-role-column' : ''}" data-role="${safe(roleName)}">${safe(roleName)}</th>`).join('')}</tr>`;
    const rows = [];
    rows.push(`<tr class="permission-category-row"><th colspan="${ROLES.length+1}">Module access and landing page</th></tr>`);
    VIEW_DEFS.forEach(([viewId,label]) => rows.push(`<tr><th scope="row">${safe(label)}</th>${ROLES.map((roleName) => { const granted=(manifest.views?.[roleName]||[]).includes(viewId); const landing=landings[roleName]===viewId; return `<td class="permission-role-column${roleName === activeRole ? ' is-active-role-column' : ''}" data-role="${safe(roleName)}" data-label="${safe(roleName)}"><span class="${granted?'permission-granted':'permission-denied'}">${granted?'Yes':'—'}</span>${landing?'<span class="permission-current-landing">Landing</span>':''}</td>`; }).join('')}</tr>`));
    rows.push(`<tr class="permission-category-row"><th colspan="${ROLES.length+1}">Action permissions</th></tr>`);
    ACTION_DEFS.forEach(([action,label]) => rows.push(`<tr><th scope="row">${safe(label)}</th>${ROLES.map((roleName) => { const granted=(manifest.actions?.[action]||[]).includes(roleName); return `<td class="permission-role-column${roleName === activeRole ? ' is-active-role-column' : ''}" data-role="${safe(roleName)}" data-label="${safe(roleName)}"><span class="${granted?'permission-granted':'permission-denied'}">${granted?'Yes':'—'}</span></td>`; }).join('')}</tr>`));
    body.innerHTML = rows.join('');
    setActiveMatrixColumn();
  }

  async function load({ quiet = false, force = false } = {}) {
    if (!isAdmin()) return null;
    if (loadPromise) return loadPromise;
    loadPromise = (async () => {
      status('Loading role permissions…');
      try {
        if (!window.LSOCloud?.getRolePermissionCenter) throw new Error('The permission connector is unavailable. Upload the complete V38 package.');
        const nextPayload = await window.LSOCloud.getRolePermissionCenter();
        applyPayload(nextPayload);
        renderEditor(); renderMatrix();
        status(`Permissions loaded${payload?.updatedAt ? ` • Last updated ${new Date(payload.updatedAt).toLocaleString('en-PH')}` : ''}.`, 'success');
        return payload;
      } catch (error) {
        status(error.message || 'Role permissions could not be loaded.', 'error');
        if (!quiet) window.LSOApp?.showToast?.(error.message || 'Role permissions could not be loaded.', true);
        return null;
      } finally {
        loadPromise = null;
      }
    })();
    return loadPromise;
  }

  function hydrateFromRuntime() {
    const runtimePayload = window.LSORoleAccess?.serverConfiguration?.();
    if (!runtimePayload?.roles?.length) return false;
    payload = runtimePayload;
    renderEditor(); renderMatrix();
    status(`Permissions ready${payload?.updatedAt ? ` • Last updated ${new Date(payload.updatedAt).toLocaleString('en-PH')}` : ''}.`, 'success');
    return true;
  }

  async function save() {
    if (!isAdmin() || activeRole === ADMIN || busy) return;
    const views = checked('#permissionModuleOptions input:not(:disabled)');
    const actions = checked('#permissionActionOptions input:not(:disabled)');
    const attendanceGroups = checked('#permissionAttendanceOptions input:not(:disabled)');
    const landingView = el('permissionLandingViewSelect')?.value || '';
    if (!views.length) return status('Assign at least one module before saving.', 'error');
    if (!views.includes(landingView)) return status('The landing page must be one of the assigned modules.', 'error');
    setBusy(true); status('Saving role permissions…');
    try {
      const nextPayload = await window.LSOCloud.saveRolePermissionCenter({ roleName: activeRole, landingView, views, actions, attendanceGroups });
      applyPayload(nextPayload);
      renderMatrix();
      window.LSOPermissions?.apply?.();
      status(`${activeRole} permissions were saved. Active users receive the update automatically.`, 'success');
      window.LSOApp?.showToast?.(`${activeRole} permissions updated.`);
    } catch (error) {
      status(error.message || 'The role permissions could not be saved.', 'error');
      window.LSOApp?.showToast?.(error.message || 'The role permissions could not be saved.', true);
    } finally { setBusy(false); renderEditor(); }
  }

  async function reset() {
    if (!isAdmin() || activeRole === ADMIN || busy) return;
    if (!window.confirm(`Reset ${activeRole} to the official LSO default permissions?`)) return;
    setBusy(true); status('Resetting role permissions…');
    try {
      const nextPayload = await window.LSOCloud.resetRolePermissionCenter(activeRole);
      applyPayload(nextPayload);
      renderMatrix();
      status(`${activeRole} was restored to its default access.`, 'success');
      window.LSOApp?.showToast?.(`${activeRole} permissions reset.`);
    } catch (error) {
      status(error.message || 'The role could not be reset.', 'error');
    } finally { setBusy(false); renderEditor(); }
  }

  function wire() {
    el('permissionRoleSelect')?.addEventListener('change', (event) => { activeRole = event.target.value; renderEditor(); setActiveMatrixColumn(); status('Review the selected role, then save any changes.'); });
    el('permissionModuleOptions')?.addEventListener('change', updateLandingOptions);
    el('permissionActionOptions')?.addEventListener('change', updateSummary);
    el('permissionAttendanceOptions')?.addEventListener('change', updateSummary);
    el('permissionLandingViewSelect')?.addEventListener('change', updateSummary);
    el('saveRolePermissionsButton')?.addEventListener('click', save);
    el('resetRolePermissionsButton')?.addEventListener('click', reset);
    el('refreshRolePermissionsButton')?.addEventListener('click', () => load({ force: true }));
    document.querySelector('[data-view="systemHealthView"]')?.addEventListener('click', () => {
      requestAnimationFrame(() => { if (!hydrateFromRuntime()) load({ quiet: true }); });
    });
  }

  function initialize() {
    wire();
    configureResponsiveSections();
    if (isAdmin()) hydrateFromRuntime();
  }

  window.addEventListener('lso:auth-changed', (event) => {
    if (event.detail?.role !== ADMIN) return;
    window.setTimeout(() => { if (!hydrateFromRuntime()) load({ quiet: true }); }, 420);
  });
  window.addEventListener('lso:permissions-changed', (event) => {
    if (suppressPermissionEventRender) return;
    if (event.detail?.payload?.roles?.length) payload = clone(event.detail.payload);
    scheduleRender({ editor: isAdmin() && Boolean(payload), matrix: true });
  });
  window.LSORolePermissionCenter = { load, render: () => { renderEditor(); renderMatrix(); }, getPayload: () => clone(payload) };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
