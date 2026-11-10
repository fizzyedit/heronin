const CACHE = 'heronin-shell-v2';
const ROOT = '/heronin/';
const SHELL = [ROOT, ROOT + 'index.html', ROOT + 'manifest.webmanifest',
  ROOT + 'NotoSansKR-Regular.ttf'];
// Program files are cached on demand with the page's exact cache-busting URLs.
async function store(cache, request, response) {
  await cache.put(request, response);
  const url = new URL(request.url);
  for (const key of await cache.keys()) {
    const old = new URL(key.url);
    if (old.origin === url.origin && old.pathname === url.pathname &&
        old.search !== url.search) await cache.delete(key);
  }
}
async function networkFirst(request) {
  const cache = await caches.open(CACHE);
  try {
    const response = await fetch(request, {cache: 'no-store'});
    if (response.ok) await store(cache, request, response.clone());
    return response;
  } catch {
    return (await cache.match(request)) ||
      (request.mode === 'navigate' && await cache.match(ROOT + 'index.html')) ||
      Response.error();
  }
}
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
    event.respondWith(networkFirst(event.request));
    return;
  }
  event.respondWith(caches.open(CACHE).then(async cache => {
    // Keep the query string: a new deploy's cache buster must fetch new bytes.
    const cached = await cache.match(event.request);
    if (cached) return cached;
    const response = await fetch(event.request);
    if (response.ok) await store(cache, event.request, response.clone());
    return response;
  }));
});
