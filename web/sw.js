const CACHE = 'heronin-shell-v2';
const ROOT = '/heronin/';
const SHELL = [ROOT, ROOT + 'index.html', ROOT + 'manifest.webmanifest',
  ROOT + 'fizzy.js', ROOT + 'web.js', ROOT + 'web.wasm',
  ROOT + 'fizzy-worker.js', ROOT + 'NotoSansKR-Regular.ttf'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key !== CACHE).map(key => caches.delete(key))
  )).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin ||
      !url.pathname.startsWith(ROOT)) return;
  if (event.request.mode === 'navigate' || url.pathname === ROOT ||
      url.pathname === ROOT + 'index.html' || url.pathname === ROOT + 'build.json') {
    event.respondWith(fetch(event.request, {cache: 'no-store'}).then(async response => {
      if (response.ok) {
        const cache = await caches.open(CACHE);
        await cache.put(event.request, response.clone());
      }
      return response;
    }).catch(() => caches.open(CACHE).then(cache => cache.match(event.request))
      .then(response => response || Response.error())));
    return;
  }
  event.respondWith(caches.open(CACHE).then(async cache => {
    const cached = await cache.match(event.request);
    if (cached) return cached;
    const response = await fetch(event.request);
    if (response.ok) await cache.put(event.request, response.clone());
    return response;
  }));
});
