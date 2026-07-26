'use strict';

const CACHE_VERSION = 'lso-website-enterprise-v32';
const SHELL_CACHE = `${CACHE_VERSION}-shell`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;
const SCOPE = new URL('./', self.location.href);
const APP_SHELL = new URL('index.html', SCOPE).toString();

const CORE_PATHS = [
  './', './index.html', './manifest.webmanifest',
  './styles.css', './website-enhancements.css', './duty-punch-state-sync-display.css',
  './duty-punch-organized-v10.css', './duty-mobile-input-v32.css', './attendance-month-workspace-v2.css',
  './duty-roster-layout.css', './access-control.css', './branding.css', './login-page.css',
  './login-logo-3d-v1.css', './login-mobile-compat-v3.css', './lso-original-color-contrast-v1.css',
  './lso-modern-lasallian-emerald-v2.css', './lso-accessible-contrast-v4.css',
  './lso-login-color-final-v6.css', './contract-maker-v3.css', './dashboard-v2.css',
  './dashboard-command-center-v4.css', './monthly-report.css', './system-enterprise-v1.css',
  './supabase-config.js', './branding.js', './branding-print-fullbleed-v31.js', './lso-system-core-v2.js', './role-access-v3.js',
  './cloud-staff-v2.js', './cloud-staff-v3.js', './cloud-staff-v4.js', './app-member-information-v5.js', './auth-view-controller-v18.js', './auth.js',
  './management-attendance-member-info-v3.js', './ui-enhancements.js', './dashboard-enhancements.js',
  './renderall-compat-v25.js', './workflow-attendance-month-v2.js', './workflow-attendance-month-v3.js', './workflow-attendance-month-v4.js', './workflow-attendance-month-v5.js', './attendance-governance.js', './duty-hours-member-info-v12.js', './duty-hours-member-info-v13.js',
  './pdf-lib.min.js', './monthly-report-template-data.js', './monthly-report.js', './monthly-report-print-v31.js',
  './contract-template-data.js', './contract-maker-membership-v4.js',
  './dashboard-intelligence-member-info-v3.js', './permissions-staff-v2.js', './dashboard-command-center-v5.js',
  './login-logo-3d-v1.js', './system-enterprise-v1.js', './pwa-enterprise-v32.js',
  './favicon.ico', './favicon-32x32.png', './apple-touch-icon.png',
  './android-chrome-192x192.png', './android-chrome-512x512.png', './maskable-icon-512x512.png',
  './lso-logo.png', './lso-login-logo.png', './lso-mark.png',
  './lso-official-template.png', './lso-official-template.pdf',
  './lso-official-header.png', './lso-official-footer.png', './lso-contract-template.pdf'
];

const CORE_URLS = CORE_PATHS.map((path) => new URL(path, SCOPE).toString());

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    for (const url of CORE_URLS) {
      try {
        const response = await fetch(url, { cache: 'reload' });
        if (response.ok) await cache.put(url, response);
      } catch {
        // One missing optional asset must not prevent the new worker from installing.
      }
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((key) => key.startsWith('lso-website-') && ![SHELL_CACHE, RUNTIME_CACHE].includes(key)).map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

async function networkFirst(request) {
  const cache = await caches.open(RUNTIME_CACHE);
  try {
    const response = await fetch(request, { cache: 'no-store' });
    if (response?.ok) await cache.put(request, response.clone());
    return response;
  } catch {
    return (await cache.match(request)) || (await caches.match(request)) || (request.mode === 'navigate' ? await caches.match(APP_SHELL) : null) || Response.error();
  }
}

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response && (response.ok || response.type === 'opaque')) {
    const cache = await caches.open(RUNTIME_CACHE);
    await cache.put(request, response.clone());
  }
  return response;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.hostname.endsWith('.supabase.co')) return;
  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(request));
    return;
  }
  if (url.hostname === 'cdn.jsdelivr.net') {
    event.respondWith(networkFirst(request));
    return;
  }
  if (url.origin === self.location.origin && /\/workflow-attendance-month-v[234]\.js$/i.test(url.pathname)) {
    const fixedUrl = new URL('./workflow-attendance-month-v5.js', SCOPE).toString();
    event.respondWith(networkFirst(new Request(fixedUrl, { cache: 'no-store', credentials: 'same-origin' })));
    return;
  }
  if (url.origin === self.location.origin) {
    const mustBeFresh = /\.(?:js|css|html|webmanifest)$/i.test(url.pathname);
    event.respondWith(mustBeFresh ? networkFirst(request) : cacheFirst(request));
  }
});

self.addEventListener('message', (event) => {
  if (event.data?.type === 'SKIP_WAITING') self.skipWaiting();
});
