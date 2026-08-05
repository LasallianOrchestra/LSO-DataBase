'use strict';

const CACHE_VERSION = 'lso-website-enterprise-v60-end-to-end-debug1';
const SHELL_CACHE = `${CACHE_VERSION}-shell`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;
const SCOPE = new URL('./', self.location.href);
const APP_SHELL = new URL('index.html', SCOPE).toString();

const CORE_PATHS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './refresh-mobile-shell-v37.html',
  './refresh-role-permissions-v38.html',
  './styles.css',
  './duty-roster-layout.css',
  './access-control.css',
  './branding.css',
  './login-page.css',
  './login-logo-3d-v1.css',
  './contract-maker-v3.css',
  './dashboard-v2.css',
  './dashboard-command-center-v4.css',
  './monthly-report.css',
  './website-enhancements.css',
  './duty-punch-state-sync-display.css',
  './duty-punch-organized-v10.css',
  './attendance-month-workspace-v2.css',
  './login-mobile-compat-v3.css',
  './lso-original-color-contrast-v1.css',
  './lso-modern-lasallian-emerald-v2.css',
  './lso-accessible-contrast-v4.css',
  './lso-login-color-final-v6.css',
  './system-enterprise-v1.css',
  './role-permission-center-v38.css',
  './attendance-duty-revision-v35.css',
  './mobile-shell-scroll-v37.css',
  './ui-performance-responsive-v39.css',
  './workflow-accessibility-v41.css',
  './professional-interface-v43.css',
  './cross-device-accessibility-v44.css',
  './smooth-motion-v1.css',
  './member-overall-record-v49.css',
  './governance-archives-v50.css',
  './targeted-repairs-v51.css',
  './device-performance-v52.css',
  './attendance-stability-v53.css',
  './runtime-stability-v54.css',
  './attendance-semester-stability-v55.css',
  './attendance-archive-workflow-v56.css',
  './attendance-workflow-v58.css',
  './supabase-config.js',
  './branding-print-fullbleed-v31.js',
  './lso-system-core-v4.js',
  './runtime-stability-v54.js',
  './role-access-v4.js',
  './cloud-staff-v5.js',
  './app-member-information-v5.js',
  './auth-view-controller-v18.js',
  './auth.js',
  './management-attendance-member-info-v4.js',
  './ui-enhancements.js',
  './dashboard-enhancements.js',
  './renderall-compat-v25.js',
  './workflow-attendance-month-v6.js',
  './attendance-governance-v2.js',
  './attendance-workflow-v58.js',
  './duty-hours-member-info-v14.js',
  './pdf-lib.min.js',
  './monthly-report-template-data.js',
  './monthly-report-print-v31.js',
  './contract-template-data.js',
  './contract-maker-membership-v4.js',
  './official-pdf-assets-v51.js',
  './member-overall-record-v49.js',
  './dashboard-intelligence-member-info-v3.js',
  './permissions-dynamic-v38.js',
  './dashboard-command-center-v5.js',
  './login-logo-3d-v1.js',
  './system-enterprise-v2.js',
  './mobile-shell-controller-v37.js',
  './role-permission-center-v38.js',
  './pwa-enterprise-v38.js',
  './favicon.ico',
  './favicon-32x32.png',
  './apple-touch-icon.png',
  './android-chrome-192x192.png',
  './android-chrome-512x512.png',
  './maskable-icon-512x512.png',
  './lso-logo.png',
  './lso-login-logo.png',
  './lso-mark.png',
  './lso-official-template.png',
  './lso-official-template.pdf',
  './lso-official-header.png',
  './lso-official-footer.png',
  './lso-contract-template.pdf'
];
const CORE_URLS = CORE_PATHS.map((path) => new URL(path, SCOPE).toString());

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    for (const url of CORE_URLS) {
      try {
        const response = await fetch(url, { cache: 'reload' });
        if (response.ok) await cache.put(url, response);
      } catch { /* one optional asset must not block activation */ }
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
  if (request.mode === 'navigate') return void event.respondWith(networkFirst(request));
  if (url.hostname === 'cdn.jsdelivr.net') return void event.respondWith(networkFirst(request));
  if (url.origin === self.location.origin && /\/(?:workflow-attendance-month-v[2-7]|management-attendance-member-info-v3|attendance-governance|duty-hours-member-info-v1[12]|auth-view-controller-v17|cloud-staff-v[34]|role-access-v3|lso-system-core-v3|permissions-staff-v2|system-enterprise-v1)\.js$/i.test(url.pathname)) {
    const redirects = [
      [/workflow-attendance-month/i, './workflow-attendance-month-v6.js'],
      [/management-attendance/i, './management-attendance-member-info-v4.js'],
      [/attendance-governance/i, './attendance-governance-v2.js'],
      [/duty-hours-member/i, './duty-hours-member-info-v14.js'],
      [/auth-view-controller/i, './auth-view-controller-v18.js'],
      [/cloud-staff/i, './cloud-staff-v5.js'],
      [/role-access/i, './role-access-v4.js'],
      [/lso-system-core/i, './lso-system-core-v4.js'],
      [/permissions-staff/i, './permissions-dynamic-v38.js'],
      [/system-enterprise/i, './system-enterprise-v2.js']
    ];
    const target = redirects.find(([pattern]) => pattern.test(url.pathname))?.[1];
    if (target) return void event.respondWith(networkFirst(new Request(new URL(target, SCOPE), { cache: 'no-store', credentials: 'same-origin' })));
  }
  if (url.origin === self.location.origin) {
    const mustBeFresh = /\.(?:js|css|html|webmanifest)$/i.test(url.pathname);
    event.respondWith(mustBeFresh ? networkFirst(request) : cacheFirst(request));
  }
});
self.addEventListener('message', (event) => { if (event.data?.type === 'SKIP_WAITING') self.skipWaiting(); });
