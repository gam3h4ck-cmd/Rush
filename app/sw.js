// Rush · service worker: l'app si apre anche con connessione debole.
// Strategia: prima la rete, se manca usa la copia salvata. I dati (Supabase) non vengono mai salvati qui.
const CACHE = "rush-v7";
const SHELL = ["./", "index.html", "staff.html", "config.js", "vendor/supabase.js",
  "manifest.webmanifest", "manifest-staff.webmanifest", "badge.html", "manifest-badge.webmanifest", "icons/icon-192.png", "icons/icon-512.png"];
self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match("index.html")))
  );
});
