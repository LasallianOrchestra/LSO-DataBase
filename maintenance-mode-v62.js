(() => {
  'use strict';

  const VERSION = '6.2.0';
  const SETTINGS_KEY = 'lso_system_settings_v2';
  const FIELD = 'maintenanceModeV61';
  const DEFAULT_MESSAGE = 'The LSO system is temporarily unavailable while an Administrator performs maintenance.';
  const CHANNEL_NAME = 'lso-maintenance-v62';
  const el = (id) => document.getElementById(id);
  let blocked = false;
  let adminPreview = false;
  let restoreViewId = '';
  let channel = null;
  let lastAppliedSignature = '';
  let saveInFlight = null;

  function account() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function isAdministrator(subject = account()) {
    return subject?.role === 'Administrator';
  }

  function canManageSettings(subject = account()) {
    if (!subject || !isAdministrator(subject)) return false;
    return window.LSORoleAccess?.can?.('manageSettings', subject) ?? true;
  }

  function parseSettings() {
    try {
      const raw = window.LSOStorage?.getItem?.(SETTINGS_KEY) ?? window.localStorage?.getItem?.(SETTINGS_KEY) ?? '{}';
      const parsed = JSON.parse(raw || '{}');
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }

  function normalize(value) {
    const source = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    return {
      enabled: Boolean(source.enabled),
      message: String(source.message || '').trim() || DEFAULT_MESSAGE,
      expectedResume: String(source.expectedResume || '').trim(),
      updatedAt: String(source.updatedAt || ''),
      updatedBy: String(source.updatedBy || ''),
      mutationId: String(source.mutationId || ''),
      version: Number(source.version) || 1
    };
  }

  function getSettings() {
    return normalize(parseSettings()[FIELD]);
  }

  function shouldBlockAccount(subject = account(), settings = getSettings()) {
    return Boolean(subject && settings.enabled && subject.role !== 'Administrator');
  }

  function activeViewId() {
    return document.querySelector('.view.active:not(.hidden)')?.id || document.querySelector('.view:not(.hidden)')?.id || '';
  }

  function setShellLock(lock) {
    const shell = el('appShell');
    if (!shell) return;
    if (lock) {
      if (!restoreViewId) restoreViewId = activeViewId();
      shell.dataset.maintenanceLocked = 'true';
      shell.setAttribute('inert', '');
      shell.setAttribute('aria-hidden', 'true');
      shell.style.setProperty('pointer-events', 'none', 'important');
      shell.style.setProperty('user-select', 'none', 'important');
      shell.style.setProperty('visibility', 'hidden', 'important');
      shell.style.setProperty('content-visibility', 'hidden', 'important');
    } else if (shell.dataset.maintenanceLocked === 'true') {
      delete shell.dataset.maintenanceLocked;
      if (document.body?.dataset.authenticated === 'true') {
        shell.removeAttribute('inert');
        shell.setAttribute('aria-hidden', 'false');
        shell.style.setProperty('visibility', 'visible', 'important');
        shell.style.setProperty('content-visibility', 'visible', 'important');
      } else {
        shell.setAttribute('inert', '');
        shell.setAttribute('aria-hidden', 'true');
      }
      shell.style.removeProperty('pointer-events');
      shell.style.removeProperty('user-select');
    }
  }

  function setOverlay(lock, settings) {
    const overlay = el('maintenanceModeOverlay');
    if (!overlay) return;
    const show = Boolean(lock || adminPreview);
    overlay.hidden = !show;
    overlay.classList.toggle('hidden', !show);
    overlay.setAttribute('aria-hidden', String(!show));
    overlay.dataset.preview = adminPreview ? 'true' : 'false';
    const message = el('maintenanceOverlayMessage');
    if (message) message.textContent = settings.message;
    const resume = el('maintenanceOverlayResume');
    if (resume) resume.textContent = settings.expectedResume ? `Expected availability: ${settings.expectedResume}` : 'Please try again after maintenance is completed.';
    el('maintenanceModeLogoutButton')?.classList.toggle('hidden', adminPreview);
    el('maintenanceModeRefreshButton')?.classList.toggle('hidden', adminPreview);
    el('maintenanceModeExitPreviewButton')?.classList.toggle('hidden', !adminPreview);
  }

  function restoreAfterUnlock() {
    const subject = account();
    if (!subject || document.body?.dataset.authenticated !== 'true') { restoreViewId = ''; return; }
    const roleAccess = window.LSORoleAccess;
    const candidate = restoreViewId && (roleAccess?.canAccessView?.(restoreViewId, subject) ?? true)
      ? restoreViewId
      : (roleAccess?.defaultView?.(subject) || (subject.role === 'Trainee/Probationary' ? 'dutyHoursView' : 'dashboardView'));
    restoreViewId = '';
    window.LSOApp?.setView?.(candidate);
  }

  function apply(options = {}) {
    const settings = getSettings();
    const subject = options.account || account();
    const nextBlocked = shouldBlockAccount(subject, settings);
    const wasBlocked = blocked;
    blocked = nextBlocked;

    document.body?.classList.toggle('lso-maintenance-locked', blocked);
    if (document.body) document.body.dataset.maintenanceMode = settings.enabled ? 'active' : 'off';
    if (document.body) document.body.dataset.maintenanceBlocked = blocked ? 'true' : 'false';
    setShellLock(blocked);
    setOverlay(blocked, settings);

    const badge = el('maintenanceAdminBadge');
    if (badge) {
      const showBadge = settings.enabled && isAdministrator(subject) && !adminPreview;
      badge.classList.toggle('hidden', !showBadge);
      badge.textContent = showBadge ? 'Maintenance Mode Active • Administrators only' : '';
    }

    if (blocked) {
      document.body?.classList.remove('sidebar-open');
      el('sidebar')?.classList.remove('open');
      try { el('maintenanceModeOverlay')?.focus?.({ preventScroll: true }); } catch { /* older browsers */ }
    } else if (wasBlocked && !adminPreview) {
      restoreAfterUnlock();
    }

    const signature = `${settings.enabled}|${settings.updatedAt}|${settings.mutationId}|${subject?.role || ''}|${blocked}|${adminPreview}`;
    if (signature !== lastAppliedSignature) {
      lastAppliedSignature = signature;
      window.dispatchEvent(new CustomEvent('lso:maintenance-applied', { detail: { blocked, settings, role: subject?.role || '' } }));
    }
    return { blocked, settings };
  }

  function isBlocking(subject = account()) {
    return shouldBlockAccount(subject) && !isAdministrator(subject);
  }

  function pendingSettingsSave() {
    const pending = window.LSOCloud?.getPendingChanges?.() || [];
    return Array.isArray(pending) && pending.includes('settings');
  }

  function delay(ms) { return new Promise((resolve) => window.setTimeout(resolve, ms)); }

  async function flushAndVerify(mutationId, enabled) {
    const cloud = window.LSOCloud;
    if (!cloud?.getSessionToken?.()) return { verified: false, reason: 'No active shared-database session.' };
    let lastError = null;
    for (let attempt = 0; attempt < 12; attempt += 1) {
      try { await cloud.flush?.(); } catch (error) { lastError = error; }
      if (!pendingSettingsSave()) break;
      await delay(Math.min(700, 100 + attempt * 60));
    }
    if (pendingSettingsSave()) return { verified: false, reason: lastError?.message || 'The maintenance change is still queued for the shared database.' };
    try {
      await cloud.loadSharedState?.({ quiet: true });
    } catch (error) {
      return { verified: false, reason: error?.message || 'The shared maintenance status could not be reloaded.' };
    }
    const remoteEcho = getSettings();
    const verified = remoteEcho.mutationId === mutationId && remoteEcho.enabled === Boolean(enabled);
    return { verified, reason: verified ? '' : 'The shared database did not return the same maintenance transaction.', settings: remoteEcho };
  }

  async function save(input = {}) {
    if (!canManageSettings()) throw new Error('Administrator settings access is required.');
    if (saveInFlight) return saveInFlight;
    saveInFlight = (async () => {
      const all = parseSettings();
      const enabled = Boolean(input.enabled);
      const message = String(input.message || '').trim() || DEFAULT_MESSAGE;
      const expectedResume = String(input.expectedResume || '').trim();
      const mutationId = window.crypto?.randomUUID?.() || `maintenance-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      const nextMaintenance = {
        enabled,
        message,
        expectedResume,
        updatedAt: new Date().toISOString(),
        updatedBy: account()?.username || account()?.displayName || 'Administrator',
        mutationId,
        version: 2
      };
      const saved = window.LSOStorage?.setItem?.(SETTINGS_KEY, JSON.stringify({ ...all, [FIELD]: nextMaintenance }));
      if (saved === false) throw new Error('This browser could not store the maintenance change. Check browser storage and try again.');
      apply();
      broadcast(nextMaintenance);
      window.dispatchEvent(new CustomEvent('lso:maintenance-mode-changed', { detail: nextMaintenance }));
      const verification = await flushAndVerify(mutationId, enabled);
      apply();
      return { settings: getSettings(), verified: verification.verified, reason: verification.reason || '' };
    })().finally(() => { saveInFlight = null; });
    return saveInFlight;
  }

  async function refresh() {
    try { await window.LSOCloud?.pollNow?.(); } catch { /* local state remains authoritative until the next successful poll */ }
    return apply();
  }

  function preview() {
    if (!isAdministrator()) return false;
    adminPreview = true;
    setOverlay(false, getSettings());
    document.body?.classList.add('lso-maintenance-preview');
    return true;
  }

  function exitPreview() {
    adminPreview = false;
    document.body?.classList.remove('lso-maintenance-preview');
    apply();
  }

  function broadcast(settings) {
    try { channel?.postMessage?.({ type: 'maintenance', settings }); } catch { /* optional */ }
  }

  function wireCrossTab() {
    if ('BroadcastChannel' in window) {
      try {
        channel = new BroadcastChannel(CHANNEL_NAME);
        channel.addEventListener('message', (event) => { if (event.data?.type === 'maintenance') refresh().catch(() => apply()); });
      } catch { channel = null; }
    }
    window.addEventListener('storage', (event) => {
      if (event.key === SETTINGS_KEY) apply();
    });
  }

  function wireUi() {
    el('maintenanceModeRefreshButton')?.addEventListener('click', async () => {
      const button = el('maintenanceModeRefreshButton');
      if (button) button.disabled = true;
      try { await refresh(); }
      finally { if (button) button.disabled = false; }
    });
    el('maintenanceModeExitPreviewButton')?.addEventListener('click', exitPreview);
    el('previewMaintenanceModeButton')?.addEventListener('click', preview);
  }

  window.addEventListener('lso:auth-changed', () => window.setTimeout(apply, 0));
  window.addEventListener('lso:cloud-state-changed', (event) => {
    const keys = Array.isArray(event.detail?.keys) ? event.detail.keys : [event.detail?.key].filter(Boolean);
    if (!keys.length || keys.includes(SETTINGS_KEY)) apply();
  });
  window.addEventListener('lso:cloud-loaded', apply);
  window.addEventListener('focus', () => { if (account()) refresh().catch(() => apply()); });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && account()) refresh().catch(() => apply()); });

  wireCrossTab();
  wireUi();

  window.LSOMaintenanceV62 = {
    VERSION,
    getSettings,
    shouldBlockAccount,
    isBlocking,
    apply,
    save,
    refresh,
    preview,
    exitPreview
  };

  apply();
})();
