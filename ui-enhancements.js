(() => {
  'use strict';

  const el = (id) => document.getElementById(id);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];

  function updateCloudStatus(event) {
    const text = el('systemStatusText');
    const statusBox = text?.closest('.topbar-status');
    if (!text || !event?.detail) return;
    text.textContent = event.detail.message || 'Shared database';
    if (statusBox) statusBox.dataset.status = event.detail.kind || 'offline';
  }

  function updateCurrentDate() {
    const target = el('currentDateLabel');
    if (!target) return;
    target.textContent = new Intl.DateTimeFormat('en-PH', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric'
    }).format(new Date());
  }

  function closeSidebar() {
    el('sidebar')?.classList.remove('open');
    document.body.classList.remove('sidebar-open');
  }

  function syncSidebarState() {
    const isOpen = Boolean(el('sidebar')?.classList.contains('open'));
    document.body.classList.toggle('sidebar-open', isOpen && window.innerWidth <= 920);
  }

  function wireResponsiveNavigation() {
    el('mobileMenuButton')?.addEventListener('click', () => requestAnimationFrame(syncSidebarState));
    el('sidebarCloseButton')?.addEventListener('click', closeSidebar);
    el('sidebarOverlay')?.addEventListener('click', closeSidebar);
    qsa('.nav-item').forEach((button) => button.addEventListener('click', closeSidebar));

    const sidebar = el('sidebar');
    if (sidebar && window.MutationObserver) {
      new MutationObserver(syncSidebarState).observe(sidebar, { attributes: true, attributeFilter: ['class'] });
    }

    let resizeFrame = 0;
    window.addEventListener('resize', () => {
      if (resizeFrame) return;
      resizeFrame = requestAnimationFrame(() => {
        resizeFrame = 0;
        if (window.innerWidth > 920) closeSidebar();
        refreshTableHints();
      });
    }, { passive: true });

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && sidebar?.classList.contains('open')) closeSidebar();
    });
  }

  function getHeaderLabels(table) {
    return qsa('thead th', table).map((header) => header.textContent.trim().replace(/\s+/g, ' '));
  }

  function applyCellLabels(table) {
    const labels = getHeaderLabels(table);
    if (!labels.length) return;

    qsa('tbody tr', table).forEach((row) => {
      qsa(':scope > td', row).forEach((cell, index) => {
        if (cell.hasAttribute('colspan')) return;
        cell.dataset.label = labels[index] || 'Details';
      });
    });
  }

  function addTableAccessibility(wrapper, index) {
    if (!wrapper.hasAttribute('tabindex')) wrapper.tabIndex = 0;
    if (!wrapper.hasAttribute('role')) wrapper.setAttribute('role', 'region');
    if (!wrapper.hasAttribute('aria-label')) wrapper.setAttribute('aria-label', `Scrollable data table ${index + 1}`);

    if (!wrapper.nextElementSibling?.classList.contains('table-scroll-hint')) {
      const hint = document.createElement('p');
      hint.className = 'table-scroll-hint';
      hint.textContent = 'Scroll sideways to view additional columns.';
      wrapper.insertAdjacentElement('afterend', hint);
    }
  }

  function refreshTableHints(wrappers = qsa('.table-wrap, .period-table-wrap')) {
    wrappers.forEach((wrapper) => {
      const hint = wrapper.nextElementSibling?.classList.contains('table-scroll-hint') ? wrapper.nextElementSibling : null;
      if (!hint) return;
      const needsHorizontalScroll = window.innerWidth > 760 && wrapper.scrollWidth > wrapper.clientWidth + 2;
      hint.style.display = needsHorizontalScroll ? 'block' : 'none';
    });
  }

  const pendingTables = new Set();
  const pendingWrappers = new Set();
  let tableRefreshFrame = 0;

  function collectTableTargets(root = document) {
    if (root === document) {
      qsa('table').forEach((table) => pendingTables.add(table));
      qsa('.table-wrap, .period-table-wrap').forEach((wrapper) => pendingWrappers.add(wrapper));
      return;
    }
    if (!(root instanceof Element)) return;
    if (root.matches('table')) pendingTables.add(root);
    root.closest('table') && pendingTables.add(root.closest('table'));
    qsa('table', root).forEach((table) => pendingTables.add(table));
    if (root.matches('.table-wrap, .period-table-wrap')) pendingWrappers.add(root);
    root.closest('.table-wrap, .period-table-wrap') && pendingWrappers.add(root.closest('.table-wrap, .period-table-wrap'));
    qsa('.table-wrap, .period-table-wrap', root).forEach((wrapper) => pendingWrappers.add(wrapper));
  }

  function enhanceTables(root = document) {
    collectTableTargets(root);
    if (tableRefreshFrame) return;
    tableRefreshFrame = requestAnimationFrame(() => {
      tableRefreshFrame = 0;
      const tables = [...pendingTables].filter((table) => table.isConnected);
      const wrappers = [...pendingWrappers].filter((wrapper) => wrapper.isConnected);
      pendingTables.clear();
      pendingWrappers.clear();
      tables.forEach(applyCellLabels);
      wrappers.forEach((wrapper, index) => addTableAccessibility(wrapper, index));
      refreshTableHints(wrappers);
    });
  }

  function wireTableEnhancement() {
    enhanceTables(document);
    if (!window.MutationObserver) return;
    const observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        if (mutation.type !== 'childList') return;
        collectTableTargets(mutation.target);
        mutation.addedNodes.forEach((node) => collectTableTargets(node));
      });
      if (pendingTables.size || pendingWrappers.size) enhanceTables();
    });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  function updatePendingAccountBadge() {
    const badge = el('pendingAccountCount');
    if (!badge) return;
    const accounts = window.LSOAuth?.loadAccounts?.() || [];
    const count = accounts.filter((account) => account.approvalStatus === 'Pending' && !account.isDefault).length;
    badge.textContent = String(count);
    badge.classList.toggle('hidden', count === 0);
    badge.setAttribute('aria-label', `${count} pending account registration${count === 1 ? '' : 's'}`);
  }

  function wireAccountBadge() {
    updatePendingAccountBadge();
    window.addEventListener('lso:accounts-changed', updatePendingAccountBadge);
    window.addEventListener('lso:auth-changed', updatePendingAccountBadge);
  }

  function enhanceButtons(root = document) {
    const buttons = [];
    if (root instanceof Element && root.matches('.table-action')) buttons.push(root);
    qsa('.table-action', root).forEach((button) => buttons.push(button));
    buttons.forEach((button) => {
      if (!button.getAttribute('aria-label')) {
        const label = button.title || button.textContent.trim() || 'Record action';
        button.setAttribute('aria-label', label);
      }
    });
  }

  function wireDynamicButtonEnhancement() {
    enhanceButtons();
    if (!window.MutationObserver) return;
    new MutationObserver((mutations) => {
      mutations.forEach((mutation) => mutation.addedNodes.forEach((node) => {
        if (node.nodeType === Node.ELEMENT_NODE) enhanceButtons(node);
      }));
    }).observe(document.body, { childList: true, subtree: true });
  }

  function initialize() {
    updateCurrentDate();
    wireResponsiveNavigation();
    wireTableEnhancement();
    wireAccountBadge();
    wireDynamicButtonEnhancement();
    window.addEventListener('lso:cloud-status', updateCloudStatus);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
