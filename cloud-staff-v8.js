(() => {
  'use strict';
  window.__LSO_CLOUD_SAVE_VERSION__ = 'v82-all-roles-supabase';

  const TABLE_ROW_ID = 1;
  const POLL_BASE_INTERVAL_MS = (() => {
    const coarse = window.matchMedia?.('(pointer: coarse)')?.matches;
    const lowConcurrency = Number(navigator.hardwareConcurrency || 8) <= 4;
    return coarse || lowConcurrency ? 12000 : 9000;
  })();
  const POLL_QUIET_INTERVAL_MS = (() => {
    const coarse = window.matchMedia?.('(pointer: coarse)')?.matches;
    const lowConcurrency = Number(navigator.hardwareConcurrency || 8) <= 4;
    return coarse || lowConcurrency ? 30000 : 22000;
  })();
  const CONNECTION_FAILURE_THRESHOLD = 2;
  const CONNECTION_RETRY_MAX_MS = 45000;
  const CONNECTION_RECOVERY_DEBOUNCE_MS = 650;
  const PENDING_KEY = 'lso_cloud_pending_v1';
  const MONTHLY_COMPAT_COLUMN = 'monthly_reports_compat';
  const MONTHLY_SETTINGS_KEY = '__lso_monthly_reports_v1';
  const MAINTENANCE_SETTINGS_KEY = 'maintenanceModeV61';
  // Legacy compatibility only: V82 Supabase supports Interview natively. The synchronized
  // Settings overlay is retained solely so the website can be deployed before the SQL patch
  // without losing an Interview grant. Once the server reports permission schema 13+, the
  // overlay is ignored and Supabase is the single source of truth.
  const PERMISSION_OVERLAY_SETTINGS_KEY = '__lso_role_permission_overlay_v79';
  const EXTENDED_PERMISSION_VIEWS = new Set(['interviewView']);
  const PERMISSION_ROLES = new Set(['Membership', 'General Secretary', 'Staff Account', 'Trainee/Probationary']);
  const ADMIN_OWNED_SETTINGS_KEYS = [MAINTENANCE_SETTINGS_KEY, PERMISSION_OVERLAY_SETTINGS_KEY];
  const KEY_TO_COLUMN = {
    lso_member_database_v1: 'members',
    lso_events_v2: 'events',
    lso_attendance_v2: 'attendance',
    lso_instruments_v2: 'instruments',
    lso_activity_log_v2: 'activity_log',
    lso_system_settings_v2: 'settings',
    lso_duty_hours_v1: 'duty_hours',
    lso_monthly_reports_v1: MONTHLY_COMPAT_COLUMN
  };
  const ARRAY_COLUMNS = new Set(['members', 'events', 'attendance', 'instruments', 'activity_log']);
  const OBJECT_COLUMNS = new Set(['settings', 'duty_hours', MONTHLY_COMPAT_COLUMN]);
  const nativeStorage = window.localStorage;
  const config = window.LSO_SUPABASE_CONFIG || {};
  const configured = Boolean(
    /^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(String(config.url || '').trim()) &&
    String(config.anonKey || '').trim().length > 20 &&
    !String(config.url).includes('PASTE_') &&
    !String(config.anonKey).includes('PASTE_')
  );

  let client = null;
  let sessionToken = '';
  let sessionAccount = null;
  let state = null;
  let loaded = false;
  let online = false;
  let lastServerUpdate = '';
  let pollTimer = null;
  let pollPromise = null;
  let unchangedPolls = 0;
  let flushTimer = null;
  let flushing = false;
  const dirtyVersions = new Map();
  const dirtyFingerprints = new Map();
  const serverFingerprints = new Map();
  const columnVersions = new Map();
  const conflicts = new Map();
  let lastSuccessfulSyncAt = '';
  let v69Capabilities = null;
  let v69MetaRetryAfter = 0;
  let lastStatusSignature = '';
  let lastStatusAt = 0;
  let connectionState = 'idle';
  let consecutiveTransportFailures = 0;
  let lastConnectionSuccessAt = '';
  let lastConnectionFailureAt = '';
  let lastConnectionError = '';
  let recoveryPromise = null;
  let recoveryTimer = null;
  const legacySnapshot = {};

  try {
    const pending = JSON.parse(nativeStorage.getItem(PENDING_KEY) || '[]');
    if (Array.isArray(pending)) pending.forEach((column) => {
      const normalizedColumn = column === 'monthly_reports' ? MONTHLY_COMPAT_COLUMN : column;
      if ([...ARRAY_COLUMNS, ...OBJECT_COLUMNS].includes(normalizedColumn)) dirtyVersions.set(normalizedColumn, 1);
    });
  } catch {
    // A malformed pending marker is ignored.
  }

  Object.keys(KEY_TO_COLUMN).forEach((key) => {
    try {
      const raw = nativeStorage.getItem(key);
      if (raw !== null) legacySnapshot[key] = raw;
    } catch {
      // A blocked local cache does not prevent the cloud connection itself.
    }
  });

  function emit(name, detail = {}) {
    window.dispatchEvent(new CustomEvent(name, { detail }));
  }

  function status(kind, message) {
    const signature = `${kind}::${message}`;
    const now = Date.now();
    if (signature === lastStatusSignature && now - lastStatusAt < 1200) return;
    lastStatusSignature = signature;
    lastStatusAt = now;
    emit('lso:cloud-status', { kind, message });
  }

  function transportMessage(error) {
    return String(error?.message || error?.details || error?.hint || error || 'Connection error');
  }

  function isTransportFailure(error) {
    if (error?.isTransportError === true) return true;
    const message = transportMessage(error);
    const statusCode = Number(error?.status || error?.statusCode || error?.code || 0);
    return navigator.onLine === false ||
      /failed to fetch|networkerror|network request failed|load failed|fetch failed|connection (?:reset|refused|closed)|timed? ?out|timeout|aborterror|dns|name resolution|gateway timeout|bad gateway|service unavailable/i.test(message) ||
      [502, 503, 504].includes(statusCode);
  }

  function markConnectionSuccess({ synchronized = false } = {}) {
    online = true;
    connectionState = 'online';
    consecutiveTransportFailures = 0;
    lastConnectionSuccessAt = new Date().toISOString();
    lastConnectionError = '';
    if (synchronized) lastSuccessfulSyncAt = lastConnectionSuccessAt;
  }

  function markConnectionFailure(error, { context = 'Shared database' } = {}) {
    if (error?.__lsoConnectionFailureRecorded) return;
    try { if (error && typeof error === 'object') error.__lsoConnectionFailureRecorded = true; } catch { /* non-extensible errors are still safe to classify */ }
    const message = transportMessage(error);
    lastConnectionFailureAt = new Date().toISOString();
    lastConnectionError = message;
    consecutiveTransportFailures += 1;
    const browserOffline = navigator.onLine === false;
    // Do not declare Offline on the first transient request failure, including during
    // startup before the first successful heartbeat. navigator.onLine=false is immediate
    // evidence; otherwise require the configured consecutive-failure threshold.
    const confirmedOffline = browserOffline || consecutiveTransportFailures >= CONNECTION_FAILURE_THRESHOLD;
    if (confirmedOffline) {
      online = false;
      connectionState = 'offline';
      status('offline', browserOffline ? 'Internet connection is offline. Shared changes remain queued.' : `${context} could not be reached. Reconnecting automatically…`);
    } else {
      // A single failed request is not enough evidence that the database is offline.
      // Keep the last known-good connection and retry so the UI does not flap Offline/Online.
      connectionState = 'reconnecting';
      status('syncing', 'Shared database connection is being verified…');
    }
    emit('lso:connection-health', getConnectionHealth());
  }

  function markApplicationSyncError(error, suffix = '') {
    const message = transportMessage(error);
    lastConnectionError = message;
    // A permission/schema/conflict response proves the server was reachable; do not call it offline.
    if (online || lastConnectionSuccessAt) {
      online = true;
      connectionState = 'online';
    }
    status('error', `${message}${suffix ? ` ${suffix}` : ''}`.trim());
    emit('lso:connection-health', getConnectionHealth());
  }

  function getConnectionHealth() {
    return {
      state: connectionState,
      online,
      browserOnline: navigator.onLine !== false,
      consecutiveFailures: consecutiveTransportFailures,
      lastSuccessAt: lastConnectionSuccessAt,
      lastFailureAt: lastConnectionFailureAt,
      lastError: lastConnectionError
    };
  }

  function retryDelay() {
    if (!consecutiveTransportFailures) return nextPollDelay();
    const multiplier = Math.min(4, Math.pow(2, Math.max(0, consecutiveTransportFailures - 1)));
    return Math.min(CONNECTION_RETRY_MAX_MS, POLL_BASE_INTERVAL_MS * multiplier);
  }

  function canWriteShared() {
    return sessionAccount?.role === 'Administrator';
  }

  function canWriteColumn(column) {
    if (!sessionAccount) return false;
    if (window.LSORoleAccess?.canWriteColumn) return window.LSORoleAccess.canWriteColumn(column, sessionAccount);
    return sessionAccount.role === 'Administrator';
  }

  function canReviewDutyPunches() {
    if (!sessionAccount) return false;
    if (window.LSORoleAccess?.can) return window.LSORoleAccess.can('reviewDutyPunches', sessionAccount);
    return ['Administrator', 'Membership', 'General Secretary', 'Staff Account'].includes(sessionAccount.role);
  }

  function canManageDutyHours() {
    if (!sessionAccount) return false;
    if (window.LSORoleAccess?.can) return window.LSORoleAccess.can('manageDutyHours', sessionAccount);
    return ['Administrator', 'Membership'].includes(sessionAccount.role);
  }

  function isTraineeAccount() {
    return sessionAccount?.role === 'Trainee/Probationary';
  }

  function emitReadOnlyDenied(column = '') {
    const role = sessionAccount?.role || 'Staff Account';
    const message = isTraineeAccount()
      ? 'Trainee/Probationary accounts may submit only their own Duty Hours punches.'
      : role === 'Membership'
        ? 'Membership access cannot save this system area.'
        : role === 'General Secretary'
          ? 'General Secretary access follows the permissions assigned by the Administrator.'
          : role === 'Staff Account'
            ? 'Staff access follows the permissions assigned by the Administrator.'
            : 'This account has read-only access.';
    emit('lso:permission-denied', { message, column });
  }

  function safeParse(raw, fallback) {
    try {
      const parsed = JSON.parse(raw);
      return parsed === null || parsed === undefined ? fallback : parsed;
    } catch {
      return fallback;
    }
  }

  function stableJsonValue(value, seen = new WeakSet()) {
    if (value === null || typeof value !== 'object') {
      if (typeof value === 'number' && !Number.isFinite(value)) return null;
      return value;
    }
    if (seen.has(value)) return '[Circular]';
    seen.add(value);
    if (Array.isArray(value)) {
      const normalized = value.map((item) => stableJsonValue(item, seen));
      seen.delete(value);
      return normalized;
    }
    const normalized = {};
    Object.keys(value).sort().forEach((key) => {
      const item = value[key];
      if (item === undefined || typeof item === 'function' || typeof item === 'symbol') return;
      normalized[key] = stableJsonValue(item, seen);
    });
    seen.delete(value);
    return normalized;
  }

  function stableSerialize(value) {
    try { return JSON.stringify(stableJsonValue(value)); }
    catch { return JSON.stringify(value); }
  }

  function semanticEqual(left, right) {
    if (left === right) return true;
    return stableSerialize(left) === stableSerialize(right);
  }

  function semanticRawEqual(leftRaw, rightRaw) {
    if (String(leftRaw ?? '') === String(rightRaw ?? '')) return true;
    try { return semanticEqual(JSON.parse(String(leftRaw ?? 'null')), JSON.parse(String(rightRaw ?? 'null'))); }
    catch { return false; }
  }

  function defaultForColumn(column) {
    return ARRAY_COLUMNS.has(column) ? [] : {};
  }

  function normalizeColumn(column, value) {
    if (ARRAY_COLUMNS.has(column)) return Array.isArray(value) ? value : [];
    if (OBJECT_COLUMNS.has(column)) return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    return {};
  }

  function getLocal(key) {
    try {
      return nativeStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function setLocal(key, value) {
    try {
      nativeStorage.setItem(key, String(value));
      return true;
    } catch {
      return false;
    }
  }

  function removeLocal(key) {
    try {
      nativeStorage.removeItem(key);
      return true;
    } catch {
      return false;
    }
  }

  function dispatchDomainChange(key, source = 'cloud', includeCloudState = true) {
    if (key === 'lso_member_database_v1') emit('lso:members-changed', { source });
    if (['lso_events_v2', 'lso_attendance_v2', 'lso_instruments_v2', 'lso_activity_log_v2', 'lso_system_settings_v2', 'lso_duty_hours_v1', 'lso_monthly_reports_v1'].includes(key)) {
      emit('lso:operations-changed', { key, source });
    }
    if (includeCloudState) emit('lso:cloud-state-changed', { key, keys: [key], source });
  }

  function compactSettingsValue(value) {
    const normalized = normalizeColumn('settings', value);
    try {
      const compacted = window.LSORuntimeStability?.compactAttendanceSettings?.(normalized);
      return compacted?.value && typeof compacted.value === 'object' ? compacted.value : normalized;
    } catch {
      return normalized;
    }
  }

  function stateColumn(stateObject, column) {
    if (!stateObject) return defaultForColumn(column);
    if (column === MONTHLY_COMPAT_COLUMN) {
      const settingsValue = stateObject.settings && typeof stateObject.settings === 'object' && !Array.isArray(stateObject.settings)
        ? stateObject.settings[MONTHLY_SETTINGS_KEY]
        : null;
      if (settingsValue && typeof settingsValue === 'object' && !Array.isArray(settingsValue)) {
        return normalizeColumn(column, settingsValue);
      }
      return normalizeColumn(column, stateObject.monthly_reports);
    }
    if (column === 'settings') {
      const settingsValue = normalizeColumn(column, stateObject.settings);
      const cleanSettings = { ...settingsValue };
      delete cleanSettings[MONTHLY_SETTINGS_KEY];
      return compactSettingsValue(cleanSettings);
    }
    return normalizeColumn(column, stateObject[column]);
  }

  function governanceEntryTimestamp(entry) {
    return Math.max(...[entry?.updatedAt, entry?.liveArchiveSyncedAt, entry?.compactedAt, entry?.reopenedAt, entry?.finalizedAt]
      .filter(Boolean).map((value) => Date.parse(value) || 0), 0);
  }

  function chooseNewerGovernanceEntry(localEntry, remoteEntry) {
    if (!localEntry) return { value: remoteEntry, localWon: false };
    if (!remoteEntry) return { value: localEntry, localWon: true };
    const localTime = governanceEntryTimestamp(localEntry);
    const remoteTime = governanceEntryTimestamp(remoteEntry);
    if (localTime !== remoteTime) return localTime > remoteTime
      ? { value: localEntry, localWon: true }
      : { value: remoteEntry, localWon: false };
    const localVersion = Math.max(Number(localEntry.stateVersion) || 0, Number(localEntry.revision) || 0);
    const remoteVersion = Math.max(Number(remoteEntry.stateVersion) || 0, Number(remoteEntry.revision) || 0);
    if (localVersion !== remoteVersion) return localVersion > remoteVersion
      ? { value: localEntry, localWon: true }
      : { value: remoteEntry, localWon: false };
    // A Finalized entry must not regress to a timestamp-less Draft due to a stale full-settings write.
    if (localEntry.state === 'Finalized' && remoteEntry.state !== 'Finalized' && !remoteEntry.reopenedAt && !remoteEntry.updatedAt) {
      return { value: localEntry, localWon: true };
    }
    return { value: remoteEntry, localWon: false };
  }

  function mergeGovernanceMap(localMap, remoteMap) {
    const result = {};
    let localWon = false;
    const keys = new Set([...Object.keys(localMap || {}), ...Object.keys(remoteMap || {})]);
    keys.forEach((key) => {
      const chosen = chooseNewerGovernanceEntry(localMap?.[key], remoteMap?.[key]);
      result[key] = chosen.value;
      localWon = localWon || chosen.localWon;
    });
    return { value: result, localWon };
  }

  function mergeAttendanceGovernance(localGovernance, remoteGovernance) {
    if (!localGovernance || typeof localGovernance !== 'object') return { value: remoteGovernance, localWon: false };
    if (!remoteGovernance || typeof remoteGovernance !== 'object') return { value: localGovernance, localWon: true };
    const months = mergeGovernanceMap(localGovernance.monthFinalizations, remoteGovernance.monthFinalizations);
    const semesters = mergeGovernanceMap(localGovernance.semesterFinalizations, remoteGovernance.semesterFinalizations);
    const endDateUpdates = mergeGovernanceMap(localGovernance.semesterEndDateUpdates, remoteGovernance.semesterEndDateUpdates);
    const semesterEndDates = { ...(remoteGovernance.semesterEndDates || {}) };
    Object.entries(endDateUpdates.value).forEach(([semester, meta]) => {
      if (meta?.value) semesterEndDates[semester] = meta.value;
    });

    const archiveMap = new Map();
    const archiveKey = (entry) => String(entry?.id || `${entry?.scopeKey || ''}::${entry?.revision || 0}::${entry?.finalizedAt || ''}`);
    [...(remoteGovernance.archives || []), ...(localGovernance.archives || [])].forEach((entry) => {
      if (!entry) return;
      const key = archiveKey(entry);
      const current = archiveMap.get(key);
      if (!current || governanceEntryTimestamp(entry) >= governanceEntryTimestamp(current)) archiveMap.set(key, entry);
    });
    const archives = [...archiveMap.values()].sort((a, b) => String(b?.finalizedAt || '').localeCompare(String(a?.finalizedAt || ''))).slice(0, 240);
    const localArchiveIds = new Set((localGovernance.archives || []).map(archiveKey));
    const remoteArchiveIds = new Set((remoteGovernance.archives || []).map(archiveKey));
    const remoteArchiveMap = new Map((remoteGovernance.archives || []).map((entry) => [archiveKey(entry), entry]));
    // Supabase stores JSON as jsonb and may return object keys in a different order. A plain
    // JSON.stringify comparison treated the same archive as different and re-queued Settings
    // after every poll. Only a genuinely missing or newer local archive now requires a push.
    const localArchiveWon = [...localArchiveIds].some((id) => !remoteArchiveIds.has(id)) ||
      (localGovernance.archives || []).some((entry) => {
        const remoteEntry = remoteArchiveMap.get(archiveKey(entry));
        if (!remoteEntry || semanticEqual(entry, remoteEntry)) return false;
        return governanceEntryTimestamp(entry) > governanceEntryTimestamp(remoteEntry);
      });

    const localUpdated = Date.parse(localGovernance.updatedAt || '') || 0;
    const remoteUpdated = Date.parse(remoteGovernance.updatedAt || '') || 0;
    const localWon = months.localWon || semesters.localWon || endDateUpdates.localWon || localArchiveWon;
    const base = localUpdated > remoteUpdated ? localGovernance : remoteGovernance;
    return {
      value: {
        ...base,
        version: Math.max(Number(localGovernance.version) || 1, Number(remoteGovernance.version) || 1),
        semesterEndDates,
        semesterEndDateUpdates: endDateUpdates.value,
        monthFinalizations: months.value,
        semesterFinalizations: semesters.value,
        archives,
        loaPolicyVersion: Math.max(Number(localGovernance.loaPolicyVersion) || 0, Number(remoteGovernance.loaPolicyVersion) || 0),
        updatedAt: localUpdated > remoteUpdated ? localGovernance.updatedAt : remoteGovernance.updatedAt,
        updatedBy: localUpdated > remoteUpdated ? localGovernance.updatedBy : remoteGovernance.updatedBy,
        mutationId: localUpdated > remoteUpdated ? localGovernance.mutationId : remoteGovernance.mutationId
      },
      localWon
    };
  }

  function mergeRemoteSettingsWithLocal(remoteSettings) {
    const remote = normalizeColumn('settings', remoteSettings);
    const local = normalizeColumn('settings', safeParse(getLocal('lso_system_settings_v2'), {}));
    const mergedGovernance = mergeAttendanceGovernance(local.attendancePeriodGovernance, remote.attendancePeriodGovernance);
    if (!mergedGovernance.value) return { value: remote, needsPush: false };
    return {
      value: { ...remote, attendancePeriodGovernance: mergedGovernance.value },
      needsPush: mergedGovernance.localWon
    };
  }

  function applyState(nextState, source = 'cloud') {
    if (!nextState || typeof nextState !== 'object') return;
    // Keep the in-memory cloud snapshot compact as well. Legacy archive payloads can be
    // several megabytes and cloning them after each update can freeze lower-power devices.
    state = {
      ...nextState,
      settings: compactSettingsValue(nextState.settings)
    };
    nextState = state;
    lastServerUpdate = String(nextState.updated_at || nextState.updatedAt || '');
    refreshColumnVersions(nextState);

    const changedKeys = [];
    let attendanceGovernanceNeedsPush = false;
    Object.entries(KEY_TO_COLUMN).forEach(([key, column]) => {
      let columnValue = stateColumn(nextState, column);
      if (column === 'settings') {
        const merged = mergeRemoteSettingsWithLocal(columnValue);
        columnValue = merged.value;
        attendanceGovernanceNeedsPush = attendanceGovernanceNeedsPush || merged.needsPush;
      }
      const remoteFingerprint = stableSerialize(serverPayloadForColumn(nextState, column));
      serverFingerprints.set(column, remoteFingerprint);

      // A pending marker can survive a closed tab even after the prior request reached the
      // server. Clear it as soon as the local and remote payloads are semantically identical.
      // For non-Administrator sessions, always accept the Administrator-owned maintenance
      // transaction before deciding whether an unrelated local settings edit remains pending.
      if (dirtyVersions.has(column)) {
        if (column === 'settings' && sessionAccount?.role !== 'Administrator') {
          try {
            const localSettings = normalizeColumn('settings', safeParse(getLocal('lso_system_settings_v2'), {}));
            const remoteSettings = normalizeColumn('settings', stateColumn(nextState, 'settings'));
            const protectedLocal = { ...localSettings };
            let protectedChanged = false;
            ADMIN_OWNED_SETTINGS_KEYS.forEach((protectedKey) => {
              if (remoteSettings?.[protectedKey] === undefined) return;
              if (stableSerialize(localSettings?.[protectedKey]) === stableSerialize(remoteSettings[protectedKey])) return;
              protectedLocal[protectedKey] = remoteSettings[protectedKey];
              protectedChanged = true;
            });
            if (protectedChanged && setLocal('lso_system_settings_v2', JSON.stringify(protectedLocal))) {
              changedKeys.push('lso_system_settings_v2');
              dispatchDomainChange('lso_system_settings_v2', source, false);
            }
          } catch { /* the standard reconciliation below remains available */ }
        }
        const localFingerprint = stableSerialize(payloadForColumn(column));
        const expectedFingerprint = dirtyFingerprints.get(column);
        if (localFingerprint === remoteFingerprint && (!expectedFingerprint || expectedFingerprint === localFingerprint)) {
          dirtyVersions.delete(column);
          dirtyFingerprints.delete(column);
          persistDirtyMarkers();
        } else {
          return;
        }
      }

      const serialized = JSON.stringify(columnValue);
      const currentRaw = storageGetItem(key);
      if (!semanticRawEqual(currentRaw, serialized)) {
        if (setLocal(key, serialized)) {
          changedKeys.push(key);
          dispatchDomainChange(key, source, false);
        } else {
          status('error', 'Browser storage is full or unavailable. Archived attendance was compacted, but this update could not be cached. Free browser site storage, then reload.');
          emit('lso:storage-error', { key, source, reason: 'write-failed' });
        }
      }
    });
    if (changedKeys.length) emit('lso:cloud-state-changed', { key: changedKeys.length === 1 ? changedKeys[0] : '', keys: changedKeys, source });
    if (attendanceGovernanceNeedsPush && sessionToken && canWriteColumn('settings')) {
      markDirty('settings', { delay: 320 });
    }

    loaded = true;
    // No module consumes a full state copy from this event. Emitting metadata prevents an
    // unnecessary deep clone of every member, attendance row, and archive after each sync.
    emit('lso:cloud-loaded', { source, keys: changedKeys, updatedAt: lastServerUpdate });
  }

  function cloneState() {
    return state ? JSON.parse(JSON.stringify(state)) : null;
  }

  function rpcErrorMessage(error) {
    const message = String(error?.message || error?.details || error?.hint || 'Unknown database error');
    if (/failed to fetch|networkerror|load failed/i.test(message)) {
      return 'The Supabase project could not be reached. Verify the Project URL, project status, and internet connection.';
    }
    if (/column [\"']?member_id[\"']? does not exist/i.test(message)) {
      return 'The account database is missing the member_id upgrade. Run LSO_MASTER_DATABASE_REPAIR.sql in Supabase SQL Editor, then refresh this page.';
    }
    if (/violates check constraint.*role|lso_accounts_role_check/i.test(message)) {
      return 'The account database still uses the old role list. Run LSO_MASTER_DATABASE_REPAIR.sql in Supabase SQL Editor, then refresh this page.';
    }
    if (/function .* does not exist|could not find the function|schema cache/i.test(message)) {
      return 'A required database function is missing. Apply the latest LSO Supabase migration; for this release run LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql, then refresh the page.';
    }
    if (/unsupported shared-data column/i.test(message)) {
      return 'The shared database is using an older schema. Monthly Report data will use compatibility storage automatically.';
    }
    if (/already linked to another active approved/i.test(message)) {
      return 'This member is already linked to another active approved Trainee/Probationary account.';
    }
    if (/overlaps an existing pending or approved duty entry/i.test(message)) {
      return 'This time overlaps an existing pending or approved duty entry for the same date.';
    }
    if (/already been reviewed/i.test(message)) {
      return 'This duty entry was already reviewed. Refresh the Duty Hours page to see its current status.';
    }
    if (/outside this member.*Trainee or Probationary period/i.test(message)) {
      return 'The selected date is outside the linked member’s Trainee or Probationary period.';
    }
    if (/future duty date/i.test(message)) {
      return 'A future duty date cannot be submitted.';
    }
    return message;
  }

  async function rpc(name, params = {}, options = {}) {
    if (!configured || !client) throw new Error('Supabase is not configured.');
    const { data, error } = await client.rpc(name, params);
    if (error) {
      const message = rpcErrorMessage(error);
      const technicalMessage = String(error?.message || error?.details || error?.hint || message);
      const sessionInvalid = /invalid or expired session|session expired|invalid session|expired token/i.test(`${message} ${technicalMessage}`);
      if (sessionInvalid) {
        // Session expiry is an authentication lifecycle event, not a database/system fault.
        // Include the token that caused the failure so a delayed response from an OLD
        // session cannot tear down a NEW login that has already succeeded.
        const failedToken = String(params?.p_token || '');
        // Only broadcast invalidation for the token that is CURRENTLY connected.
        // Expired resume attempts and delayed RPCs from a disconnected/older session
        // are handled by their caller and must not keep resetting the fresh Login form.
        const activeSessionToken = String(sessionToken || '');
        if (activeSessionToken && (!failedToken || failedToken === activeSessionToken)) {
          emit('lso:session-invalid', {
            message: 'Your session is no longer valid.',
            technicalMessage,
            token: failedToken || activeSessionToken,
            rpc: name
          });
        }
        const sessionError = new Error('Your previous session expired. Please log in again.');
        sessionError.code = 'AUTH_SESSION_INVALID';
        sessionError.rpc = name;
        sessionError.token = failedToken;
        throw sessionError;
      }
      const transportFailure = isTransportFailure(error) || /failed to fetch|networkerror|load failed|service unavailable|gateway timeout|bad gateway/i.test(technicalMessage);
      const missingFunction = /function .* does not exist|could not find the function|schema cache/i.test(technicalMessage);
      if (options?.optionalMissingRpc && missingFunction) {
        // Optional capability probe: the endpoint answered, so this is NOT a connection
        // failure and should not create a noisy System Error while deploy order catches up.
        markConnectionSuccess();
        const optionalError = new Error('Optional database capability is not installed yet.');
        optionalError.code = 'DB_OPTIONAL_RPC_MISSING';
        optionalError.rpc = name;
        optionalError.technicalMessage = technicalMessage;
        optionalError.isTransportError = false;
        throw optionalError;
      }
      const code = /migration|schema|column|function .*does not exist|schema cache/i.test(technicalMessage)
        ? (window.LSOSystemCore?.ERROR_CODES?.MIGRATION || 'DB-MIGRATION-004')
        : /permission|42501|access is required/i.test(technicalMessage)
          ? (window.LSOSystemCore?.ERROR_CODES?.PERMISSION || 'AUTH-PERMISSION-005')
          : transportFailure
            ? (window.LSOSystemCore?.ERROR_CODES?.NETWORK || 'NET-CONNECTION-001')
            : (window.LSOSystemCore?.ERROR_CODES?.UNKNOWN || 'SYS-UNEXPECTED-999');
      // A non-network PostgREST error still proves the Supabase endpoint answered.
      if (!transportFailure) markConnectionSuccess();
      emit('lso:system-error', { errorCode: code, module: 'Shared Database', publicMessage: message, technicalMessage, rpc: name, severity: 'error' });
      const wrapped = new Error(message);
      wrapped.code = code;
      wrapped.rpc = name;
      wrapped.status = error?.status || error?.statusCode || 0;
      wrapped.isTransportError = transportFailure;
      wrapped.technicalMessage = technicalMessage;
      throw wrapped;
    }
    markConnectionSuccess();
    return data;
  }

  function initClient() {
    if (!configured) {
      status('offline', 'Supabase configuration is missing or invalid');
      return null;
    }
    if (!window.supabase?.createClient) {
      status('offline', 'Supabase client library did not load');
      return null;
    }
    client = window.supabase.createClient(config.url, config.anonKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
      },
      global: {
        headers: { 'x-application-name': 'lso-orchestra-management' }
      }
    });
    return client;
  }

  function isMissingV82HealthRpc(error) {
    const raw = `${error?.technicalMessage || ''} ${error?.message || ''}`;
    return error?.rpc === 'lso_sync_health_v82' && /function .* does not exist|could not find the function|schema cache|required database function is missing/i.test(raw);
  }

  async function checkConnection({ quiet = false } = {}) {
    try {
      let result;
      // With an authenticated application session, verify the REAL LSO session + shared
      // state endpoint rather than a generic ping. This makes the status meaningful for all
      // roles and confirms the V82 permission/schema path is reachable. During deploy-order
      // compatibility, an older database simply falls back to lso_ping.
      if (sessionToken) {
        try {
          result = await rpc('lso_sync_health_v82', { p_token: sessionToken }, { optionalMissingRpc: true });
        } catch (error) {
          if (!isMissingV82HealthRpc(error)) throw error;
          result = await rpc('lso_ping');
        }
      } else {
        result = await rpc('lso_ping');
      }
      // Successful Supabase RPC execution proves reachability. Treat it as unavailable only
      // when the function explicitly returns false or an object whose `ok` value is false.
      const explicitlyUnavailable = result === false || Boolean(result && typeof result === 'object' && Object.prototype.hasOwnProperty.call(result, 'ok') && result.ok === false);
      if (!explicitlyUnavailable) {
        markConnectionSuccess();
        if (!quiet) status('online', 'Shared database connected');
        return true;
      }
      const unavailableError = new Error('Shared database health check explicitly reported unavailable.');
      unavailableError.isTransportError = true;
      markConnectionFailure(unavailableError, { context: 'Shared database' });
      return false;
    } catch (error) {
      if (isTransportFailure(error)) markConnectionFailure(error, { context: 'Shared database' });
      else markApplicationSyncError(error);
      throw error;
    }
  }

  function currentValueForColumn(column) {
    if (column === MONTHLY_COMPAT_COLUMN) {
      return normalizeColumn(column, safeParse(storageGetItem('lso_monthly_reports_v1'), {}));
    }
    const key = Object.keys(KEY_TO_COLUMN).find((item) => KEY_TO_COLUMN[item] === column);
    return normalizeColumn(column, safeParse(storageGetItem(key), defaultForColumn(column)));
  }

  function settingsPayloadWithMonthlyCompatibility() {
    return {
      ...currentValueForColumn('settings'),
      [MONTHLY_SETTINGS_KEY]: currentValueForColumn(MONTHLY_COMPAT_COLUMN)
    };
  }

  function serverPayloadForColumn(stateObject, column) {
    if (column === 'settings' || column === MONTHLY_COMPAT_COLUMN) {
      return {
        ...stateColumn(stateObject, 'settings'),
        [MONTHLY_SETTINGS_KEY]: stateColumn(stateObject, MONTHLY_COMPAT_COLUMN)
      };
    }
    return stateColumn(stateObject, column);
  }

  function refreshColumnVersions(stateObject) {
    const versions = stateObject?.column_versions || stateObject?.columnVersions || {};
    Object.entries(versions && typeof versions === 'object' ? versions : {}).forEach(([column, value]) => {
      const n = Number(value); if (Number.isFinite(n)) columnVersions.set(column, n);
    });
  }

  async function conflictAwareUpdate(column, value) {
    const expectedVersion = Number(columnVersions.get(column) || 0);
    if (!client) throw new Error('Supabase is not configured.');
    const params = { p_token: sessionToken, p_column: column, p_value: value, p_expected_version: expectedVersion };
    const response = await client.rpc('lso_update_state_v69', params);
    if (!response.error) { markConnectionSuccess(); v69Capabilities = { ...(v69Capabilities || {}), conflictProtection: true }; return response.data; }
    const raw = String(response.error?.message || response.error?.details || response.error?.hint || '');
    if (/LSO_CONFLICT:/i.test(raw)) {
      const error = new Error(raw); error.code = 'LSO_CONFLICT'; error.column = column; throw error;
    }
    if (/lso_update_state_v69|could not find the function|function .* does not exist|schema cache/i.test(raw)) {
      v69Capabilities = { ...(v69Capabilities || {}), conflictProtection: false };
      return rpc('lso_update_state', { p_token: sessionToken, p_column: column, p_value: value });
    }
    const wrapped = new Error(rpcErrorMessage(response.error));
    wrapped.isTransportError = isTransportFailure(response.error);
    wrapped.status = response.error?.status || response.error?.statusCode || 0;
    if (!wrapped.isTransportError) markConnectionSuccess();
    throw wrapped;
  }

  async function getStateMetaV69() {
    if (Date.now() < v69MetaRetryAfter) return null;
    try {
      const meta = await rpc('lso_get_state_meta_v69', { p_token: sessionToken });
      v69MetaRetryAfter = 0;
      if (meta?.columnVersions) refreshColumnVersions({ column_versions: meta.columnVersions });
      return meta;
    } catch {
      // Older databases do not have the V69 heartbeat. Avoid retrying the missing
      // RPC on every poll; a reload or the next five-minute compatibility retry
      // will detect a newly installed SQL patch.
      v69MetaRetryAfter = Date.now() + 300000;
      return null;
    }
  }

  function refreshServerFingerprints(stateObject) {
    if (!stateObject || typeof stateObject !== 'object') return;
    refreshColumnVersions(stateObject);
    const sharedSettingsFingerprint = stableSerialize(serverPayloadForColumn(stateObject, 'settings'));
    serverFingerprints.set('settings', sharedSettingsFingerprint);
    serverFingerprints.set(MONTHLY_COMPAT_COLUMN, sharedSettingsFingerprint);
    [...ARRAY_COLUMNS].forEach((column) => serverFingerprints.set(column, stableSerialize(stateColumn(stateObject, column))));
    [...OBJECT_COLUMNS].filter((column) => column !== 'settings' && column !== MONTHLY_COMPAT_COLUMN)
      .forEach((column) => serverFingerprints.set(column, stableSerialize(stateColumn(stateObject, column))));
  }

  function persistDirtyMarkers() {
    try {
      if (dirtyVersions.size) nativeStorage.setItem(PENDING_KEY, JSON.stringify([...dirtyVersions.keys()]));
      else nativeStorage.removeItem(PENDING_KEY);
    } catch {
      // Cloud saving can still continue if the pending marker cannot be stored.
    }
  }

  function scheduleFlush(delay = 180) {
    clearTimeout(flushTimer);
    flushTimer = setTimeout(() => flushDirty().catch(() => undefined), delay);
  }

  function payloadForColumn(column) {
    return column === MONTHLY_COMPAT_COLUMN || column === 'settings'
      ? settingsPayloadWithMonthlyCompatibility()
      : currentValueForColumn(column);
  }

  function markDirty(column, options = {}) {
    if (!canWriteColumn(column)) {
      emitReadOnlyDenied(column);
      return false;
    }
    const fingerprint = stableSerialize(payloadForColumn(column));
    if (serverFingerprints.get(column) === fingerprint) {
      dirtyVersions.delete(column);
      dirtyFingerprints.delete(column);
      persistDirtyMarkers();
      return false;
    }
    if (dirtyFingerprints.get(column) === fingerprint && dirtyVersions.has(column)) return false;
    dirtyFingerprints.set(column, fingerprint);
    dirtyVersions.set(column, (dirtyVersions.get(column) || 0) + 1);
    persistDirtyMarkers();
    scheduleFlush(Number(options.delay) >= 0 ? Number(options.delay) : 180);
    return true;
  }

  async function flushDirty() {
    if (flushing || !sessionToken || !dirtyVersions.size) return;
    // Never discard a queued change merely because the current permission manifest is
    // temporarily incomplete. V80 did this before flushing; an older permission payload
    // could therefore make a Membership edit disappear from the save queue. Unauthorized
    // writes are skipped and kept pending until permissions are refreshed or the user
    // deliberately changes/reloads the data.
    const blockedColumns = new Set([...dirtyVersions.keys()].filter((column) => !canWriteColumn(column)));
    // Remove stale pending markers that already match the last server state.
    for (const column of [...dirtyVersions.keys()]) {
      const fingerprint = stableSerialize(payloadForColumn(column));
      dirtyFingerprints.set(column, fingerprint);
      if (serverFingerprints.get(column) === fingerprint) {
        dirtyVersions.delete(column);
        dirtyFingerprints.delete(column);
      }
    }
    persistDirtyMarkers();
    if (!dirtyVersions.size) {
      status('online', 'All changes saved to the shared database');
      emit('lso:cloud-saved', { pending: 0 });
      return;
    }
    flushing = true;
    status('syncing', `Saving ${dirtyVersions.size} change${dirtyVersions.size === 1 ? '' : 's'}…`);

    try {
      for (const [column, version] of [...dirtyVersions.entries()]) {
        if (!dirtyVersions.has(column)) continue;
        if (blockedColumns.has(column)) continue;
        if (conflicts.has(column)) continue;
        const currentBeforeSend = stableSerialize(payloadForColumn(column));
        if (serverFingerprints.get(column) === currentBeforeSend) {
          dirtyVersions.delete(column);
          dirtyFingerprints.delete(column);
          persistDirtyMarkers();
          continue;
        }
        const serverColumn = column === MONTHLY_COMPAT_COLUMN ? 'settings' : column;
        const serverValue = payloadForColumn(column);
        const sentFingerprint = stableSerialize(serverValue);
        let nextState;
        try {
          nextState = await conflictAwareUpdate(serverColumn, serverValue);
        } catch (error) {
          if (error?.code === 'LSO_CONFLICT' || /LSO_CONFLICT:/i.test(String(error?.message || ''))) {
            const latest = await rpc('lso_get_state', { p_token: sessionToken });
            markConnectionSuccess({ synchronized: true });
            state = latest; lastServerUpdate = String(latest?.updated_at || '');
            refreshServerFingerprints(latest);
            conflicts.set(column, { column, serverColumn, localValue: serverValue, remoteValue: stateColumn(latest, serverColumn), detectedAt: new Date().toISOString(), remoteVersion: Number(columnVersions.get(serverColumn) || 0) });
            emit('lso:sync-conflict', { column, conflict: conflicts.get(column) });
            status('conflict', `A newer ${column.replace(/_/g,' ')} change exists in the shared database. Review the conflict before saving.`);
            continue;
          }
          throw error;
        }
        markConnectionSuccess({ synchronized: true });
        conflicts.delete(column);
        state = nextState;
        lastServerUpdate = String(nextState?.updated_at || '');
        refreshServerFingerprints(nextState);
        const currentFingerprint = stableSerialize(payloadForColumn(column));
        if (dirtyVersions.get(column) === version && currentFingerprint === sentFingerprint) {
          dirtyVersions.delete(column);
          dirtyFingerprints.delete(column);
          persistDirtyMarkers();
        }
      }
      applyState(state, 'cloud-save');
      if (conflicts.size) {
        status('conflict', `${conflicts.size} synchronization conflict${conflicts.size === 1 ? '' : 's'} require review.`);
      } else if (dirtyVersions.size) {
        const remaining = [...dirtyVersions.keys()];
        const blockedRemaining = remaining.filter((column) => !canWriteColumn(column));
        if (blockedRemaining.length === remaining.length) {
          status('error', `${remaining.length} pending change${remaining.length === 1 ? '' : 's'} waiting for role permission verification. The shared database remains online.`);
        } else {
          status('syncing', `Saving ${dirtyVersions.size} newer change${dirtyVersions.size === 1 ? '' : 's'}…`);
          scheduleFlush(220);
        }
      } else {
        lastSuccessfulSyncAt = new Date().toISOString();
        status('online', 'All changes saved to the shared database');
      }
      emit('lso:cloud-saved', { pending: dirtyVersions.size });
    } catch (error) {
      if (isTransportFailure(error)) markConnectionFailure(error, { context: 'Shared database save' });
      else markApplicationSyncError(error, 'Changes remain queued on this device.');
      scheduleFlush(Math.max(8000, retryDelay()));
      throw error;
    } finally {
      flushing = false;
    }
  }

  function storageGetItem(key) {
    const raw = getLocal(key);
    if (key !== 'lso_system_settings_v2' || !raw) return raw;
    try {
      const compacted = window.LSORuntimeStability?.compactSettingsRaw?.(raw);
      if (!compacted?.changed || !compacted.raw) return raw;
      // Return the compact value even when persistence is temporarily blocked so callers
      // do not repeatedly parse the legacy oversized archive payload in this session.
      setLocal(key, compacted.raw);
      return compacted.raw;
    } catch {
      return raw;
    }
  }

  function storageSetItem(key, value) {
    const column = KEY_TO_COLUMN[key];
    if (column && sessionToken && sessionAccount && !canWriteColumn(column)) {
      emitReadOnlyDenied(column);
      return false;
    }
    let nextValue = value;
    if (key === 'lso_system_settings_v2' && typeof value === 'string') {
      try {
        nextValue = window.LSORuntimeStability?.compactSettingsRaw?.(value)?.raw || value;
      } catch {
        nextValue = value;
      }
    }
    const currentValue = getLocal(key);
    // Administrator-owned settings must survive operational settings writes from other roles.
    // This protects both Maintenance Mode and the V79 permission-extension overlay from a
    // stale Membership/Secretary settings payload removing security configuration.
    if (key === 'lso_system_settings_v2' && sessionAccount?.role !== 'Administrator' && typeof nextValue === 'string') {
      try {
        const currentSettings = safeParse(currentValue, {});
        const requestedSettings = safeParse(nextValue, {});
        if (requestedSettings && typeof requestedSettings === 'object') {
          const protectedSettings = { ...requestedSettings };
          ADMIN_OWNED_SETTINGS_KEYS.forEach((protectedKey) => {
            if (currentSettings?.[protectedKey] !== undefined) protectedSettings[protectedKey] = currentSettings[protectedKey];
          });
          nextValue = JSON.stringify(protectedSettings);
        }
      } catch { /* malformed operational settings will be handled by the normal save path */ }
    }
    // Many modules defensively call save after rendering or reconciliation. Do not queue a
    // cloud write when the persisted JSON is already the same, including jsonb key reordering.
    if (semanticRawEqual(currentValue, nextValue)) return true;
    const saved = setLocal(key, nextValue);
    if (!saved) {
      status('error', 'This browser could not save the latest change because its site storage is full or blocked.');
      emit('lso:storage-error', { key, source: 'local-write', reason: 'write-failed' });
      return false;
    }
    emit('lso:storage-change', { key, before: currentValue, after: nextValue, source: 'local-write' });
    if (column && sessionToken && loaded) markDirty(column);
    return true;
  }

  function storageRemoveItem(key) {
    const column = KEY_TO_COLUMN[key];
    if (column && sessionToken && sessionAccount && !canWriteColumn(column)) {
      emitReadOnlyDenied(column);
      return false;
    }
    const before = getLocal(key);
    const removed = removeLocal(key);
    if (removed) emit('lso:storage-change', { key, before, after: column ? JSON.stringify(defaultForColumn(column)) : null, source: 'local-remove' });
    if (removed && column && sessionToken && loaded) {
      setLocal(key, JSON.stringify(defaultForColumn(column)));
      markDirty(column);
    }
    return removed;
  }

  async function loadSharedState({ quiet = false } = {}) {
    if (!sessionToken) throw new Error('No active shared-database session.');
    if (!quiet) status('syncing', 'Loading shared records…');
    const [nextState, meta] = await Promise.all([
      rpc('lso_get_state', { p_token: sessionToken }),
      getStateMetaV69()
    ]);
    if (meta?.columnVersions) nextState.column_versions = meta.columnVersions;
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'cloud');
    if ([...dirtyVersions.keys()].some((column) => canWriteColumn(column))) scheduleFlush(300);
    if (!quiet && !dirtyVersions.size) status('online', 'Shared database connected');
    return cloneState();
  }

  function buildLegacyState() {
    const result = {};
    let monthlyReports = {};
    Object.entries(KEY_TO_COLUMN).forEach(([key, column]) => {
      if (column === MONTHLY_COMPAT_COLUMN) {
        monthlyReports = normalizeColumn(column, safeParse(legacySnapshot[key], {}));
        return;
      }
      result[column] = normalizeColumn(column, safeParse(legacySnapshot[key], defaultForColumn(column)));
    });
    result.settings = { ...(result.settings || {}), [MONTHLY_SETTINGS_KEY]: monthlyReports };
    result.monthly_reports = monthlyReports;
    return result;
  }

  function hasMeaningfulData(candidate) {
    if (!candidate) return false;
    const duty = candidate.duty_hours && typeof candidate.duty_hours === 'object' ? candidate.duty_hours : {};
    const monthly = candidate.settings?.[MONTHLY_SETTINGS_KEY] && typeof candidate.settings[MONTHLY_SETTINGS_KEY] === 'object'
      ? candidate.settings[MONTHLY_SETTINGS_KEY]
      : (candidate.monthly_reports && typeof candidate.monthly_reports === 'object' ? candidate.monthly_reports : {});
    return ['members', 'events', 'attendance', 'instruments', 'activity_log']
      .some((column) => Array.isArray(candidate[column]) && candidate[column].length > 0) ||
      (candidate.settings && typeof candidate.settings === 'object' && Object.keys(candidate.settings).length > 0) ||
      (Array.isArray(duty.entries) && duty.entries.length > 0) ||
      (duty.commitments && typeof duty.commitments === 'object' && Object.keys(duty.commitments).length > 0) ||
      (monthly.reports && typeof monthly.reports === 'object' && Object.keys(monthly.reports).length > 0) ||
      (monthly.traineeFiles && typeof monthly.traineeFiles === 'object' && Object.keys(monthly.traineeFiles).length > 0);
  }

  function isCloudEmpty() {
    return !hasMeaningfulData(state);
  }

  async function migrateLegacyIfNeeded(isAdministrator = false) {
    if (!isAdministrator || !sessionToken || !isCloudEmpty()) return false;
    const legacy = buildLegacyState();
    if (!hasMeaningfulData(legacy)) return false;

    status('syncing', 'Moving existing browser records to the shared database…');
    const nextState = await rpc('lso_replace_state', {
      p_token: sessionToken,
      p_state: legacy
    });
    dirtyVersions.clear();
    dirtyFingerprints.clear();
    persistDirtyMarkers();
    applyState(nextState, 'migration');
    status('online', 'Existing records moved to the shared database');
    return true;
  }

  function nextPollDelay() {
    if (dirtyVersions.size) return POLL_BASE_INTERVAL_MS;
    return unchangedPolls >= 3 ? POLL_QUIET_INTERVAL_MS : POLL_BASE_INTERVAL_MS;
  }

  async function pollState() {
    if (!sessionToken || document.hidden) return false;
    // Focus, visibility restoration, and the scheduled timer can fire close together.
    // Reuse the active request instead of issuing overlapping lso_get_state RPC calls.
    if (pollPromise) return pollPromise;
    pollPromise = (async () => {
      try {
        const meta = await getStateMetaV69();
        const metaUpdated = String(meta?.updatedAt || meta?.updated_at || '');
        if (meta?.columnVersions) refreshColumnVersions({ column_versions: meta.columnVersions });
        if (metaUpdated && lastServerUpdate && metaUpdated === lastServerUpdate) {
          markConnectionSuccess({ synchronized: true }); unchangedPolls += 1;
          if (!dirtyVersions.size && !conflicts.size) status('online', 'Shared database connected');
          emit('lso:sync-heartbeat', { updatedAt: metaUpdated, changed: false });
          return false;
        }
        const nextState = await rpc('lso_get_state', { p_token: sessionToken });
        if (meta?.columnVersions) nextState.column_versions = meta.columnVersions;
        markConnectionSuccess({ synchronized: true });
        const nextUpdated = String(nextState?.updated_at || '');
        const changed = !lastServerUpdate || nextUpdated !== lastServerUpdate;
        if (changed) { unchangedPolls = 0; applyState(nextState, 'cloud-poll'); } else unchangedPolls += 1;
        if (!dirtyVersions.size && !conflicts.size) status('online', 'Shared database connected');
        emit('lso:sync-heartbeat', { updatedAt: nextUpdated, changed });
        return changed;
      } catch (error) {
        unchangedPolls = 0;
        if (isTransportFailure(error)) markConnectionFailure(error, { context: 'Shared database synchronization' });
        else markApplicationSyncError(error, 'Synchronization will retry automatically.');
        return false;
      } finally {
        pollPromise = null;
      }
    })();
    return pollPromise;
  }

  function scheduleNextPoll(delay = retryDelay()) {
    if (!sessionToken) return;
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(async () => {
      pollTimer = null;
      await pollState().catch(() => undefined);
      scheduleNextPoll();
    }, Math.max(1000, Number(delay) || POLL_BASE_INTERVAL_MS));
  }

  function startPolling() {
    stopPolling();
    unchangedPolls = 0;
    scheduleNextPoll(900);
  }

  function stopPolling() {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = null;
    unchangedPolls = 0;
  }

  function setSession(token, account = null) {
    sessionToken = String(token || '');
    sessionAccount = account || null;
    if (sessionToken) {
      startPolling();
      const role = sessionAccount?.role || 'Staff Account';
      if (online || lastConnectionSuccessAt) {
        markConnectionSuccess();
        status('online', role === 'Administrator'
          ? 'Shared database connected • Full access'
          : role === 'Membership'
            ? 'Shared database connected • Membership operations access'
            : role === 'General Secretary'
              ? 'Shared database connected • Attendance operations access'
              : isTraineeAccount()
                ? 'Shared database connected • Duty Hours submission access'
                : role === 'Staff Account'
                  ? 'Shared database connected • Attendance monitoring and Duty Hours review access'
                  : 'Shared database connected • Read-only access');
      } else {
        connectionState = 'checking';
        status('syncing', 'Verifying shared database connection…');
      }
    } else {
      stopPolling();
      connectionState = 'idle';
      online = false;
    }
  }

  window.addEventListener('focus', () => {
    if (!sessionToken || document.hidden) return;
    pollState().catch(() => undefined).finally(() => scheduleNextPoll());
  });
  document.addEventListener('visibilitychange', () => {
    if (!sessionToken) return;
    if (document.hidden) {
      if (pollTimer) clearTimeout(pollTimer);
      pollTimer = null;
      return;
    }
    pollState().catch(() => undefined).finally(() => scheduleNextPoll());
  });

  async function recoverConnection({ source = 'automatic', quiet = false } = {}) {
    if (recoveryPromise) return recoveryPromise;
    recoveryPromise = (async () => {
      if (navigator.onLine === false) {
        markConnectionFailure(new Error('Browser is offline.'), { context: 'Shared database' });
        return false;
      }
      connectionState = online ? 'reconnecting' : 'checking';
      if (!quiet) status('syncing', source === 'manual' ? 'Checking shared database connection…' : 'Reconnecting to the shared database…');
      try {
        const reachable = await checkConnection({ quiet: true });
        if (!reachable) return false;
        if (sessionToken) {
          try { await flushDirty(); } catch (error) { if (isTransportFailure(error)) throw error; }
          await pollState();
          scheduleNextPoll();
        }
        markConnectionSuccess();
        if (!quiet && !dirtyVersions.size && !conflicts.size) status('online', 'Shared database connected');
        return true;
      } catch (error) {
        if (isTransportFailure(error)) markConnectionFailure(error, { context: 'Shared database' });
        else markApplicationSyncError(error);
        return false;
      } finally {
        recoveryPromise = null;
      }
    })();
    return recoveryPromise;
  }

  async function disconnect({ remoteLogout = false } = {}) {
    stopPolling();
    clearTimeout(flushTimer);
    if (remoteLogout && sessionToken) {
      try { await rpc('lso_logout', { p_token: sessionToken }); } catch { /* Local sign-out still proceeds. */ }
    }
    sessionToken = '';
    sessionAccount = null;
    state = null;
    loaded = false;
    dirtyVersions.clear();
    dirtyFingerprints.clear();
    online = false;
    connectionState = 'idle';
    consecutiveTransportFailures = 0;
    status('offline', 'Signed out from the shared database');
  }


  async function registerAccount({ username, password, displayName, email }) {
    return rpc('lso_register_account', {
      p_username: username,
      p_password: password,
      p_display_name: displayName,
      p_contact_email: email || null
    });
  }

  async function login(username, password) {
    const result = await rpc('lso_login', { p_username: username, p_password: password });
    if (result?.ok && result.token) setSession(result.token, result.account || null);
    return result;
  }

  async function resumeSession(token) {
    const result = await rpc('lso_resume_session', { p_token: token });
    if (result?.ok) setSession(token, result.account || null);
    return result;
  }

  async function logout() {
    await disconnect({ remoteLogout: true });
  }

  async function listAccounts() {
    return rpc('lso_list_accounts', { p_token: sessionToken });
  }

  async function saveAccounts(accounts) {
    return rpc('lso_save_accounts', { p_token: sessionToken, p_accounts: accounts });
  }

  async function deleteAccount(accountId) {
    return rpc('lso_delete_account', { p_token: sessionToken, p_account_id: accountId });
  }


  async function submitDutyEntry({ semester, period, date, timeIn, timeOut, description }) {
    if (!isTraineeAccount()) throw new Error('Only a Trainee/Probationary account can use self-service duty submission.');
    const nextState = await rpc('lso_submit_duty_entry', {
      p_token: sessionToken,
      p_semester: semester,
      p_period: period,
      p_date: date,
      p_time_in: timeIn,
      p_time_out: timeOut,
      p_description: description || ''
    });
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'duty-submission');
    status('online', 'Duty entry submitted for administrator approval');
    return cloneState();
  }

  async function timeInDuty({ semester, description = '', memberApprovers = '' }) {
    if (!isTraineeAccount()) throw new Error('Only a Trainee/Probationary account can record Duty Hours.');
    if (!String(memberApprovers || '').trim()) throw new Error('Member/s Approved is required before submitting Time In.');
    const nextState = await rpc('lso_duty_time_in', {
      p_token: sessionToken,
      p_semester: semester,
      p_description: description || '',
      p_member_approvers: memberApprovers || ''
    });
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'duty-time-in');
    status('online', 'Duty Time In recorded');
    return cloneState();
  }

  async function timeOutDuty({ description = '', memberApprovers = '' } = {}) {
    if (!isTraineeAccount()) throw new Error('Only a Trainee/Probationary account can record Duty Hours.');
    if (!String(memberApprovers || '').trim()) throw new Error('Member/s Approved is required before submitting Time Out.');
    const nextState = await rpc('lso_duty_time_out', {
      p_token: sessionToken,
      p_description: description || '',
      p_member_approvers: memberApprovers || ''
    });
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'duty-time-out');
    status('online', 'Duty Time Out submitted for approval');
    return cloneState();
  }

  async function reviewDutyEntry(entryId, decision) {
    if (!canManageDutyHours()) throw new Error('This role is not assigned to manually manage legacy Duty Hours entries.');
    const nextState = await rpc('lso_review_duty_entry', {
      p_token: sessionToken,
      p_entry_id: entryId,
      p_decision: decision
    });
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'duty-review');
    status('online', 'Legacy duty entry review saved');
    return cloneState();
  }

  async function reviewDutyPunch(entryId, punchType, decision) {
    if (!canReviewDutyPunches()) throw new Error('This role is not assigned to review Duty Hours punches.');
    if (!['TimeIn', 'TimeOut'].includes(punchType)) throw new Error('Select a valid Time In or Time Out request.');
    const nextState = await rpc('lso_review_duty_punch', {
      p_token: sessionToken,
      p_entry_id: entryId,
      p_punch_type: punchType,
      p_decision: decision
    });
    markConnectionSuccess({ synchronized: true });
    applyState(nextState, 'duty-punch-review');
    status('online', `${punchType === 'TimeOut' ? 'Time Out' : 'Time In'} review saved`);
    return cloneState();
  }


  function uniquePermissionList(value) {
    return [...new Set((Array.isArray(value) ? value : []).map((item) => String(item || '').trim()).filter(Boolean))];
  }

  function readPermissionOverlay() {
    try {
      const settings = normalizeColumn('settings', safeParse(getLocal('lso_system_settings_v2'), {}));
      const raw = settings?.[PERMISSION_OVERLAY_SETTINGS_KEY];
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { version: 1, roles: {} };
      return {
        version: Math.max(1, Number(raw.version) || 1),
        updatedAt: String(raw.updatedAt || ''),
        updatedBy: String(raw.updatedBy || ''),
        roles: raw.roles && typeof raw.roles === 'object' && !Array.isArray(raw.roles) ? { ...raw.roles } : {}
      };
    } catch {
      return { version: 1, roles: {} };
    }
  }

  function mergePermissionOverlay(payload, overlay = readPermissionOverlay()) {
    if (!payload || typeof payload !== 'object') return payload;
    const next = JSON.parse(JSON.stringify(payload));
    if (!Array.isArray(next.roles)) next.roles = [];
    // V82+ stores Interview and derived write columns natively in Supabase. Never let a
    // stale V79 compatibility overlay override a server-authoritative grant or revocation.
    const nativePermissionModel = Number(next.schemaVersion || 0) >= 13 || String(next.permissionModel || '').toLowerCase() === 'v82';
    if (nativePermissionModel) return next;
    const roles = overlay?.roles && typeof overlay.roles === 'object' ? overlay.roles : {};
    Object.entries(roles).forEach(([roleName, rowOverlay]) => {
      if (!PERMISSION_ROLES.has(roleName) || !rowOverlay || typeof rowOverlay !== 'object') return;
      let row = next.roles.find((item) => String(item?.roleName || item?.role || '') === roleName);
      if (!row) {
        row = { roleName, landingView: '', views: [], actions: [], attendanceGroups: [] };
        next.roles.push(row);
      }
      if (Array.isArray(rowOverlay.views)) row.views = uniquePermissionList(rowOverlay.views);
      if (typeof rowOverlay.landingView === 'string') row.landingView = rowOverlay.landingView;
    });
    return next;
  }

  async function persistPermissionOverlay(roleName, { views, landingView, remove = false } = {}) {
    if (sessionAccount?.role !== 'Administrator') throw new Error('Administrator access is required to change role permissions.');
    if (!PERMISSION_ROLES.has(String(roleName || ''))) throw new Error('Select a supported non-Administrator role.');
    const settings = normalizeColumn('settings', safeParse(getLocal('lso_system_settings_v2'), {}));
    const overlay = readPermissionOverlay();
    const roles = { ...(overlay.roles || {}) };
    if (remove) delete roles[roleName];
    else {
      roles[roleName] = {
        views: uniquePermissionList(views),
        landingView: String(landingView || ''),
        updatedAt: new Date().toISOString()
      };
    }
    const nextOverlay = {
      version: 1,
      roles,
      updatedAt: new Date().toISOString(),
      updatedBy: String(sessionAccount?.displayName || sessionAccount?.username || 'Administrator')
    };
    const nextSettings = { ...settings, [PERMISSION_OVERLAY_SETTINGS_KEY]: nextOverlay };
    if (!storageSetItem('lso_system_settings_v2', JSON.stringify(nextSettings))) {
      throw new Error('The Interview permission could not be written to synchronized Settings. No permission update was confirmed.');
    }
    await flushDirty();
    if (dirtyVersions.has('settings') || conflicts.has('settings')) {
      throw new Error('The Interview permission is waiting for Settings synchronization. Resolve the shared-database sync issue, then save the role again.');
    }
    return nextOverlay;
  }

  async function getRolePermissionCenter() {
    const payload = await rpc('lso_get_permission_center', { p_token: sessionToken });
    return mergePermissionOverlay(payload);
  }

  async function saveRolePermissionCenter({ roleName, landingView, views = [], actions = [], attendanceGroups = [] } = {}) {
    if (sessionAccount?.role !== 'Administrator') throw new Error('Administrator access is required to change role permissions.');
    const requestedViews = uniquePermissionList(views);
    const requestedActions = uniquePermissionList(actions);
    const requestedGroups = uniquePermissionList(attendanceGroups);
    const requestedLanding = String(landingView || '');

    const saveParams = (serverViews, serverLanding) => ({
      p_token: sessionToken,
      p_role: roleName,
      p_landing_view: serverLanding,
      p_views: serverViews,
      p_actions: requestedActions,
      p_attendance_groups: requestedGroups
    });

    let serverPayload;
    try {
      // V82 path: send the exact Administrator selection, including Interview.
      serverPayload = await rpc('lso_save_role_permissions', saveParams(requestedViews, requestedLanding));
    } catch (error) {
      const needsInterviewCompatibility = requestedViews.some((viewId) => EXTENDED_PERMISSION_VIEWS.has(viewId)) || EXTENDED_PERMISSION_VIEWS.has(requestedLanding);
      const legacySchemaError = error?.code === (window.LSOSystemCore?.ERROR_CODES?.MIGRATION || 'DB-MIGRATION-004') || /landing page must be one of the assigned modules|required database function is missing|schema/i.test(String(error?.message || ''));
      if (!needsInterviewCompatibility || !legacySchemaError) throw error;

      // Deploy-order fallback for an older permission function that rejects/strips Interview.
      let legacyViews = requestedViews.filter((viewId) => !EXTENDED_PERMISSION_VIEWS.has(viewId));
      let legacyLanding = requestedLanding;
      if (!legacyViews.includes(legacyLanding)) legacyLanding = legacyViews[0] || '';
      if (!legacyViews.length) {
        legacyViews = ['dashboardView'];
        legacyLanding = 'dashboardView';
      }
      serverPayload = await rpc('lso_save_role_permissions', saveParams(legacyViews, legacyLanding));
    }

    const nativePermissionModel = Number(serverPayload?.schemaVersion || 0) >= 13 || String(serverPayload?.permissionModel || '').toLowerCase() === 'v82';
    if (nativePermissionModel) return serverPayload;

    // Legacy database only: keep the exact module/landing choice in synchronized Settings.
    // Actions still save through the legacy server function; role-access-v6 derives their
    // required write columns client-side until the V82 SQL patch is applied.
    const overlay = await persistPermissionOverlay(roleName, { views: requestedViews, landingView: requestedLanding });
    return mergePermissionOverlay(serverPayload, overlay);
  }

  async function resetRolePermissionCenter(roleName) {
    if (sessionAccount?.role !== 'Administrator') throw new Error('Administrator access is required to reset role permissions.');
    const serverPayload = await rpc('lso_reset_role_permissions', { p_token: sessionToken, p_role: roleName });
    const nativePermissionModel = Number(serverPayload?.schemaVersion || 0) >= 13 || String(serverPayload?.permissionModel || '').toLowerCase() === 'v82';
    if (nativePermissionModel) return serverPayload;
    const overlay = await persistPermissionOverlay(roleName, { remove: true });
    return mergePermissionOverlay(serverPayload, overlay);
  }

  async function getSystemHealth() {
    return rpc('lso_system_health', { p_token: sessionToken });
  }

  async function createRecoveryPoint({ label = 'Manual recovery point', reason = '', metadata = {} } = {}) {
    return rpc('lso_create_recovery_point', {
      p_token: sessionToken,
      p_label: label,
      p_reason: reason,
      p_metadata: metadata && typeof metadata === 'object' ? metadata : {}
    });
  }

  async function listRecoveryPoints() {
    return rpc('lso_list_recovery_points', { p_token: sessionToken });
  }

  async function restoreRecoveryPoint(recoveryId) {
    const nextState = await rpc('lso_restore_recovery_point', { p_token: sessionToken, p_recovery_id: recoveryId });
    dirtyVersions.clear();
    dirtyFingerprints.clear();
    persistDirtyMarkers();
    applyState(nextState, 'recovery-restore');
    status('online', 'Recovery point restored successfully');
    return cloneState();
  }

  async function deleteRecoveryPoint(recoveryId) {
    return rpc('lso_delete_recovery_point', { p_token: sessionToken, p_recovery_id: recoveryId });
  }

  async function logSystemError(payload = {}) {
    if (!sessionToken) return null;
    return rpc('lso_log_system_error', { p_token: sessionToken, p_error: payload });
  }

  async function listSystemErrors(limit = 100) {
    return rpc('lso_list_system_errors', { p_token: sessionToken, p_limit: limit });
  }

  async function resolveSystemError(errorId, note = '') {
    return rpc('lso_resolve_system_error', { p_token: sessionToken, p_error_id: errorId, p_note: note });
  }

  async function getCollectionPage(collection, offset = 0, limit = 25, search = '') {
    const safeOffset = Math.max(0, Number(offset) || 0), safeLimit = Math.max(1, Math.min(100, Number(limit) || 25));
    try {
      return await rpc('lso_get_collection_page_v69', { p_token: sessionToken, p_collection: collection, p_offset: safeOffset, p_limit: safeLimit, p_search: String(search || '') });
    } catch (error) {
      const value = collection === 'duty_entries' ? (currentValueForColumn('duty_hours')?.entries || []) : currentValueForColumn(collection);
      const list = Array.isArray(value) ? value : []; const q = String(search || '').trim().toLowerCase();
      const filtered = q ? list.filter((item) => stableSerialize(item).toLowerCase().includes(q)) : list;
      return { items: filtered.slice(safeOffset, safeOffset + safeLimit), total: filtered.length, offset: safeOffset, limit: safeLimit, fallback: true };
    }
  }
  async function getV69Capabilities() {
    try {
      v69Capabilities = await rpc('lso_v69_capabilities', { p_token: sessionToken });
      if (v69Capabilities?.installed) v69MetaRetryAfter = 0;
    } catch { v69Capabilities = { installed: false, conflictProtection: false, serverPagination: false, notificationPreferences: false }; }
    return { ...(v69Capabilities || {}) };
  }
  async function getNotificationPreferences() { try { return await rpc('lso_get_notification_preferences_v69', { p_token: sessionToken }); } catch { return null; } }
  async function saveNotificationPreferences(prefs) { return rpc('lso_save_notification_preferences_v69', { p_token: sessionToken, p_preferences: prefs || {} }); }
  async function saveRoleNotificationPreferences(roleName, prefs) { return rpc('lso_save_role_notification_preferences_v69', { p_token: sessionToken, p_role: roleName, p_preferences: prefs || {} }); }
  async function resolveSyncConflict(column, resolution = 'remote') {
    const conflict = conflicts.get(column); if (!conflict) return false;
    if (resolution === 'remote') {
      dirtyVersions.delete(column); dirtyFingerprints.delete(column); persistDirtyMarkers(); conflicts.delete(column);
      const latest = await rpc('lso_get_state', { p_token: sessionToken }); applyState(latest, 'conflict-remote');
      emit('lso:sync-conflict-resolved', { column, resolution: 'remote' }); return true;
    }
    if (resolution === 'local') {
      columnVersions.set(conflict.serverColumn || column, Number(conflict.remoteVersion || columnVersions.get(conflict.serverColumn || column) || 0));
      conflicts.delete(column); markDirty(column, { delay: 0 }); await flushDirty();
      emit('lso:sync-conflict-resolved', { column, resolution: 'local' }); return !conflicts.has(column);
    }
    return false;
  }
  function syncSnapshot() { const pending = [...dirtyVersions.keys()]; return { online, connectionState, browserOnline: navigator.onLine !== false, consecutiveTransportFailures, lastConnectionSuccessAt, lastConnectionFailureAt, lastConnectionError, loaded, pending, blockedPending: pending.filter((column) => !canWriteColumn(column)), conflicts: [...conflicts.values()].map((item) => ({ ...item })), lastServerUpdate, lastSuccessfulSyncAt, columnVersions: Object.fromEntries(columnVersions) }; }

  window.__LSO_STORAGE_CHANGE_EVENTS__ = 'v61';

  window.LSOStorage = {
    getItem: storageGetItem,
    setItem: storageSetItem,
    removeItem: storageRemoveItem
  };

  window.LSOCloud = {
    client: initClient(),
    isConfigured: () => configured,
    isLoaded: () => loaded,
    isOnline: () => online,
    isTrialMode: () => false,
    getItem: storageGetItem,
    setItem: storageSetItem,
    removeItem: storageRemoveItem,
    checkConnection,
    recoverConnection,
    getConnectionHealth,
    registerAccount,
    login,
    resumeSession,
    logout,
    disconnect,
    setSession,
    getSessionToken: () => sessionToken,
    getSessionAccount: () => sessionAccount ? { ...sessionAccount } : null,
    loadSharedState,
    cloneState,
    hasLegacyData: () => hasMeaningfulData(buildLegacyState()),
    isCloudEmpty,
    migrateLegacyIfNeeded,
    listProfiles: listAccounts,
    getOwnProfile: async () => sessionAccount,
    updateProfiles: saveAccounts,
    deleteAccount,
    saveAccounts,
    submitDutyEntry,
    timeInDuty,
    timeOutDuty,
    reviewDutyEntry,
    reviewDutyPunch,
    getRolePermissionCenter,
    saveRolePermissionCenter,
    resetRolePermissionCenter,
    getPermissionCompatibilitySnapshot: () => ({ overlay: readPermissionOverlay(), extendedViews: [...EXTENDED_PERMISSION_VIEWS] }),
    getSystemHealth,
    createRecoveryPoint,
    listRecoveryPoints,
    restoreRecoveryPoint,
    deleteRecoveryPoint,
    logSystemError,
    listSystemErrors,
    resolveSystemError,
    flush: flushDirty,
    getPendingChanges: () => [...dirtyVersions.keys()],
    pollNow: pollState,
    canWrite: canWriteColumn,
    canReviewDuty: canReviewDutyPunches,
    getCollectionPage,
    getV69Capabilities,
    getNotificationPreferences,
    saveNotificationPreferences,
    saveRoleNotificationPreferences,
    getSyncSnapshot: syncSnapshot,
    getConflicts: () => [...conflicts.values()].map((item) => ({ ...item })),
    resolveSyncConflict
  };

  window.addEventListener('online', () => {
    clearTimeout(recoveryTimer);
    recoveryTimer = setTimeout(() => recoverConnection({ source: 'browser-online', quiet: true }).catch(() => undefined), CONNECTION_RECOVERY_DEBOUNCE_MS);
  });

  window.addEventListener('offline', () => {
    clearTimeout(recoveryTimer);
    recoveryTimer = null;
    consecutiveTransportFailures = Math.max(CONNECTION_FAILURE_THRESHOLD, consecutiveTransportFailures + 1);
    markConnectionFailure(new Error('Browser is offline.'), { context: 'Shared database' });
  });


  window.addEventListener('lso:permissions-changed', () => {
    if (!sessionToken || !dirtyVersions.size) return;
    scheduleFlush(80);
  });

  window.addEventListener('beforeunload', () => {
    if (dirtyVersions.size) flushDirty().catch(() => undefined);
  });

  if (!configured) status('offline', 'Supabase configuration is missing or invalid');
  else if (!client) status('offline', 'Supabase client library did not load');
  else status('syncing', 'Ready to connect to the shared database');
})();
