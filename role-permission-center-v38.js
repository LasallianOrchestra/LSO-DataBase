(() => {
  'use strict';

  const el = (id) => document.getElementById(id);
  const safe = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[char]));
  const clone = (value) => JSON.parse(JSON.stringify(value || {}));
  const ADMIN = 'Administrator';
  const ROLES = ['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary'];
  const VIEW_DEFS = [
    ['dashboardView','Dashboard','Operational overview, quick actions, workflow cards, alerts, and live summaries.'],
    ['membersView','Members','Member directory, stage monitoring, profile information, and member photo management.'],
    ['lookupView','Members Overall Record','Unified member profile with contracts, Monthly Reports, Attendance, Duty Hours, corrections, PDF preview, and PDF download.'],
    ['documentsView','Document Center','Centralized access to member overview PDFs, contracts, finalized Attendance archives, Monthly Reports, and Duty Hours documents.'],
    ['contractView','Contract','Membership contract preparation, preview, generation, and tracked contract output.'],
    ['monthlyReportView','Monthly Report','Three-phase monthly filing, validation, PDF preview/download, finalization, and report archive.'],
    ['attendanceView','Attendance','Activity creation, Official/Trainee/Probationary rosters, LOA/Excused rules, Review, Finalize, Archive, revisions, and semester ratings.'],
    ['dutyHoursView','Duty Hours','Trainee/Probationary live rosters, Time In/Out punches, approvals, manual ledgers, archives, totals, and certifications.'],
    ['alertsView','Action Center','Notification Inbox, workflow alerts, exact-record routing, and follow-up actions.'],
    ['accountsView','Accounts','Security owner area for account approval, role assignment, activation, and account maintenance.'],
    ['systemHealthView','System Health','Security owner area for diagnostics, Role Management, Audit Trail, Data Quality, Maintenance Mode, and Error Resolution.'],
    ['dataView','Data & Recovery','Security owner area for system settings, backup, restore, recovery points, imports, and controlled clearing.']
  ];
  const ACTION_DEFS = [
    ['manageMembers','Manage member & Overall Records','Add/edit member profiles and photos, and correct member-linked Overall Record data through its source workflow.'],
    ['generateContract','Generate contracts','Prepare, preview, download, and regenerate official membership contracts.'],
    ['editMonthlyReport','Edit Monthly Reports','Create, revise, and save three-phase Monthly Report filing information.'],
    ['finalizeMonthlyReport','Finalize & manage Monthly Report outputs','Finalize/reopen reports and control the validated Monthly Report archive output.'],
    ['reopenMonthlyReport','Reopen Monthly Reports','Return a finalized Monthly Report to correction mode.'],
    ['manageEvents','Create/edit Attendance activities','Create and modify activities in assigned Attendance calendars and Draft/Reopened months.'],
    ['deleteEvents','Delete Attendance activities','Delete activities and their connected attendance records where workflow state allows.'],
    ['saveDraftAttendance','Record Attendance','Mark Present/Late/Absent/Excused, add remarks, and save Draft/Reopened rosters.'],
    ['finalizeAttendance','Review/finalize Attendance lifecycle','Run monthly Review, finalize validated months/activities, create archive copies, and finalize semester ratings.'],
    ['unlockAttendance','Reopen/manage Attendance archives','Return reviewed months for correction, reopen finalized periods, and manage validated Attendance archive revisions.'],
    ['reviewDutyPunches','Approve/reject Duty Hours punches','Review Time In and Time Out requests for authorized accounts.'],
    ['manageDutyHours','Manage Duty Hours records & archives','Add/edit/remove manual Duty Hours records, corrections, and completed-period archive records.'],
    ['manageDutyRequirements','Set Duty requirements','Configure required Trainee and Probationary semester hours.'],
    ['certifyDutyHours','Generate Duty certifications','Generate individual and roster Duty Hours documents and certifications.'],
    ['writeActivityLog','Write operational audit activity','Record authorized changes in the system activity/audit history.'],
    ['manageAccessibility','Use accessibility controls','Use text sizing, contrast, motion, density, and table accessibility settings.'],
    ['selfDutyPunch','Submit personal Duty punches','Linked Trainee/Probationary self-service Time In and Time Out.'],
    ['manageAccounts','Manage accounts','Protected security-owner permission for approvals, roles, activation, and account maintenance.'],
    ['manageSettings','Manage system settings','Protected security-owner permission for organization-wide settings and Maintenance Mode backing data.'],
    ['manageInventory','Manage inventory','Protected legacy inventory maintenance permission.'],
    ['manageData','Import/export/clear data','Protected security-owner data administration permission.'],
    ['manageRecovery','Manage recovery points','Protected security-owner backup and restore permission.'],
    ['viewSystemHealth','View System Health','Protected security-owner diagnostics and compatibility information.'],
    ['manageSystemErrors','Resolve system errors','Protected security-owner System Error Log resolution permission.']
  ];
  const GROUP_DEFS = [
    ['Official Members','Official Members Calendar'],
    ['Trainee Members','Trainee Members Calendar'],
    ['Probationary Members','Probationary Members Calendar']
  ];
  const PROTECTED_VIEWS = new Set(['accountsView','systemHealthView','dataView']);
  const PROTECTED_ACTIONS = new Set(['manageAccounts','manageSettings','manageInventory','manageData','manageRecovery','viewSystemHealth','manageSystemErrors']);
  const ROLE_RESTRICTED_ACTIONS = {
    // Self-service Duty punches require a linked Trainee/Probationary account.
    // All other operational permissions are assigned by the Administrator.
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
    ['permissionRoleSelect','permissionLandingViewSelect','saveRolePermissionsButton','resetRolePermissionsButton','permissionCopySourceRole','copyRolePermissionsButton'].forEach((id) => { if (el(id)) el(id).disabled = busy; });
    document.querySelectorAll('[data-permission-bulk]').forEach((button) => { button.disabled = busy || activeRole === ADMIN; });
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
    if (type === 'action' && key === 'selfDutyPunch' && roleName !== 'Trainee/Probationary') return true;
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
    const source = el('permissionCopySourceRole');
    if (source) {
      const candidates = ROLES.filter((roleName) => roleName !== activeRole);
      source.innerHTML = candidates.map((roleName) => `<option value="${safe(roleName)}">${safe(roleName)}</option>`).join('');
      if (!candidates.includes(source.value)) source.value = candidates[0] || '';
      source.disabled = activeRole === ADMIN || busy;
    }
    if (el('copyRolePermissionsButton')) el('copyRolePermissionsButton').disabled = activeRole === ADMIN || busy;
    document.querySelectorAll('[data-permission-bulk]').forEach((button) => { button.disabled = activeRole === ADMIN || busy; });
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
        : '<strong>Administrator-controlled operational access:</strong> Every supported operational permission is open for assignment. Accounts, System Health, Data & Recovery, and identity-bound self-service remain protected because their server functions are security-owner controls.';
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

  function applyWorkingCopy(sourceRole) {
    if (!isAdmin() || activeRole === ADMIN || !sourceRole || sourceRole === activeRole) return;
    const source = roleRow(sourceRole);
    if (!source) return status('The source role permissions are unavailable.', 'error');
    const groups = { view: new Set(source.views || []), action: new Set(source.actions || []), attendance: new Set(source.attendanceGroups || []) };
    document.querySelectorAll('#rolePermissionEditor input[data-permission-kind]').forEach((input) => {
      if (input.disabled) return;
      input.checked = groups[input.dataset.permissionKind]?.has(input.value) || false;
    });
    updateLandingOptions();
    const landing = el('permissionLandingViewSelect');
    if (landing && [...landing.options].some((option) => option.value === source.landingView)) landing.value = source.landingView;
    updateSummary();
    status(`${sourceRole} was applied as a working copy for ${activeRole}. Review it, then select Save Role Permissions.`, 'success');
  }

  function applyBulkPermission(action) {
    if (!isAdmin() || activeRole === ADMIN) return;
    const value = String(action || '');
    if (value === 'operational-all' || value === 'operational-none') {
      const grant = value === 'operational-all';
      document.querySelectorAll('#permissionModuleOptions input:not(:disabled), #permissionActionOptions input:not(:disabled), #permissionAttendanceOptions input:not(:disabled)')
        .forEach((input) => { input.checked = grant; });
      updateLandingOptions();
      updateSummary();
      status(`${grant ? 'Full operational access selected' : 'Operational access cleared'} for ${activeRole}. Protected security-owner controls were not changed. Review the working copy before saving.`, 'success');
      return;
    }
    const [section, mode] = value.split('-');
    const selector = section === 'modules' ? '#permissionModuleOptions' : section === 'actions' ? '#permissionActionOptions' : '#permissionAttendanceOptions';
    const inputs = [...document.querySelectorAll(`${selector} input:not(:disabled)` )];
    inputs.forEach((input) => { input.checked = mode === 'all'; });
    if (section === 'modules') updateLandingOptions(); else updateSummary();
    status(`${mode === 'all' ? 'Selected' : 'Cleared'} ${section === 'attendance' ? 'attendance groups' : section} for ${activeRole}. Review the working copy before saving.`, 'success');
  }

  async function save() {
    if (!isAdmin() || activeRole === ADMIN || busy) return;
    const previousRow = clone(roleRow(activeRole));
    const views = checked('#permissionModuleOptions input:not(:disabled)');
    const actions = checked('#permissionActionOptions input:not(:disabled)');
    const attendanceGroups = checked('#permissionAttendanceOptions input:not(:disabled)');
    const landingView = el('permissionLandingViewSelect')?.value || '';
    if (!views.length) return status('Assign at least one module before saving.', 'error');
    if (!views.includes(landingView)) return status('The landing page must be one of the assigned modules.', 'error');
    if (views.includes('attendanceView') && !attendanceGroups.length) return status('Attendance is assigned, so select at least one Official, Trainee, or Probationary attendance calendar.', 'error');
    const actionDependencies = {
      manageMembers: 'membersView', generateContract: 'contractView', editMonthlyReport: 'monthlyReportView', finalizeMonthlyReport: 'monthlyReportView', reopenMonthlyReport: 'monthlyReportView',
      manageEvents: 'attendanceView', deleteEvents: 'attendanceView', saveDraftAttendance: 'attendanceView', finalizeAttendance: 'attendanceView', unlockAttendance: 'attendanceView',
      reviewDutyPunches: 'dutyHoursView', manageDutyHours: 'dutyHoursView', manageDutyRequirements: 'dutyHoursView', certifyDutyHours: 'dutyHoursView', selfDutyPunch: 'dutyHoursView'
    };
    const missingDependency = actions.find((action) => actionDependencies[action] && !views.includes(actionDependencies[action]));
    if (missingDependency) return status(`${ACTION_DEFS.find(([key]) => key === missingDependency)?.[1] || missingDependency} requires the ${viewLabel(actionDependencies[missingDependency])} module.`, 'error');
    setBusy(true); status('Saving role permissions…');
    try {
      const nextPayload = await window.LSOCloud.saveRolePermissionCenter({ roleName: activeRole, landingView, views, actions, attendanceGroups });
      applyPayload(nextPayload);
      renderMatrix();
      window.LSOPermissions?.apply?.();
      window.LSOOperations?.logActivity?.('Updated role permissions', 'Access Control', `${activeRole} • Landing ${previousRow?.landingView || '—'} → ${landingView} • Modules ${(previousRow?.views || []).length} → ${views.length} • Actions ${(previousRow?.actions || []).length} → ${actions.length} • Attendance groups ${(previousRow?.attendanceGroups || []).length} → ${attendanceGroups.length}`);
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
      window.LSOOperations?.logActivity?.('Reset role permissions', 'Access Control', `${activeRole} was restored to the official default permission profile.`);
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
    el('copyRolePermissionsButton')?.addEventListener('click', () => applyWorkingCopy(el('permissionCopySourceRole')?.value || ''));
    el('permissionBulkActions')?.addEventListener('click', (event) => { const button = event.target.closest('[data-permission-bulk]'); if (button) applyBulkPermission(button.dataset.permissionBulk); });
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
