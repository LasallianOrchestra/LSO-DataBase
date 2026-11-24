/*
 * LSO ACCESS CONTROL — REAL-TIME ROLE/PERMISSION SYNC (V89)
 * ---------------------------------------------------------
 * Supabase remains the single source of truth. This bridge keeps every open
 * session aligned with it by:
 *   1. polling the permission-center fingerprint frequently (and immediately
 *      on focus, visibility, reconnection and authentication changes);
 *   2. broadcasting local saves to other tabs of the same browser instantly;
 *   3. applying an Administrator's account-role change to an already signed-in
 *      user without requiring sign-out/sign-in;
 *   4. keeping the legacy Settings overlay path working on older databases.
 *
 * No credentials are stored here. The Supabase session token is read only from
 * the already authenticated cloud connector.
 */
(() => {
  'use strict';

  const VERSION = 'v89';
  const CHANNEL_NAME = 'lso-access-control-v89';
  const FAST_POLL_MS = 7000;
  const BACKGROUND_POLL_MS = 25000;
  const IDENTITY_FALLBACK_MS = 30000;
  const SESSION_KEY = 'lso_shared_session_v1';
  const ROLES = new Set(['Administrator','Membership','General Secretary','Staff Account','Trainee/Probationary']);

  let pollTimer = null;
  let identityTimer = null;
  let inFlight = null;
  let signature = '';
  let schemaVersion = 0;
  let lastIdentity = null;
  let lastSyncAt = '';
  let channel = null;

  function account() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function sessionToken() {
    return String(window.LSOCloud?.getSessionToken?.() || '');
  }

  function stable(value) {
    if (value === null || typeof value !== 'object') return value === undefined ? null : value;
    if (Array.isArray(value)) return value.map(stable);
    const result = {};
    Object.keys(value).sort().forEach((key) => {
      if (value[key] !== undefined) result[key] = stable(value[key]);
    });
    return result;
  }

  function identityFromPayload(payload) {
    const current = payload?.account || {};
    return {
      id: String(current.id || payload?.accountId || ''),
      role: String(current.role || payload?.accountRole || ''),
      username: String(current.username || ''),
      displayName: String(current.displayName || ''),
      approvalStatus: String(current.approvalStatus || ''),
      disabled: Boolean(current.disabled),
      updatedAt: String(current.updatedAt || payload?.accountRoleUpdatedAt || '')
    };
  }

  function signatureFor(payload) {
    if (!payload || !Array.isArray(payload.roles) || !payload.roles.length) return '';
    return JSON.stringify(stable({
      updatedAt: String(payload.updatedAt || ''),
      schemaVersion: Number(payload.schemaVersion || 0),
      permissionModel: String(payload.permissionModel || ''),
      identity: identityFromPayload(payload),
      roles: payload.roles
    }));
  }

  function persistAccount(nextAccount) {
    try {
      const stored = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null');
      if (stored && stored.token) {
        sessionStorage.setItem(SESSION_KEY, JSON.stringify({ ...stored, account: nextAccount }));
      }
    } catch { /* Browser storage can be blocked; the in-memory session still works. */ }
  }

  function applyIdentity(identity) {
    const current = account();
    if (!current || !identity.role || !ROLES.has(identity.role)) return false;
    // The server revision timestamp changes for ordinary profile edits too.
    // Only a security-relevant identity change may re-emit authentication.
    const unchanged = current.role === identity.role
      && Boolean(current.disabled) === identity.disabled
      && (!identity.approvalStatus || current.approvalStatus === identity.approvalStatus)
      && (!identity.username || current.username === identity.username)
      && (!identity.displayName || current.displayName === identity.displayName);
    if (unchanged) {
      lastIdentity = identity;
      return false;
    }

    const next = {
      ...current,
      role: identity.role,
      updatedAt: identity.updatedAt || current.updatedAt || '',
      displayName: identity.displayName || current.displayName,
      username: identity.username || current.username
    };
    if (identity.approvalStatus) next.approvalStatus = identity.approvalStatus;
    if (typeof identity.disabled === 'boolean') next.disabled = identity.disabled;

    window.LSOCurrentAccount = next;
    persistAccount(next);
    lastIdentity = identity;
    window.dispatchEvent(new CustomEvent('lso:auth-changed', { detail: next }));
    window.LSOApp?.showToast?.(`Access updated by Administrator: ${identity.role}.`);

    window.setTimeout(() => {
      window.LSOPermissions?.apply?.();
      const view = window.LSORoleAccess?.defaultView?.(next);
      if (view) window.LSOApp?.setView?.(view);
    }, 90);
    return true;
  }

  function broadcast(sig) {
    if (!channel || !sig) return;
    try { channel.postMessage({ type: 'permissions-updated', signature: sig, at: Date.now() }); }
    catch { /* Cross-tab messaging is an acceleration, not a requirement. */ }
  }

  function startTimers() {
    stopTimers();
    pollTimer = window.setInterval(() => {
      if (!sessionToken() || document.hidden) return;
      syncNow({ reason: 'interval' }).catch(() => undefined);
    }, FAST_POLL_MS);
    identityTimer = window.setInterval(() => {
      if (!sessionToken() || document.hidden || signature) return;
      // Older Supabase databases do not include the account identity in the
      // permission payload. Resume the session periodically in that case.
      refreshIdentityFallback().catch(() => undefined);
    }, IDENTITY_FALLBACK_MS);
  }

  function stopTimers() {
    if (pollTimer) clearInterval(pollTimer);
    if (identityTimer) clearInterval(identityTimer);
    pollTimer = null;
    identityTimer = null;
  }

  async function refreshIdentityFallback() {
    if (!sessionToken() || !window.LSOCloud?.resumeSession) return null;
    try {
      const result = await window.LSOCloud.resumeSession(sessionToken());
      if (!result?.ok || !result.account) return null;
      const identity = identityFromPayload({ account: result.account });
      applyIdentity(identity);
      return result;
    } catch { return null; }
  }

  async function runSync({ reason = 'poll', force = false } = {}) {
    if (!sessionToken() || !window.LSOCloud?.getRolePermissionCenter || !window.LSORoleAccess?.applyServerPayload) return null;
    if (inFlight && !force) return inFlight;

    const task = (async () => {
      const payload = await window.LSOCloud.getRolePermissionCenter();
      if (!payload || !Array.isArray(payload.roles) || !payload.roles.length) return null;

      const nextSignature = signatureFor(payload);
      const identity = identityFromPayload(payload);
      schemaVersion = Number(payload.schemaVersion || 0);
      lastIdentity = identity;
      lastSyncAt = new Date().toISOString();

      const identityChanged = applyIdentity(identity);
      if (nextSignature && nextSignature !== signature) {
        signature = nextSignature;
        window.LSORoleAccess.applyServerPayload(payload);
        broadcast(nextSignature);
      } else if (force && identityChanged) {
        window.LSORoleAccess.applyServerPayload(payload);
      }
      return payload;
    })().catch((error) => {
      if (reason === 'manual') console.warn('Role permission synchronization failed:', error);
      return null;
    }).finally(() => {
      inFlight = null;
    });

    inFlight = task;
    return task;
  }

  function syncNow(options = {}) {
    return runSync({ force: true, reason: options.reason || 'manual', ...options });
  }

  function initialize() {
    if (window.BroadcastChannel && !channel) {
      try {
        channel = new BroadcastChannel(CHANNEL_NAME);
        channel.addEventListener('message', (event) => {
          if (event.data?.type !== 'permissions-updated' || !sessionToken()) return;
          if (event.data.signature === signature) return;
          runSync({ reason: 'broadcast', force: true }).catch(() => undefined);
        });
      } catch { channel = null; }
    }

    window.addEventListener('lso:auth-changed', (event) => {
      if (!event.detail) {
        stopTimers();
        signature = '';
        schemaVersion = 0;
        lastIdentity = null;
        return;
      }
      startTimers();
      window.setTimeout(() => runSync({ reason: 'auth', force: true }).catch(() => undefined), 240);
    });

    // An Administrator saving in one tab updates the matrix and all other tabs
    // immediately; the fingerprint check prevents a broadcast echo.
    window.addEventListener('lso:permissions-changed', (event) => {
      const payload = event.detail?.payload;
      const nextSignature = signatureFor(payload);
      if (!nextSignature) return;
      if (nextSignature === signature) return;
      signature = nextSignature;
      schemaVersion = Number(payload.schemaVersion || 0);
      broadcast(nextSignature);
    });

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible' || !sessionToken()) return;
      startTimers();
      runSync({ reason: 'visible', force: true }).catch(() => undefined);
    });
    window.addEventListener('focus', () => {
      if (!sessionToken()) return;
      runSync({ reason: 'focus', force: true }).catch(() => undefined);
    });
    window.addEventListener('lso:connection-health', (event) => {
      if (event.detail?.state !== 'online' || !sessionToken()) return;
      runSync({ reason: 'reconnect', force: true }).catch(() => undefined);
    });
    window.addEventListener('lso:cloud-state-changed', (event) => {
      const keys = Array.isArray(event.detail?.keys) ? event.detail.keys : [event.detail?.key].filter(Boolean);
      if (!keys.includes('lso_system_settings_v2') || !sessionToken()) return;
      window.setTimeout(() => runSync({ reason: 'settings-overlay', force: true }).catch(() => undefined), 120);
    });

    window.LSORoleAccessSync = {
      VERSION,
      syncNow,
      snapshot: () => ({
        version: VERSION,
        schemaVersion,
        signature,
        identity: lastIdentity,
        lastSyncAt,
        syncing: Boolean(inFlight),
        polling: Boolean(pollTimer)
      })
    };

    if (account() && sessionToken()) {
      startTimers();
      window.setTimeout(() => runSync({ reason: 'startup', force: true }).catch(() => undefined), 180);
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
