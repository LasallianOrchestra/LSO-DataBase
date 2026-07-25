'use strict';

function lsoRequestAttendanceRefreshV25() {
  try {
    if (window.LSOAttendanceMonthWorkspace?.refresh) {
      window.LSOAttendanceMonthWorkspace.refresh();
      return true;
    }
    window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request'));
    return true;
  } catch (error) {
    console.warn('LSO attendance compatibility refresh was deferred:', error);
    return false;
  }
}

// A top-level var creates the classic-script global binding required by an
// obsolete cached workflow-attendance-month-v2.js that calls renderAll().
var renderAll = typeof window.renderAll === 'function'
  ? window.renderAll
  : lsoRequestAttendanceRefreshV25;
window.renderAll = renderAll;

(() => {
  const STALE_ERROR = /renderAll is not defined/i;

  window.addEventListener('error', (event) => {
    const message = String(event?.message || event?.error?.message || '');
    const source = String(event?.filename || event?.error?.stack || '');
    if (!STALE_ERROR.test(message) || !/workflow-attendance-month-v2\.js/i.test(source)) return;
    event.preventDefault?.();
    console.warn('Recovered from an obsolete cached attendance workflow.');
    lsoRequestAttendanceRefreshV25();
    document.getElementById('systemErrorDialog')?.classList.add('hidden');
  }, true);

  window.LSORenderCompatibility = Object.freeze({
    version: 'v25',
    refreshAttendance: lsoRequestAttendanceRefreshV25
  });
})();
