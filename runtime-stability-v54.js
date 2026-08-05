(() => {
  'use strict';

  const timers = new Map();
  const frames = new Map();
  const pendingViews = new Map();
  const idleHandles = new Map();
  const raf = window.requestAnimationFrame?.bind(window) || ((callback) => window.setTimeout(callback, 16));
  const caf = window.cancelAnimationFrame?.bind(window) || window.clearTimeout.bind(window);
  const coarse = window.matchMedia?.('(pointer: coarse)')?.matches;
  const lowMemory = Number(navigator.deviceMemory || 8) <= 4;
  const lowCpu = Number(navigator.hardwareConcurrency || 8) <= 4;
  const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches;
  const constrained = Boolean(coarse || lowMemory || lowCpu || reducedMotion);

  document.documentElement.dataset.lsoPerformance = constrained ? 'constrained' : 'standard';

  const SETTINGS_KEY = 'lso_system_settings_v2';
  const STATUS_CODES = Object.freeze({ Present: 'P', Late: 'L', Absent: 'A', Excused: 'E' });

  function compactAttendanceSettings(settings) {
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) return { value: settings, changed: false };
    const governance = settings.attendancePeriodGovernance;
    if (!governance || !Array.isArray(governance.archives)) return { value: settings, changed: false };
    let changed = false;
    const archives = governance.archives.map((entry) => {
      const snapshot = entry?.snapshot;
      if (!snapshot || (!Array.isArray(snapshot.records) && !Array.isArray(snapshot.events))) return entry;
      const sourceEvents = Array.isArray(snapshot.events) ? snapshot.events : [];
      const sourceRecords = Array.isArray(snapshot.records) ? snapshot.records : [];
      const eventDirectory = [];
      const eventIndex = new Map();
      sourceEvents.forEach((event) => {
        const id = String(event?.id ?? '');
        if (!id || eventIndex.has(id)) return;
        eventIndex.set(id, eventDirectory.length);
        eventDirectory.push([id, String(event?.title || event?.name || 'Attendance activity'), String(event?.date || '')]);
      });
      const memberDirectory = [];
      const memberIndex = new Map();
      const remarksDirectory = [''];
      const remarksIndex = new Map([['', 0]]);
      const recordRows = [];
      sourceRecords.forEach((record) => {
        const eventId = String(record?.eventId ?? '');
        const memberId = String(record?.memberId ?? '');
        if (!eventId || !memberId) return;
        if (!eventIndex.has(eventId)) {
          eventIndex.set(eventId, eventDirectory.length);
          eventDirectory.push([eventId, String(record?.eventTitle || 'Attendance activity'), String(record?.eventDate || '')]);
        }
        if (!memberIndex.has(memberId)) {
          memberIndex.set(memberId, memberDirectory.length);
          memberDirectory.push([memberId, String(record?.memberName || memberId)]);
        }
        const remarks = String(record?.remarks || '');
        if (!remarksIndex.has(remarks)) {
          remarksIndex.set(remarks, remarksDirectory.length);
          remarksDirectory.push(remarks);
        }
        recordRows.push([eventIndex.get(eventId), memberIndex.get(memberId), STATUS_CODES[record?.status] || String(record?.status || ''), remarksIndex.get(remarks), record?.loaAutoExcused ? 1 : 0]);
      });
      const compactSnapshot = { ...snapshot, archiveFormat: 'compact-v1', eventDirectory, memberDirectory, remarksDirectory, recordRows, recordCount: Math.max(Number(snapshot.recordCount) || 0, recordRows.length) };
      delete compactSnapshot.events;
      delete compactSnapshot.records;
      changed = true;
      return { ...entry, snapshot: compactSnapshot, compactedAt: entry.compactedAt || new Date().toISOString() };
    });
    if (!changed) return { value: settings, changed: false };
    return { value: { ...settings, attendancePeriodGovernance: { ...governance, archives } }, changed: true };
  }

  function compactSettingsRaw(raw) {
    const text = String(raw || '');
    if (!text.includes('attendancePeriodGovernance') || !text.includes('\"records\"')) return { raw: text, changed: false };
    try {
      const parsed = JSON.parse(text);
      const compacted = compactAttendanceSettings(parsed);
      return compacted.changed ? { raw: JSON.stringify(compacted.value), changed: true } : { raw: text, changed: false };
    } catch {
      return { raw: text, changed: false };
    }
  }

  // Compact oversized legacy attendance archives before the rest of the app parses them.
  try {
    const existing = window.localStorage?.getItem(SETTINGS_KEY);
    if (existing) {
      const compacted = compactSettingsRaw(existing);
      if (compacted.changed) window.localStorage.setItem(SETTINGS_KEY, compacted.raw);
    }
  } catch { /* private browsing or storage quota can block local cache maintenance */ }

  function isViewActive(viewId) {
    if (!viewId) return true;
    const view = document.getElementById(viewId);
    return Boolean(view && view.classList.contains('active') && !view.classList.contains('hidden'));
  }

  function reportRuntimeError(key, error) {
    console.error(`[LSO runtime: ${key}]`, error);
    try {
      window.dispatchEvent(new CustomEvent('lso:runtime-error', {
        detail: { key, message: String(error?.message || error || 'Unknown runtime error') }
      }));
    } catch { /* reporting must never interrupt the interface */ }
  }

  function safeCall(key, callback) {
    try { callback(); }
    catch (error) { reportRuntimeError(key, error); }
  }

  function queueForView(viewId, key, callback) {
    if (!pendingViews.has(viewId)) pendingViews.set(viewId, new Map());
    pendingViews.get(viewId).set(key, callback);
  }

  function cancel(key) {
    const timer = timers.get(key);
    if (timer) clearTimeout(timer);
    timers.delete(key);
    const idleHandle = idleHandles.get(key);
    if (idleHandle) {
      if (typeof window.cancelIdleCallback === 'function') window.cancelIdleCallback(idleHandle);
      else clearTimeout(idleHandle);
    }
    idleHandles.delete(key);
    const frame = frames.get(key);
    if (frame) caf(frame);
    frames.delete(key);
    pendingViews.forEach((items, viewId) => {
      items.delete(key);
      if (!items.size) pendingViews.delete(viewId);
    });
  }

  function schedule(key, callback, delay = 60, options = {}) {
    const viewId = options.viewId || '';
    const force = Boolean(options.force);
    cancel(key);
    const adjustedDelay = constrained ? Math.max(delay, 90) : delay;
    const timer = window.setTimeout(() => {
      timers.delete(key);
      if (!force && viewId && !isViewActive(viewId)) {
        queueForView(viewId, key, callback);
        return;
      }
      const frame = raf(() => {
        frames.delete(key);
        safeCall(key, callback);
      });
      frames.set(key, frame);
    }, adjustedDelay);
    timers.set(key, timer);
  }

  function runIdle(key, callback, options = {}) {
    cancel(key);
    const viewId = options.viewId || '';
    const force = Boolean(options.force);
    const execute = () => {
      idleHandles.delete(key);
      if (!force && viewId && !isViewActive(viewId)) {
        queueForView(viewId, key, callback);
        return;
      }
      safeCall(key, callback);
    };
    if (typeof window.requestIdleCallback === 'function') {
      const handle = window.requestIdleCallback(execute, { timeout: options.timeout || 1200 });
      idleHandles.set(key, handle);
      return;
    }
    idleHandles.set(key, window.setTimeout(execute, constrained ? 180 : 80));
  }

  function flushView(viewId) {
    const pending = pendingViews.get(viewId);
    if (!pending?.size || !isViewActive(viewId)) return;
    pendingViews.delete(viewId);
    pending.forEach((callback, key) => schedule(key, callback, 0, { force: true }));
  }

  document.addEventListener('click', (event) => {
    const button = event.target.closest?.('[data-view]');
    if (!button?.dataset?.view) return;
    window.setTimeout(() => flushView(button.dataset.view), 0);
  }, true);

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    const active = document.querySelector('.view.active:not(.hidden)')?.id;
    if (active) flushView(active);
  });

  window.LSORuntimeStability = Object.freeze({
    constrained,
    isViewActive,
    schedule,
    runIdle,
    cancel,
    flushView,
    compactAttendanceSettings,
    compactSettingsRaw
  });
})();
