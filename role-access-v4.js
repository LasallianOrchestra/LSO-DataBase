(() => {
  'use strict';

  const core = window.LSOSystemCore || {};
  const ROLES = core.ROLES || Object.freeze({
    ADMIN: 'Administrator', STAFF: 'Staff Account', MEMBERSHIP: 'Membership', SECRETARY: 'General Secretary', TRAINEE: 'Trainee/Probationary'
  });
  const clone = (value) => JSON.parse(JSON.stringify(value || {}));
  const defaults = clone(core.PERMISSIONS || { views: {}, actions: {}, columns: {}, attendanceGroups: {} });
  const defaultLandings = Object.fromEntries(Object.values(ROLES).map((roleName) => [roleName, defaults.views?.[roleName]?.[0] || 'dashboardView']));

  let manifest = clone(defaults);
  let landingViews = { ...defaultLandings };
  let serverPayload = null;
  let refreshTimer = null;
  let refreshing = false;

  function currentAccount() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function role(account = currentAccount()) {
    const value = account?.role;
    return Object.values(ROLES).includes(value) ? value : ROLES.STAFF;
  }

  function normalizeList(value) {
    return [...new Set((Array.isArray(value) ? value : []).map((item) => String(item || '').trim()).filter(Boolean))];
  }

  function resetRuntime({ emit = true } = {}) {
    manifest = clone(defaults);
    landingViews = { ...defaultLandings };
    serverPayload = null;
    if (emit) dispatchChange('defaults');
  }

  function roleRows(payload) {
    return Array.isArray(payload?.roles) ? payload.roles : [];
  }

  function applyServerPayload(payload, { emit = true } = {}) {
    if (!payload || typeof payload !== 'object' || !roleRows(payload).length) {
      resetRuntime({ emit });
      return false;
    }

    const next = clone(defaults);
    const nextLanding = { ...defaultLandings };
    const actionKeys = Object.keys(next.actions || {});

    roleRows(payload).forEach((row) => {
      const roleName = String(row?.roleName || row?.role || '');
      if (!Object.values(ROLES).includes(roleName) || roleName === ROLES.ADMIN) return;

      next.views[roleName] = normalizeList(row.views);
      next.columns[roleName] = normalizeList(row.columns);
      next.attendanceGroups[roleName] = normalizeList(row.attendanceGroups);
      actionKeys.forEach((action) => {
        next.actions[action] = normalizeList(next.actions[action]).filter((item) => item !== roleName);
      });
      normalizeList(row.actions).forEach((action) => {
        if (!actionKeys.includes(action)) return;
        next.actions[action] = normalizeList([...(next.actions[action] || []), roleName]);
      });

      const preferred = String(row.landingView || '');
      nextLanding[roleName] = next.views[roleName].includes(preferred)
        ? preferred
        : (next.views[roleName][0] || defaultLandings[roleName] || 'dashboardView');
    });

    // Administrator permissions are deliberately immutable to prevent lockout.
    next.views[ROLES.ADMIN] = clone(defaults.views?.[ROLES.ADMIN] || []);
    next.columns[ROLES.ADMIN] = clone(defaults.columns?.[ROLES.ADMIN] || []);
    next.attendanceGroups[ROLES.ADMIN] = clone(defaults.attendanceGroups?.[ROLES.ADMIN] || []);
    Object.keys(next.actions || {}).forEach((action) => {
      const shouldHave = (defaults.actions?.[action] || []).includes(ROLES.ADMIN);
      next.actions[action] = normalizeList(next.actions[action]).filter((item) => item !== ROLES.ADMIN);
      if (shouldHave) next.actions[action].push(ROLES.ADMIN);
    });
    nextLanding[ROLES.ADMIN] = 'dashboardView';

    manifest = next;
    landingViews = nextLanding;
    serverPayload = clone(payload);
    if (emit) dispatchChange('server');
    return true;
  }

  function dispatchChange(source = 'runtime') {
    window.dispatchEvent(new CustomEvent('lso:permissions-changed', {
      detail: {
        source,
        manifest: clone(manifest),
        landingViews: { ...landingViews },
        payload: clone(serverPayload)
      }
    }));
  }

  function canAccessView(viewId, account = currentAccount()) {
    return (manifest.views?.[role(account)] || []).includes(String(viewId || ''));
  }

  function can(action, account = currentAccount()) {
    return (manifest.actions?.[String(action || '')] || []).includes(role(account));
  }

  function canWriteColumn(column, account = currentAccount()) {
    return (manifest.columns?.[role(account)] || []).includes(String(column || ''));
  }

  function canUseAttendanceGroup(group, account = currentAccount()) {
    return (manifest.attendanceGroups?.[role(account)] || []).includes(String(group || ''));
  }

  function defaultAttendanceGroup(account = currentAccount()) {
    return (manifest.attendanceGroups?.[role(account)] || [])[0] || 'Official Members';
  }

  function defaultView(account = currentAccount()) {
    const roleName = role(account);
    const views = manifest.views?.[roleName] || [];
    const preferred = landingViews[roleName];
    return views.includes(preferred) ? preferred : (views[0] || (roleName === ROLES.TRAINEE ? 'dutyHoursView' : 'dashboardView'));
  }

  function roleDescription(account = currentAccount()) {
    const roleName = role(account);
    if (roleName === ROLES.ADMIN) return 'Administrator • Full Access';
    const count = (manifest.views?.[roleName] || []).length;
    return `${roleName} • ${count} assigned module${count === 1 ? '' : 's'}`;
  }

  function deniedMessage(action = '') {
    const roleName = role();
    const label = roleName || 'This account';
    if (action === 'attendanceGroup') return `${label} is not assigned to the selected Attendance calendar.`;
    return `${label} does not currently have permission to perform this action. Ask an Administrator to review the Role & Permission Center.`;
  }

  async function refreshFromServer({ quiet = true, force = false } = {}) {
    if (refreshing && !force) return false;
    const cloud = window.LSOCloud;
    if (!cloud?.getRolePermissionCenter || !cloud?.getSessionToken?.()) return false;
    refreshing = true;
    try {
      const payload = await cloud.getRolePermissionCenter();
      applyServerPayload(payload);
      return true;
    } catch (error) {
      // Compatibility fallback keeps login usable until migration 009 is installed.
      if (!quiet) window.LSOApp?.showToast?.(error.message || 'Role permissions could not be refreshed.', true);
      console.warn('Role permission center unavailable; using packaged defaults.', error);
      return false;
    } finally {
      refreshing = false;
    }
  }

  function startPolling() {
    stopPolling();
    refreshTimer = window.setInterval(() => {
      if (!document.hidden && window.LSOCurrentAccount) refreshFromServer({ quiet: true }).catch(() => undefined);
    }, 60000);
  }

  function stopPolling() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = null;
  }

  function reconcileCurrentView() {
    const account = currentAccount();
    if (!account) return;
    window.LSOPermissions?.apply?.();
    const roleLabel = document.getElementById('currentAccountRole');
    if (roleLabel) roleLabel.textContent = roleDescription(account);
    const active = document.querySelector('.view:not(.hidden), .view.active');
    if (active?.id && !canAccessView(active.id, account)) {
      window.LSOApp?.setView?.(defaultView(account));
    }
  }

  window.addEventListener('lso:permissions-changed', () => setTimeout(reconcileCurrentView, 0));
  window.addEventListener('lso:auth-changed', (event) => {
    if (event.detail) {
      startPolling();
      window.setTimeout(() => refreshFromServer({ quiet: true }).catch(() => undefined), 200);
    } else {
      stopPolling();
      resetRuntime({ emit: false });
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && window.LSOCurrentAccount) refreshFromServer({ quiet: true }).catch(() => undefined);
  });

  window.LSORoleAccess = {
    ROLES,
    role,
    currentAccount,
    canAccessView,
    can,
    canWriteColumn,
    canUseAttendanceGroup,
    defaultAttendanceGroup,
    defaultView,
    roleDescription,
    deniedMessage,
    viewsForRole: (account = currentAccount()) => [...(manifest.views?.[role(account)] || [])],
    permissionManifest: () => clone(manifest),
    landingManifest: () => ({ ...landingViews }),
    serverConfiguration: () => clone(serverPayload),
    applyServerPayload,
    refreshFromServer,
    resetRuntime
  };
})();
