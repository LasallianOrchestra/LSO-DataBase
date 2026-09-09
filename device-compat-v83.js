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
    const ios = /iP(hone|ad|od)/.test(navigator.userAgent) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    body.dataset.lsoCoarse = coarse ? 'true' : 'false';
    body.dataset.lsoNarrow = narrow ? 'true' : 'false';
    body.dataset.lsoIos = ios ? 'true' : 'false';
    if (ios) body.classList.add('lso-ios');
  }

  document.addEventListener('gesturestart', (event) => {
    if (event.touches && event.touches.length > 1) event.preventDefault();
  }, { passive: false });

  function wire() {
    markDevice();
    setViewportVars();
    window.addEventListener('resize', () => { markDevice(); setViewportVars(); }, { passive: true });
    window.addEventListener('orientationchange', () => setTimeout(() => { markDevice(); setViewportVars(); }, 200), { passive: true });
    window.visualViewport?.addEventListener('resize', setViewportVars, { passive: true });
    window.visualViewport?.addEventListener('scroll', setViewportVars, { passive: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire, { once: true });
  else wire();
})();
