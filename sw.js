/* ============================================================
   ANAM BARBERSHOP — Service Worker v1
   - Cache-first untuk asset statis (HTML/CSS/JS/font) → offline
   - Network-first untuk API Supabase (gak boleh stale)
   - Fallback: index.html saat offline
   ============================================================ */
const CACHE = 'anam-v1';
const CORE = [
  './',
  './index.html',
  './manifest.webmanifest'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // network-first untuk Supabase & WA
  if (url.hostname.includes('supabase.co') || url.hostname.includes('wa.me')) return;
  // cache-first untuk semuanya (statis)
  e.respondWith(
    caches.match(e.request).then(cached => {
      const fetchP = fetch(e.request).then(res => {
        if (res && res.status === 200 && res.type === 'basic') {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => caches.match('./index.html'));
      return cached || fetchP;
    })
  );
});

self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});
