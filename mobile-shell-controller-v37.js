(() => {
  'use strict';

  const MOBILE = window.matchMedia('(max-width: 920px)');
  const COARSE = window.matchMedia('(pointer: coarse)');
  const body = document.body;
  const root = document.documentElement;
  const sidebar = document.getElementById('sidebar');
  const closeButton = document.getElementById('sidebarCloseButton');
  const overlay = document.getElementById('sidebarOverlay');
  let lockedScrollY = 0;
  let drawerLocked = false;
  let syncQueued = false;

  const isMobile = () => MOBILE.matches || COARSE.matches;

  function updateViewportUnit() {
    const viewport = window.visualViewport;
    const height = Math.max(320, Math.round(viewport?.height || window.innerHeight || document.documentElement.clientHeight || 0));
    root.style.setProperty('--lso-mobile-viewport', `${height}px`);
  }

  function lockDocumentForDrawer() {
    if (!isMobile() || drawerLocked) return;
    lockedScrollY = Math.max(0, window.scrollY || document.documentElement.scrollTop || 0);
    drawerLocked = true;
    body.dataset.lsoDrawerLocked = 'true';
    body.style.position = 'fixed';
    body.style.top = `-${lockedScrollY}px`;
    body.style.left = '0';
    body.style.right = '0';
    body.style.width = '100%';
    body.style.overflow = 'hidden';
  }

  function unlockDocumentFromDrawer() {
    if (!drawerLocked && body.dataset.lsoDrawerLocked !== 'true') return;
    const top = Number.parseFloat(body.style.top || '0');
    const restoreY = Number.isFinite(top) && top < 0 ? Math.abs(top) : lockedScrollY;
    drawerLocked = false;
    delete body.dataset.lsoDrawerLocked;
    ['position', 'top', 'left', 'right', 'width', 'overflow', 'overflow-y'].forEach((property) => body.style.removeProperty(property));
    requestAnimationFrame(() => window.scrollTo({ top: restoreY, left: 0, behavior: 'auto' }));
  }

  function syncDrawerState({ focusClose = false } = {}) {
    if (!sidebar) return;
    const open = isMobile() && sidebar.classList.contains('open');
    body.classList.toggle('sidebar-open', open);
    sidebar.setAttribute('aria-hidden', open ? 'false' : 'true');
    overlay?.setAttribute('aria-hidden', open ? 'false' : 'true');
    if (open) {
      lockDocumentForDrawer();
      if (focusClose) requestAnimationFrame(() => closeButton?.focus({ preventScroll: true }));
    } else {
      unlockDocumentFromDrawer();
    }
  }

  function queueSync(options) {
    if (syncQueued) return;
    syncQueued = true;
    requestAnimationFrame(() => {
      syncQueued = false;
      updateViewportUnit();
      syncDrawerState(options);
    });
  }

  function closeDrawer() {
    sidebar?.classList.remove('open');
    queueSync();
  }

  function wire() {
    updateViewportUnit();
    syncDrawerState();

    document.getElementById('mobileMenuButton')?.addEventListener('click', () => queueSync({ focusClose: true }));
    closeButton?.addEventListener('click', closeDrawer);
    overlay?.addEventListener('click', closeDrawer);

    document.addEventListener('click', (event) => {
      if (event.target.closest('.sidebar .nav-item')) closeDrawer();
    });

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && sidebar?.classList.contains('open')) closeDrawer();
    });

    if (sidebar && window.MutationObserver) {
      new MutationObserver(() => queueSync()).observe(sidebar, { attributes: true, attributeFilter: ['class'] });
    }

    window.addEventListener('resize', () => {
      updateViewportUnit();
      if (!isMobile()) closeDrawer();
    }, { passive: true });
    window.addEventListener('orientationchange', () => window.setTimeout(() => queueSync(), 180), { passive: true });
    window.visualViewport?.addEventListener('resize', updateViewportUnit, { passive: true });

    ['lso:auth-changed', 'lso:view-changed'].forEach((name) => {
      window.addEventListener(name, () => window.setTimeout(() => {
        closeDrawer();
        updateViewportUnit();
      }, 30));
    });

    window.addEventListener('pageshow', () => {
      if (!sidebar?.classList.contains('open')) {
        body.classList.remove('sidebar-open');
        unlockDocumentFromDrawer();
      }
      updateViewportUnit();
    });
  }

  window.LSOMobileShell = Object.freeze({
    closeDrawer,
    sync: queueSync,
    updateViewport: updateViewportUnit
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire, { once: true });
  else wire();
})();
