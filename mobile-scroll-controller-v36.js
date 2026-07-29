(() => {
  'use strict';

  const MOBILE_QUERY = window.matchMedia('(max-width: 920px)');
  const COARSE_QUERY = window.matchMedia('(pointer: coarse)');
  const root = document.documentElement;
  const body = document.body;
  let repairQueued = false;

  const visible = (node) => {
    if (!node || node.hidden || node.classList.contains('hidden')) return false;
    const style = window.getComputedStyle(node);
    return style.display !== 'none' && style.visibility !== 'hidden';
  };

  function isMobileTouch() {
    return MOBILE_QUERY.matches || COARSE_QUERY.matches;
  }

  function updateViewportHeight() {
    const height = Math.max(320, Math.round(window.visualViewport?.height || window.innerHeight || 0));
    root.style.setProperty('--lso-mobile-vh', `${height}px`);
  }

  function blockingOverlayIsOpen() {
    const sidebarOpen = body.classList.contains('sidebar-open') && document.getElementById('sidebar')?.classList.contains('open');
    if (sidebarOpen) return true;
    const selectors = [
      '.modal-backdrop:not(.hidden)',
      '.dcc-modal:not(.hidden)',
      '.monthly-report-audit-panel:not(.hidden)',
      '#systemErrorDialog:not(.hidden)',
      '#accessibilityDrawer:not(.hidden)'
    ];
    return selectors.some((selector) => [...document.querySelectorAll(selector)].some(visible));
  }

  function clearStaleScrollLock() {
    if (!isMobileTouch()) return;

    const sidebar = document.getElementById('sidebar');
    if (body.classList.contains('sidebar-open') && !sidebar?.classList.contains('open')) {
      body.classList.remove('sidebar-open');
    }

    if (blockingOverlayIsOpen()) return;

    const inlineOverflow = body.style.getPropertyValue('overflow').trim().toLowerCase();
    const inlineOverflowY = body.style.getPropertyValue('overflow-y').trim().toLowerCase();
    if (['hidden', 'clip'].includes(inlineOverflow)) body.style.removeProperty('overflow');
    if (['hidden', 'clip'].includes(inlineOverflowY)) body.style.removeProperty('overflow-y');
    body.classList.remove('modal-open', 'no-scroll', 'scroll-locked');
  }

  function repairScrollState() {
    if (repairQueued) return;
    repairQueued = true;
    requestAnimationFrame(() => {
      repairQueued = false;
      updateViewportHeight();
      clearStaleScrollLock();
    });
  }

  function keepFocusedFieldVisible(target) {
    if (!isMobileTouch() || !target?.matches?.('input, select, textarea, [contenteditable="true"]')) return;
    window.setTimeout(() => {
      if (document.activeElement !== target) return;
      const viewportHeight = window.visualViewport?.height || window.innerHeight;
      const topGuard = 74;
      const bottomGuard = Math.max(20, Math.min(120, viewportHeight * 0.12));
      const rect = target.getBoundingClientRect();
      if (rect.top < topGuard || rect.bottom > viewportHeight - bottomGuard) {
        target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
      }
    }, 280);
  }

  function wire() {
    updateViewportHeight();
    clearStaleScrollLock();

    window.addEventListener('resize', repairScrollState, { passive: true });
    window.addEventListener('orientationchange', () => window.setTimeout(repairScrollState, 180), { passive: true });
    window.visualViewport?.addEventListener('resize', updateViewportHeight, { passive: true });
    window.visualViewport?.addEventListener('scroll', clearStaleScrollLock, { passive: true });

    document.addEventListener('focusin', (event) => keepFocusedFieldVisible(event.target), { passive: true });
    document.addEventListener('touchend', clearStaleScrollLock, { passive: true });
    document.addEventListener('click', (event) => {
      if (event.target.closest('.nav-item, #sidebarCloseButton, #sidebarOverlay, [data-view], [data-jump]')) {
        window.setTimeout(repairScrollState, 40);
      }
    }, { passive: true });

    ['lso:auth-changed', 'lso:view-changed', 'lso:state-updated', 'lso:data-changed'].forEach((name) => {
      window.addEventListener(name, () => window.setTimeout(repairScrollState, 30));
    });

    if (window.MutationObserver) {
      const observer = new MutationObserver((mutations) => {
        const relevant = mutations.some((mutation) => mutation.type === 'attributes' || mutation.addedNodes.length || mutation.removedNodes.length);
        if (relevant) repairScrollState();
      });
      observer.observe(body, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ['class', 'hidden', 'style', 'aria-hidden']
      });
    }
  }

  window.LSOMobileScroll = Object.freeze({
    repair: repairScrollState,
    clearStaleLock: clearStaleScrollLock,
    updateViewportHeight
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire, { once: true });
  else wire();
})();
