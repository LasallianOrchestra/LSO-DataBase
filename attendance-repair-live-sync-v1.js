(() => {
  'use strict';

  window.__LSO_ATTENDANCE_REPAIR_VERSION__ = 'attendance-live-sync-root-fix-v1';

  const EVENTS_KEY = 'lso_events_v2';
  const ATTENDANCE_KEY = 'lso_attendance_v2';

  const read = (key) => {
    try {
      const raw = window.LSOStorage?.getItem?.(key) ?? localStorage.getItem(key) ?? '[]';
      const data = JSON.parse(raw);
      return Array.isArray(data) ? data : [];
    } catch {
      return [];
    }
  };

  function patchOperations() {
    const ops = window.LSOOperations;
    if (!ops || ops.__attendanceRepairApplied) return Boolean(ops);

    const originalRefresh = ops.refreshAll;
    ops.getEvents = () => read(EVENTS_KEY);
    ops.getAttendance = () => read(ATTENDANCE_KEY);

    ops.refreshAll = (options = {}) => {
      const result = originalRefresh?.({ force: true, ...options });
      window.dispatchEvent(new CustomEvent('lso:attendance-live-refreshed', {
        detail: {
          events: read(EVENTS_KEY).length,
          attendance: read(ATTENDANCE_KEY).length,
          timestamp: new Date().toISOString()
        }
      }));
      return result;
    };

    ops.__attendanceRepairApplied = true;
    return true;
  }

  function install() {
    if (!patchOperations()) {
      setTimeout(install, 100);
      return;
    }

    [
      'lso:operations-changed',
      'lso:cloud-state-changed',
      'lso:members-changed',
      'lso:attendance-month-changed',
      'lso:attendance-group-changed',
      'lso:attendance-roster-mode-changed'
    ].forEach((eventName) => {
      window.addEventListener(eventName, () => {
        window.LSOOperations?.refreshAll?.({ force: true });
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }
})();
