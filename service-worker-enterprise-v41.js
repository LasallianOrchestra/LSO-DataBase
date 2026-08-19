'use strict';

const CACHE_VERSION = 'lso-website-enterprise-v82-all-roles-supabase-r1';
const SHELL_CACHE = `${CACHE_VERSION}-shell`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;
const SCOPE = new URL('./', self.location.href);
const APP_SHELL = new URL('index.html', SCOPE).toString();

const CORE_PATHS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './lso-ui-bundle-v73.css',
  './supabase-config.js',
  './branding-print-fullbleed-v31.js',
  './lso-system-core-v4.js',
  './runtime-stability-v54.js',
  './role-access-v6.js',
  './cloud-staff-v8.js',
  './app-member-information-v5.js',
  './auth-view-controller-v18.js',
  './auth.js',
  './maintenance-mode-v62.js',
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
  './interview-manager-v5.js',
  './official-pdf-assets-v51.js',
  './member-photo-v73.js',
  './platform-upgrade-v70.js',
  './dashboard-intelligence-member-info-v3.js',
  './permissions-dynamic-v38.js',
  './dashboard-command-center-v5.js',
  './login-logo-3d-v1.js',
  './system-enterprise-v2.js',
  './mobile-shell-controller-v37.js',
  './role-permission-center-v39.js',
  './operations-governance-v61.js',
  './pwa-enterprise-v41.js',
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
  if (url.origin === self.location.origin && /\/(?:workflow-attendance-month-v[2-7]|management-attendance-member-info-v3|attendance-governance|duty-hours-member-info-v1[12]|auth-view-controller-v17|cloud-staff-v[3-7]|role-access-v[3-5]|lso-system-core-v3|permissions-staff-v2|system-enterprise-v1|platform-upgrade-v69|role-permission-center-v38|pwa-enterprise-v(?:38|39|40))\.js$/i.test(url.pathname)) {
    const redirects = [
      [/workflow-attendance-month/i, './workflow-attendance-month-v6.js'],
      [/management-attendance/i, './management-attendance-member-info-v4.js'],
      [/attendance-governance/i, './attendance-governance-v2.js'],
      [/duty-hours-member/i, './duty-hours-member-info-v14.js'],
      [/auth-view-controller/i, './auth-view-controller-v18.js'],
      [/cloud-staff/i, './cloud-staff-v8.js'],
      [/role-access/i, './role-access-v6.js'],
      [/role-permission-center/i, './role-permission-center-v39.js'],
      [/lso-system-core/i, './lso-system-core-v4.js'],
      [/permissions-staff/i, './permissions-dynamic-v38.js'],
      [/system-enterprise/i, './system-enterprise-v2.js'],
      [/platform-upgrade/i, './platform-upgrade-v70.js'],
      [/pwa-enterprise/i, './pwa-enterprise-v41.js']
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
