const CACHE_NAME = 'archive-v1';
// Derive base from SW location: https://host/xbafcrxg-yvoenel/
const BASE = new URL('.', self.location).href;

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll([BASE, BASE + 'index.html']))
      .then(() => precacheSitemap())
  );
});

async function precacheSitemap() {
  try {
    const resp = await fetch(BASE + 'sitemap.xml', {cache: 'no-store'});
    if (!resp.ok) throw new Error('sitemap ' + resp.status);
    const text = await resp.text();
    const urls = [...text.matchAll(/<loc>([^<]+)<\/loc>/g)].map(m => m[1]);
    const cache = await caches.open(CACHE_NAME);
    // Batch 8 at a time to avoid overwhelming the network
    for (let i = 0; i < urls.length; i += 8) {
      await Promise.all(
        urls.slice(i, i + 8).map(url =>
          fetch(url, {cache: 'no-store'})
            .then(r => { if (r.ok) return cache.put(url, r); })
            .catch(() => null)
        )
      );
    }
    console.log('[SW] precached', urls.length, 'URLs from sitemap');
  } catch (e) {
    console.error('[SW] precache failed:', e);
  }
}

self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      caches.keys().then(keys =>
        Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
      )
    ])
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  if (!event.request.url.startsWith(BASE)) return;

  event.respondWith(
    caches.match(event.request).then(cached => {
      // Background revalidation: always try to update cache
      const networkFetch = fetch(event.request)
        .then(response => {
          if (response.ok) {
            caches.open(CACHE_NAME).then(c => c.put(event.request, response.clone()));
          }
          return response;
        })
        .catch(() => null);

      // Serve from cache immediately; fall back to network if not cached
      return cached || networkFetch;
    })
  );
});
