(() => {
  'use strict';

  const ACTIVE_WORKER = 'service-worker-enterprise-v37.js';
  const ACTIVE_CACHE_MARKER = 'enterprise-v37';
  const installButton = document.getElementById('installAppButton');
  const connectionBanner = document.getElementById('connectionBanner');
  let deferredPrompt = null;
  let controllerReloaded = false;

  function standalone() {
    return window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true;
  }

  function banner(message, state = 'offline', timeout = 0) {
    if (!connectionBanner) return;
    connectionBanner.textContent = message;
    connectionBanner.dataset.state = state;
    connectionBanner.classList.remove('hidden');
    if (timeout) window.setTimeout(() => connectionBanner.classList.add('hidden'), timeout);
  }

  function updateConnection() {
    if (navigator.onLine) {
      banner('Connection restored. Refreshing shared records…', 'online', 2400);
      window.LSOCloud?.loadSharedState?.({ quiet: true }).catch(() => undefined);
    } else {
      banner('You are offline. Viewing cached screens only; database changes require a connection.', 'offline');
    }
  }

  function wireInstall() {
    if (!installButton || standalone()) return;
    window.addEventListener('beforeinstallprompt', (event) => {
      event.preventDefault();
      deferredPrompt = event;
      installButton.classList.remove('hidden');
    });
    installButton.addEventListener('click', async () => {
      if (!deferredPrompt) return;
      deferredPrompt.prompt();
      await deferredPrompt.userChoice;
      deferredPrompt = null;
      installButton.classList.add('hidden');
    });
    window.addEventListener('appinstalled', () => {
      deferredPrompt = null;
      installButton.classList.add('hidden');
      window.LSOApp?.showToast?.('LSO System installed successfully.');
    });
  }

  async function removeObsoleteWorkersAndCaches() {
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.filter((registration) => {
        const script = registration.active?.scriptURL || registration.waiting?.scriptURL || registration.installing?.scriptURL || '';
        return script && !script.includes(ACTIVE_WORKER);
      }).map((registration) => registration.unregister()));
    } catch { /* continue with the current page */ }
    try {
      const keys = await caches.keys();
      await Promise.all(keys.filter((key) => key.startsWith('lso-website-') && !key.includes(ACTIVE_CACHE_MARKER)).map((key) => caches.delete(key)));
    } catch { /* cache storage can be unavailable in private mode */ }
  }

  async function registerWorker() {
    if (!('serviceWorker' in navigator)) return;
    const secure = window.isSecureContext || ['localhost', '127.0.0.1'].includes(location.hostname);
    if (!secure) return;
    await removeObsoleteWorkersAndCaches();
    try {
      const registration = await navigator.serviceWorker.register(`./${ACTIVE_WORKER}`, { scope: './', updateViaCache: 'none' });
      await registration.update();
      if (registration.waiting) registration.waiting.postMessage({ type: 'SKIP_WAITING' });
      registration.addEventListener('updatefound', () => {
        const worker = registration.installing;
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'installed' && navigator.serviceWorker.controller) {
            banner('A mobile navigation and scrolling update is ready. Applying it now…', 'online');
            worker.postMessage({ type: 'SKIP_WAITING' });
          }
        });
      });
      navigator.serviceWorker.addEventListener('controllerchange', () => {
        if (controllerReloaded) return;
        controllerReloaded = true;
        window.location.reload();
      });
    } catch (error) {
      console.warn('LSO service worker registration failed:', error);
      window.LSOEnterprise?.reportError?.({
        module: 'Progressive Web App',
        publicMessage: 'Offline installation could not be updated. The online website remains available.',
        technicalMessage: error.message,
        errorCode: 'PWA-UPDATE-010'
      }, { show: false });
    }
  }

  window.addEventListener('online', updateConnection);
  window.addEventListener('offline', updateConnection);
  wireInstall();
  registerWorker();
  if (!navigator.onLine) updateConnection();
})();
