// Minimal app-shell service worker for the kiosk PWA.
//
// App-shell caching only — every kiosk screen needs a live Supabase call
// anyway (stock, coupons, finalizing a sale), so there is no offline
// sale-recording mode here. This only makes kiosk.html itself and its own
// static assets load instantly on reopen/install, same as any installed app.
const CACHE_NAME = 'meensha-kiosk-shell-v1';
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

// Cache-first for the app shell's own same-origin assets only; everything
// else (Supabase REST/RPC/Edge Function calls, Google Fonts, product photos)
// goes straight to the network — never intercepted, never cached stale.
self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (!SHELL_ASSETS.some((path) => url.pathname.endsWith('/' + path) || url.pathname === '/' + path)) return;

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
