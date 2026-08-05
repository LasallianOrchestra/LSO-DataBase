(() => {
  'use strict';

  const TABLE_ROW_ID = 1;
  const POLL_INTERVAL_MS = (() => {
    const coarse = window.matchMedia?.('(pointer: coarse)')?.matches;
    const lowConcurrency = Number(navigator.hardwareConcurrency || 8) <= 4;
    return coarse || lowConcurrency ? 10000 : 7000;
  })();
  const PENDING_KEY = 'lso_cloud_pending_v1';
  const MONTHLY_COMPAT_COLUMN = 'monthly_reports_compat';
  const MONTHLY_SETTINGS_KEY = '__lso_monthly_reports_v1';
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
  let flushTimer = null;
  let flushing = false;
  const dirtyVersions = new Map();
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
    emit('lso:cloud-status', { kind, message });
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
    const localArchiveWon = [...localArchiveIds].some((id) => !remoteArchiveIds.has(id)) ||
      (localGovernance.archives || []).some((entry) => {
        const remoteEntry = remoteArchiveMap.get(archiveKey(entry));
        return remoteEntry && governanceEntryTimestamp(entry) >= governanceEntryTimestamp(remoteEntry) && JSON.stringify(entry) !== JSON.stringify(remoteEntry);
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

    const changedKeys = [];
    let attendanceGovernanceNeedsPush = false;
    Object.entries(KEY_TO_COLUMN).forEach(([key, column]) => {
      if (dirtyVersions.has(column)) return;
      let columnValue = stateColumn(nextState, column);
      if (column === 'settings') {
        const merged = mergeRemoteSettingsWithLocal(columnValue);
        columnValue = merged.value;
        attendanceGovernanceNeedsPush = attendanceGovernanceNeedsPush || merged.needsPush;
      }
      const serialized = JSON.stringify(columnValue);
      if (storageGetItem(key) !== serialized) {
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
      dirtyVersions.set('settings', (dirtyVersions.get('settings') || 0) + 1);
      persistDirtyMarkers();
      scheduleFlush(320);
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
      return 'The required database functions are missing. Run URGENT_MEMBER_ID_APPROVAL_FIX.sql in the Supabase SQL Editor, then refresh this page.';
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

  async function rpc(name, params = {}) {
    if (!configured || !client) throw new Error('Supabase is not configured.');
    const { data, error } = await client.rpc(name, params);
    if (error) {
      const message = rpcErrorMessage(error);
      const technicalMessage = String(error?.message || error?.details || error?.hint || message);
      const code = /migration|schema|column|function .*does not exist|schema cache/i.test(technicalMessage)
        ? (window.LSOSystemCore?.ERROR_CODES?.MIGRATION || 'DB-MIGRATION-004')
        : /permission|42501|access is required/i.test(technicalMessage)
          ? (window.LSOSystemCore?.ERROR_CODES?.PERMISSION || 'AUTH-PERMISSION-005')
          : /failed to fetch|networkerror|load failed/i.test(technicalMessage)
            ? (window.LSOSystemCore?.ERROR_CODES?.NETWORK || 'NET-CONNECTION-001')
            : (window.LSOSystemCore?.ERROR_CODES?.UNKNOWN || 'SYS-UNEXPECTED-999');
      emit('lso:system-error', { errorCode: code, module: 'Shared Database', publicMessage: message, technicalMessage, rpc: name, severity: 'error' });
      if (/invalid or expired session/i.test(message)) emit('lso:session-invalid', { message });
      throw new Error(message);
    }
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

  async function checkConnection() {
    try {
      const result = await rpc('lso_ping');
      online = Boolean(result?.ok);
      status(online ? 'online' : 'offline', online ? 'Shared database connected' : 'Shared database unavailable');
      return online;
    } catch (error) {
      online = false;
      status('offline', error.message);
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

  function markDirty(column) {
    if (!canWriteColumn(column)) {
      emitReadOnlyDenied(column);
      return;
    }
    dirtyVersions.set(column, (dirtyVersions.get(column) || 0) + 1);
    persistDirtyMarkers();
    scheduleFlush();
  }

  async function flushDirty() {
    if (flushing || !sessionToken || !dirtyVersions.size) return;
    for (const column of [...dirtyVersions.keys()]) {
      if (!canWriteColumn(column)) dirtyVersions.delete(column);
    }
    persistDirtyMarkers();
    if (!dirtyVersions.size) return;
    flushing = true;
    status('syncing', `Saving ${dirtyVersions.size} change${dirtyVersions.size === 1 ? '' : 's'}…`);

    try {
      for (const [column, version] of [...dirtyVersions.entries()]) {
        const serverColumn = column === MONTHLY_COMPAT_COLUMN ? 'settings' : column;
        const serverValue = column === MONTHLY_COMPAT_COLUMN || column === 'settings'
          ? settingsPayloadWithMonthlyCompatibility()
          : currentValueForColumn(column);
        const nextState = await rpc('lso_update_state', {
          p_token: sessionToken,
          p_column: serverColumn,
          p_value: serverValue
        });
        online = true;
        state = nextState;
        lastServerUpdate = String(nextState?.updated_at || '');
        if (dirtyVersions.get(column) === version) {
          dirtyVersions.delete(column);
          persistDirtyMarkers();
        }
      }
      applyState(state, 'cloud-save');
      status('online', 'All changes saved to the shared database');
      emit('lso:cloud-saved', { pending: dirtyVersions.size });
    } catch (error) {
      online = false;
      status('offline', `${error.message} Changes remain queued on this device.`);
      scheduleFlush(5000);
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
    const saved = setLocal(key, nextValue);
    if (!saved) {
      status('error', 'This browser could not save the latest change because its site storage is full or blocked.');
      emit('lso:storage-error', { key, source: 'local-write', reason: 'write-failed' });
      return false;
    }
    if (column && sessionToken && loaded) markDirty(column);
    return true;
  }

  function storageRemoveItem(key) {
    const column = KEY_TO_COLUMN[key];
    if (column && sessionToken && sessionAccount && !canWriteColumn(column)) {
      emitReadOnlyDenied(column);
      return false;
    }
    const removed = removeLocal(key);
    if (removed && column && sessionToken && loaded) {
      setLocal(key, JSON.stringify(defaultForColumn(column)));
      markDirty(column);
    }
    return removed;
  }

  async function loadSharedState({ quiet = false } = {}) {
    if (!sessionToken) throw new Error('No active shared-database session.');
    if (!quiet) status('syncing', 'Loading shared records…');
    const nextState = await rpc('lso_get_state', { p_token: sessionToken });
    online = true;
    applyState(nextState, 'cloud');
    if (!quiet) status('online', 'Shared database connected');
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
    persistDirtyMarkers();
    applyState(nextState, 'migration');
    status('online', 'Existing records moved to the shared database');
    return true;
  }

  async function pollState() {
    if (!sessionToken || document.hidden) return;
    try {
      const nextState = await rpc('lso_get_state', { p_token: sessionToken });
      online = true;
      const nextUpdated = String(nextState?.updated_at || '');
      if (!lastServerUpdate || nextUpdated !== lastServerUpdate) applyState(nextState, 'cloud-poll');
      if (!dirtyVersions.size) status('online', 'Shared database connected');
    } catch (error) {
      online = false;
      status('offline', `${error.message} Reconnecting automatically…`);
    }
  }

  function startPolling() {
    stopPolling();
    pollTimer = setInterval(() => pollState().catch(() => undefined), POLL_INTERVAL_MS);
  }

  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }

  function setSession(token, account = null) {
    sessionToken = String(token || '');
    sessionAccount = account || null;
    if (sessionToken) {
      startPolling();
      if ([...dirtyVersions.keys()].some((column) => canWriteColumn(column))) scheduleFlush(500);
      const role = sessionAccount?.role || 'Staff Account';
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
    } else stopPolling();
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
    online = true;
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
    online = true;
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
    online = true;
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
    online = true;
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
    online = true;
    applyState(nextState, 'duty-punch-review');
    status('online', `${punchType === 'TimeOut' ? 'Time Out' : 'Time In'} review saved`);
    return cloneState();
  }


  async function getRolePermissionCenter() {
    return rpc('lso_get_permission_center', { p_token: sessionToken });
  }

  async function saveRolePermissionCenter({ roleName, landingView, views = [], actions = [], attendanceGroups = [] } = {}) {
    if (sessionAccount?.role !== 'Administrator') throw new Error('Administrator access is required to change role permissions.');
    return rpc('lso_save_role_permissions', {
      p_token: sessionToken,
      p_role: roleName,
      p_landing_view: landingView,
      p_views: Array.isArray(views) ? views : [],
      p_actions: Array.isArray(actions) ? actions : [],
      p_attendance_groups: Array.isArray(attendanceGroups) ? attendanceGroups : []
    });
  }

  async function resetRolePermissionCenter(roleName) {
    if (sessionAccount?.role !== 'Administrator') throw new Error('Administrator access is required to reset role permissions.');
    return rpc('lso_reset_role_permissions', { p_token: sessionToken, p_role: roleName });
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
    getSystemHealth,
    createRecoveryPoint,
    listRecoveryPoints,
    restoreRecoveryPoint,
    deleteRecoveryPoint,
    logSystemError,
    listSystemErrors,
    resolveSystemError,
    flush: flushDirty,
    pollNow: pollState,
    canWrite: canWriteColumn,
    canReviewDuty: canReviewDutyPunches
  };

  window.addEventListener('online', () => {
    if (!sessionToken) return;
    checkConnection()
      .then(() => flushDirty())
      .then(() => pollState())
      .catch(() => undefined);
  });

  window.addEventListener('beforeunload', () => {
    if (dirtyVersions.size) flushDirty().catch(() => undefined);
  });

  if (!configured) status('offline', 'Supabase configuration is missing or invalid');
  else if (!client) status('offline', 'Supabase client library did not load');
  else status('syncing', 'Ready to connect to the shared database');
})();
