// Minimal app-shell service worker for the kiosk PWA.
//
// App-shell caching only — every kiosk screen needs a live Supabase call
// anyway (stock, coupons, finalizing a sale), so there is no offline
// sale-recording mode here. This only makes kiosk.html itself and its own
// static assets load instantly on reopen/install, same as any installed app.
//
// 2026-11-01: kiosk.html was cache-first with a CACHE_NAME that never
// changes between deploys, so an installed device's cached copy was never
// invalidated by a new deploy -- staff could be running JS from whenever
// they first opened the app, silently, with no way to tell (found when
// Shalini's app was missing menu items that had shipped weeks earlier).
// kiosk.html is now network-first (falls back to cache only when the
// network fetch fails, e.g. briefly offline) so every open picks up the
// live file when online; manifest/icons stay cache-first since they're
// static and the instant-load benefit still applies there. CACHE_NAME is
// also bumped so every device's stale v1 entry is dropped by the existing
// activate-handler cleanup below.
const CACHE_NAME = 'meensha-kiosk-shell-v2';
const NETWORK_FIRST_ASSETS = ['kiosk.html'];
const SHELL_ASSETS = [
  'kiosk.html',
  'manifest.json',
  'icons/icon-192.png',
  'icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    ).then(() => self.clients.claim())
  );
});

// Same-origin app-shell assets only; everything else (Supabase REST/RPC/Edge
// Function calls, Google Fonts, product photos) goes straight to the network
// — never intercepted, never cached stale.
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const match = SHELL_ASSETS.find((path) => url.pathname.endsWith('/' + path) || url.pathname === '/' + path);
  if (!match) return;

  if (NETWORK_FIRST_ASSETS.includes(match)) {
    event.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
        return res;
      }).catch(() => caches.match(req))
    );
    return;
  }

  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
        return res;
      });
    })
  );
});
