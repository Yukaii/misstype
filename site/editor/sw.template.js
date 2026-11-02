// Generated into dist/editor/sw.js by vite.config.js, which fills in the
// precache list and cache version. Everything is same-origin and
// local: nothing typed ever reaches this file.
const CACHE = "misstype-editor-__VERSION__";
const ROOT = new URL("../", self.location.href);
const PRECACHE = __PRECACHE__.map((path) => new URL(path, ROOT).href);
const SHELL = new URL("./", self.location.href).href;
/** True when an older worker was active: this is an update, not a first install. */
let updating = false;

self.addEventListener("install", (event) => {
  updating = Boolean(self.registration.active);
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // `cache.addAll` uses the HTTP cache, so a just-deployed HTML can be
    // precached stale and point at a JS hash the new build no longer has.
    // Reload every entry from the network instead.
    await Promise.all(PRECACHE.map(async (url) => {
      const response = await fetch(url, { cache: "reload" });
      if (!response.ok) throw new Error(`precache ${url}: HTTP ${response.status}`);
      await cache.put(url, response);
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith("misstype-editor-") && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
  // Pages already open keep the old bundle until they navigate; an updated
  // worker reloads them once so the new JS and IME fixes take effect. Do not
  // await this inside `activate`: the navigation waits for activation, so
  // awaiting it deadlocks the first load.
  if (!updating) return;
  self.clients.matchAll({ type: "window" }).then((windows) => {
    for (const client of windows) client.navigate(client.url).catch(() => {});
  });
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
    // A navigation must not come from the HTTP cache either: its asset hashes
    // change on every deploy, and the SW cache is the offline copy.
    const refresh = fetch(request, request.mode === "navigate" ? { cache: "reload" } : undefined).then((response) => {
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
