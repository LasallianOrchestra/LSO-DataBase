/* ==========================================================================
   LSO shell layout contract — single source of truth (V75, audit fix F9).

   The CSS turns the sidebar into an off-canvas drawer and the shell into a
   single-column block layout inside:

       @media (max-width: 920px), (pointer: coarse) { ... }

   Every piece of layout JavaScript MUST consult this contract through
   `window.LSOShellLayout` instead of re-declaring its own matchMedia query.
   Before V75 the query was duplicated in auth.js,
   auth-view-controller-v18.js, ui-enhancements.js and
   mobile-shell-controller-v37.js — a stale width-only copy in
   auth-view-controller-v18.js silently overrode the fixed one and produced
   the F0 column-collapse defect on wide touch screens. Keeping the query,
   the MediaQueryList and the change-fan-out here means the four consumers
   can never drift apart again.

   Load order: this file must be included BEFORE auth-view-controller-v18.js
   (and therefore before auth.js / ui-enhancements.js /
   mobile-shell-controller-v37.js). Consumers still carry a defensive
   fallback in case the script fails to load.
   ========================================================================== */
(() => {
  'use strict';

  const QUERY = '(max-width: 920px), (pointer: coarse)';
  const media = window.matchMedia ? window.matchMedia(QUERY) : null;
  const subscribers = new Set();

  function notify() {
    const matches = Boolean(media && media.matches);
    subscribers.forEach((fn) => {
      try { fn(matches); } catch (_) { /* a broken subscriber must not kill the fan-out */ }
    });
  }

  if (media) {
    if (media.addEventListener) media.addEventListener('change', notify);
    else if (media.addListener) media.addListener(notify);
  }

  window.LSOShellLayout = {
    /** The media query that defines the mobile/drawer shell. Mirrors the CSS. */
    QUERY,
    /** The shared MediaQueryList (may be null on ancient engines). */
    media,
    /** True when the shell must render as the mobile/drawer layout. */
    isMobileShell() {
      return Boolean(media && media.matches);
    },
    /** Subscribe to contract flips (rotation, resize, pointer change).
        Returns an unsubscribe function. */
    onChange(fn) {
      if (typeof fn !== 'function') return () => {};
      subscribers.add(fn);
      return () => subscribers.delete(fn);
    }
  };
})();
