(() => {
  'use strict';

  const root = document.documentElement;
  const body = document.body;

  function setViewportVars() {
    const vv = window.visualViewport;
    const height = Math.round(vv?.height || window.innerHeight || root.clientHeight || 0);
    const inner = Math.round(window.innerHeight || height);
    const keyboard = Math.max(0, inner - height - (vv?.offsetTop || 0));
    root.style.setProperty('--lso-vvh', `${Math.max(280, height)}px`);
    root.style.setProperty('--lso-keyboard', `${keyboard}px`);
    body.classList.toggle('lso-keyboard-open', keyboard > 80);
  }

  function markDevice() {
    const coarse = window.matchMedia('(pointer: coarse)').matches;
    const narrow = window.matchMedia('(max-width: 920px)').matches;
    const wide = window.matchMedia('(min-width: 1367px)').matches;
    const ios = /iP(hone|ad|od)/.test(navigator.userAgent) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    body.dataset.lsoCoarse = coarse ? 'true' : 'false';
    body.dataset.lsoNarrow = narrow ? 'true' : 'false';
    body.dataset.lsoIos = ios ? 'true' : 'false';
    /* Touch tablet held wide enough to keep the two-track grid shell -- this is
       the band where the main column was being lost. */
    body.dataset.lsoTablet = (coarse && !narrow && !wide) ? 'true' : 'false';
    if (ios) body.classList.add('lso-ios');
  }

  /* Belt-and-braces companion to the `grid-template-areas` rules in
     device-compat-v83.css. Inline placement always wins over a stylesheet, so
     even a stale cached bundle cannot let .main-content be auto-placed into the
     sidebar track while the sidebar and its overlay sit out of flow. */
  function pinShellGrid() {
    const shell = document.getElementById('appShell');
    const main = shell?.querySelector(':scope > .main-content');
    if (!shell || !main) return;

    const gridded = window.getComputedStyle(shell).display === 'grid';
    if (gridded) {
      if (main.style.gridColumn !== '2') main.style.gridColumn = '2';
      if (main.style.gridRow !== '1') main.style.gridRow = '1';
    } else {
      main.style.removeProperty('grid-column');
      main.style.removeProperty('grid-row');
    }
  }

  document.addEventListener('gesturestart', (event) => {
    if (event.touches && event.touches.length > 1) event.preventDefault();
  }, { passive: false });

  function wire() {
    markDevice();
    setViewportVars();
    pinShellGrid();
    window.addEventListener('resize', () => { markDevice(); setViewportVars(); pinShellGrid(); }, { passive: true });
    window.addEventListener('orientationchange', () => setTimeout(() => { markDevice(); setViewportVars(); pinShellGrid(); }, 200), { passive: true });
    window.visualViewport?.addEventListener('resize', setViewportVars, { passive: true });
    window.visualViewport?.addEventListener('scroll', setViewportVars, { passive: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire, { once: true });
  else wire();

  window.LSODeviceCompat = Object.freeze({ pinShellGrid, markDevice, setViewportVars });
})();
