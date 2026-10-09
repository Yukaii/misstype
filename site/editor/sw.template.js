// Generated into dist/editor/sw.js by vite.config.js, which fills in the
// precache list and cache version. Everything is same-origin and
// local: nothing typed ever reaches this file.
const CACHE = "misstype-editor-__VERSION__";
const ROOT = new URL("../", self.location.href);
const PRECACHE = __PRECACHE__.map((path) => new URL(path, ROOT).href);
const SHELL = new URL("./", self.location.href).href;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("misstype-editor-") && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Cached copy first so the editor opens instantly and offline; the network
// copy refreshes the cache for the next visit.
self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const hit = await cache.match(request, { ignoreSearch: true })
      || (request.mode === "navigate" ? await cache.match(SHELL) : undefined);
    const refresh = fetch(request).then((response) => {
      if (response.ok && response.type === "basic") cache.put(request, response.clone());
      return response;
    });
    if (hit) {
      refresh.catch(() => {});
      return hit;
    }
    return refresh;
  })());
});
